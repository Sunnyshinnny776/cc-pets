#import "CCPetsUsage.h"
#import "CCPetsPaths.h"
#import <sys/file.h>
#import <sys/stat.h>
#import <errno.h>
#import <fcntl.h>
#import <unistd.h>

// Claude 的 rate_limits 不带 window_minutes，窗长按官方订阅固定。既用于 Token 聚合区间，
// 也用于快照的合理性校验，所以定义在这里给两处共用。
static const double FiveHourWindowMinutes = 300;
static const double SevenDayWindowMinutes = 10080;

// 时钟偏差与整分对齐的余量。resets_at 本身是整分的，这点余量只是不想让几秒的偏差
// 把一份本来正常的快照判死。
static const NSTimeInterval QuotaResetSkewSeconds = 600.0;

// 一条限额错误刚发生、手上却一个可用窗口都没有时的保留时长。见 ExhaustionStillHolds。
static const NSTimeInterval RecentExhaustionGraceSeconds = 300.0;

// 一份快照要么描述当前窗口，要么就没有任何用处：resets_at 落在过去说明这个窗口早就翻篇，
// 落在一个窗长之外则根本不可能是它的重置时刻。2026-08-19 实测被顶进来的坏快照正是后者
// ——5 小时窗口的 resets_at 报到了十几小时之后。两种都在入口就拒绝，别让它进文件。
static BOOL ResetLooksCurrentAt(double reset, double windowMinutes, NSTimeInterval sampledAt) {
    if (reset <= 0 || windowMinutes <= 0) return NO;
    return reset > sampledAt && reset <= sampledAt + windowMinutes * 60.0 + QuotaResetSkewSeconds;
}

static BOOL QuotaWindowLooksCurrentAt(NSDictionary *quota, double windowMinutes,
    NSTimeInterval sampledAt) {
    NSNumber *reset = [quota[@"resets_at"] isKindOfClass:NSNumber.class] ? quota[@"resets_at"] : nil;
    if (!reset) return NO;
    return ResetLooksCurrentAt(reset.doubleValue, windowMinutes, sampledAt);
}

static BOOL QuotaWindowLooksCurrent(NSDictionary *quota, double windowMinutes, NSTimeInterval now) {
    return QuotaWindowLooksCurrentAt(quota, windowMinutes, now);
}

// Codex 的 rate_limits 是一份会话快照，不会在窗口自然重置时自行刷新。一个快照里的
// 5 小时和 7 天窗口因此可能处于不同状态：例如 5 小时的 resets_at 已过去几天，但 7 天
// 的仍在未来。不能因为后者还活着，就把前者的旧百分比继续当成当前额度展示。
//
// 缺 resets_at 的旧版记录暂时保留，兼容历史会话和只提供百分比的上游版本；只要服务端给了
// 重置时间，就必须用它校验窗口。这个函数放在读取层而不是绘制层，状态栏、历史曲线和气泡
// 台词才能使用同一份已校正的数据。
static NSDictionary *UsageByRemovingInactiveQuotaWindows(NSDictionary *usage) {
    if (![usage isKindOfClass:NSDictionary.class]) return usage;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSDictionary<NSString *, NSNumber *> *windows = @{
        @"fiveHour": @(FiveHourWindowMinutes),
        @"week": @(SevenDayWindowMinutes)
    };
    NSMutableDictionary *result = nil;
    NSMutableDictionary *expired = nil;
    for (NSString *key in windows) {
        NSDictionary *quota = [usage[key] isKindOfClass:NSDictionary.class] ? usage[key] : nil;
        NSNumber *reset = [quota[@"resets_at"] isKindOfClass:NSNumber.class]
            ? quota[@"resets_at"] : nil;
        if (!reset || QuotaWindowLooksCurrent(quota, windows[key].doubleValue, now)) continue;
        if (!result) result = [usage mutableCopy];
        result[key] = NSNull.null;
        // 百分比不再展示，但 resets_at 必须留下。窗口一旦被清空，"这个窗口已经重置过"
        // 就再也无从得知——而缺失的窗口本来就用 NSNull 表示（官方没给），两者混在一起
        // 分不开。ExhaustionStillHolds 要靠这份记录让受限标记按时失效，否则只剩一个
        // 未到期的 7 天窗口时，一次限流会让卡片永久挂着"额度受限"。
        if (!expired) expired = [NSMutableDictionary dictionary];
        expired[key] = reset;
    }
    if (expired) result[@"expiredWindowResets"] = expired;
    return result ?: usage;
}

// 同一个账号下的每个 Claude 会话都会把自己那次响应里的 rate_limits 抄到同一个文件上，
// 而"响应更早、落盘更晚"在并发会话下完全正常。无条件覆盖时旧快照会盖掉新快照，面板上
// 的剩余额度于是来回跳（实测 99% → 94% → 又回 99%）。同一窗口内官方用量只增不减，
// 据此逐窗口丢弃倒退的快照。
//
// 判据刻意**不比较两份快照的 resets_at**。7 天窗口是滚动的，resets_at 随着旧用量滑出
// 窗口不断前移，前后两次上报差出十几个小时都算正常；原先写的"resets_at 变了就当窗口
// 滚动、无条件接受归零"于是对 7 天窗口几乎每次都成立，这道防线等同于从未生效——
// 2026-08-19 实测面板被一份 used=2% 的旧快照顶成剩余 98%，就是从这条分支进来的。
// 真正的窗口滚动只可能发生在旧窗口到期之后，拿 now 和 storedReset 判断就够了。
static BOOL ShouldAcceptQuotaWindow(id storedValue, NSDictionary *fresh, double windowMinutes,
    BOOL stale, NSTimeInterval now) {
    if (!QuotaWindowLooksCurrent(fresh, windowMinutes, now)) return NO;
    NSDictionary *stored = [storedValue isKindOfClass:NSDictionary.class] ? storedValue : nil;
    if (!stored) return YES;
    // 旧窗口确实到期了：新周期里用量归零是真的。
    if (now >= [stored[@"resets_at"] doubleValue]) return YES;
    if (stale) return YES;
    return [fresh[@"used_percentage"] doubleValue] >= [stored[@"used_percentage"] doubleValue];
}

