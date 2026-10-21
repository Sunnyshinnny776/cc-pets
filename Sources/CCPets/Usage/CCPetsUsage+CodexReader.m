#import "CCPetsUsage+Internal.h"
#import "CCPetsPaths.h"

// 一份额度都没拿到时也照样统计 Token：Token 是本机数出来的，不该因为官方额度缺失就空着。
//
// archive 是"已结束自然月"的归档（见 MonthlyUsageArchivePath）。上月一旦归档，扫描范围就
// 收窄到本月，上月的会话文件再也不会被打开；archiveChanged 置位表示这一轮新写了归档，
// 调用方据此落盘。
static NSDictionary *UsageByAddingTokenTotals(NSDictionary *usage, NSURL *sessionsURL,
    NSArray<NSURL *> *pinnedURLs, NSMutableDictionary *cache, NSMutableDictionary *archive,
    BOOL *archiveChanged) {
    if (![usage isKindOfClass:NSDictionary.class]) usage = @{};
    BOOL apiMode = ProfileShowsAPIUsage(@"codex", sessionsURL.path.stringByDeletingLastPathComponent);
    NSTimeInterval rollingFloor = RollingTokenWindowFloor();
    NSDictionary *monthWindows = CalendarMonthWindows(0);
    NSTimeInterval monthStart = [monthWindows[@"monthStart"] doubleValue];
    NSTimeInterval monthCurveEnd = [monthWindows[@"monthCurveEnd"] doubleValue];
    NSTimeInterval monthComparableEnd = [monthWindows[@"monthComparableEnd"] doubleValue];
    NSTimeInterval previousMonthStart = [monthWindows[@"previousMonthStart"] doubleValue];
    NSTimeInterval previousMonthEnd = [monthWindows[@"previousMonthEnd"] doubleValue];
    NSString *previousMonthKey = MonthArchiveKey(previousMonthStart);
    NSArray<NSDictionary *> *archivedDaily = apiMode &&
        [archive[previousMonthKey][@"daily"] isKindOfClass:NSArray.class]
        ? archive[previousMonthKey][@"daily"] : nil;
    // 上月还没归档时才把扫描范围放宽到上月月初，而且只放宽这一次。
    BOOL buildsArchive = apiMode && !archivedDaily;
    NSTimeInterval earliest = buildsArchive ? previousMonthStart
        : (apiMode ? fmin(monthStart, rollingFloor) : rollingFloor);
    NSArray<NSURL *> *urls = TokenAggregationURLs(sessionsURL, earliest, pinnedURLs);
    NSDictionary *five = [usage[@"fiveHour"] isKindOfClass:NSDictionary.class]
        ? usage[@"fiveHour"] : nil;
    NSDictionary *week = [usage[@"week"] isKindOfClass:NSDictionary.class] ? usage[@"week"] : nil;
    NSDictionary *fiveTokens = TokenTotalsForQuota(five, FiveHourWindowMinutes, urls, cache);
    NSDictionary *weekTokens = TokenTotalsForQuota(week, SevenDayWindowMinutes, urls, cache);
    NSTimeInterval todayStart = 0, rollingWeekStart = 0, rollingEnd = 0;
    RollingTokenWindows(&todayStart, &rollingWeekStart, &rollingEnd);
    NSDictionary *todayTokens = TokenTotalsInWindow(todayStart, rollingEnd, urls, cache);
    NSDictionary *recentTokens = TokenTotalsInWindow(rollingWeekStart, rollingEnd, urls, cache);
    // 订阅视图不看月度数据，连算都不必算：会话列表本来就只回溯 8 天，月窗口只会得到
    // 一段被截断的假数据，而代价是每次刷新多遍历一遍全部会话。
    BOOL hasDailySchema = NO;
    // 曲线铺满整个自然月：末尾这些还没到的日子是货真价实的 0，读者能一眼看出月份过了多少。
    NSArray *monthDaily = apiMode
        ? CodexDailyTokenSeries(monthStart, monthCurveEnd, urls, cache, &hasDailySchema) : @[];
    NSDictionary *monthTokens = hasDailySchema ? SummedDailyTokenSeries(monthDaily) : nil;
    NSDictionary *monthComparable = hasDailySchema
        ? SummedDailyTokenSeriesInRange(monthDaily, monthStart, monthComparableEnd) : nil;
    if (buildsArchive) {
        NSArray *previousDaily = CodexDailyTokenSeries(previousMonthStart, monthStart,
            urls, cache, NULL);
        archive[previousMonthKey] = @{ @"daily": previousDaily,
            @"totals": SummedDailyTokenSeries(previousDaily) };
        archivedDaily = previousDaily;
        if (archiveChanged) *archiveChanged = YES;
    }
    NSDictionary *previousMonthTokens = archivedDaily
        ? SummedDailyTokenSeriesInRange(archivedDaily, previousMonthStart, previousMonthEnd) : nil;
    NSMutableSet<NSString *> *liveWindowKeys = [NSMutableSet setWithArray:@[
        PartialTokenKey(todayStart, rollingEnd), PartialTokenKey(rollingWeekStart, rollingEnd)]];
    NSArray<NSDictionary *> *windows = @[
        @{@"quota": five ?: @{}, @"minutes": @(FiveHourWindowMinutes)},
        @{@"quota": week ?: @{}, @"minutes": @(SevenDayWindowMinutes)}];
    for (NSDictionary *window in windows) {
        NSTimeInterval start = 0;
        NSTimeInterval end = 0;
        if (TokenWindowOrFallback(window[@"quota"], [window[@"minutes"] doubleValue], &start, &end)) {
            [liveWindowKeys addObject:PartialTokenKey(start, end)];
        }
    }
    PruneTokenCache(cache, urls, liveWindowKeys);
    NSMutableDictionary *result = [usage mutableCopy];
    result[@"tokenUsage"] = @{
        @"fiveHour": fiveTokens ?: NSNull.null,
        @"week": weekTokens ?: NSNull.null,
        @"today": todayTokens ?: NSNull.null,
        @"recentWeek": recentTokens ?: NSNull.null,
        @"recentWeekStartsAt": @(rollingWeekStart),
        @"month": monthTokens ?: NSNull.null,
        // 同比用的是"到最后一个完整自然日为止"的两段，与展示用的 month（含今天）不是一回事。
        @"monthComparable": monthComparable ?: NSNull.null,
        @"previousMonthToDate": previousMonthTokens ?: NSNull.null,
        @"monthDaily": monthDaily,
        @"monthStartsAt": @(monthStart),
        @"monthComparableEndsAt": @(monthComparableEnd),
        @"previousMonthComparableEndsAt": @(previousMonthEnd),
        @"source": @"local"
    };
    return result;
}

