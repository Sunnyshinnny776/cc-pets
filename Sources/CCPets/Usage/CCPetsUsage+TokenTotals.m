#import "CCPetsUsage+Internal.h"

static NSTimeInterval LineTimestamp(NSData *line) {
    if (line.length == 0) return 0;
    id root = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
    if (![root isKindOfClass:NSDictionary.class]) return 0;
    NSDate *date = ISO8601Timestamp(((NSDictionary *)root)[@"timestamp"]);
    return date ? date.timeIntervalSince1970 : 0;
}

// 按块切行喂给 consume，返回消费掉的字节数（截止最后一个换行）。返回值就是下一次可以
// 安全续读的偏移：结尾那半行还没写完，不能算进去。includeTail=YES 时残行照样交给
// consume（一次性整篇扫描的调用方要它，最后一行未必有换行结尾）。
static unsigned long long EnumerateLines(NSFileHandle *handle, BOOL includeTail,
    void (^consume)(NSData *)) {
    NSMutableData *pending = [NSMutableData data];
    unsigned long long consumed = 0;
    while (YES) {
        NSData *chunk = [handle readDataOfLength:256 * 1024];
        if (chunk.length == 0) break;
        [pending appendData:chunk];
        const uint8_t *bytes = pending.bytes;
        NSUInteger lineStart = 0;
        for (NSUInteger index = 0; index < pending.length; index++) {
            if (bytes[index] != '\n') continue;
            if (index > lineStart) {
                consume([pending subdataWithRange:NSMakeRange(lineStart, index - lineStart)]);
            }
            lineStart = index + 1;
        }
        if (lineStart > 0) {
            consumed += lineStart;
            pending = [[pending subdataWithRange:NSMakeRange(
                lineStart, pending.length - lineStart)] mutableCopy];
        }
    }
    if (includeTail && pending.length > 0) consume(pending);
    return consumed;
}

static void AddTokenCounts(NSMutableDictionary *target, NSDictionary *counts) {
    for (NSString *key in TokenKeys()) {
        unsigned long long current = [target[key] unsignedLongLongValue];
        unsigned long long addition = [counts[key] unsignedLongLongValue];
        if (counts[key]) target[key] = @(current + addition);
    }
}

// total_token_usage 是会话内累计值，但同一个 rollout 文件里它会中途归零重来：resume 或
// 上下文压缩之后进程从头开始计数。本机近 14 天 106 个会话里 3 个如此，最狠的一个从
// 1098 万掉回 11 万——只认末行 total 的话，归零之前那一整段全被吞掉（该会话真实用量
// 约 1146 万，末行只有 47 万，漏掉 96%）。因此把会话按归零点切成若干段：段内仍然用
// 累计值（对重复写入的 token_count 幂等），段与段之间相加。
static BOOL TokenTotalsDidReset(NSDictionary *totals, NSDictionary *previous) {
    for (NSString *key in TokenKeys()) {
        if (!totals[key] || !previous[key]) continue;
        if ([totals[key] unsignedLongLongValue] < [previous[key] unsignedLongLongValue]) return YES;
    }
    return NO;
}

static NSDictionary *SummedSegmentTotals(NSArray<NSDictionary *> *segments) {
    NSMutableDictionary *total = [NSMutableDictionary dictionary];
    for (NSDictionary *segment in segments) AddTokenCounts(total, segment);
    return total;
}

// 日桶除 Token 字段外还带 request_count，合并时要一起累加。
static void AddDailyTokenCounts(NSMutableDictionary *target, NSDictionary *counts) {
    AddTokenCounts(target, counts);
    if (!counts[@"request_count"]) return;
    target[@"request_count"] = @([target[@"request_count"] unsignedLongLongValue] +
        [counts[@"request_count"] unsignedLongLongValue]);
}

static NSString *DayBucketKey(NSTimeInterval dayStart) {
    return [NSString stringWithFormat:@"%.0f", dayStart];
}

// 带模型的摘要条目的版本。2 起会话摘要多了 modelDays / model（按模型归属的日桶）。
// 只有用量页（trackModels）要这两样：旧条目没法凭已有字段补出来，只能整篇重读——版本对不上就当没缓存。
// 悬停面板不看模型，也不检查版本，升级后它的缓存照旧可用，不会在主线程上把会话全部重读一遍。
static const NSInteger TokenSummaryVersion = 2;

// 不是真实模型：Claude Code 给本地注入的消息打的占位名，没有对应的用量。
BOOL IsPseudoModelName(NSString *model) {
    return model.length == 0 || [model hasPrefix:@"<"];
}

