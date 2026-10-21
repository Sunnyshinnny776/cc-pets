#import "CCPetsUsage+Internal.h"
#import "CCPetsPaths.h"

#pragma mark - 按模型的用量

// 面向 UI 的统一口径：四栏互不重叠，加起来就是总 Token。
//   input      非缓存输入
//   cacheRead  缓存命中读
//   cacheWrite 缓存写入
//   output     输出
//   reasoning  输出里的推理 token（Codex 才有，是 output 的子集，不另外加）
//   requests   请求数
// 两家原始口径不同：Claude 的 input_tokens 不含缓存；Codex 的 cached_input_tokens 是
// input_tokens 的子集（input + output = total），所以 Codex 要先减掉缓存命中的部分。
static NSDictionary *ModelCountsMake(unsigned long long input, unsigned long long cacheRead,
    unsigned long long cacheWrite, unsigned long long output, unsigned long long reasoning,
    unsigned long long requests) {
    return @{@"input": @(input), @"cacheRead": @(cacheRead), @"cacheWrite": @(cacheWrite),
             @"output": @(output), @"reasoning": @(reasoning), @"requests": @(requests)};
}

static NSArray<NSString *> *ModelCountKeys(void) {
    return @[@"input", @"cacheRead", @"cacheWrite", @"output", @"reasoning", @"requests"];
}

static void AddModelCounts(NSMutableDictionary *target, NSDictionary *counts) {
    for (NSString *key in ModelCountKeys()) {
        target[key] = @([target[key] unsignedLongLongValue] + [counts[key] unsignedLongLongValue]);
    }
}

unsigned long long CCPetsTotalTokens(NSDictionary *counts) {
    return [counts[@"input"] unsignedLongLongValue] + [counts[@"cacheRead"] unsignedLongLongValue] +
        [counts[@"cacheWrite"] unsignedLongLongValue] + [counts[@"output"] unsignedLongLongValue];
}

static NSDictionary *ModelCountsFromCodexBucket(NSDictionary *bucket) {
    unsigned long long input = [bucket[@"input_tokens"] unsignedLongLongValue];
    unsigned long long cached = [bucket[@"cached_input_tokens"] unsignedLongLongValue];
    return ModelCountsMake(input >= cached ? input - cached : 0, cached,
        [bucket[@"cache_write_input_tokens"] unsignedLongLongValue],
        [bucket[@"output_tokens"] unsignedLongLongValue],
        [bucket[@"reasoning_output_tokens"] unsignedLongLongValue],
        [bucket[@"request_count"] unsignedLongLongValue]);
}

// [start, end) 里每个自然日的零点。
static NSArray<NSNumber *> *ModelUsageDayStarts(NSTimeInterval start, NSTimeInterval end) {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSMutableArray<NSNumber *> *days = [NSMutableArray array];
    NSDate *cursor = [calendar startOfDayForDate:[NSDate dateWithTimeIntervalSince1970:start]];
    while (cursor.timeIntervalSince1970 < end) {
        if (cursor.timeIntervalSince1970 >= start) [days addObject:@(cursor.timeIntervalSince1970)];
        NSDate *next = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:cursor options:0];
        if (!next) break;
        cursor = next;
    }
    return days;
}

// 按模型用量里"某一天"的键：当前时区下的日期 yyyy-MM-dd，不用零点时间戳。零点时间戳跟着
// 时区走，换了时区后同一天的键就变了——会话摘要缓存里的日桶和归档都是按当时的时区存的，
// 新时区下拿新零点去取会全部落空。先加 12 小时再取日期：旧时区的零点在偏差 ±12 小时以内的
// 新时区里仍然落在同一天，夏令时那一小时也一样。
static NSString *DayLabel(NSTimeInterval dayStart) {
    NSDateComponents *components = [NSCalendar.currentCalendar
        components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay
        fromDate:[NSDate dateWithTimeIntervalSince1970:dayStart + 43200]];
    return [NSString stringWithFormat:@"%04ld-%02ld-%02ld", (long)components.year,
        (long)components.month, (long)components.day];
}

