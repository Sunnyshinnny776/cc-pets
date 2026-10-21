#import "CCPetsUsage+Internal.h"
#import "CCPetsPaths.h"

// MARK: - Claude Code 本地 Token 统计
//
// 数据源是 ~/.claude/projects/<编码后的 cwd>/<session-uuid>.jsonl，以及同级的
// <session-uuid>/subagents/agent-*.jsonl（子 agent 的转录，见 RecentClaudeTranscriptURLs）。
// 每条 type=assistant 的行带 timestamp 和 message.usage，是**单次请求的增量**，
// 与 Codex 的会话累计值不同，因此必须逐条落窗口累加，不能取末行。
//
// 关键差异：Claude 的 --resume / fork / compact 会把旧行原样复制进新文件，本机实测
// 5575 行里有 692 行重复（12%）。不去重的话 7 天用量会虚高一成以上，所以按
// message.id + requestId 做全局去重（两者缺失时回退 uuid）。同一次请求还会被拆成多行、
// 各带一份递增的 usage 快照，所以去重是**逐字段取最大值合并**而不是丢弃后续行，
// 详见 ClaudeTokenTotals。

// 记录缓存条目的版本。2 起记录多了 model 字段，结构体变长，旧条目按旧步长存的，
// 不能当新的读——版本对不上就整篇重来。
static const NSInteger ClaudeRecordCacheVersion = 2;
// 缓存里的保留键：模型名表。键不是路径，清理失效路径时要跳过它。
static NSString *const ClaudeModelTableKey = @"~models";
static const uint32_t ClaudeUnknownModel = UINT32_MAX;

// 模型名表只增不减，下标一旦发出去就不能变（记录里存的就是下标）。
NSArray<NSString *> *ClaudeModelNames(NSDictionary *cache) {
    NSDictionary *table = [cache[ClaudeModelTableKey] isKindOfClass:NSDictionary.class]
        ? cache[ClaudeModelTableKey] : nil;
    return [table[@"names"] isKindOfClass:NSArray.class] ? table[@"names"] : @[];
}

// 清掉已经不在扫描范围里的文件条目。模型名表不是路径，必须留着：删了它，已有记录里存的
// 下标就对不上名字了。
void PruneClaudeRecordCache(NSMutableDictionary *cache, NSSet<NSString *> *livePaths) {
    for (NSString *path in cache.allKeys) {
        if ([path isEqualToString:ClaudeModelTableKey]) continue;
        if (![livePaths containsObject:path]) [cache removeObjectForKey:path];
    }
}

static uint32_t ClaudeModelIndex(NSMutableDictionary *cache, NSString *model) {
    if (model.length == 0) return ClaudeUnknownModel;
    NSArray<NSString *> *names = ClaudeModelNames(cache);
    NSUInteger index = [names indexOfObject:model];
    if (index != NSNotFound) return (uint32_t)index;
    // 换成不可变副本再存：落盘读回的容器可变性不可靠（见 MakeCachedRecordsMutable 的注释）。
    cache[ClaudeModelTableKey] = @{@"names": [names arrayByAddingObject:model]};
    return (uint32_t)names.count;
}

// 去重键存 64 位散列而不是原字符串：近 7 天约 5.5k 条记录，散列后每条 56 字节（含模型下标）、
// 常驻约 300KB；64 位空间下这个量级的碰撞概率约 1e-12，可以忽略。用量页另有一份 90 天的
// 记录缓存（claude-models），大小随天数大致线性增长，同量级下是这份的十几倍。
static uint64_t ClaudeIdentityHash(NSString *first, NSString *second) {
    uint64_t hash = 1469598103934665603ULL;
    for (NSString *part in @[first ?: @"", @"\n", second ?: @""]) {
        const char *bytes = part.UTF8String;
        for (const char *cursor = bytes; cursor && *cursor; cursor++) {
            hash ^= (uint64_t)(unsigned char)*cursor;
            hash *= 1099511628211ULL;
        }
    }
    return hash;
}

static unsigned long long ClaudeCount(NSDictionary *usage, NSString *key) {
    NSNumber *number = [usage[key] isKindOfClass:NSNumber.class] ? usage[key] : nil;
    return number.unsignedLongLongValue;
}