// 单调性判据只在旧快照还新鲜时成立。官方口径调整（例如临时提额）会让用量真的掉下去，
// 这时旧值必须能被顶掉，否则面板会被永久钉在一个偏高的数字上。
static const NSTimeInterval StaleQuotaSnapshotSeconds = 600.0;

// 拿锁的重试上限。拿不到就放弃这次写入：并发写者手里的数据同样新鲜，跳过一次不丢信息，
// 而无锁写入正是要避免的读改写交错。阻塞版 flock 没有超时，一个被 SIGSTOP 或卡在慢速
// 卷上的写者会把之后每一次 statusline 渲染永久挂住，那是比丢一次采样糟得多的故障。
static const int QuotaLockAttempts = 50;
static const useconds_t QuotaLockRetryMicroseconds = 20 * 1000;

static int AcquireQuotaLock(NSString *lockPath) {
    int descriptor = open(lockPath.fileSystemRepresentation, O_RDONLY | O_CREAT, S_IRUSR | S_IWUSR);
    if (descriptor < 0) return -1;
    for (int attempt = 0; attempt < QuotaLockAttempts; attempt++) {
        if (flock(descriptor, LOCK_EX | LOCK_NB) == 0) return descriptor;
        if (errno != EWOULDBLOCK) break;
        usleep(QuotaLockRetryMicroseconds);
    }
    close(descriptor);
    return -1;
}

int RecordClaudeUsage(void) {
    NSData *input = [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile];
    NSDictionary *payload = input.length > 0 ? [NSJSONSerialization JSONObjectWithData:input options:0 error:nil] : nil;
    NSDictionary *limits = [payload[@"rate_limits"] isKindOfClass:NSDictionary.class] ? payload[@"rate_limits"] : nil;
    if (!limits) return EXIT_SUCCESS;

    NSString *path = ClaudeUsagePath();
    // 判据要先读后写，多个会话同时跑就会读改写交错，所以整段必须在锁里。
    int lockDescriptor = AcquireQuotaLock(ClaudeUsageLockPath());
    if (lockDescriptor < 0) return EXIT_SUCCESS;

    NSData *existing = [NSData dataWithContentsOfFile:path];
    id storedValue = existing.length > 0
        ? [NSJSONSerialization JSONObjectWithData:existing options:0 error:nil] : nil;
    NSDictionary *stored = [storedValue isKindOfClass:NSDictionary.class] ? storedValue : nil;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    // 过期判据必须逐窗口记"上一次被接受的时刻"。用整个文件的写盘时间会让逃生阀失效：
    // 快照被判倒退而拒绝时文件照样被写，只要还有会话在持续上报，就永远到不了 10 分钟，
    // 于是官方真的下调用量时面板被永久钉住——正是这个阀门要防的情况。
    id acceptedValue = stored[@"accepted_at"];
    NSDictionary *accepted = [acceptedValue isKindOfClass:NSDictionary.class] ? acceptedValue : nil;

    NSMutableDictionary *merged = stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
    NSMutableDictionary *mergedAccepted = accepted ? [accepted mutableCopy] : [NSMutableDictionary dictionary];
    NSDictionary *windowMinutes = @{@"five_hour": @(FiveHourWindowMinutes),
                                    @"seven_day": @(SevenDayWindowMinutes)};
    for (NSString *key in @[@"five_hour", @"seven_day"]) {
        NSDictionary *fresh = [limits[key] isKindOfClass:NSDictionary.class] ? limits[key] : nil;
        if (!fresh) continue;  // 这次响应没带某个窗口时保留旧的：整体覆盖会让面板凭空少掉一个窗口。
        // accepted_at 缺失的是上一版写的文件，当过期处理，一次就能迁移过来。
        BOOL stale = now - [accepted[key] doubleValue] > StaleQuotaSnapshotSeconds;
        if (!ShouldAcceptQuotaWindow(stored[key], fresh, [windowMinutes[key] doubleValue],
                                     stale, now)) continue;
        merged[key] = fresh;
        mergedAccepted[key] = @(now);
    }
    merged[@"accepted_at"] = mergedAccepted;
    // 最后一次写盘时间。不再参与任何判据，只留给排查用。
    merged[@"written_at"] = @(now);

    NSData *json = [NSJSONSerialization dataWithJSONObject:merged options:0 error:nil];
    if (json && [json writeToFile:path options:NSDataWritingAtomic error:nil]) {
        chmod(path.fileSystemRepresentation, S_IRUSR | S_IWUSR);
    }
    flock(lockDescriptor, LOCK_UN);
    close(lockDescriptor);
    return EXIT_SUCCESS;
}

NSDictionary *ClaudeRateLimits(void) {
    // 只读主账号那一份。桌宠继承的 CLAUDE_CONFIG_DIR 属于"第一个拉起它的客户端"，
    // 拿它选文件会让面板显示另一个账号的额度。
    NSData *data = [NSData dataWithContentsOfFile:
        ClaudeUsagePathForConfigDirectory(DefaultClaudeConfigDirectory())];
    NSDictionary *limits = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![limits isKindOfClass:NSDictionary.class]) return nil;
    id fiveHour = [limits[@"five_hour"] isKindOfClass:NSDictionary.class] ? limits[@"five_hour"] : NSNull.null;
    id week = [limits[@"seven_day"] isKindOfClass:NSDictionary.class] ? limits[@"seven_day"] : NSNull.null;
    return @{@"fiveHour": fiveHour, @"week": week};
}

NSDictionary *LatestClaudeUsage(void) {
    return [[ClaudeUsageReader new] refreshWithFullAggregation];
}

static BOOL AllDigits(NSString *text) {
    if (text.length == 0) return NO;
    static NSCharacterSet *nonDigits;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        nonDigits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet;
    });
    return [text rangeOfCharacterFromSet:nonDigits].location == NSNotFound;
}