// 每个回合开头 Codex 会写一行 turn_context，model 在它的 payload 里，和 token_count 不在同一行。
// 这行很大（带着整份沙箱 / 权限配置），先用标记过滤，只有命中的才值得做 JSON 解析。
static NSString *ModelFromTurnContextLine(NSData *lineData) {
    static NSData *marker;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        marker = [@"\"type\":\"turn_context\"" dataUsingEncoding:NSUTF8StringEncoding];
    });
    if ([lineData rangeOfData:marker options:0 range:NSMakeRange(0, lineData.length)].location ==
        NSNotFound) return nil;
    id root = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
    if (![root isKindOfClass:NSDictionary.class]) return nil;
    if (![root[@"type"] isEqual:@"turn_context"]) return nil;
    NSDictionary *payload = [root[@"payload"] isKindOfClass:NSDictionary.class] ? root[@"payload"] : nil;
    NSString *model = [payload[@"model"] isKindOfClass:NSString.class] ? payload[@"model"] : nil;
    return IsPseudoModelName(model) ? nil : model;
}

static NSDictionary *TokenCountsBySubtracting(NSDictionary *totals, NSDictionary *baseline);

// 分段必须整篇扫描（末行 total 不再够用），因此改成按偏移增量追读：活跃会话每轮只解析
// 新增的那几行，段状态（各段末尾的累计值）留在缓存里续接。
//
// 解析时顺手把每条记录的增量摊到它所属的自然日（summary[@"days"]）。API 视图要画一个月的
// 日曲线，如果改成按天各扫一遍窗口，跨天会话会被 PartialTokenTotals 整篇重读 31 次——
// 实测本机每次刷新要多花 130ms，全落在主线程上，悬停时连拖动都会卡住。
//
// trackModels 只给用量页（后台线程）用：按 turn_context 把增量再分到模型名下。悬停面板走主线程、
// 用不到模型，关掉后不碰 turn_context 行，省掉逐行查标记和对大行的 JSON 解析。
NSDictionary *TokenSessionSummaryTracking(NSURL *url, NSMutableDictionary *cache,
    BOOL trackModels) {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    NSDictionary *cached = cache[url.path];
    if (trackModels && cached && [cached[@"v"] integerValue] != TokenSummaryVersion) cached = nil;
    // 没有 token_count 的会话（旧格式、被截断、刚创建）也会留下缓存条目，否则每一轮都要
    // 把整篇重读一遍。文件长大后 size 变化自然会让缓存失效。
    if (cached && [cached[@"size"] unsignedLongLongValue] == size) {
        return (cached[@"start"] && cached[@"total"]) ? cached : nil;
    }

    unsigned long long offset = 0;
    NSMutableArray<NSDictionary *> *segments = [NSMutableArray array];
    NSMutableArray<NSNumber *> *requestTimestamps = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *days = [NSMutableDictionary dictionary];
    // 日 -> 模型 -> 用量。模型跟着"当时生效的 turn_context"走：会话中途 /model 切换后，
    // 后面的增量归新模型。追读时 currentModel 要跟着缓存一起续上，否则从中间续读的那段没人认领。
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSMutableDictionary *> *> *modelDays =
        [NSMutableDictionary dictionary];
    __block NSString *currentModel = nil;
    __block NSNumber *start = nil;
    __block NSTimeInterval last = 0;
    __block NSDictionary *lastRequestTotal = nil;
    if (cached) {
        unsigned long long cachedOffset = [cached[@"offset"] unsignedLongLongValue];
        // offset > size 只可能是文件被改写（截断/重建），旧的段全部作废，整篇重来。
        if (cachedOffset <= size) {
            offset = cachedOffset;
            start = [cached[@"start"] isKindOfClass:NSNumber.class] ? cached[@"start"] : nil;
            last = [cached[@"end"] doubleValue];
            if ([cached[@"segments"] isKindOfClass:NSArray.class]) {
                [segments addObjectsFromArray:cached[@"segments"]];
            }
            if ([cached[@"requestTimestamps"] isKindOfClass:NSArray.class]) {
                [requestTimestamps addObjectsFromArray:cached[@"requestTimestamps"]];
            }
            if ([cached[@"days"] isKindOfClass:NSDictionary.class]) {
                for (NSString *key in (NSDictionary *)cached[@"days"]) {
                    days[key] = [cached[@"days"][key] mutableCopy];
                }
            }
            lastRequestTotal = [cached[@"lastRequestTotal"] isKindOfClass:NSDictionary.class]
                ? cached[@"lastRequestTotal"] : nil;
            currentModel = trackModels && [cached[@"model"] isKindOfClass:NSString.class]
                ? cached[@"model"] : nil;
            NSDictionary *cachedModelDays = trackModels &&
                [cached[@"modelDays"] isKindOfClass:NSDictionary.class] ? cached[@"modelDays"] : nil;
            for (NSString *dayKey in cachedModelDays) {
                NSMutableDictionary *perModel = [NSMutableDictionary dictionary];
                for (NSString *model in cachedModelDays[dayKey]) {
                    perModel[model] = [cachedModelDays[dayKey][model] mutableCopy];
                }
                modelDays[dayKey] = perModel;
            }
        }
    }

    NSCalendar *calendar = NSCalendar.currentCalendar;
    // 会话内记录是按时间递增写入的，日边界只在跨天那一条上重算，不必每条都问日历。
    __block NSTimeInterval bucketStart = 0;
    __block NSTimeInterval bucketEnd = 0;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!handle) return nil;
    if (offset > 0) [handle seekToFileOffset:offset];
    unsigned long long consumed = EnumerateLines(handle, NO, ^(NSData *line) {
        // 会话起点取文件第一条带 timestamp 的行，不限于 token_count：它决定这个会话算不算
        // 整段落在窗口内。找到之后就不再对普通行做 JSON 解析。
        if (!start) {
            NSTimeInterval timestamp = LineTimestamp(line);
            if (timestamp > 0) start = @(timestamp);
        }
        NSString *turnModel = trackModels ? ModelFromTurnContextLine(line) : nil;
        if (turnModel) {
            currentModel = turnModel;
            return;
        }
        NSDictionary *record = TokenRecordFromLine(line);
        NSDictionary *total = record[@"total"];
        if (!total) return;
        last = [record[@"timestamp"] doubleValue];
        // Codex 会重复写同一份累计快照，事件行数不能直接当调用次数。累计值发生变化才代表
        // 一次新的模型响应；上下文压缩导致累计值归零时同样会被识别为新响应。
        BOOL newRequest = !lastRequestTotal || ![total isEqualToDictionary:lastRequestTotal];
        if (newRequest) [requestTimestamps addObject:record[@"timestamp"]];
        // 段内用累计值相减、归零时整份计入，与 TokenSessionSummary 的分段口径一致：
        // 逐条增量相加会收敛回段末的累计值，因此日桶之和等于 summary[@"total"]。
        NSDictionary *increment = TokenCountsBySubtracting(total, lastRequestTotal);
        if (last < bucketStart || last >= bucketEnd) {
            NSDate *dayStart = [calendar startOfDayForDate:[NSDate dateWithTimeIntervalSince1970:last]];
            NSDate *next = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:dayStart
                options:0];
            bucketStart = dayStart.timeIntervalSince1970;
            bucketEnd = (next ?: [dayStart dateByAddingTimeInterval:86400]).timeIntervalSince1970;
        }
        NSString *dayKey = DayBucketKey(bucketStart);
        NSMutableDictionary *bucket = days[dayKey];
        if (!bucket) {
            bucket = [NSMutableDictionary dictionary];
            days[dayKey] = bucket;
        }
        AddTokenCounts(bucket, increment);
        if (newRequest) {
            bucket[@"request_count"] = @([bucket[@"request_count"] unsignedLongLongValue] + 1);
        }
        // 同一份增量再按模型记一遍。没见过 turn_context 就记在 unknown 名下，总量对得上。
        if (trackModels) {
            NSMutableDictionary<NSString *, NSMutableDictionary *> *perModel = modelDays[dayKey];
            if (!perModel) {
                perModel = [NSMutableDictionary dictionary];
                modelDays[dayKey] = perModel;
            }
            NSString *modelName = currentModel ?: @"unknown";
            NSMutableDictionary *modelBucket = perModel[modelName];
            if (!modelBucket) {
                modelBucket = [NSMutableDictionary dictionary];
                perModel[modelName] = modelBucket;
            }
            AddTokenCounts(modelBucket, increment);
            if (newRequest) {
                modelBucket[@"request_count"] = @([modelBucket[@"request_count"] unsignedLongLongValue] + 1);
            }
        }
        lastRequestTotal = total;
        NSDictionary *previous = segments.lastObject;
        if (!previous || TokenTotalsDidReset(total, previous)) [segments addObject:total];
        else segments[segments.count - 1] = total;
    });
    [handle closeFile];

    NSMutableDictionary *summary = [@{@"size": @(size), @"offset": @(offset + consumed)} mutableCopy];
    // 不跟踪模型的条目不打版本：它没有 modelDays，用量页读到时要当没缓存、整篇重读。
    if (trackModels) summary[@"v"] = @(TokenSummaryVersion);
    if (currentModel) summary[@"model"] = currentModel;
    if (start) summary[@"start"] = start;
    if (segments.count > 0) {
        summary[@"segments"] = [segments copy];
        summary[@"end"] = @(last);
        summary[@"total"] = SummedSegmentTotals(segments);
        summary[@"requestTimestamps"] = [requestTimestamps copy];
        // 冻结成不可变，避免下一轮增量追读时改到已经交给调用方的那份。
        NSMutableDictionary *frozenDays = [NSMutableDictionary dictionaryWithCapacity:days.count];
        for (NSString *key in days) frozenDays[key] = [days[key] copy];
        summary[@"days"] = [frozenDays copy];
        NSMutableDictionary *frozenModelDays = [NSMutableDictionary dictionaryWithCapacity:modelDays.count];
        for (NSString *dayKey in modelDays) {
            NSMutableDictionary *perModel = [NSMutableDictionary dictionary];
            for (NSString *model in modelDays[dayKey]) perModel[model] = [modelDays[dayKey][model] copy];
            frozenModelDays[dayKey] = [perModel copy];
        }
        if (trackModels) summary[@"modelDays"] = [frozenModelDays copy];
        if (lastRequestTotal) summary[@"lastRequestTotal"] = lastRequestTotal;
    }
    cache[url.path] = summary;
    return (start && summary[@"total"]) ? summary : nil;
}