// message.usage 的顶层就是该次请求的聚合值，内层 iterations 是明细，不能再加一遍。
static BOOL ClaudeRecordFromLine(NSData *lineData, ClaudeTokenRecord *record, NSString **outModel) {
    if (lineData.length == 0) return NO;
    static NSData *marker;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        marker = [@"\"type\":\"assistant\"" dataUsingEncoding:NSUTF8StringEncoding];
    });
    if ([lineData rangeOfData:marker options:0 range:NSMakeRange(0, lineData.length)].location ==
        NSNotFound) return NO;
    id rootValue = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
    if (![rootValue isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *root = rootValue;
    if (![root[@"type"] isKindOfClass:NSString.class] ||
        ![root[@"type"] isEqualToString:@"assistant"]) return NO;
    NSDictionary *message = [root[@"message"] isKindOfClass:NSDictionary.class]
        ? root[@"message"] : nil;
    NSDictionary *usage = [message[@"usage"] isKindOfClass:NSDictionary.class]
        ? message[@"usage"] : nil;
    NSDate *date = ISO8601Timestamp(root[@"timestamp"]);
    if (!usage || !date) return NO;

    NSString *identifier = [message[@"id"] isKindOfClass:NSString.class] ? message[@"id"] : nil;
    NSString *requestIdentifier = [root[@"requestId"] isKindOfClass:NSString.class]
        ? root[@"requestId"] : nil;
    // 本机实测 3112 行里有 17 行缺 id 或 requestId，回退到行级 uuid 保证仍能去重。
    NSString *fallback = [root[@"uuid"] isKindOfClass:NSString.class] ? root[@"uuid"] : nil;
    record->timestamp = date.timeIntervalSince1970;
    record->identity = (identifier && requestIdentifier)
        ? ClaudeIdentityHash(identifier, requestIdentifier)
        : ClaudeIdentityHash(fallback, nil);
    record->input = ClaudeCount(usage, @"input_tokens");
    record->output = ClaudeCount(usage, @"output_tokens");
    record->cacheRead = ClaudeCount(usage, @"cache_read_input_tokens");
    record->cacheWrite = ClaudeCount(usage, @"cache_creation_input_tokens");
    if (outModel) *outModel = [message[@"model"] isKindOfClass:NSString.class] ? message[@"model"] : nil;
    return YES;
}

// 收集目录内 mtime 落在窗口内的 .jsonl；顺带把子目录交给调用方（传 nil 表示不关心），
// 省一次 readdir。
static void AppendRecentTranscriptsInDirectory(NSURL *directory, NSTimeInterval earliest,
    NSMutableArray<NSURL *> *urls, NSMutableArray<NSURL *> *outSubdirectories) {
    NSArray<NSURLResourceKey> *keys = @[NSURLContentModificationDateKey, NSURLIsRegularFileKey,
        NSURLIsDirectoryKey];
    NSArray<NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory
        includingPropertiesForKeys:keys options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    for (NSURL *url in contents) {
        NSDictionary *values = [url resourceValuesForKeys:keys error:nil];
        if ([values[NSURLIsDirectoryKey] boolValue]) {
            [outSubdirectories addObject:url];
            continue;
        }
        if (![url.pathExtension.lowercaseString isEqualToString:@"jsonl"]) continue;
        if (![values[NSURLIsRegularFileKey] boolValue]) continue;
        NSDate *modified = values[NSURLContentModificationDateKey];
        if (modified && modified.timeIntervalSince1970 < earliest) continue;
        [urls addObject:url];
    }
}

// 只看 mtime 落在窗口内的转录文件。本机 76 个文件里近 7 天只有 44 个，目录遍历约 3ms。
//
// 子 agent（Task/Explore）的转录不写进主会话文件，而是单独落在
// <project>/<session-uuid>/subagents/agent-*.jsonl，只扫项目目录一层的话它们一条都进不来
// ——本机主会话文件里 isSidechain 的行数为 0，漏掉的就是全部子 agent 用量（历史上单个
// 文件到过 269 万 token）。
//
// 下钻哪些会话由主会话文件 <session-uuid>.jsonl 的 mtime 决定：Task 的调用和结果都会写进
// 主会话文件，主文件不在窗口内，它的子 agent 也不可能在。projects/ 目录只增不减（本机
// 99 个会话里近 8 天只有 27 个），无条件下钻等于给每个历史会话都白跑一次 readdir，而且
// 多数子目录压根不是 subagents（本机 13 个里 7 个是 tool-results/memory）。
// 不能改用 <session-uuid>/ 目录自身的 mtime 剪枝：目录 mtime 只在直接子项增删时更新，
// 往已有 agent-*.jsonl 追加写不会动它，正在跑的长任务会被剪掉。
// earliest 的口径与 RecentCodexSessionURLs 一致，由调用方按展示模式和归档状态算好。
NSArray<NSURL *> *RecentClaudeTranscriptURLs(NSURL *projectsURL,
    NSTimeInterval earliest) {
    NSArray<NSURL *> *projects = [NSFileManager.defaultManager contentsOfDirectoryAtURL:projectsURL
        includingPropertiesForKeys:@[NSURLIsDirectoryKey]
        options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSURL *project in projects) {
        NSNumber *isDirectory = nil;
        if (![project getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil]) continue;
        if (!isDirectory.boolValue) continue;
        NSMutableArray<NSURL *> *sessions = [NSMutableArray array];
        NSUInteger firstIndex = urls.count;
        AppendRecentTranscriptsInDirectory(project, earliest, urls, sessions);
        NSMutableSet<NSString *> *activeSessions = [NSMutableSet set];
        for (NSUInteger index = firstIndex; index < urls.count; index++) {
            [activeSessions addObject:urls[index].URLByDeletingPathExtension.lastPathComponent];
        }
        for (NSURL *session in sessions) {
            if (![activeSessions containsObject:session.lastPathComponent]) continue;
            AppendRecentTranscriptsInDirectory(
                [session URLByAppendingPathComponent:@"subagents" isDirectory:YES],
                earliest, urls, nil);
        }
    }
    return urls;
}

// 转录文件只追加（fork 走新文件），因此按 offset 追读即可，活跃会话每轮只解析新增字节。
NSData *ClaudeRecordsForFile(NSURL *url, NSMutableDictionary *cache) {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path
        error:nil];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    NSDictionary *cached = cache[url.path];
    if (cached && [cached[@"v"] integerValue] != ClaudeRecordCacheVersion) cached = nil;
    unsigned long long offset = [cached[@"offset"] unsignedLongLongValue];
    // 这里可以直接原地追加：可变性由 MakeCachedRecordsMutable 在缓存读回时统一保证。
    // 不要退回成 isKindOfClass:NSMutableData 判断——NSData 是类簇，落盘缓存解析出的
    // 不可变 __NSCFData 对它同样返回 YES，据此原地 appendBytes 会写出界。详见该函数注释。
    NSMutableData *records = [cached[@"records"] isKindOfClass:NSData.class]
        ? (NSMutableData *)cached[@"records"] : nil;
    if (!records || offset > size) {
        // 首次读取，或文件被改写导致偏移失效，整篇重来。
        offset = 0;
        records = [NSMutableData data];
    }
    if (cached && offset == size) {
        // 正常情况下 records 就是缓存里那一份，不必回写；只有上面因偏移失效重建过
        // （文件被清空到 0 字节）才是新对象，这时写回去，免得下一轮又重建一遍。
        if (records != cached[@"records"]) {
            cache[url.path] = @{@"offset": @(offset), @"records": records,
                                @"v": @(ClaudeRecordCacheVersion)};
        }
        return records;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!handle) return records;
    [handle seekToFileOffset:offset];
    NSData *fresh = [handle readDataToEndOfFile];
    [handle closeFile];

    const uint8_t *bytes = fresh.bytes;
    NSUInteger lineStart = 0;
    NSUInteger consumed = 0;
    for (NSUInteger index = 0; index < fresh.length; index++) {
        if (bytes[index] != '\n') continue;
        ClaudeTokenRecord record = {0};
        NSString *model = nil;
        if (index > lineStart && ClaudeRecordFromLine(
                [fresh subdataWithRange:NSMakeRange(lineStart, index - lineStart)], &record, &model) &&
            // <synthetic> 之类的占位模型是本地注入的消息，没有真实用量，不进统计。
            !(model.length > 0 && IsPseudoModelName(model))) {
            record.model = ClaudeModelIndex(cache, model);
            [records appendBytes:&record length:sizeof(record)];
        }
        lineStart = index + 1;
        consumed = lineStart;
    }
    // 只推进到最后一个换行符，未写完的尾行留到下一轮，避免把半行当成坏数据丢掉。
    cache[url.path] = @{@"offset": @(offset + consumed), @"records": records,
                        @"v": @(ClaudeRecordCacheVersion)};
    return records;
}

