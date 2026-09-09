#import "CCPetsEvents.h"
#import "CCPetsPaths.h"
#import "CCPetsTerminalFocus.h"
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

NSString *SanitizedShortString(id value, NSUInteger maximumLength) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (text.length == 0) return @"";
    NSMutableString *safe = [NSMutableString stringWithCapacity:MIN(text.length, maximumLength)];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._- "];
    for (NSUInteger index = 0; index < text.length && safe.length < maximumLength; index++) {
        unichar character = [text characterAtIndex:index];
        if ([allowed characterIsMember:character]) [safe appendFormat:@"%C", character];
    }
    return [safe stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

NSString *ProviderFromEnvironment(void) {
    NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
    if ([environment[@"CC_PETS_CODEX_AGENT_HOOK"] boolValue]) return @"Codex";
    if ([environment[@"CC_PETS_CLAUDE_AGENT_HOOK"] boolValue]) return @"Claude";
    return @"Agent";
}

static BOOL CodexAutoReviewEnabled(void) {
    NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
    NSString *codexHome = environment[@"CODEX_HOME"];
    if (![codexHome isKindOfClass:NSString.class] || codexHome.length == 0) {
        codexHome = [NSHomeDirectory() stringByAppendingPathComponent:@".codex"];
    }
    NSString *configPath = [codexHome stringByAppendingPathComponent:@"config.toml"];
    NSString *contents = [NSString stringWithContentsOfFile:configPath
        encoding:NSUTF8StringEncoding error:nil];
    if (contents.length == 0) return NO;

    __block BOOL topLevel = YES;
    __block BOOL enabled = NO;
    [contents enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"]) return;
        if ([trimmed hasPrefix:@"["]) {
            topLevel = NO;
            return;
        }
        if (!topLevel) return;
        NSRange equals = [trimmed rangeOfString:@"="];
        if (equals.location == NSNotFound) return;
        NSString *key = [[trimmed substringToIndex:equals.location]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (![key isEqualToString:@"approvals_reviewer"]) return;
        NSString *value = [[trimmed substringFromIndex:equals.location + 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSRange comment = [value rangeOfString:@"#"];
        if (comment.location != NSNotFound) {
            value = [[value substringToIndex:comment.location]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        }
        if (value.length >= 2) {
            unichar first = [value characterAtIndex:0];
            unichar last = [value characterAtIndex:value.length - 1];
            if ((first == '"' && last == '"') || (first == '\'' && last == '\'')) {
                value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
            }
        }
        enabled = [value isEqualToString:@"auto_review"];
        *stop = YES;
    }];
    return enabled;
}

NSString *NormalizedStateForEvent(NSString *event, BOOL failed) {
    if ([event isEqualToString:@"StopFailure"]) return @"failed";
    if (failed || [event isEqualToString:@"PostToolUseFailure"]) return @"tool_failed";
    if ([event isEqualToString:@"SessionStart"]) return @"starting";
    if ([event isEqualToString:@"UserPromptSubmit"]) return @"thinking";
    if ([event isEqualToString:@"PermissionRequest"]) return @"approval";
    if ([event isEqualToString:@"PreToolUse"]) return @"tool";
    if ([event isEqualToString:@"SubagentStart"] || [event isEqualToString:@"TaskCreated"]) return @"subagent";
    if ([event isEqualToString:@"PostToolUse"] || [event isEqualToString:@"SubagentStop"] ||
        [event isEqualToString:@"TaskCompleted"]) return @"thinking";
    if ([event isEqualToString:@"Stop"] || [event isEqualToString:@"SessionEnd"]) return @"completed";
    if ([event isEqualToString:@"Notification"]) return @"notification";
    return @"thinking";
}

static const off_t AgentEventLogSizeLimit = 4 * 1024 * 1024;

BOOL AppendAgentEventRecord(NSDictionary *record) {
    // 测试会跑包装脚本和 hook，漏设 CC_PETS_STATE_DIR 的用例会把事件写进用户真实的
    // 事件流里，把正在运行的桌宠打回"正在启动"。测试统一导出这个变量，写入端打上标记，
    // 收尾就能只对"测试自己写的行"判污染——按文件大小判会被同机的真实会话误伤。
    // 正常使用下没有任何东西会设它。
    NSString *mark = NSProcessInfo.processInfo.environment[@"CC_PETS_TEST_MARK"];
    if (mark.length > 0) {
        NSMutableDictionary *marked = [record mutableCopy];
        marked[@"testMark"] = SanitizedShortString(mark, 64);
        record = marked;
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    if (!json) return NO;
    // JSON 和换行必须一次 write 写完：O_APPEND 只保证单次 write 的原子性，
    // 拆成两次的话，Codex 与 Claude 的 hook 同时触发就可能交错成
    // “json1 json2 \n \n”，坏行会被读取端整行丢弃，桌宠漏掉一次状态切换。
    NSMutableData *line = [NSMutableData dataWithCapacity:json.length + 1];
    [line appendData:json];
    [line appendBytes:"\n" length:1];
    int descriptor = open(AgentEventPath().fileSystemRepresentation,
        O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR);
    if (descriptor < 0) return NO;
    // 事件文件只被追加、从不回收。超过上限就整体截断重来：读取端已经能处理
    // “文件变短”（size < offset 时重置偏移），所以截断是安全的。
    struct stat status;
    if (fstat(descriptor, &status) == 0 && status.st_size > AgentEventLogSizeLimit) {
        ftruncate(descriptor, 0);
    }
    BOOL succeeded = write(descriptor, line.bytes, line.length) == (ssize_t)line.length;
    close(descriptor);
    return succeeded;
}

// 只有 NSNumber / NSString 响应 -boolValue。原实现直接对 dictionary[@"is_error"]
// 取 boolValue，遇到 "is_error": null 就是对 NSNull 发未实现的选择子，直接崩。
static BOOL HookFlagIsTruthy(id value, BOOL *present) {
    if ([value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class]) {
        if (present) *present = YES;
        return [value boolValue];
    }
    if (present) *present = NO;
    return NO;
}

static const NSUInteger HookFailureMaximumDepth = 4;

static BOOL HookValueIndicatesFailureAtDepth(id value, NSUInteger depth) {
    if (depth > HookFailureMaximumDepth) return NO;
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = value;
        BOOL present = NO;
        if (HookFlagIsTruthy(dictionary[@"is_error"], &present) && present) return YES;
        BOOL success = HookFlagIsTruthy(dictionary[@"success"], &present);
        if (present && !success) return YES;
        NSString *status = [dictionary[@"status"] isKindOfClass:NSString.class]
            ? [(NSString *)dictionary[@"status"] lowercaseString] : nil;
        if ([status isEqualToString:@"error"] || [status isEqualToString:@"failed"] ||
            [status isEqualToString:@"failure"]) return YES;
        // 原实现还有一条 `dictionary[@"error"] != nil` 判定，任意层级只要出现一个非空
        // error 键就整体判失败——诊断数组、返回体里的 error 字段都会误命中，导致
        // 任务成功却播失败动画并弹“任务失败”通知。这里只认上面几个显式信号。
        for (id child in dictionary.allValues) {
            if (HookValueIndicatesFailureAtDepth(child, depth + 1)) return YES;
        }
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id child in value) {
            if (HookValueIndicatesFailureAtDepth(child, depth + 1)) return YES;
        }
    }
    return NO;
}

// 深度上限防止深嵌套 JSON 递归爆栈。
BOOL HookValueIndicatesFailure(id value) {
    return HookValueIndicatesFailureAtDepth(value, 0);
}

int RecordHookEvent(void) {
    NSData *input = [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile];
    NSDictionary *payload = input.length > 0 ? [NSJSONSerialization JSONObjectWithData:input options:0 error:nil] : nil;
    if (![payload isKindOfClass:NSDictionary.class]) return EXIT_SUCCESS;
    NSString *event = payload[@"hook_event_name"];
    if (![event isKindOfClass:NSString.class] || event.length == 0) return EXIT_SUCCESS;
    // Claude Agent SDK / ACP 也会执行用户级 Hooks。IDE 或终端仅仅创建、销毁这类
    // 后台会话时就会发 SessionStart / SessionEnd，但它们不代表用户启动了 Agent
    // 任务或完成了一轮工作。真实 CLI 的启动状态由包装脚本显式写入，任务完成则由
    // Stop 表示，因此这里忽略纯会话生命周期事件，避免普通终端开关触发误报。
    if ([event isEqualToString:@"SessionStart"] || [event isEqualToString:@"SessionEnd"]) {
        return EXIT_SUCCESS;
    }
    NSString *tool = [payload[@"tool_name"] isKindOfClass:NSString.class] ? payload[@"tool_name"] : @"";
    NSString *session = SanitizedShortString(payload[@"session_id"], 128);
    id toolResult = payload[@"tool_response"] ?: payload[@"tool_result"];
    BOOL failed = [event isEqualToString:@"PostToolUseFailure"] ||
        [event isEqualToString:@"StopFailure"] || HookValueIndicatesFailure(toolResult);
    NSString *provider = ProviderFromEnvironment();
    BOOL autoReview = [provider isEqualToString:@"Codex"] &&
        [event isEqualToString:@"PermissionRequest"] && CodexAutoReviewEnabled();
    NSMutableDictionary *record = [@{
        @"event": event,
        @"tool": tool,
        @"failed": @(failed),
        @"provider": provider,
        @"state": autoReview ? @"auto_review" : NormalizedStateForEvent(event, failed),
        @"timestamp": @([NSDate.date timeIntervalSince1970])
    } mutableCopy];
    if (session.length > 0) record[@"session"] = session;
    NSDictionary *terminal = TerminalFocusTargetFromEnvironment();
    if (terminal.count > 0) record[@"terminal"] = terminal;
    AppendAgentEventRecord(record);
    return EXIT_SUCCESS;
}

int RecordProviderEvent(void) {
    NSData *input = [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile];
    NSDictionary *payload = input.length > 0
        ? [NSJSONSerialization JSONObjectWithData:input options:0 error:nil] : nil;
    if (![payload isKindOfClass:NSDictionary.class] ||
        ![payload[@"schemaVersion"] isKindOfClass:NSNumber.class] ||
        [payload[@"schemaVersion"] integerValue] != 1) {
        fprintf(stderr, "provider-event 需要 schemaVersion 为 1 的 JSON 对象。\n");
        return 2;
    }
    NSString *provider = SanitizedShortString(payload[@"provider"], 32);
    NSString *state = SanitizedShortString(payload[@"state"], 32).lowercaseString;
    NSString *tool = SanitizedShortString(payload[@"tool"], 64);
    NSSet<NSString *> *states = [NSSet setWithArray:@[
        @"starting", @"thinking", @"tool", @"approval", @"subagent",
        @"tool_completed", @"tool_failed", @"completed", @"failed", @"notification"
    ]];
    if (provider.length == 0 || ![states containsObject:state]) {
        fprintf(stderr, "provider-event 的 provider 或 state 无效。\n");
        return 2;
    }
    NSDictionary<NSString *, NSString *> *events = @{
        @"starting": @"SessionStart",
        @"thinking": @"UserPromptSubmit",
        @"tool": @"PreToolUse",
        @"approval": @"PermissionRequest",
        @"subagent": @"SubagentStart",
        @"tool_completed": @"PostToolUse",
        @"tool_failed": @"PostToolUseFailure",
        @"completed": @"Stop",
        @"failed": @"StopFailure",
        @"notification": @"Notification"
    };
    NSMutableDictionary *record = [@{
        @"event": events[state],
        @"tool": tool,
        @"failed": @([state isEqualToString:@"failed"] || [state isEqualToString:@"tool_failed"]),
        @"provider": provider,
        @"state": state,
        @"timestamp": @([NSDate.date timeIntervalSince1970])
    } mutableCopy];
    NSDictionary *terminal = TerminalFocusTargetFromEnvironment();
    if (terminal.count > 0) record[@"terminal"] = terminal;
    if (!AppendAgentEventRecord(record)) {
        fprintf(stderr, "无法写入 Provider 事件。\n");
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