static NSURL *CodexSessionsURL(void) {
    return [NSURL fileURLWithPath:
        [DefaultCodexHomeDirectory() stringByAppendingPathComponent:@"sessions"]];
}

NSDictionary *LatestUsage(void) {
    NSURL *sessions = CodexSessionsURL();
    NSURL *newest = NewestCodexSessionURL(sessions);
    if (!newest) return nil;

    NSData *tail = SessionTailData(newest);
    if (!tail) return nil;
    NSNumber *exhaustedAt = nil;
    NSDictionary *usage = LatestUsageInData(tail, &exhaustedAt)
        ?: LatestQuotaInRecentSessions(sessions, newest);
    usage = UsageByRemovingInactiveQuotaWindows(usage);
    // --status 这类一次性调用不带缓存也不写归档：它只需要当下这一份数字。
    usage = UsageByAddingTokenTotals(usage, sessions, newest ? @[newest] : nil,
        [NSMutableDictionary dictionary],
        LoadMonthlyUsageArchive(MonthlyUsageArchivePath(@"codex", sessions.path)), NULL);
    return UsageByMarkingExhaustion(usage, exhaustedAt.doubleValue);
}

// 额度窗口的身份：两个 resets_at 一变就说明窗口滚动了，缓存必须作废。
NSString *TokenWindowIdentity(NSDictionary *usage) {
    NSDictionary *five = [usage[@"fiveHour"] isKindOfClass:NSDictionary.class]
        ? usage[@"fiveHour"] : nil;
    NSDictionary *week = [usage[@"week"] isKindOfClass:NSDictionary.class] ? usage[@"week"] : nil;
    return [NSString stringWithFormat:@"%.0f/%.0f",
        [five[@"resets_at"] doubleValue], [week[@"resets_at"] doubleValue]];
}

@interface CodexUsageReader ()
@property NSMutableDictionary *tokenSummaryCache;
@property NSString *tokenSummaryCachePath;
@property NSTimeInterval tokenCacheSavedAt;
@property NSMutableDictionary *monthlyArchive;
@property NSString *monthlyArchivePath;
@property NSDictionary *tokenUsage;
@property NSString *tokenWindowIdentity;
@property NSTimeInterval tokenComputedAt;
@property NSTimeInterval exhaustedAt;
@property BOOL forcesTokenAggregation;
// 内核已经点名"刚被写过"的会话文件：当前正在增量读取的这个，以及最近几批 FSEvents 报上来的
// 并发会话。它们无条件参与 Token 聚合，不受日期目录扫描的取舍影响。
@property NSMutableArray<NSURL *> *pinnedSessionURLs;
@end