static NSDictionary *TokenSessionSummary(NSURL *url, NSMutableDictionary *cache) {
    return TokenSessionSummaryTracking(url, cache, NO);
}

// 累计值相减，而不是累加窗口内的 last_token_usage：Codex 会把同一份 token_count
// 重复写进会话（本机近期 68 个会话里 14 个如此，sum(last) 整体比末行 total 高 1.1%，
// 最差的单个会话高 7.7%），累加就把重复的那次算了两遍。累计值对重复事件是幂等的。
// total_token_usage 罕见地回退（会话内重置）时，窗口前的基线已经失效，直接取窗口内的值。
static NSDictionary *TokenCountsBySubtracting(NSDictionary *totals, NSDictionary *baseline) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in TokenKeys()) {
        if (!totals[key]) continue;
        unsigned long long current = [totals[key] unsignedLongLongValue];
        unsigned long long previous = [baseline[key] unsignedLongLongValue];
        result[key] = @(current >= previous ? current - previous : current);
    }
    return result;
}

// 跨窗口起点的会话只算窗口内的增量。分段规则与 TokenSessionSummary 一致：累计值一旦
// 归零，窗口起点之前取到的基线就作废了，后面那一段要从 0 起算，段与段的增量再相加。
static NSDictionary *PartialTokenTotals(NSURL *url, NSTimeInterval start, NSTimeInterval end) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!handle) return nil;
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    __block NSDictionary *previous = nil;
    __block NSDictionary *baseline = nil;
    __block NSDictionary *inside = nil;
    // 窗口内一条 token_count 都没有的段不贡献任何用量。
    void (^flush)(void) = ^{
        if (inside) AddTokenCounts(result, TokenCountsBySubtracting(inside, baseline));
        baseline = nil;
        inside = nil;
    };
    EnumerateLines(handle, YES, ^(NSData *line) {
        NSDictionary *record = TokenRecordFromLine(line);
        NSDictionary *total = record[@"total"];
        if (!total) return;
        if (previous && TokenTotalsDidReset(total, previous)) flush();
        previous = total;
        NSTimeInterval timestamp = [record[@"timestamp"] doubleValue];
        if (timestamp < start) baseline = total;
        else if (timestamp < end) inside = total;
    });
    flush();
    [handle closeFile];
    return result;
}

