#import <Foundation/Foundation.h>
#import "CCPetsUsage.h"
#import "CCPetsPaths.h"

static NSString *Timestamp(NSTimeInterval value) {
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
        NSISO8601DateFormatWithFractionalSeconds;
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:value]];
}

static NSData *TokenEvent(NSTimeInterval timestamp, unsigned long long input,
    unsigned long long cached, unsigned long long output, BOOL includeLimits,
    NSTimeInterval fiveReset, NSTimeInterval weekReset, unsigned long long totalMultiplier) {
    unsigned long long total = input + cached + output;
    NSDictionary *lastCounts = @{
        @"input_tokens": @(input), @"cached_input_tokens": @(cached),
        @"cache_write_input_tokens": @0, @"output_tokens": @(output),
        @"reasoning_output_tokens": @0, @"total_tokens": @(total)
    };
    NSDictionary *totalCounts = @{
        @"input_tokens": @(input * totalMultiplier),
        @"cached_input_tokens": @(cached * totalMultiplier),
        @"cache_write_input_tokens": @0,
        @"output_tokens": @(output * totalMultiplier),
        @"reasoning_output_tokens": @0,
        @"total_tokens": @(total * totalMultiplier)
    };
    NSMutableDictionary *payload = [@{
        @"type": @"token_count",
        @"info": @{@"last_token_usage": lastCounts, @"total_token_usage": totalCounts}
    } mutableCopy];
    if (includeLimits) {
        payload[@"rate_limits"] = @{
            @"primary": @{@"window_minutes": @300, @"used_percent": @12,
                @"resets_at": @(fiveReset)},
            @"secondary": @{@"window_minutes": @10080, @"used_percent": @34,
                @"resets_at": @(weekReset)}
        };
    }
    NSDictionary *event = @{@"timestamp": Timestamp(timestamp), @"type": @"event_msg",
        @"payload": payload};
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:event options:0 error:nil] mutableCopy];
    [data appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    return data;
}

// 账号额度被（别人）用完之后 Codex 写的两种行：rate_limits 里窗口全是 null，
// 以及 task_complete 带 error.codex_error_info = usage_limit_exceeded。
static NSData *EventLine(NSDictionary *event) {
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:event options:0
        error:nil] mutableCopy];
    [data appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    return data;
}

static NSData *NullLimitsEvent(NSTimeInterval timestamp) {
    return EventLine(@{@"timestamp": Timestamp(timestamp), @"type": @"event_msg",
        @"payload": @{@"type": @"token_count", @"info": NSNull.null,
            @"rate_limits": @{@"limit_id": @"premium", @"primary": NSNull.null,
                @"secondary": NSNull.null,
                @"credits": @{@"has_credits": @NO, @"unlimited": @NO, @"balance": @"0"}}}});
}

static NSData *UsageLimitErrorEvent(NSTimeInterval timestamp) {
    return EventLine(@{@"timestamp": Timestamp(timestamp), @"type": @"event_msg",
        @"payload": @{@"type": @"task_complete", @"last_agent_message": NSNull.null,
            @"error": @{@"message": @"You've hit your usage limit.",
                @"codex_error_info": @"usage_limit_exceeded"}}});
}