@implementation CodexUsageReader
- (instancetype)init {
    return [self initWithCodexHome:DefaultCodexHomeDirectory()];
}
- (instancetype)initWithCodexHome:(NSString *)codexHome {
    if ((self = [super init])) {
        _sessionsURL = [NSURL fileURLWithPath:[codexHome stringByAppendingPathComponent:@"sessions"]];
        _partialLine = [NSMutableData data];
        _tokenSummaryCachePath = TokenSummaryCachePath(@"codex", _sessionsURL.path);
        _tokenSummaryCache = LoadTokenSummaryCache(_tokenSummaryCachePath);
        _monthlyArchivePath = MonthlyUsageArchivePath(@"codex", _sessionsURL.path);
        _monthlyArchive = LoadMonthlyUsageArchive(_monthlyArchivePath);
        _pinnedSessionURLs = [NSMutableArray array];
    }
    return self;
}
// 缓存里过期的条目由 PruneTokenCache 在每次聚合里清掉，所以落盘的那份不会只增不减。
- (void)persistTokenSummaryCacheThrottled:(BOOL)throttled {
    if (!self.persistsCache) return;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (throttled && now - self.tokenCacheSavedAt < TokenCacheSaveInterval) return;
    self.tokenCacheSavedAt = now;
    SaveTokenSummaryCache(self.tokenSummaryCache, self.tokenSummaryCachePath);
}
- (NSDictionary *)usageWithTokenTotals:(NSDictionary *)usage {
    if (![usage isKindOfClass:NSDictionary.class]) usage = @{};
    usage = UsageByRemovingInactiveQuotaWindows(usage);
    NSString *identity = [NSString stringWithFormat:@"%@:%d", TokenWindowIdentity(usage),
        ProfileShowsAPIUsage(@"codex", self.sessionsURL.path.stringByDeletingLastPathComponent)];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    BOOL reusable = !self.forcesTokenAggregation && self.tokenUsage &&
        [identity isEqualToString:self.tokenWindowIdentity] &&
        now - self.tokenComputedAt < TokenAggregationInterval;
    if (reusable) {
        NSMutableDictionary *result = [usage mutableCopy];
        result[@"tokenUsage"] = self.tokenUsage;
        return [self usageByApplyingExhaustion:result];
    }
    BOOL archiveChanged = NO;
    // 正在增量读取的会话永远排在钉住列表最前面：它是最不该被漏掉的那一个，而漏掉它
    // 恰恰是"额度读得出、今日 Token 却是 0"的成因。
    [self notePinnedSessionURL:self.sessionURL];
    NSDictionary *result = UsageByAddingTokenTotals(usage, self.sessionsURL,
        self.pinnedSessionURLs, self.tokenSummaryCache, self.monthlyArchive, &archiveChanged);
    if (archiveChanged) {
        PruneMonthlyArchive(self.monthlyArchive);
        if (self.persistsCache) SaveTokenSummaryCache(self.monthlyArchive, self.monthlyArchivePath);
    }
    [self persistTokenSummaryCacheThrottled:YES];
    id tokens = result[@"tokenUsage"];
    self.tokenUsage = [tokens isKindOfClass:NSDictionary.class] ? tokens : nil;
    self.tokenWindowIdentity = identity;
    self.tokenComputedAt = now;
    self.forcesTokenAggregation = NO;
    return [self usageByApplyingExhaustion:result];
}
// 耗尽事件只往前走：额度恢复由"更新的额度快照"或窗口重置表达（见 ExhaustionStillHolds）。
- (void)noteExhaustion:(NSNumber *)timestamp {
    if (timestamp.doubleValue > self.exhaustedAt) self.exhaustedAt = timestamp.doubleValue;
}
// 标记失效时把记下的时刻一并清掉：留着它只会在下一轮再比一次同样的大小，而窗口一旦重置，
// 这个时刻就永远不该再让任何快照被判成受限了。
- (NSDictionary *)usageByApplyingExhaustion:(NSDictionary *)usage {
    if (![usage isKindOfClass:NSDictionary.class]) return usage;
    if (!ExhaustionStillHolds(usage, self.exhaustedAt)) {
        // 快照只会向前走（NewerUsageSnapshot），所以失效一次就是永久失效；真再撞上限流，
        // noteExhaustion: 会记下新的时刻。
        self.exhaustedAt = 0;
        return usage;
    }
    return UsageByMarkingExhaustion(usage, self.exhaustedAt);
}
// 最近被写过的会话，最新的排在前面。并发会话不会太多，留 8 个足够覆盖一批 FSEvents；
// 更早的那些反正也会被目录扫描按 mtime 捞回来，钉住它们只是白读文件。
static const NSUInteger MaximumPinnedSessions = 8;