// 聚合区间对齐官方重置时间：[resets_at - 窗长, resets_at)。
// Codex 的 rate_limits 自带 window_minutes；Claude 没有这个字段，由调用方给出订阅
// 固定的 300 / 10080 分钟作为兜底。返回 NO 表示窗口当前不可用（缺 resets_at 或已过期），
// 此时不做任何 Token 统计，避免拿过期窗口冒充当前值。
static BOOL TokenWindowForQuota(NSDictionary *quota, double fallbackMinutes,
    NSTimeInterval *outStart, NSTimeInterval *outEnd) {
    NSNumber *minutes = [quota[@"window_minutes"] isKindOfClass:NSNumber.class]
        ? quota[@"window_minutes"] : nil;
    double windowMinutes = minutes ? minutes.doubleValue : fallbackMinutes;
    NSNumber *reset = [quota[@"resets_at"] isKindOfClass:NSNumber.class] ? quota[@"resets_at"] : nil;
    if (windowMinutes <= 0 || !reset) return NO;
    NSTimeInterval end = reset.doubleValue;
    if (NSDate.date.timeIntervalSince1970 >= end) return NO;
    if (outStart) *outStart = end - windowMinutes * 60.0;
    if (outEnd) *outEnd = end;
    return YES;
}

// 官方窗口拿不到时（账号根本没有这个窗口、缺 resets_at、或窗口已过期），Token 依然是
// 本机自己数出来的，没有理由跟着变成 `--`。退化成按本机时钟往回推的滚动窗口。
// 终点向上对齐到 10 分钟：起点每秒都在动的话，分片缓存的键每轮都变，跨界会话会被整篇重扫。
static const NSTimeInterval TokenFallbackGranularity = 600;
static void RollingWindowForMinutes(double minutes, NSTimeInterval *outStart, NSTimeInterval *outEnd) {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSTimeInterval end = (floor(now / TokenFallbackGranularity) + 1) * TokenFallbackGranularity;
    if (outStart) *outStart = end - minutes * 60.0;
    if (outEnd) *outEnd = end;
}
BOOL TokenWindowOrFallback(NSDictionary *quota, double fallbackMinutes,
    NSTimeInterval *outStart, NSTimeInterval *outEnd) {
    if (TokenWindowForQuota(quota, fallbackMinutes, outStart, outEnd)) return YES;
    if (fallbackMinutes <= 0) return NO;
    RollingWindowForMinutes(fallbackMinutes, outStart, outEnd);
    return YES;
}