// 同一次请求会被拆成多行写入（thinking / text / tool_use 各一行），每行都带一份 usage
// 快照，而这些快照是**递增的**：本机实测有 14 组末行的 output_tokens 远大于首行
// （6→235、3→1870），首行取到的是流式过程中的中间值。因此同 identity 的多行必须逐字段
// 取最大值合并，只保留第一条会少算——全量口径下少算 16060 个 output token。
// 取 max 而不是"取最后一行"：fork/resume 会把旧行复制进新文件，跨文件的行序没有保证。
NSData *ClaudeMergedRecords(NSArray<NSData *> *recordSets, NSTimeInterval start,
    NSTimeInterval end) {
    NSMutableDictionary<NSNumber *, NSNumber *> *slots = [NSMutableDictionary dictionary];
    NSMutableData *merged = [NSMutableData data];
    for (NSData *data in recordSets) {
        const ClaudeTokenRecord *records = data.bytes;
        NSUInteger count = data.length / sizeof(ClaudeTokenRecord);
        for (NSUInteger index = 0; index < count; index++) {
            const ClaudeTokenRecord *record = &records[index];
            if (record->timestamp < start || record->timestamp >= end) continue;
            NSNumber *identity = @(record->identity);
            NSNumber *slot = slots[identity];
            if (!slot) {
                slots[identity] = @(merged.length / sizeof(ClaudeTokenRecord));
                [merged appendBytes:record length:sizeof(*record)];
                continue;
            }
            // append 可能搬动缓冲区，基址每次重新取。
            ClaudeTokenRecord *target =
                (ClaudeTokenRecord *)merged.mutableBytes + slot.unsignedIntegerValue;
            target->input = MAX(target->input, record->input);
            target->output = MAX(target->output, record->output);
            target->cacheRead = MAX(target->cacheRead, record->cacheRead);
            target->cacheWrite = MAX(target->cacheWrite, record->cacheWrite);
            // 同一次请求只可能是一个模型；先出现的行没带 model（unknown）时，用后面带的补上。
            if (target->model == ClaudeUnknownModel) target->model = record->model;
        }
    }
    return merged;
}