// 日 -> 模型 -> 用量（统一口径），日是 DayLabel。Codex 直接取会话摘要里按模型分好的日桶；
// 摘要里的键是解析时那个时区的零点，在这里统一换成日期。
static NSDictionary<NSString *, NSDictionary *> *CodexModelDays(NSTimeInterval start,
    NSTimeInterval end, NSMutableDictionary *cache, NSURL *sessionsURL) {
    NSArray<NSURL *> *urls = RecentCodexSessionURLs(sessionsURL, start);
    NSString *startLabel = DayLabel(start);
    NSString *endLabel = DayLabel(end);
    NSMutableDictionary<NSString *, NSMutableDictionary *> *result = [NSMutableDictionary dictionary];
    for (NSURL *url in urls) {
        NSDictionary *summary = TokenSessionSummaryTracking(url, cache, YES);
        NSDictionary *modelDays = [summary[@"modelDays"] isKindOfClass:NSDictionary.class]
            ? summary[@"modelDays"] : nil;
        for (NSString *dayKey in modelDays) {
            NSString *label = DayLabel(dayKey.doubleValue);
            // yyyy-MM-dd 按字典序就是按时间序。
            if ([label compare:startLabel] == NSOrderedAscending ||
                [label compare:endLabel] != NSOrderedAscending) continue;
            NSMutableDictionary *perModel = result[label];
            if (!perModel) {
                perModel = [NSMutableDictionary dictionary];
                result[label] = perModel;
            }
            for (NSString *model in modelDays[dayKey]) {
                NSMutableDictionary *counts = perModel[model];
                if (!counts) {
                    counts = [NSMutableDictionary dictionary];
                    perModel[model] = counts;
                }
                AddModelCounts(counts, ModelCountsFromCodexBucket(modelDays[dayKey][model]));
            }
        }
    }
    // 窗口之外的会话缓存和 partial 分片没人再读，顺手清掉。
    PruneTokenCache(cache, urls, [NSSet set]);
    return result;
}

// Claude：先按请求去重（跨文件、同请求多行取逐字段最大值），再按"日 × 模型"落桶，日是 DayLabel。
static NSDictionary<NSString *, NSDictionary *> *ClaudeModelDays(NSTimeInterval start,
    NSTimeInterval end, NSMutableDictionary *cache, NSURL *projectsURL) {
    NSArray<NSURL *> *urls = RecentClaudeTranscriptURLs(projectsURL, start);
    NSMutableArray<NSData *> *recordSets = [NSMutableArray arrayWithCapacity:urls.count];
    NSMutableSet<NSString *> *livePaths = [NSMutableSet setWithCapacity:urls.count];
    for (NSURL *url in urls) {
        [livePaths addObject:url.path];
        NSData *records = ClaudeRecordsForFile(url, cache);
        if (records.length > 0) [recordSets addObject:records];
    }
    PruneClaudeRecordCache(cache, livePaths);
    NSArray<NSString *> *names = ClaudeModelNames(cache);
    NSData *merged = ClaudeMergedRecords(recordSets, start, end);
    const ClaudeTokenRecord *records = merged.bytes;
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSMutableDictionary<NSString *, NSMutableDictionary *> *result = [NSMutableDictionary dictionary];
    NSTimeInterval bucketStart = 0, bucketEnd = 0, bucketLabelStart = 0;
    NSString *bucketLabel = nil;
    for (NSUInteger index = 0; index < merged.length / sizeof(ClaudeTokenRecord); index++) {
        const ClaudeTokenRecord *record = &records[index];
        // 合并后的记录不是按时间排的，日边界缓存只在恰好命中时有用，不命中就重算。
        if (record->timestamp < bucketStart || record->timestamp >= bucketEnd) {
            NSDate *dayStart = [calendar startOfDayForDate:
                [NSDate dateWithTimeIntervalSince1970:record->timestamp]];
            NSDate *next = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:dayStart options:0];
            bucketStart = dayStart.timeIntervalSince1970;
            bucketEnd = (next ?: [dayStart dateByAddingTimeInterval:86400]).timeIntervalSince1970;
        }
        if (!bucketLabel || bucketLabelStart != bucketStart) {
            bucketLabel = DayLabel(bucketStart);
            bucketLabelStart = bucketStart;
        }
        NSMutableDictionary *perModel = result[bucketLabel];
        if (!perModel) {
            perModel = [NSMutableDictionary dictionary];
            result[bucketLabel] = perModel;
        }
        NSString *model = record->model < names.count ? names[record->model] : @"unknown";
        NSMutableDictionary *counts = perModel[model];
        if (!counts) {
            counts = [NSMutableDictionary dictionary];
            perModel[model] = counts;
        }
        AddModelCounts(counts, ModelCountsMake(record->input, record->cacheRead, record->cacheWrite,
            record->output, 0, 1));
    }
    return result;
}