// 面板要并列展示两家数据，而两家的 resets_at 并不一致（实测能差 2 天以上），
// 所以汇总另用一组与订阅完全脱钩的自然日窗口，保证两家的时间口径一致。
//
// 取自然日边界而不是"从现在往回推 N 秒"，是因为分片缓存的键里含窗口起点：起点每秒
// 都在动的话，跨界会话每一轮都要整篇重扫；对齐到零点后起点一天之内不变，缓存才能命中。
void RollingTokenWindows(NSTimeInterval *todayStart, NSTimeInterval *weekStart,
    NSTimeInterval *end) {
    NSDate *now = NSDate.date;
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *midnight = [calendar startOfDayForDate:now];
    if (todayStart) *todayStart = midnight.timeIntervalSince1970;
    if (weekStart) {
        NSDate *start = [calendar dateByAddingUnit:NSCalendarUnitDay value:-6 toDate:midnight
            options:0];
        *weekStart = (start ?: midnight).timeIntervalSince1970;
    }
    // 时钟轻微前后跳动时，不要把刚落盘的记录挡在窗口外，因此终点先留出 60 秒余量。
    // 之后再向上对齐到 10 分钟：分片缓存的键里同时含起点和终点，终点每秒都在动的话，
    // 键每一轮都是新的，起点对齐到零点省下的那次命中会被它整个抵消——跨界会话照样
    // 每轮重扫，而且上一轮写下的分片还会被 PruneTokenCache 当成过期窗口清掉。
    if (end) {
        *end = ceil((now.timeIntervalSince1970 + 60) / TokenFallbackGranularity) *
            TokenFallbackGranularity;
    }
}

// 自然月窗口。本月是 1 日 00:00 起算，展示区间到"此刻"，曲线区间到月底。
//
// 同比区间两边都只数到"最后一个完整的自然日"：本月 1 日至今日 00:00，对比上月 1 日至上月
// 第 N 日 00:00（N = 本月已过完的整日数）。刻意不做到同一时刻——上月的数据来自日粒度的
// 归档，切不出"14 日 15:30"这种半天；而月度同比本来就是趋势判断，差半天换来"上月的会话
// 文件一次都不用再打开"，这笔账是划算的。上月天数不够时（3 月 31 日对比 2 月）封顶到上月末。
NSDictionary *CalendarMonthWindows(NSTimeInterval alignedEnd) {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *now = NSDate.date;
    NSDate *monthStart = CurrentMonthStartDate();
    NSDate *nextMonthStart = [calendar dateByAddingUnit:NSCalendarUnitMonth value:1
        toDate:monthStart options:0] ?: now;
    NSDate *previousMonthStart = [calendar dateByAddingUnit:NSCalendarUnitMonth value:-1
        toDate:monthStart options:0] ?: monthStart;
    NSDate *todayStart = [calendar startOfDayForDate:now];
    NSInteger elapsedDays = [calendar components:NSCalendarUnitDay fromDate:monthStart
        toDate:todayStart options:0].day;
    if (elapsedDays < 0) elapsedDays = 0;
    NSDate *previousComparableEnd = [calendar dateByAddingUnit:NSCalendarUnitDay
        value:(int)elapsedDays toDate:previousMonthStart options:0] ?: previousMonthStart;
    NSTimeInterval currentStart = monthStart.timeIntervalSince1970;
    return @{ @"monthStart": @(currentStart),
        @"monthEnd": @(fmin(alignedEnd, nextMonthStart.timeIntervalSince1970)),
        @"monthCurveEnd": @(nextMonthStart.timeIntervalSince1970),
        // 每月 1 号这一天 todayStart == monthStart，同比区间两边都是空的，比出来是"持平"。
        @"monthComparableEnd": @(todayStart.timeIntervalSince1970),
        @"previousMonthStart": @(previousMonthStart.timeIntervalSince1970),
        @"previousMonthEnd": @(fmin(currentStart,
            previousComparableEnd.timeIntervalSince1970)) };
}