static NSDictionary *ClaudeTokenTotals(NSArray<NSData *> *recordSets, NSTimeInterval start,
    NSTimeInterval end) {
    NSData *merged = ClaudeMergedRecords(recordSets, start, end);
    unsigned long long input = 0, output = 0, cacheRead = 0, cacheWrite = 0;
    const ClaudeTokenRecord *unique = merged.bytes;
    for (NSUInteger index = 0; index < merged.length / sizeof(ClaudeTokenRecord); index++) {
        input += unique[index].input;
        output += unique[index].output;
        cacheRead += unique[index].cacheRead;
        cacheWrite += unique[index].cacheWrite;
    }
    // 不输出 reasoning_output_tokens：Claude 的思考 token 已经计入 output_tokens，
    // 单列一个恒为 0 的字段会让人误以为没统计。
    return @{
        @"input_tokens": @(input),
        @"cached_input_tokens": @(cacheRead),
        @"cache_write_input_tokens": @(cacheWrite),
        @"output_tokens": @(output),
        @"total_tokens": @(input + output + cacheRead + cacheWrite),
        @"request_count": @(merged.length / sizeof(ClaudeTokenRecord))
    };
}

static NSArray<NSDictionary *> *ClaudeDailyTokenSeries(NSArray<NSData *> *recordSets,
    NSTimeInterval start, NSTimeInterval end) {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSMutableArray<NSDictionary *> *series = [NSMutableArray array];
    NSDate *cursor = [NSDate dateWithTimeIntervalSince1970:start];
    while (cursor.timeIntervalSince1970 < end) {
        NSDate *next = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:cursor options:0];
        if (!next) break;
        NSTimeInterval bucketEnd = fmin(end, next.timeIntervalSince1970);
        [series addObject:@{ @"timestamp": @(cursor.timeIntervalSince1970),
            @"totals": ClaudeTokenTotals(recordSets, cursor.timeIntervalSince1970, bucketEnd) }];
        cursor = next;
    }
    return series;
}

