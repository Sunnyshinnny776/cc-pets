#import "CCPetsUsage+Internal.h"
#import "CCPetsProfiles.h"
#import "CCPetsUsageMode.h"

static BOOL AllDigits(NSString *text) {
    if (text.length == 0) return NO;
    static NSCharacterSet *nonDigits;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        nonDigits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet;
    });
    return [text rangeOfCharacterFromSet:nonDigits].location == NSNotFound;
}

const NSArray<NSString *> *TokenKeys(void) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[@"input_tokens", @"cached_input_tokens", @"cache_write_input_tokens",
                 @"output_tokens", @"reasoning_output_tokens", @"total_tokens"];
    });
    return keys;
}

NSDate *ISO8601Timestamp(NSString *value) {
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

NSDictionary *TokenRecordFromLine(NSData *lineData) {
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
NSURL *NewestSessionFileInDirectory(NSURL *directory, NSDate **outDate) {
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
NSURL *NewestCodexSessionURL(NSURL *sessionsURL) {
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
NSNumber *ExhaustionTimestampFromLine(NSData *lineData) {
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

NSDictionary *UsageFromCodexLine(NSData *lineData) {
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
BOOL ExhaustionStillHolds(NSDictionary *usage, NSTimeInterval exhaustedAt) {
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
NSDictionary *UsageByMarkingExhaustion(NSDictionary *usage, NSTimeInterval exhaustedAt) {
    if (![usage isKindOfClass:NSDictionary.class]) return usage;
    if (!ExhaustionStillHolds(usage, exhaustedAt)) return usage;
    NSMutableDictionary *result = [usage mutableCopy];
    result[@"exhaustedAt"] = @(exhaustedAt);
    return result;
}

// 多个会话里的额度是同一个账号的快照，只允许采样时刻向前推进。FSEvents 既可能把
// 多个文件合在一批里，也可能把“响应更早、落盘更晚”的旧文件单独送来；仅在批量候选
// 之间比较不够，最终写入 self.usage 的每个入口都必须经过这一层。
NSDictionary *NewerUsageSnapshot(NSDictionary *current, NSDictionary *candidate) {
    if (![candidate isKindOfClass:NSDictionary.class]) return current;
    if (![current isKindOfClass:NSDictionary.class]) return candidate;
    return [candidate[@"sampledAt"] doubleValue] >= [current[@"sampledAt"] doubleValue]
        ? candidate : current;
}

// token_count 行几乎总在文件末尾，因此从尾部反向按 \n 切片逐行试，命中即停。
// 原实现会把整段（最多 2MB）解码成 NSString、再切成全部行、再把每行编码回 NSData、
// 又解码回 NSString 查子串，等于来回往返两遍。
NSDictionary *LatestUsageInData(NSData *data, NSNumber **outExhaustedAt) {
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
BOOL ProfileShowsAPIUsage(NSString *provider, NSString *home) {
    return CCPetsProfileShowsAPIUsage(CCPetsProfileForHome(provider, home)
        ?: @{@"provider": provider, @"home": home});
}

// resets_at 恒在未来，因此 7 天窗口的起点不可能早于 now - 7d；再留一天覆盖时区和跨日边界。
// 这是所有模式的下限：订阅视图只要这么多，API 视图的月窗口在月初也可能比它还窄。
NSTimeInterval RollingTokenWindowFloor(void) {
    return NSDate.date.timeIntervalSince1970 - 8 * 86400.0;
}

// 本月 1 日 00:00。
NSDate *CurrentMonthStartDate(void) {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *now = NSDate.date;
    NSDateComponents *components = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth
        fromDate:now];
    components.day = 1;
    return [calendar dateFromComponents:components] ?: [calendar startOfDayForDate:now];
}

// 归档的键：本机时区的 YYYY-MM。
NSString *MonthArchiveKey(NSTimeInterval monthStart) {
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
NSArray<NSURL *> *RecentCodexSessionURLs(NSURL *sessionsURL, NSTimeInterval earliest) {
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
NSArray<NSURL *> *TokenAggregationURLs(NSURL *sessionsURL, NSTimeInterval earliest,
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

NSData *SessionTailData(NSURL *url) {
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
NSDictionary *LatestQuotaInRecentSessions(NSURL *sessionsURL, NSURL *skipURL) {
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