static const NSArray<NSString *> *TokenKeys(void) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[@"input_tokens", @"cached_input_tokens", @"cache_write_input_tokens",
                 @"output_tokens", @"reasoning_output_tokens", @"total_tokens"];
    });
    return keys;
}

static NSDate *ISO8601Timestamp(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSISO8601DateFormatter new];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
            NSISO8601DateFormatWithFractionalSeconds;
    });
    NSDate *date = [formatter dateFromString:value];
    if (date) return date;
    static NSISO8601DateFormatter *fallback;
    static dispatch_once_t fallbackOnce;
    dispatch_once(&fallbackOnce, ^{
        fallback = [NSISO8601DateFormatter new];
        fallback.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    return [fallback dateFromString:value];
}

static NSDictionary *TokenPayloadFromLine(NSData *lineData, NSDictionary **root) {
    if (lineData.length == 0) return nil;
    static NSData *marker;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        marker = [@"\"type\":\"token_count\"" dataUsingEncoding:NSUTF8StringEncoding];
    });
    if ([lineData rangeOfData:marker options:0 range:NSMakeRange(0, lineData.length)].location ==
        NSNotFound) return nil;
    id rootValue = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
    if (![rootValue isKindOfClass:NSDictionary.class]) return nil;
    id payloadValue = ((NSDictionary *)rootValue)[@"payload"];
    if (![payloadValue isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *payload = payloadValue;
    id typeValue = payload[@"type"];
    if (![typeValue isKindOfClass:NSString.class] ||
        ![(NSString *)typeValue isEqualToString:@"token_count"]) return nil;
    if (root) *root = rootValue;
    return payload;
}

static NSDictionary *SanitizedTokenCounts(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    for (NSString *key in TokenKeys()) {
        NSNumber *number = [value[key] isKindOfClass:NSNumber.class] ? value[key] : nil;
        if (number) counts[key] = @([number unsignedLongLongValue]);
    }
    return counts.count > 0 ? counts : nil;
}

static NSDictionary *TokenRecordFromLine(NSData *lineData) {
    NSDictionary *root = nil;
    NSDictionary *payload = TokenPayloadFromLine(lineData, &root);
    NSDictionary *info = [payload[@"info"] isKindOfClass:NSDictionary.class] ? payload[@"info"] : nil;
    NSDate *date = ISO8601Timestamp(root[@"timestamp"]);
    NSDictionary *last = SanitizedTokenCounts(info[@"last_token_usage"]);
    NSDictionary *total = SanitizedTokenCounts(info[@"total_token_usage"]);
    if (!date || (!last && !total)) return nil;
    NSMutableDictionary *record = [@{@"timestamp": @([date timeIntervalSince1970])} mutableCopy];
    if (last) record[@"last"] = last;
    if (total) record[@"total"] = total;
    return record;
}

// 会话目录是零填充的 YYYY/MM/DD，字典序等于时间序，因此倒序取名字即可，不必 stat。
static NSArray<NSURL *> *DescendingNumericSubdirectories(NSURL *directory) {
    NSArray<NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory
        includingPropertiesForKeys:@[NSURLIsDirectoryKey]
        options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSMutableArray<NSURL *> *result = [NSMutableArray arrayWithCapacity:contents.count];
    for (NSURL *url in contents) {
        NSNumber *isDirectory = nil;
        if (![url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil]) continue;
        if (!isDirectory.boolValue || !AllDigits(url.lastPathComponent)) continue;
        [result addObject:url];
    }
    [result sortUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
        return [right.lastPathComponent compare:left.lastPathComponent];
    }];
    return result;
}

// 单个目录内 mtime 最新的 .jsonl。文件名格式不是契约，因此文件一律按 mtime 选，
// 只有日期目录名吃字典序。
static NSURL *NewestSessionFileInDirectory(NSURL *directory, NSDate **outDate) {
    NSArray<NSURLResourceKey> *keys = @[NSURLContentModificationDateKey, NSURLIsRegularFileKey];
    NSArray<NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory
        includingPropertiesForKeys:keys options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSURL *newest = nil;
    NSDate *newestDate = NSDate.distantPast;
    for (NSURL *url in contents) {
        if (![url.pathExtension isEqualToString:@"jsonl"]) continue;
        NSDictionary *values = [url resourceValuesForKeys:keys error:nil];
        if (![values[NSURLIsRegularFileKey] boolValue]) continue;
        NSDate *date = values[NSURLContentModificationDateKey] ?: NSDate.distantPast;
        if ([date compare:newestDate] == NSOrderedDescending) {
            newest = url;
            newestDate = date;
        }
    }
    if (outDate) *outDate = newest ? newestDate : nil;
    return newest;
}

static const NSUInteger MinimumExaminedSessionDays = 3;
static const NSUInteger MaximumExaminedSessionDays = 40;

// 按 YYYY/MM/DD 倒序下钻，成本与历史会话总量无关，只与近期活跃度有关。
// 收手条件必须同时满足“看够 MinimumExaminedSessionDays 个日期目录”和“已经找到过文件”：
// 只写前者的话，用户闲置数天后冷启动会一无所获，比全量扫描更差。
static NSURL *NewestCodexSessionURL(NSURL *sessionsURL) {
    NSURL *newest = nil;
    NSDate *newestDate = NSDate.distantPast;
    NSUInteger examinedDays = 0;
    for (NSURL *year in DescendingNumericSubdirectories(sessionsURL)) {
        for (NSURL *month in DescendingNumericSubdirectories(year)) {
            for (NSURL *day in DescendingNumericSubdirectories(month)) {
                NSDate *date = nil;
                NSURL *candidate = NewestSessionFileInDirectory(day, &date);
                if (candidate && [date compare:newestDate] == NSOrderedDescending) {
                    newest = candidate;
                    newestDate = date;
                }
                examinedDays += 1;
                if (examinedDays >= MinimumExaminedSessionDays && newest) return newest;
                if (examinedDays >= MaximumExaminedSessionDays) return newest;
            }
        }
    }
    // 兜底：非 YYYY/MM/DD 布局（例如直接摊在 sessions/ 下）仍然能被发现。
    return newest ?: NewestSessionFileInDirectory(sessionsURL, NULL);
}

