#import <Foundation/Foundation.h>
#import "CCPetsTerminalFocus.h"
#import <sqlite3.h>
#import <math.h>

// 回跳目标的身份来自两处：TERM_PROGRAM 的映射值，和包装脚本捕获的 bundleID。
// 谁优先不是风格问题——选错了点状态卡片就完全没有反应：
//
// 1. TERM_PROGRAM=vscode 是 VS Code 家族（官方 / Cursor / Windsurf / Antigravity）
//    共用的标记，映射到 com.microsoft.VSCode 对分支编辑器一律是个没在运行的
//    bundle ID，必须让捕获值排在前面。
// 2. 其余终端反过来：映射值比"启动瞬间的前台应用"可靠，捕获值只当兜底。

static BOOL CheckCandidates(NSString *name, NSDictionary *target, NSArray<NSString *> *expected) {
    NSArray<NSString *> *actual = TerminalFocusBundleCandidates(target);
    if ([actual isEqualToArray:expected]) return YES;
    NSLog(@"%@ 的候选应为 %@，实际 %@", name, expected, actual);
    return NO;
}

// 以子进程身份被拉起时只报告目标里有几项，供父进程判断。
static int RunProbe(void) {
    printf("%lu\n", (unsigned long)TerminalFocusTargetFromEnvironment().count);
    return EXIT_SUCCESS;
}

// 让探针跑在一个 argv 里带（或不带）--managed-daemon 的 sh 下面。脚本末尾的 exit 防止
// sh 把最后一条命令 exec 掉——那样 sh 这一层就不在父进程链上了。
static NSString *ProbeTargetCount(NSString *executable, BOOL underDaemon) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    NSMutableArray *arguments = [@[@"-c", @"\"$0\" --probe; exit $?", executable] mutableCopy];
    if (underDaemon) [arguments addObject:@"--managed-daemon"];
    task.arguments = arguments;
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    environment[@"CC_PETS_TERMINAL_TTY"] = @"/dev/ttys001";
    environment[@"CC_PETS_TERMINAL_BUNDLE_ID"] = @"com.jetbrains.intellij";
    task.environment = environment;
    NSPipe *output = [NSPipe pipe];
    task.standardOutput = output;
    [task launch];
    [task waitUntilExit];
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSTask *SleepingProcess(void) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sleep"];
    task.arguments = @[@"60"];
    [task launch];
    return task;
}

static void WriteRollout(NSString *codexHome, NSString *thread, NSString *cwd, NSTimeInterval createdAt) {
    NSString *day = [codexHome stringByAppendingPathComponent:@"sessions/2026/09/30"];
    [NSFileManager.defaultManager createDirectoryAtPath:day withIntermediateDirectories:YES
        attributes:nil error:nil];
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
        NSISO8601DateFormatWithFractionalSeconds;
    NSDictionary *meta = @{@"type": @"session_meta", @"payload": @{
        @"id": thread, @"cwd": cwd,
        @"timestamp": [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:createdAt]]}};
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:meta options:0 error:nil] mutableCopy];
    [data appendData:[@"\n{\"type\":\"event_msg\"}\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [data writeToFile:[day stringByAppendingPathComponent:
        [NSString stringWithFormat:@"rollout-2026-09-30T00-00-00-%@.jsonl", thread]] atomically:YES];
}