- (void)notePinnedSessionURL:(NSURL *)url {
    if (!url.path.length) return;
    NSMutableArray<NSURL *> *pinned = self.pinnedSessionURLs;
    if (!pinned) {
        pinned = [NSMutableArray array];
        self.pinnedSessionURLs = pinned;
    }
    for (NSUInteger index = 0; index < pinned.count; index++) {
        if ([pinned[index].path isEqualToString:url.path]) {
            [pinned removeObjectAtIndex:index];
            break;
        }
    }
    [pinned insertObject:url atIndex:0];
    while (pinned.count > MaximumPinnedSessions) [pinned removeLastObject];
}

- (void)selectSessionURL:(NSURL *)url {
    self.sessionURL = url;
    self.offset = 0;
    [self.partialLine setLength:0];
    if (!url) {
        self.usage = nil;
        return;
    }
    [self notePinnedSessionURL:url];
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!handle) return;
    unsigned long long size = [handle seekToEndOfFile];
    unsigned long long start = size > 2 * 1024 * 1024 ? size - 2 * 1024 * 1024 : 0;
    [handle seekToFileOffset:start];
    NSData *tail = [handle readDataToEndOfFile];
    [handle closeFile];
    self.offset = start + tail.length;
    // 切换会话意味着数据来源变了，不受节流约束。
    self.forcesTokenAggregation = YES;
    // 额度是账号级的，不随会话切换失效。新会话在首个 token_count 落盘前没有 rate_limits，
    // 这时沿用上一份，否则每次开新会话面板都会整块闪空。窗口过期的判定另有 resets_at 兜底。
    NSNumber *exhaustedAt = nil;
    NSDictionary *latest = LatestUsageInData(tail, &exhaustedAt);
    [self noteExhaustion:exhaustedAt];
    NSDictionary *fallback = self.usage ?: LatestQuotaInRecentSessions(self.sessionsURL, url);
    self.usage = [self usageWithTokenTotals:NewerUsageSnapshot(fallback, latest)];

    const uint8_t *bytes = tail.bytes;
    NSUInteger lastNewline = NSNotFound;
    for (NSUInteger index = tail.length; index > 0; index--) {
        if (bytes[index - 1] == '\n') {
            lastNewline = index - 1;
            break;
        }
    }
    if (lastNewline == NSNotFound) [self.partialLine appendData:tail];
    else if (lastNewline + 1 < tail.length) {
        [self.partialLine appendData:[tail subdataWithRange:NSMakeRange(lastNewline + 1, tail.length - lastNewline - 1)]];
    }
}
- (void)consumeIncrementalData:(NSData *)data {
    if (data.length == 0) return;
    [self.partialLine appendData:data];
    const uint8_t *bytes = self.partialLine.bytes;
    NSUInteger lineStart = 0;
    for (NSUInteger index = 0; index < self.partialLine.length; index++) {
        if (bytes[index] != '\n') continue;
        NSData *line = [self.partialLine subdataWithRange:NSMakeRange(lineStart, index - lineStart)];
        [self noteExhaustion:ExhaustionTimestampFromLine(line)];
        NSDictionary *newUsage = UsageFromCodexLine(line);
        self.usage = NewerUsageSnapshot(self.usage, newUsage);
        lineStart = index + 1;
    }
    if (lineStart > 0) {
        NSData *remainder = [self.partialLine subdataWithRange:
            NSMakeRange(lineStart, self.partialLine.length - lineStart)];
        self.partialLine = [remainder mutableCopy];
    }
    if (self.partialLine.length > 2 * 1024 * 1024) [self.partialLine setLength:0];
}
- (NSDictionary *)refresh {
    return [self refreshDiscovering:YES];
}
// discovering=NO 用于 FSEvents 定向路径：内核已经点名了变更的文件，再按 mtime 挑一次
// 只会推翻这个结论——发现步骤两条分支（全量的 NewestCodexSessionURL 和同目录的
// NewestSessionFileInDirectory）用的都是 mtime，而 mtime 顺序和额度采样先后并不一致。
- (NSDictionary *)refreshDiscovering:(BOOL)discovering {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (discovering) {
        BOOL needsFullDiscovery = !self.sessionURL || now - self.lastFullDiscovery >= 60;
        NSURL *candidate = nil;
        if (needsFullDiscovery) {
            candidate = NewestCodexSessionURL(self.sessionsURL);
            self.lastFullDiscovery = now;
        } else {
            candidate = NewestSessionFileInDirectory(
                self.sessionURL.URLByDeletingLastPathComponent, NULL);
        }
        if (candidate && ![candidate.path isEqualToString:self.sessionURL.path]) [self selectSessionURL:candidate];
    }
    if (!self.sessionURL) return self.usage;

    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:self.sessionURL error:nil];
    if (!handle) {
        self.lastFullDiscovery = 0;
        return self.usage;
    }
    unsigned long long size = [handle seekToEndOfFile];
    if (size < self.offset) {
        [handle closeFile];
        [self selectSessionURL:self.sessionURL];
        return self.usage;
    }
    if (size > self.offset) {
        unsigned long long start = self.offset;
        [handle seekToFileOffset:start];
        NSData *newData = [handle readDataToEndOfFile];
        self.offset = start + newData.length;
        [self consumeIncrementalData:newData];
    }
    [handle closeFile];
    self.usage = [self usageWithTokenTotals:self.usage];
    return self.usage;
}
- (NSDictionary *)refreshWithFullDiscovery {
    self.lastFullDiscovery = 0;
    self.forcesTokenAggregation = YES;
    return [self refresh];
}
- (BOOL)isSessionURL:(NSURL *)url {
    if (!url || ![url.pathExtension.lowercaseString isEqualToString:@"jsonl"]) return NO;
    NSString *sessionsPath = self.sessionsURL.path.stringByResolvingSymlinksInPath;
    NSString *prefix = [sessionsPath stringByAppendingString:@"/"];
    return [url.path.stringByResolvingSymlinksInPath hasPrefix:prefix];
}
// 并发会话下一批事件里会有多个会话文件同时变更，而"文件更晚被写"和"额度采样更晚"是两回事：
// 会话拿到 rate_limits 之后还会继续追加别的行。取遍历到的最后一个就会切到采样偏旧的会话，
// 面板上的百分比于是在两个会话之间来回跳。这里读各自的尾巴，按 sampledAt 挑，与
// LatestQuotaInRecentSessions 的判据保持一致。
//
// 别的会话也必须读取并比较：迟到的旧响应通常会作为下一批里的唯一文件出现。
// 唯一的例外是当前会话自己——那是单会话的常态热路径，追加的新行走增量读取，
// consumeIncrementalData 里的 NewerUsageSnapshot 已经保证了单调性，不必为它白读一遍尾巴。
- (NSDictionary *)refreshForSessionURLs:(NSArray<NSURL *> *)urls {
    NSURL *chosen = nil;
    NSURL *currentSession = nil;
    double chosenSampledAt = [self.usage[@"sampledAt"] doubleValue];
    for (NSURL *url in urls) {
        if (![self isSessionURL:url]) continue;
        // 额度竞选的输赢与 Token 聚合无关：这一批里每个会话文件都刚被写过，落选的那些
        // 同样带着新的 token_count。钉住它们，别再让日期目录扫描替内核做一次取舍。
        [self notePinnedSessionURL:url];
        if (self.sessionURL && [url.path isEqualToString:self.sessionURL.path]) {
            currentSession = url;
            continue;
        }
        // 耗尽事件也在这段尾巴里。反正已经读了，顺手记下来：候选因为采样更旧而落选时
        // 整批事件都不再走 refresh，不在这里捕获就永远丢了——而"另一个会话刚更新过额度、
        // 这个会话撞上限流"正是最容易发生耗尽的时刻。
        NSNumber *exhaustedAt = nil;
        NSDictionary *usage = LatestUsageInData(SessionTailData(url), &exhaustedAt);
        [self noteExhaustion:exhaustedAt];
        // 整篇都没有额度、或者采样比当前面板更旧的会话不参与竞选。
        if (!usage) continue;
        double sampledAt = [usage[@"sampledAt"] doubleValue];
        if (sampledAt >= chosenSampledAt) {
            chosen = url;
            chosenSampledAt = sampledAt;
        }
    }
    // 没有别的会话胜出时才轮到当前会话，这样先后遍历到谁都不影响结果。
    if (!chosen) chosen = currentSession;
    // 一个候选都没选中就不会再走到 usageWithTokenTotals，刚记下的耗尽标记得在这里贴上。
    if (!chosen) {
        self.usage = [self usageByApplyingExhaustion:self.usage];
        return self.usage;
    }
    if (![chosen.path isEqualToString:self.sessionURL.path]) [self selectSessionURL:chosen];
    return [self refreshDiscovering:NO];
}
@end