// 额度被拒时 Codex 会写一条带 error.codex_error_info = usage_limit_exceeded 的事件。
// 这是唯一能说明"官方额度现在不给用了"的结构化信号：同一时刻 rate_limits 里
// primary/secondary 全是 null，光看额度字段只能看到"这行没有数据"，于是上一份百分比
// 会一直挂在面板上——账号被别人用完时，那个数字既过期又正好指向相反的结论。
static NSNumber *ExhaustionTimestampFromLine(NSData *lineData) {
    if (lineData.length == 0) return nil;
    static NSData *marker;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        marker = [@"usage_limit_exceeded" dataUsingEncoding:NSUTF8StringEncoding];
    });
    if ([lineData rangeOfData:marker options:0 range:NSMakeRange(0, lineData.length)].location ==
        NSNotFound) return nil;
    id rootValue = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
    if (![rootValue isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *root = rootValue;
    NSDictionary *payload = [root[@"payload"] isKindOfClass:NSDictionary.class] ? root[@"payload"] : nil;
    NSDictionary *error = [payload[@"error"] isKindOfClass:NSDictionary.class] ? payload[@"error"] : nil;
    NSString *info = [error[@"codex_error_info"] isKindOfClass:NSString.class]
        ? error[@"codex_error_info"] : nil;
    if (![info containsString:@"usage_limit"]) return nil;
    NSDate *date = ISO8601Timestamp(root[@"timestamp"]);
    return date ? @(date.timeIntervalSince1970) : nil;
}

static NSDictionary *UsageFromCodexLine(NSData *lineData) {
    NSDictionary *root = nil;
    NSDictionary *payload = TokenPayloadFromLine(lineData, &root);
    if (!payload) return nil;
    id limitsValue = payload[@"rate_limits"];
    if (![limitsValue isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *limits = limitsValue;
    id primaryValue = limits[@"primary"];
    id secondaryValue = limits[@"secondary"];
    NSDictionary *primary = [primaryValue isKindOfClass:NSDictionary.class] ? primaryValue : nil;
    NSDictionary *secondary = [secondaryValue isKindOfClass:NSDictionary.class] ? secondaryValue : nil;
    NSDictionary *fiveHour = nil;
    NSDictionary *week = nil;
    for (NSDictionary *quota in @[primary ?: @{}, secondary ?: @{}]) {
        NSInteger minutes = [quota[@"window_minutes"] integerValue];
        if (minutes == 300) fiveHour = quota;
        if (minutes == 10080) week = quota;
    }
    // primary/secondary 全是 null 的 rate_limits（实测切到 premium/credits 计费后每条都这样）
    // 并不表示额度消失，只是这条响应没带窗口信息。当成"这行没有额度"往前找，
    // 否则上一份仍然有效的窗口会被它整块盖掉，面板退回 `--` + 等待数据。
    if (!fiveHour && !week) return nil;
    // 采样时刻用来和耗尽事件比先后：耗尽之后又拿到新的额度快照，说明额度已经恢复。
    NSDate *sampledAt = ISO8601Timestamp(root[@"timestamp"]);
    return @{
        @"fiveHour": fiveHour ?: NSNull.null,
        @"week": week ?: NSNull.null,
        @"sampledAt": @(sampledAt ? sampledAt.timeIntervalSince1970 : 0)
    };
}

// 受限事件没有窗口归属，只能给它一个有效期：快照里最短窗口的 resets_at 一过，那个窗口
// 必然已经重置，再挂着"额度受限"就是在声称一件我们已经不知道的事——而受限期间官方常年
// 只回 primary/secondary 全 null（见 UsageFromCodexLine），等"更新的快照"来推翻可能等不到。
// 真正用尽的是 7 天窗口时，5 小时窗口重置后仍会被拒，届时会写下新的 usage_limit_exceeded，
// 标记自己会贴回来。
static BOOL ExhaustionStillHolds(NSDictionary *usage, NSTimeInterval exhaustedAt) {
    if (![usage isKindOfClass:NSDictionary.class] || exhaustedAt <= 0) return NO;
    if (exhaustedAt < [usage[@"sampledAt"] doubleValue]) return NO;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSTimeInterval earliestReset = 0;
    BOOL foundReset = NO;
    BOOL foundQuotaWithoutReset = NO;
    NSDictionary<NSString *, NSNumber *> *windows = @{
        @"fiveHour": @(FiveHourWindowMinutes),
        @"week": @(SevenDayWindowMinutes)
    };
    NSDictionary *expired = [usage[@"expiredWindowResets"] isKindOfClass:NSDictionary.class]
        ? usage[@"expiredWindowResets"] : nil;
    for (NSString *key in windows) {
        NSDictionary *quota = [usage[key] isKindOfClass:NSDictionary.class] ? usage[key] : nil;
        NSNumber *reset = [quota[@"resets_at"] isKindOfClass:NSNumber.class] ? quota[@"resets_at"] : nil;
        // 关键是“限额错误发生时”这个 reset 是否还属于当前窗口，而不是它现在是否已过期。
        // 例如错误发生后 5 小时窗口自然重置，标记应当清掉；反过来，数天前就过期的
        // 5 小时快照不能让一条刚发生的错误立即失效。
        if (!quota) {
            // 窗口被 UsageByRemovingInactiveQuotaWindows 清掉了，用它留下的 resets_at 继续
            // 判断。少了这一支，5 小时窗口重置后标记就再也没有失效的依据。
            NSNumber *expiredReset = [expired[key] isKindOfClass:NSNumber.class] ? expired[key] : nil;
            if (!expiredReset) continue;
            foundReset = YES;
            double value = expiredReset.doubleValue;
            if (!ResetLooksCurrentAt(value, windows[key].doubleValue, exhaustedAt)) continue;
            if (earliestReset == 0 || value < earliestReset) earliestReset = value;
            continue;
        }
        if (!reset) {
            foundQuotaWithoutReset = YES;
            continue;
        }
        foundReset = YES;
        if (!QuotaWindowLooksCurrentAt(quota, windows[key].doubleValue, exhaustedAt)) continue;
        double value = reset.doubleValue;
        if (earliestReset == 0 || value < earliestReset) earliestReset = value;
    }
    if (earliestReset > now) return YES;
    // 有一个属于当前窗口的 reset 且它已经过去，说明额度确实重置了，标记必须清掉。
    if (earliestReset > 0) return NO;
    // 走到这里说明一个可用窗口都没有，推不出有效期。这恰恰是最需要受限提示的时刻——
    // 上面注释里说的"受限期间官方常年只回 primary/secondary 全 null"就落在这个分支，
    // app-server 也拿不到实时额度时更是如此。所以刚发生的错误先无条件保留一小段时间，
    // 别让面板在用户正撞限额的当口显示一切正常。
    if (now - exhaustedAt < RecentExhaustionGraceSeconds) return YES;
    // 老版会话只给百分比、没有 resets_at 时无法推断受限状态的有效期；沿用之前的保守
    // 行为，等更新的额度快照来清掉它。只要至少有一个明确的 reset，就以它为准。
    return !foundReset && foundQuotaWithoutReset;
}

// 受限事件仍然成立时，把标记贴到 usage 上。事件本身没有窗口归属，面板只能提示"额度受限"
// 并把已有百分比标为快照，不能据此把 5 小时和 7 天窗口都判成 0。
static NSDictionary *UsageByMarkingExhaustion(NSDictionary *usage, NSTimeInterval exhaustedAt) {
    if (![usage isKindOfClass:NSDictionary.class]) return usage;
    if (!ExhaustionStillHolds(usage, exhaustedAt)) return usage;
    NSMutableDictionary *result = [usage mutableCopy];
    result[@"exhaustedAt"] = @(exhaustedAt);
    return result;
}

// 多个会话里的额度是同一个账号的快照，只允许采样时刻向前推进。FSEvents 既可能把
// 多个文件合在一批里，也可能把“响应更早、落盘更晚”的旧文件单独送来；仅在批量候选
// 之间比较不够，最终写入 self.usage 的每个入口都必须经过这一层。
static NSDictionary *NewerUsageSnapshot(NSDictionary *current, NSDictionary *candidate) {
    if (![candidate isKindOfClass:NSDictionary.class]) return current;
    if (![current isKindOfClass:NSDictionary.class]) return candidate;
    return [candidate[@"sampledAt"] doubleValue] >= [current[@"sampledAt"] doubleValue]
        ? candidate : current;
}

// token_count 行几乎总在文件末尾，因此从尾部反向按 \n 切片逐行试，命中即停。
// 原实现会把整段（最多 2MB）解码成 NSString、再切成全部行、再把每行编码回 NSData、
// 又解码回 NSString 查子串，等于来回往返两遍。
static NSDictionary *LatestUsageInData(NSData *data, NSNumber **outExhaustedAt) {
    const uint8_t *bytes = data.bytes;
    NSUInteger end = data.length;
    NSDictionary *usage = nil;
    NSNumber *exhaustedAt = nil;
    while (end > 0) {
        NSUInteger start = end;
        while (start > 0 && bytes[start - 1] != '\n') start -= 1;
        if (end > start) {
            NSData *line = [data subdataWithRange:NSMakeRange(start, end - start)];
            if (!exhaustedAt) exhaustedAt = ExhaustionTimestampFromLine(line);
            if (!usage) usage = UsageFromCodexLine(line);
            if (usage && exhaustedAt) break;
        }
        end = start > 0 ? start - 1 : 0;
    }
    if (outExhaustedAt) *outExhaustedAt = exhaustedAt;
    return usage;
}

// 「本月 / 上月同期」只有 API 展示模式要用。让默认的订阅视图也回溯到上月月初，等于把上个月
// 的全部会话白解析一遍：本机实测冷启动 7s vs 0.7s，扫描的文件数 327 vs 61。因此按每家自己的
// 展示模式决定回溯多远，两家的读取窗口互不牵连。
static BOOL ProviderShowsAPIUsage(NSString *preferenceKey) {
    return [[NSUserDefaults.standardUserDefaults stringForKey:preferenceKey] isEqualToString:@"api"];
}

// resets_at 恒在未来，因此 7 天窗口的起点不可能早于 now - 7d；再留一天覆盖时区和跨日边界。
// 这是所有模式的下限：订阅视图只要这么多，API 视图的月窗口在月初也可能比它还窄。
static NSTimeInterval RollingTokenWindowFloor(void) {
    return NSDate.date.timeIntervalSince1970 - 8 * 86400.0;
}

// 本月 1 日 00:00。
static NSDate *CurrentMonthStartDate(void) {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *now = NSDate.date;
    NSDateComponents *components = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth
        fromDate:now];
    components.day = 1;
    return [calendar dateFromComponents:components] ?: [calendar startOfDayForDate:now];
}

// 归档的键：本机时区的 YYYY-MM。
static NSString *MonthArchiveKey(NSTimeInterval monthStart) {
    NSDateComponents *components = [NSCalendar.currentCalendar
        components:NSCalendarUnitYear | NSCalendarUnitMonth
        fromDate:[NSDate dateWithTimeIntervalSince1970:monthStart]];
    return [NSString stringWithFormat:@"%04ld-%02ld", (long)components.year, (long)components.month];
}

// 目录名是本机时区的 YYYY/MM/DD。解析不出日期时返回 0，调用方据此放弃剪枝而不是误删。
static NSTimeInterval DayDirectoryEnd(NSURL *year, NSURL *month, NSURL *day) {
    NSDateComponents *components = [NSDateComponents new];
    components.year = year.lastPathComponent.integerValue;
    components.month = month.lastPathComponent.integerValue;
    components.day = day.lastPathComponent.integerValue;
    NSDate *date = [NSCalendar.currentCalendar dateFromComponents:components];
    return date ? date.timeIntervalSince1970 + 86400.0 : 0;
}

// 目录名只说明"会话是哪天建的"，不说明"会话哪天还在被写"：`codex resume` 会一直往
// 建会话那天的目录里追加，实测有用户近 8 天的全部 token_count 都写在 15 天前的
// sessions/2026/08/06/ 里。原实现在这里按目录名直接 return，那台机器上 urls 恒为空，
// 今日 / 最近 7 天的 Token 于是恒为 0（额度却正常——它走 NewestCodexSessionURL，按 mtime）。
// 所以窗口之前的目录不再收手，而是继续扫、只收 mtime 落在窗口内的文件。
// mtime 也是 Claude 侧 AppendRecentTranscriptsInDirectory 用的判据，两边口径就此一致。
static const NSUInteger ResumeLookbackDays = 60;

// earliest 由调用方按当前口径算好：订阅视图是 8 天，API 视图是本月 1 日（上月已归档）或
// 上月 1 日（还没归档，要扫一次把归档建出来），三者都不会早于 8 天下限。
static NSArray<NSURL *> *RecentCodexSessionURLs(NSURL *sessionsURL, NSTimeInterval earliest) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSUInteger examinedDays = 0;
    // 连续多少个"整天落在窗口之前、且一个活跃文件都没有"的目录。成本上界与历史长度无关：
    // 续写旧会话的用户在这个计数清零之前就被捞到，闲置多年的历史最多多读 60 次目录项。
    NSUInteger staleDays = 0;
    // 目录个数的上限跟着时间窗口走，再多留几天处理时区边界和异常目录。
    const NSUInteger maximumTokenDays =
        (NSUInteger)ceil((NSDate.date.timeIntervalSince1970 - earliest) / 86400.0) + 3;
    NSArray<NSURLResourceKey> *keys = @[NSURLIsRegularFileKey, NSURLContentModificationDateKey];
    for (NSURL *year in DescendingNumericSubdirectories(sessionsURL)) {
        for (NSURL *month in DescendingNumericSubdirectories(year)) {
            for (NSURL *day in DescendingNumericSubdirectories(month)) {
                // 天数上限用完之后不是收手，而是降级成同一套 mtime 过滤：直接 return 会
                // 把上限之外那个仍在续写的旧会话又一次切掉。目录名解析不出日期（dayEnd 为 0）
                // 时按窗口内处理，交给天数上限收手，不误删。
                NSTimeInterval dayEnd = DayDirectoryEnd(year, month, day);
                BOOL beforeWindow = (dayEnd > 0 && dayEnd < earliest) ||
                    examinedDays >= maximumTokenDays;
                if (beforeWindow && staleDays >= ResumeLookbackDays) return urls;
                NSArray<NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:day
                    includingPropertiesForKeys:keys options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
                BOOL matched = NO;
                for (NSURL *url in contents) {
                    if (![url.pathExtension.lowercaseString isEqualToString:@"jsonl"]) continue;
                    NSDictionary *values = [url resourceValuesForKeys:keys error:nil];
                    if (![values[NSURLIsRegularFileKey] boolValue]) continue;
                    // 窗口内的目录整目录都要（文件本身可能刚建、mtime 还没落后），窗口之前的
                    // 目录只认最近被写过的文件——判据是 mtime，不是文件里的时间戳：伪造/回填
                    // 的时间戳不该把一份三个月前的会话拉回今天。
                    if (beforeWindow) {
                        NSDate *modified = values[NSURLContentModificationDateKey];
                        if (!modified || modified.timeIntervalSince1970 < earliest) continue;
                    }
                    [urls addObject:url];
                    matched = YES;
                }
                if (beforeWindow) staleDays = matched ? 0 : staleDays + 1;
                else examinedDays += 1;
            }
        }
    }
    return urls;
}

// 目录扫描之外再兜一层：当前正在被增量读取的会话、以及 FSEvents 这一轮点名的会话文件，
// 无条件参与 Token 聚合。内核已经确认它们刚被写过，这个结论比任何按路径名或 mtime 的
// 推断都可靠。多喂进来的文件不会让数字虚高——窗口过滤在 TokenTotalsInWindow 里按行内
// 时间戳做，这里只是保证文件有机会被读到。
static NSArray<NSURL *> *TokenAggregationURLs(NSURL *sessionsURL, NSTimeInterval earliest,
    NSArray<NSURL *> *pinnedURLs) {
    NSMutableArray<NSURL *> *urls = [RecentCodexSessionURLs(sessionsURL, earliest) mutableCopy];
    if (pinnedURLs.count == 0) return urls;
    NSMutableSet<NSString *> *paths = [NSMutableSet setWithCapacity:urls.count];
    for (NSURL *url in urls) [paths addObject:url.path];
    for (NSURL *url in pinnedURLs) {
        if (!url.path.length || [paths containsObject:url.path]) continue;
        // 会话文件可能已经被删/被轮转，PruneTokenCache 拿这份列表当保留集，塞不存在的
        // 路径进去会让缓存条目永远清不掉。
        if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) continue;
        [paths addObject:url.path];
        [urls addObject:url];
    }
    return urls;
}

