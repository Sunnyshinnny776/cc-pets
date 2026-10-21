#import "CCPetsUsage+Internal.h"
#import "CCPetsPaths.h"
#import <sys/file.h>
#import <sys/stat.h>
#import <errno.h>
#import <fcntl.h>
#import <unistd.h>

// 时钟偏差与整分对齐的余量。resets_at 本身是整分的，这点余量只是不想让几秒的偏差
// 把一份本来正常的快照判死。
static const NSTimeInterval QuotaResetSkewSeconds = 600.0;

// 一份快照要么描述当前窗口，要么就没有任何用处：resets_at 落在过去说明这个窗口早就翻篇，
// 落在一个窗长之外则根本不可能是它的重置时刻。2026-08-19 实测被顶进来的坏快照正是后者
// ——5 小时窗口的 resets_at 报到了十几小时之后。两种都在入口就拒绝，别让它进文件。
BOOL ResetLooksCurrentAt(double reset, double windowMinutes, NSTimeInterval sampledAt) {
    if (reset <= 0 || windowMinutes <= 0) return NO;
    return reset > sampledAt && reset <= sampledAt + windowMinutes * 60.0 + QuotaResetSkewSeconds;
}

BOOL QuotaWindowLooksCurrentAt(NSDictionary *quota, double windowMinutes,
    NSTimeInterval sampledAt) {
    NSNumber *reset = [quota[@"resets_at"] isKindOfClass:NSNumber.class] ? quota[@"resets_at"] : nil;
    if (!reset) return NO;
    return ResetLooksCurrentAt(reset.doubleValue, windowMinutes, sampledAt);
}

BOOL QuotaWindowLooksCurrent(NSDictionary *quota, double windowMinutes, NSTimeInterval now) {
    return QuotaWindowLooksCurrentAt(quota, windowMinutes, now);
}