NSString *PartialTokenKey(NSTimeInterval start, NSTimeInterval end) {
    return [NSString stringWithFormat:@"partial-%.0f-%.0f", start, end];
}

// requestTimestamps 按写入顺序递增，取区间计数用二分即可：逐条比较要在每个窗口上把
// 所有会话的时间戳全走一遍，窗口一多就成了主线程上的固定开销。
static NSUInteger TimestampLowerBound(NSArray<NSNumber *> *timestamps, NSTimeInterval value) {
    NSUInteger low = 0;
    NSUInteger high = timestamps.count;
    while (low < high) {
        NSUInteger middle = low + (high - low) / 2;
        if (timestamps[middle].doubleValue < value) low = middle + 1;
        else high = middle;
    }
    return low;
}

NSDictionary *TokenTotalsInWindow(NSTimeInterval start, NSTimeInterval end,
    NSArray<NSURL *> *urls, NSMutableDictionary *cache) {
    NSMutableDictionary *totals = [NSMutableDictionary dictionary];
    BOOL hasTokenSchema = NO;
    unsigned long long requestCount = 0;
    for (NSURL *url in urls) {
        NSMutableDictionary *summary = [(NSDictionary *)TokenSessionSummary(url, cache) mutableCopy];
        if (!summary) continue;
        hasTokenSchema = YES;
        NSTimeInterval sessionStart = [summary[@"start"] doubleValue];
        NSTimeInterval sessionEnd = [summary[@"end"] doubleValue];
        if (sessionEnd < start || sessionStart >= end) continue;
        NSArray<NSNumber *> *timestamps = [summary[@"requestTimestamps"] isKindOfClass:NSArray.class]
            ? summary[@"requestTimestamps"] : @[];
        requestCount += TimestampLowerBound(timestamps, end) -
            TimestampLowerBound(timestamps, start);
        if (sessionStart >= start) {
            AddTokenCounts(totals, summary[@"total"]);
            continue;
        }
        NSString *partialKey = PartialTokenKey(start, end);
        NSDictionary *partial = summary[partialKey];
        if (!partial) {
            partial = PartialTokenTotals(url, start, end) ?: @{};
            summary[partialKey] = partial;
            cache[url.path] = summary;
        }
        AddTokenCounts(totals, partial);
    }
    if (!hasTokenSchema) return nil;
    // 有会话但没有一条落在窗口内时，真实用量就是 0，不能退化成"无数据"的 `--`。
    if (totals.count == 0) {
        for (NSString *key in TokenKeys()) totals[key] = @0;
    }
    totals[@"request_count"] = @(requestCount);
    return totals;
}

NSDictionary *TokenTotalsForQuota(NSDictionary *quota, double fallbackMinutes,
    NSArray<NSURL *> *urls, NSMutableDictionary *cache) {
    NSTimeInterval start = 0;
    NSTimeInterval end = 0;
    if (!TokenWindowOrFallback(quota, fallbackMinutes, &start, &end)) return nil;
    return TokenTotalsInWindow(start, end, urls, cache);
}