// 历史按日留一份，因为源头会清：Claude Code 默认约 30 天后清理转录，那之后这些天只能靠这份。
// 每个已经过去的自然日，先比整天的 Token 总量：源头现在数出来的不比存下的少，说明源头没被清，
// 它就是一次完整的重算，整天换成它——同一份用量换了模型名（unknown 后来认出了模型）时，
// 旧名字跟着整天被替掉，不会和新名字各留一份。数出来的更少才说明源头被清了一部分，这时按模型
// 各取大的再合并：被清掉的模型靠归档补上，还在的照样取新值。今天还没结束，不进归档。
static unsigned long long ModelDayTokens(NSDictionary *models) {
    unsigned long long total = 0;
    for (NSString *model in models) total += CCPetsTotalTokens(models[model]);
    return total;
}

static NSString *const ModelArchiveSchemaKey = @"schema";
// 2 起归档的键是 DayLabel（日期），1 是日零点的时间戳字符串。
static const NSInteger ModelArchiveSchemaVersion = 2;
// 用量页最长看 90 天（CCPetsUsagePage.m 的 UsageMaximumRangeDays），归档只需要覆盖这么多，
// 再留几天余量。读取只取请求区间里的日子，留得更久也没有路径能读到。两边要一起改。
static const NSInteger ModelArchiveRetentionDays = 100;

// 版本 1 的归档不能直接丢：源头被清掉的那些天只剩这一份。把时间戳键换成日期就能接着用。
static NSMutableDictionary *LoadModelArchive(NSString *path, BOOL *outMigrated) {
    NSMutableDictionary *archive = LoadTokenSummaryCache(path);
    NSDictionary *schema = [archive[ModelArchiveSchemaKey] isKindOfClass:NSDictionary.class]
        ? archive[ModelArchiveSchemaKey] : nil;
    NSInteger version = [schema[@"version"] integerValue];
    if (version == 1 && [archive[@"days"] isKindOfClass:NSDictionary.class]) {
        NSDictionary *oldDays = archive[@"days"];
        NSMutableDictionary *days = [NSMutableDictionary dictionaryWithCapacity:oldDays.count];
        for (NSString *key in oldDays) {
            if (![oldDays[key] isKindOfClass:NSDictionary.class]) continue;
            NSString *label = DayLabel(key.doubleValue);
            // 两个旧键落到同一天只可能是时区跳得离谱，留总量大的那份。
            if (!days[label] || ModelDayTokens(oldDays[key]) > ModelDayTokens(days[label])) {
                days[label] = oldDays[key];
            }
        }
        archive[@"days"] = days;
        if (outMigrated) *outMigrated = YES;
    } else if (version != ModelArchiveSchemaVersion) {
        [archive removeAllObjects];
    }
    archive[ModelArchiveSchemaKey] = @{@"version": @(ModelArchiveSchemaVersion)};
    if (![archive[@"days"] isKindOfClass:NSDictionary.class]) archive[@"days"] = @{};
    return archive;
}