@interface ClaudeUsageReader ()
@property NSString *configDirectory;
@property NSMutableDictionary *recordCache;
@property NSString *recordCachePath;
@property NSTimeInterval recordCacheSavedAt;
@property NSMutableDictionary *monthlyArchive;
@property NSString *monthlyArchivePath;
@property NSDictionary *tokenUsage;
@property NSString *tokenWindowIdentity;
@property NSTimeInterval tokenComputedAt;
@property BOOL forcesTokenAggregation;
@end

@implementation ClaudeUsageReader
- (instancetype)init {
    return [self initWithConfigDirectory:DefaultClaudeConfigDirectory()];
}
- (instancetype)initWithConfigDirectory:(NSString *)configDirectory {
    if ((self = [super init])) {
        _configDirectory = configDirectory.stringByStandardizingPath;
        _projectsURL = [NSURL fileURLWithPath:[_configDirectory stringByAppendingPathComponent:@"projects"]];
        _recordCachePath = TokenSummaryCachePath(@"claude", _projectsURL.path);
        _recordCache = LoadTokenSummaryCache(_recordCachePath);
        MakeCachedRecordsMutable(_recordCache);
        _monthlyArchivePath = MonthlyUsageArchivePath(@"claude", _projectsURL.path);
        _monthlyArchive = LoadTokenSummaryCache(_monthlyArchivePath);
    }
    return self;
}
- (NSDictionary *)aggregateForLimits:(NSDictionary *)limits {
    NSDictionary *five = [limits[@"fiveHour"] isKindOfClass:NSDictionary.class]
        ? limits[@"fiveHour"] : nil;
    NSDictionary *week = [limits[@"week"] isKindOfClass:NSDictionary.class] ? limits[@"week"] : nil;
    NSTimeInterval fiveStart = 0, fiveEnd = 0, weekStart = 0, weekEnd = 0;
    // Claude 的 rate_limits 没有 window_minutes，窗长按官方订阅固定为 5 小时 / 7 天。
    // 窗口不可用时退化成滚动窗口，Token 是本机数据，不跟着官方额度一起变成 `--`。
    TokenWindowOrFallback(five, FiveHourWindowMinutes, &fiveStart, &fiveEnd);
    TokenWindowOrFallback(week, SevenDayWindowMinutes, &weekStart, &weekEnd);
    // 自然日窗口和额度无关，即使两个额度窗口都不可用也照样统计。
    BOOL apiMode = ProfileShowsAPIUsage(@"claude", self.configDirectory);
    NSDictionary *monthWindows = CalendarMonthWindows(0);
    NSTimeInterval monthStart = [monthWindows[@"monthStart"] doubleValue];
    NSTimeInterval monthCurveEnd = [monthWindows[@"monthCurveEnd"] doubleValue];
    NSTimeInterval monthComparableEnd = [monthWindows[@"monthComparableEnd"] doubleValue];
    NSTimeInterval previousMonthStart = [monthWindows[@"previousMonthStart"] doubleValue];
    NSTimeInterval previousMonthEnd = [monthWindows[@"previousMonthEnd"] doubleValue];
    NSString *previousMonthKey = MonthArchiveKey(previousMonthStart);
    NSArray<NSDictionary *> *archivedDaily = apiMode &&
        [self.monthlyArchive[previousMonthKey][@"daily"] isKindOfClass:NSArray.class]
        ? self.monthlyArchive[previousMonthKey][@"daily"] : nil;
    // 与 Codex 侧同一套：上月归档好了就只读本月的转录，没归档才放宽一次把归档建出来。
    BOOL buildsArchive = apiMode && !archivedDaily;
    NSTimeInterval earliest = buildsArchive ? previousMonthStart
        : (apiMode ? fmin(monthStart, RollingTokenWindowFloor()) : RollingTokenWindowFloor());
    NSArray<NSURL *> *urls = RecentClaudeTranscriptURLs(self.projectsURL, earliest);
    NSMutableArray<NSData *> *recordSets = [NSMutableArray arrayWithCapacity:urls.count];
    NSMutableSet<NSString *> *livePaths = [NSMutableSet setWithCapacity:urls.count];
    for (NSURL *url in urls) {
        [livePaths addObject:url.path];
        NSData *records = ClaudeRecordsForFile(url, self.recordCache);
        if (records.length > 0) [recordSets addObject:records];
    }
    PruneClaudeRecordCache(self.recordCache, livePaths);
    NSTimeInterval savedAt = NSDate.date.timeIntervalSince1970;
    if (self.persistsCache && savedAt - self.recordCacheSavedAt >= TokenCacheSaveInterval) {
        self.recordCacheSavedAt = savedAt;
        SaveTokenSummaryCache(self.recordCache, self.recordCachePath);
    }
    NSTimeInterval todayStart = 0, rollingWeekStart = 0, rollingEnd = 0;
    RollingTokenWindows(&todayStart, &rollingWeekStart, &rollingEnd);
    // 与 Codex 侧同理：订阅视图下转录只回溯 8 天，月度口径既算不准也没人看。
    // 曲线同样铺满整个自然月，末尾没到的日子是 0。
    NSArray<NSDictionary *> *monthDaily = apiMode
        ? ClaudeDailyTokenSeries(recordSets, monthStart, monthCurveEnd) : @[];
    if (buildsArchive) {
        NSArray *previousDaily = ClaudeDailyTokenSeries(recordSets, previousMonthStart, monthStart);
        self.monthlyArchive[previousMonthKey] = @{ @"daily": previousDaily,
            @"totals": SummedDailyTokenSeries(previousDaily) };
        archivedDaily = previousDaily;
        PruneMonthlyArchive(self.monthlyArchive);
        if (self.persistsCache) {
            SaveTokenSummaryCache(self.monthlyArchive, self.monthlyArchivePath);
        }
    }
    return @{
        @"fiveHour": ClaudeTokenTotals(recordSets, fiveStart, fiveEnd),
        @"week": ClaudeTokenTotals(recordSets, weekStart, weekEnd),
        @"today": ClaudeTokenTotals(recordSets, todayStart, rollingEnd),
        @"recentWeek": ClaudeTokenTotals(recordSets, rollingWeekStart, rollingEnd),
        @"recentWeekStartsAt": @(rollingWeekStart),
        @"month": apiMode ? SummedDailyTokenSeries(monthDaily) : NSNull.null,
        @"monthComparable": apiMode
            ? SummedDailyTokenSeriesInRange(monthDaily, monthStart, monthComparableEnd)
            : NSNull.null,
        @"previousMonthToDate": archivedDaily
            ? SummedDailyTokenSeriesInRange(archivedDaily, previousMonthStart, previousMonthEnd)
            : NSNull.null,
        @"monthDaily": monthDaily,
        @"monthStartsAt": @(monthStart),
        @"monthComparableEndsAt": @(monthComparableEnd),
        @"previousMonthComparableEndsAt": @(previousMonthEnd),
        @"source": @"local"
    };
}
- (NSDictionary *)refresh {
    // 额度快照是 statusline hook 写出来的（见 RecordClaudeUsage）：第三方 statusline 注入不
    // 进去、或者账号本身（API key / Bedrock / Vertex）就不带 rate_limits 时，这份文件永远
    // 不存在。而 Token 是本机从转录里数出来的，跟官方额度没有半点关系，不能被它一票否决
    // ——原先这里直接 return nil，面板上 Claude 整行（百分比、已用 Token、今日输入输出）
    // 全是 `--`，看起来像统计坏了。缺额度时百分比照样 `--`，用量正常显示。
    NSDictionary *limits = ClaudeRateLimitsForConfigDirectory(self.configDirectory) ?:
        @{@"fiveHour": NSNull.null, @"week": NSNull.null};
    NSString *identity = [NSString stringWithFormat:@"%@:%d", TokenWindowIdentity(limits),
        ProfileShowsAPIUsage(@"claude", self.configDirectory)];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    BOOL reusable = !self.forcesTokenAggregation && self.tokenUsage &&
        [identity isEqualToString:self.tokenWindowIdentity] &&
        now - self.tokenComputedAt < TokenAggregationInterval;
    if (!reusable) {
        self.tokenUsage = [self aggregateForLimits:limits];
        self.tokenWindowIdentity = identity;
        self.tokenComputedAt = now;
        self.forcesTokenAggregation = NO;
    }
    NSMutableDictionary *usage = [limits mutableCopy];
    usage[@"tokenUsage"] = self.tokenUsage;
    return usage;
}
- (NSDictionary *)refreshWithFullAggregation {
    self.forcesTokenAggregation = YES;
    return [self refresh];
}
@end