// 日曲线直接汇总各会话解析时就分好的日桶：一天一次窗口聚合会让跨天会话被整篇重读，
// 而日桶只是遍历一遍缓存里的小字典。
NSArray<NSDictionary *> *CodexDailyTokenSeries(NSTimeInterval start, NSTimeInterval end,
    NSArray<NSURL *> *urls, NSMutableDictionary *cache, BOOL *outHasTokenSchema) {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSMutableArray<NSNumber *> *dayStarts = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *buckets = [NSMutableDictionary dictionary];
    NSDate *cursor = [calendar startOfDayForDate:[NSDate dateWithTimeIntervalSince1970:start]];
    while (cursor.timeIntervalSince1970 < end) {
        NSTimeInterval dayStart = cursor.timeIntervalSince1970;
        if (dayStart >= start) {
            [dayStarts addObject:@(dayStart)];
            buckets[DayBucketKey(dayStart)] = [NSMutableDictionary dictionary];
        }
        NSDate *next = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:cursor options:0];
        if (!next) break;
        cursor = next;
    }
    for (NSURL *url in urls) {
        NSDictionary *summary = TokenSessionSummary(url, cache);
        NSDictionary *days = [summary[@"days"] isKindOfClass:NSDictionary.class]
            ? summary[@"days"] : nil;
        if (days && outHasTokenSchema) *outHasTokenSchema = YES;
        for (NSString *key in days) {
            NSMutableDictionary *bucket = buckets[key];
            if (bucket) AddDailyTokenCounts(bucket, days[key]);
        }
    }
    NSMutableArray<NSDictionary *> *series = [NSMutableArray arrayWithCapacity:dayStarts.count];
    for (NSNumber *dayStart in dayStarts) {
        NSMutableDictionary *bucket = buckets[DayBucketKey(dayStart.doubleValue)];
        // 没有任何记录的那天是真实的 0，不能留成空字典让调用方当"无数据"。
        for (NSString *key in TokenKeys()) if (!bucket[key]) bucket[key] = @0;
        if (!bucket[@"request_count"]) bucket[@"request_count"] = @0;
        [series addObject:@{ @"timestamp": dayStart, @"totals": [bucket copy] }];
    }
    return series;
}

// 本月至今的窗口起点是自然日零点、终点在未来（对齐到 10 分钟的"现在"），窗口内不可能有
// 半天，所以日桶之和与按窗口聚合逐字节等价——省掉一遍对全部会话的窗口扫描。
// 上月同期的终点落在某天中间，仍然要走 TokenTotalsInWindow。
NSDictionary *SummedDailyTokenSeries(NSArray<NSDictionary *> *series) {
    NSMutableDictionary *totals = [NSMutableDictionary dictionary];
    for (NSDictionary *day in series) AddDailyTokenCounts(totals, day[@"totals"]);
    for (NSString *key in TokenKeys()) if (!totals[key]) totals[key] = @0;
    if (!totals[@"request_count"]) totals[@"request_count"] = @0;
    return totals;
}

// 日序列里 [start, end) 之间那几天的合计。同比两侧都靠它切出"到最后一个完整自然日为止"。
NSDictionary *SummedDailyTokenSeriesInRange(NSArray<NSDictionary *> *series,
    NSTimeInterval start, NSTimeInterval end) {
    NSMutableArray<NSDictionary *> *slice = [NSMutableArray array];
    for (NSDictionary *day in series) {
        NSTimeInterval timestamp = [day[@"timestamp"] doubleValue];
        if (timestamp >= start && timestamp < end) [slice addObject:day];
    }
    return SummedDailyTokenSeries(slice);
}

// 会话滚出 7 天窗口、额度窗口滚动之后，缓存里对应的条目和 partial-* 分片再也不会被读到。
// 常驻进程不清理就是只增不减。
void PruneTokenCache(NSMutableDictionary *cache, NSArray<NSURL *> *urls,
    NSSet<NSString *> *liveWindowKeys) {
    NSMutableSet<NSString *> *livePaths = [NSMutableSet setWithCapacity:urls.count];
    for (NSURL *url in urls) [livePaths addObject:url.path];
    for (NSString *path in cache.allKeys) {
        if (![livePaths containsObject:path]) {
            [cache removeObjectForKey:path];
            continue;
        }
        NSDictionary *summary = cache[path];
        NSMutableDictionary *trimmed = nil;
        for (NSString *key in summary.allKeys) {
            if (![key hasPrefix:@"partial-"] || [liveWindowKeys containsObject:key]) continue;
            if (!trimmed) trimmed = [summary mutableCopy];
            [trimmed removeObjectForKey:key];
        }
        if (trimmed) cache[path] = trimmed;
    }
}

// 摘要缓存落盘/读回。二进制 plist：内容全是 NSNumber / NSString / NSData / 容器，
// 写入走临时文件 + 替换，中途崩溃不会留下半个文件。缓存丢失或格式不对只意味着重新解析一遍，
// 因此所有失败路径都是静默降级。
NSMutableDictionary *LoadTokenSummaryCache(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return [NSMutableDictionary dictionary];
    id root = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListMutableContainers format:NULL error:NULL];
    if (![root isKindOfClass:NSMutableDictionary.class]) return [NSMutableDictionary dictionary];
    // 条目形如 路径 -> 摘要字典。别的形状一律丢掉，后面的代码不必再防一遍。
    NSMutableDictionary *cache = root;
    for (NSString *key in cache.allKeys) {
        if (![key isKindOfClass:NSString.class] ||
            ![cache[key] isKindOfClass:NSDictionary.class]) {
            [cache removeObjectForKey:key];
        }
    }
    return cache;
}