static NSData *SessionTailData(NSURL *url) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!handle) return nil;
    unsigned long long size = [handle seekToEndOfFile];
    [handle seekToFileOffset:size > 2 * 1024 * 1024 ? size - 2 * 1024 * 1024 : 0];
    NSData *tail = [handle readDataToEndOfFile];
    [handle closeFile];
    return tail;
}

static BOOL UsageHasLiveWindow(NSDictionary *usage) {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSDictionary<NSString *, NSNumber *> *windows = @{
        @"fiveHour": @(FiveHourWindowMinutes),
        @"week": @(SevenDayWindowMinutes)
    };
    for (NSString *key in windows) {
        NSDictionary *quota = [usage[key] isKindOfClass:NSDictionary.class] ? usage[key] : nil;
        if (QuotaWindowLooksCurrent(quota, windows[key].doubleValue, now)) return YES;
    }
    return NO;
}

// 最新会话整篇都没有额度时往前找。rate_limits 是账号级的，写在哪个会话里都一样；
// 而新会话在第一次拿到限流响应之前一条都不写，冷启动正好撞上就会整块空白。
// 只接受 resets_at 还没到的窗口，免得把过期的百分比当成当前值。
static NSDictionary *LatestQuotaInRecentSessions(NSURL *sessionsURL, NSURL *skipURL) {
    // 找的是"最近一次额度快照"，按 mtime 排完只看前 8 个文件，没有必要把上个月的会话
    // 也列出来再排一遍序，因此这里固定用窄窗口。
    NSArray<NSURL *> *urls = [RecentCodexSessionURLs(sessionsURL, RollingTokenWindowFloor())
        sortedArrayUsingComparator:
        ^NSComparisonResult(NSURL *left, NSURL *right) {
            NSDate *leftDate = nil, *rightDate = nil;
            [left getResourceValue:&leftDate forKey:NSURLContentModificationDateKey error:nil];
            [right getResourceValue:&rightDate forKey:NSURLContentModificationDateKey error:nil];
            return [(rightDate ?: NSDate.distantPast) compare:(leftDate ?: NSDate.distantPast)];
        }];
    NSUInteger examined = 0;
    NSDictionary *newest = nil;
    for (NSURL *url in urls) {
        if (skipURL && [url.path isEqualToString:skipURL.path]) continue;
        if (++examined > 8) break;
        NSDictionary *usage = LatestUsageInData(SessionTailData(url), NULL);
        if (!usage || !UsageHasLiveWindow(usage)) continue;
        // mtime 只够用来挑候选：会话在拿到额度之后还会继续追加别的行，文件的新旧顺序和
        // 额度采样的先后并不一致。命中即返回会拿到偏旧的百分比，改成按采样时刻取最新。
        if (!newest || [usage[@"sampledAt"] doubleValue] > [newest[@"sampledAt"] doubleValue]) {
            newest = usage;
        }
    }
    return newest;
}

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