// 多客户端配对需要真实格式的就绪元数据，只有 rollout 创建时间不能确定所属 PID。
static BOOL WriteReadyLog(NSString *codexHome, pid_t pid, NSTimeInterval readyAt) {
    NSString *path = [codexHome stringByAppendingPathComponent:@"logs_2.sqlite"];
    sqlite3 *database = NULL;
    sqlite3_stmt *statement = NULL;
    BOOL ok = sqlite3_open(path.fileSystemRepresentation, &database) == SQLITE_OK;
    if (ok) ok = sqlite3_exec(database,
        "CREATE TABLE IF NOT EXISTS logs (ts INTEGER, ts_nanos INTEGER, process_uuid TEXT, "
        "target TEXT, feedback_log_body TEXT)", NULL, NULL, NULL) == SQLITE_OK;
    if (ok) ok = sqlite3_prepare_v2(database,
        "INSERT INTO logs VALUES (?, ?, ?, 'codex_tui::app::startup', 'tui startup initial frame scheduled')",
        -1, &statement, NULL) == SQLITE_OK;
    if (ok) {
        sqlite3_int64 seconds = (sqlite3_int64)floor(readyAt);
        NSString *process = [NSString stringWithFormat:@"pid:%d:fixture", pid];
        sqlite3_bind_int64(statement, 1, seconds);
        sqlite3_bind_int64(statement, 2, (sqlite3_int64)llround((readyAt - seconds) * 1e9));
        sqlite3_bind_text(statement, 3, process.UTF8String, -1, SQLITE_TRANSIENT);
        ok = sqlite3_step(statement) == SQLITE_DONE;
    }
    if (!ok) NSLog(@"无法写入测试用 TUI 就绪日志：%s", database ? sqlite3_errmsg(database) : "open failed");
    if (statement) sqlite3_finalize(statement);
    if (database) sqlite3_close(database);
    return ok;
}

static BOOL ExpectTTY(NSString *name, NSString *thread, NSDictionary *payload, NSString *expected) {
    NSString *actual = CodexLaunchTerminalForThread(thread, payload)[@"tty"];
    if ((expected == nil && actual == nil) || [actual isEqualToString:expected]) return YES;
    NSLog(@"%@：期望 %@，实际 %@", name, expected ?: @"(空)", actual ?: @"(空)");
    return NO;
}