// Codex 归档是"上月已经算完"的物化结果，一旦落盘就再也不重算（见 UsageByAddingTokenTotals
// 里的 buildsArchive）。旧版本按日期目录名剪枝，长期续写旧会话的机器归出来的档本身就是缺数的，
// 光换扫描口径不会自愈。版本号对不上就整份丢掉，让下一轮重新归一次。
static NSString *const MonthlyArchiveSchemaKey = @"schema";
static const NSInteger MonthlyArchiveSchemaVersion = 2;

NSMutableDictionary *LoadMonthlyUsageArchive(NSString *path) {
    NSMutableDictionary *archive = LoadTokenSummaryCache(path);
    NSDictionary *schema = [archive[MonthlyArchiveSchemaKey] isKindOfClass:NSDictionary.class]
        ? archive[MonthlyArchiveSchemaKey] : nil;
    if ([schema[@"version"] integerValue] != MonthlyArchiveSchemaVersion) [archive removeAllObjects];
    // PruneMonthlyArchive 按 YYYY-MM 的字典序裁剪，"schema" 排在所有月份键之后，不会被裁掉。
    archive[MonthlyArchiveSchemaKey] = @{@"version": @(MonthlyArchiveSchemaVersion)};
    return archive;
}

// NSData 是类簇，可变性判断不能靠 isKindOfClass：二进制 plist 解析出来的**不可变**
// __NSCFData 对 isKindOfClass:NSMutableData 同样返回 YES。据此把只读缓冲区当成可变的
// 原地 appendBytes，就会写到它末尾之外——ASan 抓到的正是这一下：
//   heap-buffer-overflow, WRITE of size 48, 0 bytes after 6640-byte region
//   分配点 __CFBinaryPlistCreateObjectFiltered <- LoadTokenSummaryCache
// 越界写破坏堆之后进程不会当场死，而是在之后任意一次内存操作上倒下，因此崩溃点看起来
// 和这里毫无关系（实际报告里落在 EnumerateLines 和 SaveTokenSummaryCache 上）。
//
// 可靠的做法只有一条：落盘缓存一读回来就把 records 换成本进程创建的可变副本，
// 之后 ClaudeRecordsForFile 的原地追加才成立。只替换 records，其余字段原样保留——
// Codex 侧的条目形状不同（start/total/segments/days…），整条重建会把它们抹掉。
void MakeCachedRecordsMutable(NSMutableDictionary *cache) {
    for (NSString *path in cache.allKeys) {
        NSDictionary *entry = cache[path];
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSData *records = [entry[@"records"] isKindOfClass:NSData.class] ? entry[@"records"] : nil;
        if (!records) continue;
        NSMutableDictionary *updated = [entry mutableCopy];
        updated[@"records"] = [records mutableCopy];
        cache[path] = updated;
    }
}

void SaveTokenSummaryCache(NSDictionary *cache, NSString *path) {
    if (!path.length) return;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:cache
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    if (!data) return;
    NSString *temporary = [path stringByAppendingPathExtension:@"tmp"];
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil];
    if (![data writeToFile:temporary atomically:NO]) return;
    NSURL *destination = [NSURL fileURLWithPath:path];
    if (![NSFileManager.defaultManager replaceItemAtURL:destination
            withItemAtURL:[NSURL fileURLWithPath:temporary] backupItemName:nil options:0
            resultingItemURL:NULL error:NULL]) {
        // 目标还不存在时 replaceItemAtURL 会失败，这时直接搬过去。
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        if (![NSFileManager.defaultManager moveItemAtPath:temporary toPath:path error:nil]) {
            [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
        }
    }
}

// 归档只用来做"上月同期"对比，留着更早的月份没有意义。保留 3 个月是给跨月那一下留余量，
// 顺带在时区/系统时间被改回去时还能命中。
void PruneMonthlyArchive(NSMutableDictionary *archive) {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *monthStart = CurrentMonthStartDate();
    NSDate *oldest = [calendar dateByAddingUnit:NSCalendarUnitMonth value:-3 toDate:monthStart
        options:0] ?: monthStart;
    NSString *oldestKey = MonthArchiveKey(oldest.timeIntervalSince1970);
    for (NSString *key in archive.allKeys) {
        if ([key compare:oldestKey] == NSOrderedAscending) [archive removeObjectForKey:key];
    }
}