NSDictionary *CCPetsModelUsage(NSString *provider, NSTimeInterval start, NSTimeInterval end) {
    NSString *home = [provider isEqualToString:@"claude"]
        ? DefaultClaudeConfigDirectory() : DefaultCodexHomeDirectory();
    return CCPetsModelUsageAtHome(provider, home, start, end);
}

NSDictionary *CCPetsModelUsageAtHome(NSString *provider, NSString *home,
    NSTimeInterval start, NSTimeInterval end) {
    BOOL isClaude = [provider isEqualToString:@"claude"];
    if (!isClaude && ![provider isEqualToString:@"codex"]) return nil;
    NSString *canonicalHome = home.stringByStandardizingPath;
    NSURL *sourceURL = [NSURL fileURLWithPath:[canonicalHome stringByAppendingPathComponent:
        isClaude ? @"projects" : @"sessions"]];
    NSString *source = sourceURL.path;
    NSString *cachePath = TokenSummaryCachePath(
        isClaude ? @"claude-models" : @"codex-models", source);
    NSString *archivePath = TokenSummaryCachePath(
        isClaude ? @"claude-model-days" : @"codex-model-days", source);
    NSMutableDictionary *cache = LoadTokenSummaryCache(cachePath);
    if (isClaude) MakeCachedRecordsMutable(cache);
    BOOL archiveChanged = NO;
    NSMutableDictionary *archive = LoadModelArchive(archivePath, &archiveChanged);

    NSDictionary<NSString *, NSDictionary *> *fresh = isClaude
        ? ClaudeModelDays(start, end, cache, sourceURL)
        : CodexModelDays(start, end, cache, sourceURL);

    NSMutableDictionary *archivedDays = [archive[@"days"] mutableCopy];
    NSTimeInterval todayStart = [NSCalendar.currentCalendar
        startOfDayForDate:NSDate.date].timeIntervalSince1970;
    NSMutableArray<NSDictionary *> *daily = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *totals = [NSMutableDictionary dictionary];
    for (NSNumber *dayStart in ModelUsageDayStarts(start, end)) {
        NSString *key = DayLabel(dayStart.doubleValue);
        NSDictionary *models = fresh[key] ?: @{};
        if (dayStart.doubleValue < todayStart) {
            NSDictionary *stored = [archivedDays[key] isKindOfClass:NSDictionary.class]
                ? archivedDays[key] : @{};
            NSMutableDictionary *combined = nil;
            if (ModelDayTokens(models) >= ModelDayTokens(stored)) {
                combined = [models mutableCopy];
            } else {
                combined = [stored mutableCopy];
                for (NSString *model in models) {
                    NSDictionary *existing = combined[model];
                    if (!existing || CCPetsTotalTokens(models[model]) >= CCPetsTotalTokens(existing)) {
                        combined[model] = models[model];
                    }
                }
            }
            if (![combined isEqualToDictionary:stored] && combined.count > 0) {
                archivedDays[key] = combined;
                archiveChanged = YES;
            }
            models = combined;
        }
        [daily addObject:@{@"timestamp": dayStart, @"models": models}];
        for (NSString *model in models) {
            NSMutableDictionary *sum = totals[model];
            if (!sum) {
                sum = [NSMutableDictionary dictionary];
                totals[model] = sum;
            }
            AddModelCounts(sum, models[model]);
        }
    }
    // 只留近 ModelArchiveRetentionDays 天。键是 yyyy-MM-dd，字典序就是时间序。
    NSDate *oldestDate = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitDay
        value:-ModelArchiveRetentionDays toDate:[NSDate dateWithTimeIntervalSince1970:todayStart] options:0];
    NSString *oldest = DayLabel(oldestDate.timeIntervalSince1970);
    for (NSString *key in archivedDays.allKeys) {
        if ([key compare:oldest] == NSOrderedAscending) {
            [archivedDays removeObjectForKey:key];
            archiveChanged = YES;
        }
    }
    archive[@"days"] = archivedDays;
    SaveTokenSummaryCache(cache, cachePath);
    if (archiveChanged) SaveTokenSummaryCache(archive, archivePath);
    return @{@"models": totals, @"daily": daily};
}