// Codex 的 rate_limits 是一份会话快照，不会在窗口自然重置时自行刷新。一个快照里的
// 5 小时和 7 天窗口因此可能处于不同状态：例如 5 小时的 resets_at 已过去几天，但 7 天
// 的仍在未来。不能因为后者还活着，就把前者的旧百分比继续当成当前额度展示。
//
// 缺 resets_at 的旧版记录暂时保留，兼容历史会话和只提供百分比的上游版本；只要服务端给了
// 重置时间，就必须用它校验窗口。这个函数放在读取层而不是绘制层，状态栏、历史曲线和气泡
// 台词才能使用同一份已校正的数据。
NSDictionary *UsageByRemovingInactiveQuotaWindows(NSDictionary *usage) {
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

NSDictionary *UsageByRemovingExpiredQuotaWindows(NSDictionary *usage) {
    return UsageByRemovingInactiveQuotaWindows(usage);
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
//
// 用量真的下降（官方口径调整、临时提额）时单调性不成立，只能靠"这份快照来自更新的响应"
// 放行。freshSince / storedSince 就是两份快照各自对应响应的时刻（见 QuotaValueSince）。
// 原先这里是"上次接受已过 10 分钟就无条件放行"，但 statusline 配了 refreshInterval 时，
// 每个开着的空闲会话每分钟都会把自己最后一次响应里的旧额度重报一遍：活跃会话一关，
// 10 分钟后面板就被某个空闲会话的旧值顶掉（2026-09-29 实测剩余 18% → 跳回 70%）。
static BOOL ShouldAcceptQuotaWindow(id storedValue, NSDictionary *fresh, double windowMinutes,
    NSTimeInterval freshSince, NSTimeInterval storedSince, NSTimeInterval now) {
    if (!QuotaWindowLooksCurrent(fresh, windowMinutes, now)) return NO;
    NSDictionary *stored = [storedValue isKindOfClass:NSDictionary.class] ? storedValue : nil;
    if (!stored) return YES;
    // 旧窗口确实到期了：新周期里用量归零是真的。
    if (now >= [stored[@"resets_at"] doubleValue]) return YES;
    if ([fresh[@"used_percentage"] doubleValue] >= [stored[@"used_percentage"] doubleValue]) return YES;
    return freshSince > storedSince;
}

// 一份快照对应的响应是什么时候拿到的。statusline 的 payload 不带这个时刻，只能按会话推断：
// 同一个会话重报的值和它上次一模一样，说明它没有拿到新响应，时刻沿用上次记下的；值变了
// 才是新响应，记为现在。第一次见到的会话记 0（未知）——它可能是早就开着的空闲会话，
// 不能凭"刚被看到"就当成最新；它下一次真的变了自然会拿到时刻。
static NSTimeInterval QuotaValueSince(NSDictionary *previous, NSDictionary *fresh, NSTimeInterval now) {
    if (![previous isKindOfClass:NSDictionary.class]) return 0;
    BOOL unchanged = [previous[@"used_percentage"] isEqual:fresh[@"used_percentage"]] &&
        [previous[@"resets_at"] isEqual:fresh[@"resets_at"]];
    return unchanged ? [previous[@"since"] doubleValue] : now;
}

// 会话记录只为判断"值有没有变"，一天没再上报的会话早就关了；上限防止异常情况下无限增长。
static const NSTimeInterval QuotaSessionRecordTTL = 24 * 60 * 60;
static const NSUInteger QuotaSessionRecordLimit = 64;

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
    NSDictionary *storedSinceValue = [stored[@"value_since"] isKindOfClass:NSDictionary.class]
        ? stored[@"value_since"] : @{};
    NSMutableDictionary *sessions = [stored[@"sessions"] isKindOfClass:NSDictionary.class]
        ? [stored[@"sessions"] mutableCopy] : [NSMutableDictionary dictionary];
    // 没有 session_id 的 payload 无法区分"空闲重报"和"新响应"，只按单调性判。
    NSString *sessionID = [payload[@"session_id"] isKindOfClass:NSString.class] &&
        [payload[@"session_id"] length] > 0 ? payload[@"session_id"] : nil;
    NSDictionary *previousRecord = [sessions[sessionID] isKindOfClass:NSDictionary.class]
        ? sessions[sessionID] : nil;
    NSMutableDictionary *sessionRecord = [@{@"seen_at": @(now)} mutableCopy];

    NSMutableDictionary *merged = stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
    [merged removeObjectForKey:@"accepted_at"];  // 上一版的逃生阀字段，已不再使用。
    NSMutableDictionary *mergedSince = [storedSinceValue mutableCopy];
    NSDictionary *windowMinutes = @{@"five_hour": @(FiveHourWindowMinutes),
                                    @"seven_day": @(SevenDayWindowMinutes)};
    for (NSString *key in @[@"five_hour", @"seven_day"]) {
        NSDictionary *fresh = [limits[key] isKindOfClass:NSDictionary.class] ? limits[key] : nil;
        if (!fresh) continue;  // 这次响应没带某个窗口时保留旧的：整体覆盖会让面板凭空少掉一个窗口。
        NSTimeInterval freshSince = sessionID ? QuotaValueSince(previousRecord[key], fresh, now) : 0;
        if (sessionID) {
            sessionRecord[key] = @{@"used_percentage": fresh[@"used_percentage"] ?: NSNull.null,
                                   @"resets_at": fresh[@"resets_at"] ?: NSNull.null,
                                   @"since": @(freshSince)};
        }
        NSTimeInterval storedSince = [storedSinceValue[key] doubleValue];
        if (!ShouldAcceptQuotaWindow(stored[key], fresh, [windowMinutes[key] doubleValue],
                                     freshSince, storedSince, now)) continue;
        merged[key] = fresh;
        // 按单调性收下的旧响应不能把时刻往回拨，否则更旧的快照就能借它反超。
        mergedSince[key] = @(fmax(freshSince, storedSince));
    }
    merged[@"value_since"] = mergedSince;

    if (sessionID) sessions[sessionID] = sessionRecord;
    for (NSString *key in sessions.allKeys) {
        NSDictionary *record = [sessions[key] isKindOfClass:NSDictionary.class] ? sessions[key] : nil;
        if (!record || now - [record[@"seen_at"] doubleValue] > QuotaSessionRecordTTL) {
            [sessions removeObjectForKey:key];
        }
    }
    if (sessions.count > QuotaSessionRecordLimit) {
        NSArray *oldestFirst = [sessions keysSortedByValueUsingComparator:^NSComparisonResult(id left, id right) {
            return [left[@"seen_at"] compare:right[@"seen_at"]];
        }];
        [sessions removeObjectsForKeys:[oldestFirst subarrayWithRange:
            NSMakeRange(0, sessions.count - QuotaSessionRecordLimit)]];
    }
    merged[@"sessions"] = sessions;
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
    return ClaudeRateLimitsForConfigDirectory(DefaultClaudeConfigDirectory());
}

NSDictionary *ClaudeRateLimitsForConfigDirectory(NSString *configDirectory) {
    NSData *data = [NSData dataWithContentsOfFile:
        ClaudeUsagePathForConfigDirectory(configDirectory)];
    NSDictionary *limits = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![limits isKindOfClass:NSDictionary.class]) return nil;
    id fiveHour = [limits[@"five_hour"] isKindOfClass:NSDictionary.class] ? limits[@"five_hour"] : NSNull.null;
    id week = [limits[@"seven_day"] isKindOfClass:NSDictionary.class] ? limits[@"seven_day"] : NSNull.null;
    // 快照只在有会话上报时更新。窗口到期后没人再报，旧百分比会一直挂着（实测 5 小时窗口
    // 重置后面板仍显示剩余 0%），与 Codex 同样按 resets_at 清掉已经翻篇的窗口。
    return UsageByRemovingInactiveQuotaWindows(@{@"fiveHour": fiveHour, @"week": week});
}

NSDictionary *LatestClaudeUsage(void) {
    return [[ClaudeUsageReader new] refreshWithFullAggregation];
}