int main(void) {
    @autoreleasepool {
        NSString *home = NSProcessInfo.processInfo.environment[@"CC_PETS_CODEX_HOME"];
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        // 日期目录名参与窗口剪枝，写死日期的话这个测试会在 8 天后自己过期。
        NSDateFormatter *dayFormatter = [NSDateFormatter new];
        dayFormatter.dateFormat = @"yyyy/MM/dd";
        NSString *(^sessionDirectory)(NSTimeInterval) = ^(NSTimeInterval when) {
            NSString *path = [home stringByAppendingPathComponent:[NSString stringWithFormat:
                @"sessions/%@", [dayFormatter stringFromDate:
                    [NSDate dateWithTimeIntervalSince1970:when]]]];
            [NSFileManager.defaultManager createDirectoryAtPath:path
                withIntermediateDirectories:YES attributes:nil error:nil];
            return path;
        };
        NSString *directory = sessionDirectory(now);
        NSTimeInterval fiveReset = now + 1800;
        NSTimeInterval weekReset = now + 3600;
        NSArray<NSDictionary *> *fixtures = @[
            @{@"name": @"stale.jsonl", @"time": @(now - 700000), @"input": @300,
                @"cached": @40, @"output": @60, @"mtime": @(now - 30)},
            @{@"name": @"week.jsonl", @"time": @(now - 20000), @"input": @120,
                @"cached": @20, @"output": @60, @"mtime": @(now - 20)},
            @{@"name": @"latest.jsonl", @"time": @(now - 1000), @"input": @60,
                @"cached": @10, @"output": @30, @"mtime": @(now - 10), @"limits": @YES}
        ];
        for (NSDictionary *fixture in fixtures) {
            NSString *path = [directory stringByAppendingPathComponent:fixture[@"name"]];
            NSData *data = TokenEvent([fixture[@"time"] doubleValue],
                [fixture[@"input"] unsignedLongLongValue],
                [fixture[@"cached"] unsignedLongLongValue],
                [fixture[@"output"] unsignedLongLongValue],
                [fixture[@"limits"] boolValue], fiveReset, weekReset, 1);
            [data writeToFile:path atomically:YES];
            [NSFileManager.defaultManager setAttributes:@{
                NSFileModificationDate: [NSDate dateWithTimeIntervalSince1970:[fixture[@"mtime"] doubleValue]]
            } ofItemAtPath:path error:nil];
        }
        // 会话横跨 5 小时窗口起点：5 小时只应计入后一条，7 天使用会话累计值。
        NSString *crossingPath = [directory stringByAppendingPathComponent:@"crossing.jsonl"];
        NSMutableData *crossing = [TokenEvent(now - 17000, 24, 4, 12, NO,
            fiveReset, weekReset, 1) mutableCopy];
        [crossing appendData:TokenEvent(now - 15000, 24, 4, 12, NO,
            fiveReset, weekReset, 2)];
        [crossing writeToFile:crossingPath atomically:YES];
        [NSFileManager.defaultManager setAttributes:@{
            NSFileModificationDate: [NSDate dateWithTimeIntervalSince1970:now - 15]
        } ofItemAtPath:crossingPath error:nil];

        NSDictionary *tokens = LatestUsage()[@"tokenUsage"];
        NSDictionary *five = tokens[@"fiveHour"];
        NSDictionary *week = tokens[@"week"];
        if ([five[@"total_tokens"] unsignedLongLongValue] != 140 ||
            [week[@"total_tokens"] unsignedLongLongValue] != 380 ||
            [week[@"input_tokens"] unsignedLongLongValue] != 228 ||
            [week[@"cached_input_tokens"] unsignedLongLongValue] != 38 ||
            [week[@"output_tokens"] unsignedLongLongValue] != 114) {
            NSLog(@"Token 聚合不正确: %@", tokens);
            return EXIT_FAILURE;
        }
        puts("Codex 5 小时/7 天 Token 聚合测试通过");

        // Codex 会把同一份 token_count 重复写进会话。跨窗口那一段若按 last_token_usage
        // 累加就会把重复的算两遍，因此改成 total_token_usage 求差——累计值对重复是幂等的。
        NSString *duplicateHome = [home stringByAppendingPathComponent:@"duplicate-events"];
        NSString *duplicateDirectory = [duplicateHome stringByAppendingPathComponent:[NSString
            stringWithFormat:@"sessions/%@", [dayFormatter stringFromDate:NSDate.date]]];
        [NSFileManager.defaultManager createDirectoryAtPath:duplicateDirectory
            withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableData *duplicated = [TokenEvent(now - 17000, 24, 4, 12, YES,
            fiveReset, weekReset, 1) mutableCopy];
        [duplicated appendData:TokenEvent(now - 15000, 24, 4, 12, NO, fiveReset, weekReset, 2)];
        [duplicated appendData:TokenEvent(now - 15000, 24, 4, 12, NO, fiveReset, weekReset, 2)];
        [duplicated writeToFile:[duplicateDirectory
            stringByAppendingPathComponent:@"duplicate.jsonl"] atomically:YES];
        setenv("CC_PETS_CODEX_HOME", duplicateHome.fileSystemRepresentation, 1);
        NSDictionary *duplicateFive = LatestUsage()[@"tokenUsage"][@"fiveHour"];
        setenv("CC_PETS_CODEX_HOME", home.fileSystemRepresentation, 1);
        if ([duplicateFive[@"total_tokens"] unsignedLongLongValue] != 40) {
            NSLog(@"重复 token_count 被重复计入: %@", duplicateFive);
            return EXIT_FAILURE;
        }
        puts("Codex 重复 token_count 不重复计入测试通过");

        // resume / 上下文压缩之后 total_token_usage 会在同一个会话文件里归零重来。只认末行
        // 累计值的话，归零之前那一整段全被吞掉（实测最狠的会话漏掉 96%）。因此会话要按
        // 归零点切段：段内仍用累计值求差，段与段相加。两条取数路径都要覆盖——
        // reset.jsonl 整段落在 5 小时窗口内（走末行累计值），crossing-reset.jsonl 跨窗口
        // 起点（走窗口内求差，且归零把窗口前取到的基线一并作废）。
        NSString *resetHome = [home stringByAppendingPathComponent:@"reset-events"];
        NSString *resetDirectory = [resetHome stringByAppendingPathComponent:[NSString
            stringWithFormat:@"sessions/%@", [dayFormatter stringFromDate:NSDate.date]]];
        [NSFileManager.defaultManager createDirectoryAtPath:resetDirectory
            withIntermediateDirectories:YES attributes:nil error:nil];
        // 段一 100 → 300，归零后段二 10 → 50，合计 350。
        NSMutableData *reset = [TokenEvent(now - 1000, 100, 0, 0, NO,
            fiveReset, weekReset, 1) mutableCopy];
        [reset appendData:TokenEvent(now - 800, 100, 0, 0, NO, fiveReset, weekReset, 3)];
        [reset appendData:TokenEvent(now - 600, 10, 0, 0, NO, fiveReset, weekReset, 1)];
        [reset appendData:TokenEvent(now - 400, 10, 0, 0, NO, fiveReset, weekReset, 5)];
        [reset writeToFile:[resetDirectory stringByAppendingPathComponent:@"reset.jsonl"]
            atomically:YES];
        // 5 小时窗口起点是 now - 16200：窗口前基线 100，段一窗口内到 400（计 300），
        // 归零后段二从 0 起算到 60（计 60），合计 360。
        NSMutableData *crossingReset = [TokenEvent(now - 17000, 100, 0, 0, YES,
            fiveReset, weekReset, 1) mutableCopy];
        [crossingReset appendData:TokenEvent(now - 15000, 100, 0, 0, NO, fiveReset, weekReset, 4)];
        [crossingReset appendData:TokenEvent(now - 14000, 10, 0, 0, NO, fiveReset, weekReset, 1)];
        [crossingReset appendData:TokenEvent(now - 13000, 10, 0, 0, NO, fiveReset, weekReset, 6)];
        [crossingReset writeToFile:[resetDirectory
            stringByAppendingPathComponent:@"crossing-reset.jsonl"] atomically:YES];
        setenv("CC_PETS_CODEX_HOME", resetHome.fileSystemRepresentation, 1);
        NSDictionary *resetFive = LatestUsage()[@"tokenUsage"][@"fiveHour"];
        setenv("CC_PETS_CODEX_HOME", home.fileSystemRepresentation, 1);
        if ([resetFive[@"total_tokens"] unsignedLongLongValue] != 710 ||
            [resetFive[@"input_tokens"] unsignedLongLongValue] != 710) {
            NSLog(@"会话内累计值归零后漏算: %@", resetFive);
            return EXIT_FAILURE;
        }
        puts("Codex 会话内累计值归零仍全额计入测试通过");

        // 过期日期目录必须按目录名剪掉：文件内时间戳再新也不该被计入。
        // 扫描窗口要覆盖"上月同期"对比，已经回溯到上月月初（最多约两个自然月），因此这里
        // 取 120 天前——它同时落在天数上限和最早时间点之外，才是无歧义的"过期目录"。
        const NSTimeInterval ancientAge = 120 * 86400;
        NSString *ancientDirectory = sessionDirectory(now - ancientAge);
        NSString *ancientPath = [ancientDirectory stringByAppendingPathComponent:@"ancient.jsonl"];
        [TokenEvent(now - 60, 900, 60, 39, NO, fiveReset, weekReset, 1)
            writeToFile:ancientPath atomically:YES];
        [NSFileManager.defaultManager setAttributes:@{
            NSFileModificationDate: [NSDate dateWithTimeIntervalSince1970:now - ancientAge]
        } ofItemAtPath:ancientPath error:nil];
        if ([LatestUsage()[@"tokenUsage"][@"week"][@"total_tokens"] unsignedLongLongValue] != 380) {
            NSLog(@"过期日期目录未被剪枝");
            return EXIT_FAILURE;
        }
        puts("Codex 过期日期目录剪枝测试通过");

        // 反过来：目录早就过期、但文件今天仍在被追加（`codex resume` 续写旧会话，目录名
        // 停在建会话那天）。这类会话必须照常参与聚合——实测有用户近 8 天的全部 token_count
        // 都写在 15 天前的目录里，按目录名一刀切会让"今日 / 最近 7 天"恒为 0。
        // 与上面那条 ancient.jsonl 正好互为对照：判据是 mtime，不是文件里的时间戳。
        NSString *resumedHome = [home stringByAppendingPathComponent:@"resumed-old-session"];
        NSString *resumedDirectory = [resumedHome stringByAppendingPathComponent:[NSString
            stringWithFormat:@"sessions/%@", [dayFormatter stringFromDate:
                [NSDate dateWithTimeIntervalSince1970:now - 15 * 86400]]]];
        [NSFileManager.defaultManager createDirectoryAtPath:resumedDirectory
            withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *resumedPath = [resumedDirectory
            stringByAppendingPathComponent:@"resumed.jsonl"];
        NSMutableData *resumed = [TokenEvent(now - 16 * 86400, 1000, 0, 0, YES,
            fiveReset, weekReset, 1) mutableCopy];
        [resumed appendData:TokenEvent(now - 120, 1000, 0, 0, YES, fiveReset, weekReset, 2)];
        [resumed writeToFile:resumedPath atomically:YES];
        [NSFileManager.defaultManager setAttributes:@{
            NSFileModificationDate: [NSDate dateWithTimeIntervalSince1970:now - 60]
        } ofItemAtPath:resumedPath error:nil];
        setenv("CC_PETS_CODEX_HOME", resumedHome.fileSystemRepresentation, 1);
        NSDictionary *resumedTokens = LatestUsage()[@"tokenUsage"];
        setenv("CC_PETS_CODEX_HOME", home.fileSystemRepresentation, 1);
        // 窗口前的基线是第一条累计值 1000，今天这条累计到 2000，窗口内计 1000。
        if ([resumedTokens[@"today"][@"total_tokens"] unsignedLongLongValue] != 1000 ||
            [resumedTokens[@"recentWeek"][@"total_tokens"] unsignedLongLongValue] != 1000) {
            NSLog(@"续写旧日期目录的会话未参与聚合: %@", resumedTokens);
            return EXIT_FAILURE;
        }
        puts("Codex 续写旧日期目录会话仍计入测试通过");

        // 有会话但没有一条落在窗口内时应为 0，不能退化成"无数据"。
        NSString *emptyHome = [home stringByAppendingPathComponent:@"empty-window"];
        NSString *emptyDirectory = [emptyHome stringByAppendingPathComponent:[NSString
            stringWithFormat:@"sessions/%@", [dayFormatter stringFromDate:NSDate.date]]];
        [NSFileManager.defaultManager createDirectoryAtPath:emptyDirectory
            withIntermediateDirectories:YES attributes:nil error:nil];
        [TokenEvent(now - 20000, 100, 0, 0, YES, fiveReset, weekReset, 1)
            writeToFile:[emptyDirectory stringByAppendingPathComponent:@"old.jsonl"] atomically:YES];
        setenv("CC_PETS_CODEX_HOME", emptyHome.fileSystemRepresentation, 1);
        NSDictionary *emptyFive = LatestUsage()[@"tokenUsage"][@"fiveHour"];
        setenv("CC_PETS_CODEX_HOME", home.fileSystemRepresentation, 1);
        if (![emptyFive isKindOfClass:NSDictionary.class] ||
            [emptyFive[@"total_tokens"] unsignedLongLongValue] != 0) {
            NSLog(@"窗口内无会话应聚合为 0，实际: %@", emptyFive);
            return EXIT_FAILURE;
        }
        puts("Codex 空窗口 Token 归零测试通过");

        // 账号是共享的，别人把额度用完时本机这份百分比不会动：官方从此只回 primary/
        // secondary 全 null，旧值被原样挂着，还正好指向"我还有额度"的相反结论。
        // 认 usage_limit_exceeded 事件，把这一刻之后的额度按耗尽处理；等新的额度快照
        // 落盘（窗口重置或别人释放），标记要自动消失。
        NSString *exhaustedHome = [home stringByAppendingPathComponent:@"exhausted"];
        NSString *exhaustedDirectory = [exhaustedHome stringByAppendingPathComponent:
            [NSString stringWithFormat:@"sessions/%@", [dayFormatter stringFromDate:NSDate.date]]];
        [NSFileManager.defaultManager createDirectoryAtPath:exhaustedDirectory
            withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *exhaustedPath = [exhaustedDirectory
            stringByAppendingPathComponent:@"rollout.jsonl"];
        NSMutableData *exhaustedLines = [NSMutableData data];
        [exhaustedLines appendData:TokenEvent(now - 3000, 60, 10, 30, YES, fiveReset, weekReset, 1)];
        [exhaustedLines appendData:NullLimitsEvent(now - 100)];
        [exhaustedLines appendData:UsageLimitErrorEvent(now - 90)];
        [exhaustedLines writeToFile:exhaustedPath atomically:YES];
        setenv("CC_PETS_CODEX_HOME", exhaustedHome.fileSystemRepresentation, 1);
        NSDictionary *exhausted = LatestUsage();
        if (![exhausted[@"exhaustedAt"] isKindOfClass:NSNumber.class]) {
            NSLog(@"额度被拒后应标记为已用尽: %@", exhausted);
            setenv("CC_PETS_CODEX_HOME", home.fileSystemRepresentation, 1);
            return EXIT_FAILURE;
        }
        // 全 null 的 rate_limits 不能把上一份仍然有效的窗口抹掉。
        if ([exhausted[@"week"][@"used_percent"] doubleValue] != 34) {
            NSLog(@"全 null 的 rate_limits 不应覆盖上一份额度: %@", exhausted);
            setenv("CC_PETS_CODEX_HOME", home.fileSystemRepresentation, 1);
            return EXIT_FAILURE;
        }
        NSFileHandle *recovery = [NSFileHandle fileHandleForWritingAtPath:exhaustedPath];
        [recovery seekToEndOfFile];
        [recovery writeData:TokenEvent(now - 10, 60, 10, 30, YES, fiveReset, weekReset, 1)];
        [recovery closeFile];
        NSDictionary *recovered = LatestUsage();
        setenv("CC_PETS_CODEX_HOME", home.fileSystemRepresentation, 1);
        if (recovered[@"exhaustedAt"]) {
            NSLog(@"更新的额度快照应清掉耗尽标记: %@", recovered);
            return EXIT_FAILURE;
        }
        puts("Codex 额度耗尽标记与恢复测试通过");

        // 受限之后官方常年只回全 null 的 rate_limits，"等一份更新的快照"可能永远等不到。
        // 快照里最短窗口的 resets_at 一过，那个窗口必然已经重置，标记必须自己失效——
        // 否则一次限流会让卡片永久挂着"额度受限"，趋势曲线也跟着永久停更。
        NSString *staleHome = [home stringByAppendingPathComponent:@"exhausted-stale"];
        NSString *staleDirectory = [staleHome stringByAppendingPathComponent:
            [NSString stringWithFormat:@"sessions/%@", [dayFormatter stringFromDate:NSDate.date]]];
        [NSFileManager.defaultManager createDirectoryAtPath:staleDirectory
            withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableData *staleLines = [NSMutableData data];
        // 快照的 5 小时窗口在 60 秒前就该重置了，之后再撞上限流也只说明"那一刻被拒"。
        [staleLines appendData:TokenEvent(now - 3000, 60, 10, 30, YES, now - 60, now + 3600, 1)];
        [staleLines appendData:NullLimitsEvent(now - 100)];
        [staleLines appendData:UsageLimitErrorEvent(now - 90)];
        [staleLines writeToFile:[staleDirectory stringByAppendingPathComponent:@"rollout.jsonl"]
            atomically:YES];
        setenv("CC_PETS_CODEX_HOME", staleHome.fileSystemRepresentation, 1);
        NSDictionary *stale = LatestUsage();
        setenv("CC_PETS_CODEX_HOME", home.fileSystemRepresentation, 1);
        if (stale[@"exhaustedAt"]) {
            NSLog(@"窗口重置时刻已过时不应再判为额度受限: %@", stale);
            return EXIT_FAILURE;
        }
        // 失效的只是受限标记，官方百分比仍是上一份快照，不能被一起清掉。
        if ([stale[@"week"][@"used_percent"] doubleValue] != 34) {
            NSLog(@"受限标记失效不应带走官方百分比: %@", stale);
            return EXIT_FAILURE;
        }
        puts("Codex 受限标记过期失效测试通过");

        // Token 聚合按窗口节流：额度百分比要实时跟进，Token 沿用缓存；
        // 全量刷新必须绕过节流立即重算。
        CodexUsageReader *reader = [CodexUsageReader new];
        NSString *latestPath = [directory stringByAppendingPathComponent:@"latest.jsonl"];
        if ([[reader refresh][@"tokenUsage"][@"week"][@"total_tokens"] unsignedLongLongValue] != 380) {
            NSLog(@"首次 refresh 的 Token 聚合不正确");
            return EXIT_FAILURE;
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:latestPath];
        [handle seekToEndOfFile];
        // 会话累计值翻倍：latest.jsonl 的贡献从 100 变成 200，7 天合计 380 → 480。
        [handle writeData:TokenEvent(now - 500, 60, 10, 30, YES, fiveReset, weekReset, 2)];
        [handle closeFile];
        NSDictionary *throttled = [reader refresh];
        if (![throttled[@"fiveHour"] isKindOfClass:NSDictionary.class]) {
            NSLog(@"节流不应影响额度本身的增量跟读");
            return EXIT_FAILURE;
        }
        if (![throttled[@"tokenUsage"][@"week"] isKindOfClass:NSDictionary.class] ||
            [throttled[@"tokenUsage"][@"week"][@"total_tokens"] unsignedLongLongValue] != 380) {
            NSLog(@"节流期内不应重算 Token，且不能丢失 tokenUsage: %@", throttled[@"tokenUsage"]);
            return EXIT_FAILURE;
        }
        if ([[reader refreshWithFullDiscovery][@"tokenUsage"][@"week"][@"total_tokens"]
                unsignedLongLongValue] != 480) {
            NSLog(@"全量刷新未绕过节流重算 Token");
            return EXIT_FAILURE;
        }
        puts("Codex Token 聚合节流与强制刷新测试通过");

        // 桌宠是被某个客户端 open 起来的常驻进程，会一直带着当时的 CODEX_HOME。
        // 用它选目录就等于永久绑定到第一个拉起桌宠的那份配置，和 CLAUDE_CONFIG_DIR 同理。
        NSString *decoyHome = [home stringByAppendingPathComponent:@"decoy-codex"];
        NSString *decoyDirectory = [decoyHome stringByAppendingPathComponent:[NSString
            stringWithFormat:@"sessions/%@", [dayFormatter stringFromDate:NSDate.date]]];
        [NSFileManager.defaultManager createDirectoryAtPath:decoyDirectory
            withIntermediateDirectories:YES attributes:nil error:nil];
        [TokenEvent(now - 100, 90000, 0, 0, YES, fiveReset, weekReset, 1)
            writeToFile:[decoyDirectory stringByAppendingPathComponent:@"decoy.jsonl"]
            atomically:YES];
        setenv("CODEX_HOME", decoyHome.fileSystemRepresentation, 1);
        unsigned long long ignored = [LatestUsage()[@"tokenUsage"][@"week"][@"total_tokens"]
            unsignedLongLongValue];
        unsetenv("CODEX_HOME");
        if (ignored != 480) {
            NSLog(@"桌宠端不该跟随继承来的 CODEX_HOME，实际: %llu", ignored);
            return EXIT_FAILURE;
        }
        puts("Codex 桌宠忽略继承的 CODEX_HOME 测试通过");

        // Claude Code：转录行是单次请求的增量，且 --resume/fork/compact 会把旧行原样
        // 复制进新文件，因此必须逐条落窗口累加并全局去重。
        NSString *root = home.stringByDeletingLastPathComponent;
        NSString *claudeHome = [root stringByAppendingPathComponent:@"claude"];
        NSString *stateDirectory = [root stringByAppendingPathComponent:@"claude-state"];
        [NSFileManager.defaultManager createDirectoryAtPath:stateDirectory
            withIntermediateDirectories:YES attributes:nil error:nil];
        // 桌宠端认的是 CC_PETS_CLAUDE_CONFIG_DIR，不是会话级的 CLAUDE_CONFIG_DIR。
        setenv("CC_PETS_CLAUDE_CONFIG_DIR", claudeHome.fileSystemRepresentation, 1);
        setenv("CC_PETS_STATE_DIR", stateDirectory.fileSystemRepresentation, 1);

        NSString *(^project)(NSString *) = ^(NSString *name) {
            NSString *path = [claudeHome stringByAppendingPathComponent:
                [@"projects" stringByAppendingPathComponent:name]];
            [NSFileManager.defaultManager createDirectoryAtPath:path
                withIntermediateDirectories:YES attributes:nil error:nil];
            return path;
        };
        // 每条记录固定 1/2/3/4，合计 10，方便按条数反推期望值。
        NSData *(^assistantLine)(NSTimeInterval, NSString *, NSString *, NSString *) =
            ^(NSTimeInterval at, NSString *identifier, NSString *request, NSString *uuid) {
            NSMutableDictionary *message = [@{@"usage": @{
                @"input_tokens": @1, @"output_tokens": @2,
                @"cache_read_input_tokens": @3, @"cache_creation_input_tokens": @4
            }} mutableCopy];
            if (identifier) message[@"id"] = identifier;
            NSMutableDictionary *line = [@{@"type": @"assistant", @"timestamp": Timestamp(at),
                @"message": message} mutableCopy];
            if (request) line[@"requestId"] = request;
            if (uuid) line[@"uuid"] = uuid;
            NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:line options:0
                error:nil] mutableCopy];
            [data appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
            return (NSData *)data;
        };

        NSTimeInterval claudeFiveReset = now + 1800;
        NSTimeInterval claudeWeekReset = now + 3600;
        NSTimeInterval claudeFiveStart = claudeFiveReset - 300 * 60;
        void (^writeLimits)(NSDictionary *) = ^(NSDictionary *limits) {
            [[NSJSONSerialization dataWithJSONObject:limits options:0 error:nil]
                writeToFile:ClaudeUsagePath() atomically:YES];
        };
        writeLimits(@{@"five_hour": @{@"used_percentage": @23, @"resets_at": @(claudeFiveReset)},
                      @"seven_day": @{@"used_percentage": @41, @"resets_at": @(claudeWeekReset)}});

        NSMutableData *first = [NSMutableData data];
        [first appendData:assistantLine(now - 100, @"m1", @"r1", @"u1")];   // 5 小时 + 7 天
        [first appendData:assistantLine(now - 200, @"m2", @"r2", @"u2")];   // 5 小时 + 7 天
        // 夹住 5 小时窗口的起点：内侧计入，外侧只进 7 天。不取端点本身，因为时间戳只
        // 保留到毫秒，端点会被取整挤出窗口，断言会随运行时刻抖动。
        [first appendData:assistantLine(claudeFiveStart + 1, @"m7", @"r7", @"u7")];
        [first appendData:assistantLine(claudeFiveStart - 1, @"m8", @"r8", @"u8")];
        [first appendData:assistantLine(now - 20000, @"m4", @"r4", @"u4")]; // 只在 7 天内
        [first appendData:assistantLine(now - 700000, @"m5", @"r5", @"u5")]; // 两个窗口都在外
        [first appendData:assistantLine(now - 300, nil, nil, @"u6")];       // 缺 id/requestId
        [first writeToFile:[project(@"-Users-a") stringByAppendingPathComponent:@"a.jsonl"]
            atomically:YES];

        NSMutableData *forked = [NSMutableData data];
        [forked appendData:assistantLine(now - 100, @"m1", @"r1", @"u1")];  // fork 复制，必须去重
        [forked appendData:assistantLine(now - 300, nil, nil, @"u6")];      // uuid 回退去重
        [forked writeToFile:[project(@"-Users-b") stringByAppendingPathComponent:@"b.jsonl"]
            atomically:YES];

        NSDictionary *claude = LatestClaudeUsage()[@"tokenUsage"];
        if ([claude[@"fiveHour"][@"total_tokens"] unsignedLongLongValue] != 40 ||
            [claude[@"week"][@"total_tokens"] unsignedLongLongValue] != 60 ||
            [claude[@"week"][@"input_tokens"] unsignedLongLongValue] != 6 ||
            [claude[@"week"][@"output_tokens"] unsignedLongLongValue] != 12 ||
            [claude[@"week"][@"cached_input_tokens"] unsignedLongLongValue] != 18 ||
            [claude[@"week"][@"cache_write_input_tokens"] unsignedLongLongValue] != 24) {
            NSLog(@"Claude Token 聚合不正确: %@", claude);
            return EXIT_FAILURE;
        }
        if (![claude[@"source"] isEqualToString:@"local"]) {
            NSLog(@"Claude Token 来源标记不正确: %@", claude[@"source"]);
            return EXIT_FAILURE;
        }
        puts("Claude Code 5 小时/7 天 Token 聚合与跨文件去重测试通过");

        // 缺 resets_at 或窗口已过期时，官方口径没了，但 Token 一直是本机数出来的：降级成
        // 按本机时钟往回推的滚动窗口继续统计，而不是整列退化成 `--`。
        // 滚动 5 小时窗口把 claudeFiveStart±1 两条和 now-100/-200/-300 都圈进来（5 条 50），
        // now-20000 落在窗外；滚动 7 天只把 now-700000 排除在外（6 条 60）。
        writeLimits(@{@"five_hour": @{@"used_percentage": @23},
                      @"seven_day": @{@"used_percentage": @41, @"resets_at": @(now - 60)}});
        NSDictionary *degraded = LatestClaudeUsage()[@"tokenUsage"];
        if ([degraded[@"fiveHour"][@"total_tokens"] unsignedLongLongValue] != 50 ||
            [degraded[@"week"][@"total_tokens"] unsignedLongLongValue] != 60) {
            NSLog(@"缺失或过期的额度窗口应降级为滚动窗口统计: %@", degraded);
            return EXIT_FAILURE;
        }
        // 窗口到期后没人再上报，旧百分比不能继续挂着（实测 5 小时窗口重置后仍显示剩余 0%）。
        // 缺 resets_at 的旧记录无从判断，照旧保留。
        NSDictionary *expiredLimits = LatestClaudeUsage();
        if (expiredLimits[@"week"] != NSNull.null ||
            [expiredLimits[@"fiveHour"][@"used_percentage"] integerValue] != 23) {
            NSLog(@"已过期的额度窗口应清掉，缺 resets_at 的应保留: %@", expiredLimits);
            return EXIT_FAILURE;
        }
        puts("Claude Code 额度窗口缺失与过期降级测试通过");

        // 额度快照文件压根不存在（第三方 statusline 注入不进去、或账号本身不带 rate_limits）
        // 时，Token 也必须照常统计：本机数出来的用量不该被官方额度一票否决，否则面板上
        // Claude 整行都是 `--`，看起来像统计坏了。窗口口径与上面的降级用例一致。
        [NSFileManager.defaultManager removeItemAtPath:ClaudeUsagePath() error:nil];
        NSDictionary *withoutLimits = LatestClaudeUsage();
        NSDictionary *withoutLimitsTokens = withoutLimits[@"tokenUsage"];
        if ([withoutLimitsTokens[@"fiveHour"][@"total_tokens"] unsignedLongLongValue] != 50 ||
            [withoutLimitsTokens[@"week"][@"total_tokens"] unsignedLongLongValue] != 60 ||
            [withoutLimitsTokens[@"today"][@"total_tokens"] unsignedLongLongValue] == 0) {
            NSLog(@"缺少额度快照时 Token 被一并吞掉: %@", withoutLimits);
            return EXIT_FAILURE;
        }
        // 百分比该缺就缺：没有额度数据时两个窗口都是 null，不能凭空造一个。
        if (withoutLimits[@"fiveHour"] != NSNull.null || withoutLimits[@"week"] != NSNull.null) {
            NSLog(@"缺少额度快照时不应有额度窗口: %@", withoutLimits);
            return EXIT_FAILURE;
        }
        writeLimits(@{@"five_hour": @{@"used_percentage": @23, @"resets_at": @(claudeFiveReset)},
                      @"seven_day": @{@"used_percentage": @41, @"resets_at": @(claudeWeekReset)}});
        puts("Claude Code 缺少额度快照仍统计 Token 测试通过");

        // 汇总条要并列展示两家，而两家的 resets_at 并不一致，按各自订阅窗口算出来的数不在
        // 同一区间上。自然日窗口与额度完全脱钩：这里把额度窗口整个抽掉，today /
        // recentWeek 仍须照常统计。
        writeLimits(@{@"five_hour": @{@"used_percentage": @23},
                      @"seven_day": @{@"used_percentage": @41}});
        NSDictionary *rolling = LatestClaudeUsage()[@"tokenUsage"];
        if ([rolling[@"fiveHour"][@"total_tokens"] unsignedLongLongValue] != 50 ||
            [rolling[@"week"][@"total_tokens"] unsignedLongLongValue] != 60) {
            NSLog(@"额度窗口整个抽掉时仍应有滚动窗口的统计: %@", rolling);
            return EXIT_FAILURE;
        }
        // today 是本地自然日窗口，夹具却是按"距 now 多少秒"铺的，两者的相对位置随运行时刻
        // 变化：跨过午夜之后，claudeFiveStart±1 和 now-20000 这三条会落到昨天去。写死 60
        // 只在本地时间晚于约 05:34 时成立，凌晨跑必挂，所以按同一口径现算期望值。
        // 去重后的 6 条各 10，m1/u6 被 fork 复制的那两条不重复计入。
        NSTimeInterval fixtureAt[] = {
            now - 100, now - 200, claudeFiveStart + 1, claudeFiveStart - 1, now - 20000, now - 300
        };
        NSTimeInterval midnight = [NSCalendar.currentCalendar
            startOfDayForDate:[NSDate dateWithTimeIntervalSince1970:now]].timeIntervalSince1970;
        NSDate *expectedWeekStartDate = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitDay
            value:-6 toDate:[NSDate dateWithTimeIntervalSince1970:midnight] options:0];
        NSTimeInterval expectedWeekStart = expectedWeekStartDate.timeIntervalSince1970;
        unsigned long long expectedToday = 0;
        for (NSUInteger index = 0; index < sizeof(fixtureAt) / sizeof(fixtureAt[0]); index++) {
            // 与 ClaudeTokenTotals 的窗口边界一致：[start, end)。
            if (fixtureAt[index] >= midnight) expectedToday += 10;
        }
        if ([rolling[@"today"][@"total_tokens"] unsignedLongLongValue] != expectedToday ||
            [rolling[@"recentWeek"][@"total_tokens"] unsignedLongLongValue] != 60 ||
            fabs([rolling[@"recentWeekStartsAt"] doubleValue] - expectedWeekStart) > 0.5) {
            NSLog(@"自然日窗口应与额度窗口无关地照常统计（today 期望 %llu）: %@",
                expectedToday, rolling);
            return EXIT_FAILURE;
        }
        puts("Claude Code 汇总口径与订阅窗口解耦测试通过");

        // Codex 侧同样要给出自然日口径，否则汇总条里的两家数据不可比。
        NSDictionary *codexRolling = LatestUsage()[@"tokenUsage"];
        if (![codexRolling[@"today"] isKindOfClass:NSDictionary.class] ||
            ![codexRolling[@"recentWeek"] isKindOfClass:NSDictionary.class] ||
            fabs([codexRolling[@"recentWeekStartsAt"] doubleValue] - expectedWeekStart) > 0.5) {
            NSLog(@"Codex 缺少自然日口径的 Token 统计: %@", codexRolling);
            return EXIT_FAILURE;
        }
        puts("Codex 汇总口径与订阅窗口解耦测试通过");

        // 一台机器上可以有多个 Claude 配置目录（~/.claude 与 ~/.claude-nw），各自是不同
        // 账号、不同额度。桌宠是被某个客户端 open 起来的常驻进程，会把当时的
        // CLAUDE_CONFIG_DIR 一直带着——用它选目录，桌宠就会永久只统计"第一个拉起它的
        // 账号"，主账号一条都进不来（实测差 26 倍）。所以桌宠端必须无视这个变量。
        NSString *foreign = [root stringByAppendingPathComponent:@"claude-nw"];
        [NSFileManager.defaultManager createDirectoryAtPath:
            [foreign stringByAppendingPathComponent:@"projects/-Users-x"]
            withIntermediateDirectories:YES attributes:nil error:nil];
        [assistantLine(now - 100, @"n1", @"nr1", @"nu1")
            writeToFile:[foreign stringByAppendingPathComponent:@"projects/-Users-x/n.jsonl"]
            atomically:YES];
        writeLimits(@{@"five_hour": @{@"used_percentage": @23, @"resets_at": @(claudeFiveReset)},
                      @"seven_day": @{@"used_percentage": @41, @"resets_at": @(claudeWeekReset)}});

        setenv("CLAUDE_CONFIG_DIR", foreign.fileSystemRepresentation, 1);
        NSDictionary *inherited = LatestClaudeUsage()[@"tokenUsage"];
        unsigned long long inheritedWeek =
            [inherited[@"recentWeek"][@"total_tokens"] unsignedLongLongValue];
        unsigned long long inheritedFive =
            [inherited[@"fiveHour"][@"total_tokens"] unsignedLongLongValue];
        unsetenv("CLAUDE_CONFIG_DIR");
        // 另一个目录里只有 1 条记录（10）；主账号有 6 条（60）。读错目录会立刻露馅。
        if (inheritedWeek != 60 || inheritedFive != 40) {
            NSLog(@"桌宠受继承的 CLAUDE_CONFIG_DIR 影响了: 7天=%llu 5小时=%llu",
                inheritedWeek, inheritedFive);
            return EXIT_FAILURE;
        }
        puts("Claude Code 桌宠忽略继承的 CLAUDE_CONFIG_DIR 测试通过");

        // 额度是按账号的：两个配置目录必须写到不同文件，否则各自的 statusline 会互相
        // 覆盖，面板就会把 A 账号的剩余百分比配上 B 账号的用量。
        NSString *mine = ClaudeUsagePathForConfigDirectory(DefaultClaudeConfigDirectory());
        NSString *theirs = ClaudeUsagePathForConfigDirectory(foreign);
        if ([mine isEqualToString:theirs]) {
            NSLog(@"不同配置目录共用了同一个额度文件: %@", mine);
            return EXIT_FAILURE;
        }
        setenv("CLAUDE_CONFIG_DIR", foreign.fileSystemRepresentation, 1);
        NSString *recorded = ClaudeUsagePath();
        unsetenv("CLAUDE_CONFIG_DIR");
        // 记录端跑在 CLI 会话里，必须按会话真正使用的目录落盘。
        if (![recorded isEqualToString:theirs]) {
            NSLog(@"记录端没有按会话的 CLAUDE_CONFIG_DIR 落盘: %@", recorded);
            return EXIT_FAILURE;
        }
        NSString *sameNameElsewhere = [NSTemporaryDirectory()
            stringByAppendingPathComponent:foreign.lastPathComponent];
        NSString *sameNamePath = ClaudeUsagePathForConfigDirectory(sameNameElsewhere);
        if ([sameNamePath isEqualToString:theirs]) {
            NSLog(@"末级同名的不同配置目录共用了额度文件: %@", sameNamePath);
            return EXIT_FAILURE;
        }
        puts("Claude Code 多配置目录额度文件隔离测试通过");

        // 子 agent（Task/Explore）的转录单独落在 <project>/<session-uuid>/subagents/ 下，
        // 只扫项目目录一层的话这部分用量整块漏掉。同时验证去重是全局的：子链里被复制的
        // 主线记录（m1/r1）不能再算一遍。
        NSString *subagents = [project(@"-Users-a")
            stringByAppendingPathComponent:@"a/subagents"];
        [NSFileManager.defaultManager createDirectoryAtPath:subagents
            withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableData *sidechain = [NSMutableData data];
        [sidechain appendData:assistantLine(now - 150, @"s1", @"sr1", @"su1")]; // 5 小时 + 7 天
        [sidechain appendData:assistantLine(now - 100, @"m1", @"r1", @"u1")];   // 与主线重复
        [sidechain writeToFile:[subagents stringByAppendingPathComponent:@"agent-x.jsonl"]
            atomically:YES];

        NSDictionary *withSubagents = LatestClaudeUsage()[@"tokenUsage"];
        unsigned long long subFive =
            [withSubagents[@"fiveHour"][@"total_tokens"] unsignedLongLongValue];
        unsigned long long subWeek =
            [withSubagents[@"week"][@"total_tokens"] unsignedLongLongValue];
        // 主账号原本 5 小时 40 / 7 天 60，子 agent 只多出 s1 这一条（10）。
        if (subFive != 50 || subWeek != 70) {
            NSLog(@"子 agent 的 Token 没有被统计或重复计入: 5小时=%llu 7天=%llu",
                subFive, subWeek);
            return EXIT_FAILURE;
        }
        puts("Claude Code 子 agent 转录纳入统计测试通过");

        // 主会话文件已经滚出窗口的会话，不再下钻它的 subagents：projects/ 只增不减，
        // 无条件下钻等于给每个历史会话白跑一次 readdir。Task 的调用和结果都写在主会话
        // 文件里，主文件不在窗口内，它的子 agent 也不可能在。
        NSString *staleProject = project(@"-Users-d");
        NSString *stalePath = [staleProject stringByAppendingPathComponent:@"d.jsonl"];
        [assistantLine(now - 100, @"d1", @"dr1", @"du1") writeToFile:stalePath atomically:YES];
        NSString *staleSubagents = [staleProject stringByAppendingPathComponent:@"d/subagents"];
        [NSFileManager.defaultManager createDirectoryAtPath:staleSubagents
            withIntermediateDirectories:YES attributes:nil error:nil];
        [assistantLine(now - 150, @"d2", @"dr2", @"du2")
            writeToFile:[staleSubagents stringByAppendingPathComponent:@"agent-z.jsonl"]
            atomically:YES];
        // 主会话文件的 mtime 推到 120 天前，子 agent 文件保持最新。取 120 天而不是 30 天：
        // 转录的读取窗口已经回溯到上月月初，30 天前的主会话仍可能落在窗口内。
        [NSFileManager.defaultManager setAttributes:
            @{NSFileModificationDate: [NSDate dateWithTimeIntervalSince1970:now - 120 * 86400]}
            ofItemAtPath:stalePath error:nil];
        NSDictionary *pruned = LatestClaudeUsage()[@"tokenUsage"];
        if ([pruned[@"fiveHour"][@"total_tokens"] unsignedLongLongValue] != 50 ||
            [pruned[@"week"][@"total_tokens"] unsignedLongLongValue] != 70) {
            NSLog(@"主会话文件滚出窗口后不该再下钻它的 subagents: %@", pruned);
            return EXIT_FAILURE;
        }
        puts("Claude Code 按主会话 mtime 剪枝 subagents 下钻测试通过");

        // 同一次请求会被拆成多行，每行带一份**递增**的 usage 快照。去重时保留第一条会
        // 取到流式过程中的中间值（本机实测 output 6→235），必须逐字段取最大值合并。
        NSMutableData *chunked = [NSMutableData data];
        NSData *(^usageLine)(NSTimeInterval, NSString *, NSString *, unsigned long long) =
            ^(NSTimeInterval at, NSString *identifier, NSString *request, unsigned long long out) {
            NSDictionary *line = @{@"type": @"assistant", @"timestamp": Timestamp(at),
                @"requestId": request,
                @"message": @{@"id": identifier, @"usage": @{
                    @"input_tokens": @1, @"output_tokens": @(out),
                    @"cache_read_input_tokens": @3, @"cache_creation_input_tokens": @4}}};
            NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:line options:0
                error:nil] mutableCopy];
            [data appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
            return (NSData *)data;
        };
        // 三行同属一次请求：output 2 → 2 → 500，合并后应记 500（连同 1/3/4 共 508）。
        [chunked appendData:usageLine(now - 250, @"c1", @"cr1", 2)];
        [chunked appendData:usageLine(now - 250, @"c1", @"cr1", 2)];
        [chunked appendData:usageLine(now - 250, @"c1", @"cr1", 500)];
        [chunked writeToFile:[project(@"-Users-e") stringByAppendingPathComponent:@"e.jsonl"]
            atomically:YES];

        NSDictionary *streamed = LatestClaudeUsage()[@"tokenUsage"];
        if ([streamed[@"fiveHour"][@"total_tokens"] unsignedLongLongValue] != 50 + 508 ||
            [streamed[@"fiveHour"][@"output_tokens"] unsignedLongLongValue] != 10 + 500) {
            NSLog(@"分块写入的 usage 快照应逐字段取最大值合并: %@", streamed);
            return EXIT_FAILURE;
        }
        puts("Claude Code 同一请求多行 usage 快照合并测试通过");
    }
    return EXIT_SUCCESS;
}