// Codex 共享服务下，hook 靠 codex-with-pet 的启动登记把会话配回终端。
static BOOL CheckCodexLaunchPairing(void) {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"cc-pets-launch-%d", getpid()]];
    NSString *codexHome = [root stringByAppendingPathComponent:@"codex"];
    setenv("CC_PETS_STATE_DIR", [root stringByAppendingPathComponent:@"state"].UTF8String, 1);
    setenv("CC_PETS_CODEX_HOME", codexHome.UTF8String, 1);
    NSTask *first = SleepingProcess(), *second = SleepingProcess(), *third = SleepingProcess();
    // 就绪时间必须晚于真实子进程的创建时间，否则应被 PID 复用保护拒绝。
    // 后续时间是模拟事件的时间线，无需真实 sleep 等待。
    NSTimeInterval t = NSDate.date.timeIntervalSince1970;
    BOOL ok = RegisterCodexLaunchForProcess(first.processIdentifier, @"/work/a",
            @{@"tty": @"ttys011"}, t) &&
        RegisterCodexLaunchForProcess(second.processIdentifier, @"/work/a",
            @{@"tty": @"ttys012"}, t + 10) &&
        RegisterCodexLaunchForProcess(third.processIdentifier, @"/work/b",
            @{@"tty": @"ttys013"}, t + 20);
    if (!ok) NSLog(@"启动登记失败");
    WriteRollout(codexHome, @"thread-x", @"/work/a", t + 1);
    WriteRollout(codexHome, @"thread-y", @"/work/a", t + 11);
    WriteRollout(codexHome, @"thread-n", @"/work/b", t + 30);
    WriteRollout(codexHome, @"thread-m", @"/work/a", t + 40);
    // 同目录多个 CLI：无就绪证据时不猜归属，日志落盘后可以再次配对。
    ok &= ExpectTTY(@"缺少就绪日志的多客户端会话", @"thread-x", @{}, nil);
    ok &= WriteReadyLog(codexHome, first.processIdentifier, t + 0.5);
    ok &= WriteReadyLog(codexHome, second.processIdentifier, t + 10.5);
    // 两个会话分别只有一个 PID 在创建前一秒内就绪，与查询顺序无关。
    ok &= ExpectTTY(@"同目录较早的会话", @"thread-x", @{}, @"ttys011");
    ok &= ExpectTTY(@"同目录较晚的会话", @"thread-y", @{}, @"ttys012");
    ok &= ExpectTTY(@"已配对的会话再次查询", @"thread-x", @{}, @"ttys011");
    // hook 给了 transcript_path 就直接读它；这里的记录里没有 cwd，用 payload 的 cwd 兜底。
    NSString *transcript = [root stringByAppendingPathComponent:@"z.jsonl"];
    [@"{}\n" writeToFile:transcript atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ok &= ExpectTTY(@"按 transcript_path 与 payload cwd 配对", @"thread-z",
        @{@"transcript_path": transcript, @"cwd": @"/work/b"}, @"ttys013");
    // 同一个 TUI 里 /new 出来的会话：同目录只剩这一个 CLI，认它。
    ok &= ExpectTTY(@"同目录唯一 CLI 的新会话", @"thread-n", @{}, @"ttys013");
    // 同目录两个 CLI 都已配过会话，分不清就不配，不能跳错。
    ok &= ExpectTTY(@"无法区分的新会话", @"thread-m", @{}, nil);
    ok &= ExpectTTY(@"没有登记过的目录", @"thread-c", @{@"cwd": @"/work/c"}, nil);
    // CLI 退出后，它的配对随之失效。
    [third terminate];
    [third waitUntilExit];
    ok &= ExpectTTY(@"CLI 退出后的会话", @"thread-z", @{@"cwd": @"/work/b"}, nil);
    [first terminate];
    [second terminate];
    [first waitUntilExit];
    [second waitUntilExit];
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    return ok;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--probe") == 0) return RunProbe();
        BOOL ok = YES;
        ok &= CheckCandidates(@"Antigravity", @{
            @"tty": @"ttys003", @"program": @"vscode",
            @"bundleID": @"com.google.antigravity-ide"
        }, @[@"com.google.antigravity-ide", @"com.microsoft.VSCode"]);
        ok &= CheckCandidates(@"官方 VS Code", @{
            @"tty": @"ttys003", @"program": @"vscode",
            @"bundleID": @"com.microsoft.VSCode"
        }, @[@"com.microsoft.VSCode"]);
        // 没走包装脚本时捕获值可能是空的，映射值得继续兜住。
        ok &= CheckCandidates(@"VS Code 家族缺少捕获值", @{
            @"tty": @"ttys003", @"program": @"vscode"
        }, @[@"com.microsoft.VSCode"]);
        ok &= CheckCandidates(@"Apple Terminal", @{
            @"tty": @"ttys001", @"program": @"Apple_Terminal",
            @"bundleID": @"com.apple.Terminal"
        }, @[@"com.apple.Terminal"]);
        // JetBrains 没有统一的 TERM_PROGRAM，只剩捕获值。
        ok &= CheckCandidates(@"WebStorm", @{
            @"tty": @"ttys001", @"bundleID": @"com.jetbrains.WebStorm"
        }, @[@"com.jetbrains.WebStorm"]);
        // 映射值没在运行时要能退到捕获值，所以两个都得留在候选里。
        ok &= CheckCandidates(@"映射值与捕获值不一致", @{
            @"tty": @"ttys001", @"program": @"WarpTerminal",
            @"bundleID": @"dev.warp.Warp-Preview"
        }, @[@"dev.warp.Warp-Stable", @"dev.warp.Warp-Preview"]);
        ok &= CheckCandidates(@"空目标", @{}, @[]);
        if (!ok) return EXIT_FAILURE;
        puts("终端回跳候选优先级测试通过");

        // Codex 共享服务拉起的 hook 继承的是服务启动那一刻的终端环境，不能当成会话所在的终端。
        NSString *executable = NSProcessInfo.processInfo.arguments.firstObject;
        NSString *normal = ProbeTargetCount(executable, NO);
        NSString *shared = ProbeTargetCount(executable, YES);
        if ([normal integerValue] == 0 || ![shared isEqualToString:@"0"]) {
            NSLog(@"共享服务下应记空目标：普通 %@，共享服务 %@", normal, shared);
            return EXIT_FAILURE;
        }
        puts("Codex 共享服务下不记录回跳目标测试通过");
        if (!CheckCodexLaunchPairing()) return EXIT_FAILURE;
        puts("Codex 共享服务下会话与终端配对测试通过");
    }
    return EXIT_SUCCESS;
}