static NSDictionary *TokenCountsBySubtracting(NSDictionary *totals, NSDictionary *baseline);

// 分段必须整篇扫描（末行 total 不再够用），因此改成按偏移增量追读：活跃会话每轮只解析
// 新增的那几行，段状态（各段末尾的累计值）留在缓存里续接。
//
// 解析时顺手把每条记录的增量摊到它所属的自然日（summary[@"days"]）。API 视图要画一个月的
// 日曲线，如果改成按天各扫一遍窗口，跨天会话会被 PartialTokenTotals 整篇重读 31 次——
// 实测本机每次刷新要多花 130ms，全落在主线程上，悬停时连拖动都会卡住。
static NSDictionary *TokenSessionSummary(NSURL *url, NSMutableDictionary *cache) {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    NSDictionary *cached = cache[url.path];
    // 没有 token_count 的会话（旧格式、被截断、刚创建）也会留下缓存条目，否则每一轮都要
    // 把整篇重读一遍。文件长大后 size 变化自然会让缓存失效。
    if (cached && [cached[@"size"] unsignedLongLongValue] == size) {
        return (cached[@"start"] && cached[@"total"]) ? cached : nil;
    }

    unsigned long long offset = 0;
    NSMutableArray<NSDictionary *> *segments = [NSMutableArray array];
    NSMutableArray<NSNumber *> *requestTimestamps = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *days = [NSMutableDictionary dictionary];
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
        lastRequestTotal = total;
        NSDictionary *previous = segments.lastObject;
        if (!previous || TokenTotalsDidReset(total, previous)) [segments addObject:total];
        else segments[segments.count - 1] = total;
    });
    [handle closeFile];

    NSMutableDictionary *summary = [@{@"size": @(size), @"offset": @(offset + consumed)} mutableCopy];
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
        if (lastRequestTotal) summary[@"lastRequestTotal"] = lastRequestTotal;
    }
    cache[url.path] = summary;
    return (start && summary[@"total"]) ? summary : nil;
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
static BOOL TokenWindowOrFallback(NSDictionary *quota, double fallbackMinutes,
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
static void RollingTokenWindows(NSTimeInterval *todayStart, NSTimeInterval *weekStart,
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
static NSDictionary *CalendarMonthWindows(NSTimeInterval alignedEnd) {
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

static NSString *PartialTokenKey(NSTimeInterval start, NSTimeInterval end) {
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

static NSDictionary *TokenTotalsInWindow(NSTimeInterval start, NSTimeInterval end,
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

static NSDictionary *TokenTotalsForQuota(NSDictionary *quota, double fallbackMinutes,
    NSArray<NSURL *> *urls, NSMutableDictionary *cache) {
    NSTimeInterval start = 0;
    NSTimeInterval end = 0;
    if (!TokenWindowOrFallback(quota, fallbackMinutes, &start, &end)) return nil;
    return TokenTotalsInWindow(start, end, urls, cache);
}

// 日曲线直接汇总各会话解析时就分好的日桶：一天一次窗口聚合会让跨天会话被整篇重读，
// 而日桶只是遍历一遍缓存里的小字典。
static NSArray<NSDictionary *> *CodexDailyTokenSeries(NSTimeInterval start, NSTimeInterval end,
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
static NSDictionary *SummedDailyTokenSeries(NSArray<NSDictionary *> *series) {
    NSMutableDictionary *totals = [NSMutableDictionary dictionary];
    for (NSDictionary *day in series) AddDailyTokenCounts(totals, day[@"totals"]);
    for (NSString *key in TokenKeys()) if (!totals[key]) totals[key] = @0;
    if (!totals[@"request_count"]) totals[@"request_count"] = @0;
    return totals;
}

// 日序列里 [start, end) 之间那几天的合计。同比两侧都靠它切出"到最后一个完整自然日为止"。
static NSDictionary *SummedDailyTokenSeriesInRange(NSArray<NSDictionary *> *series,
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
static void PruneTokenCache(NSMutableDictionary *cache, NSArray<NSURL *> *urls,
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
static NSMutableDictionary *LoadTokenSummaryCache(NSString *path) {
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

static NSMutableDictionary *LoadMonthlyUsageArchive(NSString *path) {
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
static void MakeCachedRecordsMutable(NSMutableDictionary *cache) {
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

static void SaveTokenSummaryCache(NSDictionary *cache, NSString *path) {
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
static void PruneMonthlyArchive(NSMutableDictionary *archive) {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *monthStart = CurrentMonthStartDate();
    NSDate *oldest = [calendar dateByAddingUnit:NSCalendarUnitMonth value:-3 toDate:monthStart
        options:0] ?: monthStart;
    NSString *oldestKey = MonthArchiveKey(oldest.timeIntervalSince1970);
    for (NSString *key in archive.allKeys) {
        if ([key compare:oldestKey] == NSOrderedAscending) [archive removeObjectForKey:key];
    }
}

// 一份额度都没拿到时也照样统计 Token：Token 是本机数出来的，不该因为官方额度缺失就空着。
//
// archive 是"已结束自然月"的归档（见 MonthlyUsageArchivePath）。上月一旦归档，扫描范围就
// 收窄到本月，上月的会话文件再也不会被打开；archiveChanged 置位表示这一轮新写了归档，
// 调用方据此落盘。
static NSDictionary *UsageByAddingTokenTotals(NSDictionary *usage, NSURL *sessionsURL,
    NSArray<NSURL *> *pinnedURLs, NSMutableDictionary *cache, NSMutableDictionary *archive,
    BOOL *archiveChanged) {
    if (![usage isKindOfClass:NSDictionary.class]) usage = @{};
    BOOL apiMode = ProviderShowsAPIUsage(CodexUsageDisplayModeKey);
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

// Token 聚合要遍历近 7 天的会话文件，而 refresh 由 FSEvents 驱动、会话写盘时约 0.5 秒
// 一次。按额度窗口节流，窗口滚动或手动刷新时立刻重算。
static const NSTimeInterval TokenAggregationInterval = 5.0;

// 额度窗口的身份：两个 resets_at 一变就说明窗口滚动了，缓存必须作废。
static NSString *TokenWindowIdentity(NSDictionary *usage) {
    NSDictionary *five = [usage[@"fiveHour"] isKindOfClass:NSDictionary.class]
        ? usage[@"fiveHour"] : nil;
    NSDictionary *week = [usage[@"week"] isKindOfClass:NSDictionary.class] ? usage[@"week"] : nil;
    return [NSString stringWithFormat:@"%.0f/%.0f",
        [five[@"resets_at"] doubleValue], [week[@"resets_at"] doubleValue]];
}

// 落盘节流：聚合本身最快 5 秒一次，缓存写盘没必要跟得那么紧。进程被 kill 而没来得及写，
// 代价也只是下次启动多解析一段。
static const NSTimeInterval TokenCacheSaveInterval = 60.0;

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
    if ((self = [super init])) {
        _sessionsURL = CodexSessionsURL();
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
    NSString *identity = TokenWindowIdentity(usage);
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
- (NSDictionary *)refreshForSessionURL:(NSURL *)url {
    return [self refreshForSessionURLs:url ? @[url] : @[]];
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

typedef struct {
    double timestamp;
    uint64_t identity;
    unsigned long long input;
    unsigned long long output;
    unsigned long long cacheRead;
    unsigned long long cacheWrite;
} ClaudeTokenRecord;

// 去重键存 64 位散列而不是原字符串：近 7 天约 5.5k 条记录，散列后每条 48 字节、
// 常驻不到 300KB；64 位空间下这个量级的碰撞概率约 1e-12，可以忽略。
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
static BOOL ClaudeRecordFromLine(NSData *lineData, ClaudeTokenRecord *record) {
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
    return YES;
}

// 桌宠只统计主账号 ~/.claude。刻意不读 CLAUDE_CONFIG_DIR：桌宠是被某个客户端 open
// 起来的常驻进程，会一直带着当时的环境变量。用 claude-nw 启动过一次，桌宠就会永久
// 只统计那个账号，主账号的用量一条都进不来——实测差了 26 倍（156.8M vs 5.96M）。
static NSURL *ClaudeProjectsURL(void) {
    return [NSURL fileURLWithPath:
        [DefaultClaudeConfigDirectory() stringByAppendingPathComponent:@"projects"]];
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
static NSArray<NSURL *> *RecentClaudeTranscriptURLs(NSURL *projectsURL,
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
static NSData *ClaudeRecordsForFile(NSURL *url, NSMutableDictionary *cache) {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path
        error:nil];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    NSDictionary *cached = cache[url.path];
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
            cache[url.path] = @{@"offset": @(offset), @"records": records};
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
        if (index > lineStart && ClaudeRecordFromLine(
                [fresh subdataWithRange:NSMakeRange(lineStart, index - lineStart)], &record)) {
            [records appendBytes:&record length:sizeof(record)];
        }
        lineStart = index + 1;
        consumed = lineStart;
    }
    // 只推进到最后一个换行符，未写完的尾行留到下一轮，避免把半行当成坏数据丢掉。
    cache[url.path] = @{@"offset": @(offset + consumed), @"records": records};
    return records;
}

// 同一次请求会被拆成多行写入（thinking / text / tool_use 各一行），每行都带一份 usage
// 快照，而这些快照是**递增的**：本机实测有 14 组末行的 output_tokens 远大于首行
// （6→235、3→1870），首行取到的是流式过程中的中间值。因此同 identity 的多行必须逐字段
// 取最大值合并，只保留第一条会少算——全量口径下少算 16060 个 output token。
// 取 max 而不是"取最后一行"：fork/resume 会把旧行复制进新文件，跨文件的行序没有保证。
static NSDictionary *ClaudeTokenTotals(NSArray<NSData *> *recordSets, NSTimeInterval start,
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
        }
    }
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
    if ((self = [super init])) {
        _projectsURL = ClaudeProjectsURL();
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
    BOOL apiMode = ProviderShowsAPIUsage(ClaudeUsageDisplayModeKey);
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
    for (NSString *path in self.recordCache.allKeys) {
        if (![livePaths containsObject:path]) [self.recordCache removeObjectForKey:path];
    }
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
    NSDictionary *limits = ClaudeRateLimits() ?: @{@"fiveHour": NSNull.null, @"week": NSNull.null};
    NSString *identity = TokenWindowIdentity(limits);
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
