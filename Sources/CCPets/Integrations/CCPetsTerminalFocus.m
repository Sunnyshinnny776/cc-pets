#import "CCPetsTerminalFocus.h"
#import "CCPetsEvents.h"
#import "CCPetsPaths.h"
#import "CCPetsIDEIntegration.h"
#import "CCPetsVSCodeIntegration.h"
#import <fcntl.h>
#import <sys/file.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <stdlib.h>
#import <unistd.h>
#import <sqlite3.h>

static BOOL ProcessInfoForPID(pid_t pid, struct kinfo_proc *info) {
    if (pid <= 0) return NO;
    size_t length = sizeof(*info);
    int name[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    return sysctl(name, 4, info, &length, NULL, 0) == 0 && length > 0;
}

BOOL IsCodexDesktopFocusTarget(NSDictionary *target) {
    if (![target isKindOfClass:NSDictionary.class]) return NO;
    return [target[@"bundleID"] isEqual:@"com.openai.codex"] &&
        (![target[@"tty"] isKindOfClass:NSString.class] || [target[@"tty"] length] == 0);
}

BOOL CodexDesktopFocusTargetIsLive(NSDictionary *target, NSTimeInterval eventTime) {
    if (!IsCodexDesktopFocusTarget(target) || !(eventTime > 0)) return NO;
    for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.openai.codex"]) {
        if (!app.terminated && app.launchDate && app.launchDate.timeIntervalSince1970 <= eventTime) return YES;
    }
    return NO;
}

BOOL CodexDesktopApplicationIsRunning(void) {
    for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.openai.codex"]) {
        if (!app.terminated) return YES;
    }
    return NO;
}

NSNumber *CodexPersistentThreadStatus(NSString *thread, NSString *codexHome) {
    if (thread.length == 0 || !codexHome.isAbsolutePath) return nil;
    sqlite3 *db = NULL;
    NSString *path = [codexHome stringByAppendingPathComponent:@"state_5.sqlite"];
    if (sqlite3_open_v2(path.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return nil;
    }
    sqlite3_busy_timeout(db, 10);
    sqlite3_stmt *statement = NULL;
    NSNumber *result = nil;
    // 索引不可读或版本改变时返回未知，不能把错误当作“会话已退出”。
    if (sqlite3_prepare_v2(db, "SELECT archived FROM threads WHERE id = ? LIMIT 1", -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_text(statement, 1, thread.UTF8String, -1, SQLITE_TRANSIENT);
        int step = sqlite3_step(statement);
        if (step == SQLITE_ROW) result = @(sqlite3_column_int(statement, 0) == 0);
        else if (step == SQLITE_DONE) result = @NO;
    }
    sqlite3_finalize(statement);
    sqlite3_close(db);
    return result;
}

// 包装脚本没被走到时（用户直接跑 codex / claude，或终端窗口早于 shim 安装就已打开）
// 环境里没有 CC_PETS_TERMINAL_*。记录端自己是 Agent 的子进程，控制终端就是 Agent
// 所在的那个 tty，直接问内核即可——stdin 是 JSON 管道，isatty 这类办法在这里没用。
static NSString *ControllingTerminalName(void) {
    struct kinfo_proc info;
    if (!ProcessInfoForPID(getpid(), &info)) return @"";
    dev_t device = info.kp_eproc.e_tdev;
    if (device == NODEV) return @"";
    const char *tty = devname(device, S_IFCHR);
    return tty ? @(tty).lastPathComponent : @"";
}

// 承载终端的应用：沿父进程链往上走，第一个能被 NSRunningApplication 认领的就是
// GUI 应用本体（Ghostty / Terminal / iTerm2 …）。不能用"当前前台应用"兜底——
// Hook 触发时用户往往已经切到别的窗口，那样会把跳转目标记错。
static NSString *HostApplicationBundleIdentifier(void) {
    pid_t pid = getppid();
    for (NSUInteger depth = 0; depth < 16 && pid > 1; depth++) {
        NSString *bundleID = [NSRunningApplication
            runningApplicationWithProcessIdentifier:pid].bundleIdentifier;
        if (bundleID.length > 0) return bundleID;
        struct kinfo_proc info;
        if (!ProcessInfoForPID(pid, &info)) break;
        pid = info.kp_eproc.e_ppid;
    }
    return @"";
}

// KERN_PROCARGS2 的布局：argc（int），可执行文件路径，若干 \0 填充，然后是 argc 个参数。
static NSArray<NSString *> *ProcessArguments(pid_t pid) {
    int name[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t size = 0;
    if (sysctl(name, 3, NULL, &size, NULL, 0) != 0 || size <= sizeof(int)) return @[];
    NSMutableData *buffer = [NSMutableData dataWithLength:size];
    if (sysctl(name, 3, buffer.mutableBytes, &size, NULL, 0) != 0 || size <= sizeof(int)) return @[];
    const char *bytes = buffer.bytes;
    int argc = 0;
    memcpy(&argc, bytes, sizeof(argc));
    size_t offset = sizeof(argc);
    while (offset < size && bytes[offset] != '\0') offset++;  // 可执行文件路径
    while (offset < size && bytes[offset] == '\0') offset++;
    NSMutableArray<NSString *> *arguments = [NSMutableArray array];
    while (offset < size && (int)arguments.count < argc) {
        size_t length = strnlen(bytes + offset, size - offset);
        NSString *argument = [[NSString alloc] initWithBytes:bytes + offset length:length
            encoding:NSUTF8StringEncoding];
        [arguments addObject:argument ?: @""];
        offset += length + 1;
    }
    return arguments;
}

// 新版 Codex 把各个终端里的会话都交给一个常驻的共享服务（codex app-server --managed-daemon）
// 执行，hook 是这个服务拉起的，继承的是它自己的环境。那份环境停在第一次拉起服务的终端上：
// 实测服务从 IntelliJ 启动后，VS Code 里的 Codex 会话事件全被记成 IntelliJ 的 ttys001，
// 点气泡跳到了别的终端。此时 CC_PETS_TERMINAL_*、控制终端、父进程链都说明不了会话在哪儿。
BOOL TerminalFocusRunsUnderSharedAgentHost(void) {
    pid_t pid = getppid();
    for (NSUInteger depth = 0; depth < 16 && pid > 1; depth++) {
        if ([ProcessArguments(pid) containsObject:@"--managed-daemon"]) return YES;
        struct kinfo_proc info;
        if (!ProcessInfoForPID(pid, &info)) break;
        pid = info.kp_eproc.e_ppid;
    }
    return NO;
}

static NSString *TerminalTargetValue(NSDictionary<NSString *, NSString *> *environment,
    NSString *key, NSUInteger maximumLength) {
    return SanitizedShortString(environment[key], maximumLength);
}

NSDictionary *TerminalFocusTargetFromEnvironment(void) {
    // 记不准就不记：没有目标时点气泡不跳，比跳到别人的终端好。
    if (TerminalFocusRunsUnderSharedAgentHost()) return @{};
    NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
    NSString *tty = environment[@"CC_PETS_TERMINAL_TTY"];
    if ([tty isKindOfClass:NSString.class]) tty = tty.lastPathComponent;
    tty = SanitizedShortString(tty, 64);
    NSString *program = TerminalTargetValue(environment, @"CC_PETS_TERMINAL_PROGRAM", 64);
    NSString *session = TerminalTargetValue(environment, @"CC_PETS_TERMINAL_SESSION", 128);
    NSString *bundleID = TerminalTargetValue(environment, @"CC_PETS_TERMINAL_BUNDLE_ID", 128);
    NSString *ideInstance = TerminalTargetValue(environment, @"CC_PETS_IDE_INSTANCE_ID", 64);
    NSString *ideTerminal = TerminalTargetValue(environment, @"CC_PETS_IDE_TERMINAL_ID", 64);
    if (tty.length == 0) tty = SanitizedShortString(ControllingTerminalName(), 64);
    if (bundleID.length == 0) {
        bundleID = SanitizedShortString(HostApplicationBundleIdentifier(), 128);
    }
    if (tty.length == 0 && program.length == 0 && session.length == 0 && bundleID.length == 0 && ideInstance.length == 0) {
        return @{};
    }
    NSMutableDictionary *target = [NSMutableDictionary dictionary];
    if (tty.length > 0) target[@"tty"] = tty;
    if (program.length > 0) target[@"program"] = program;
    if (session.length > 0) target[@"session"] = session;
    if (bundleID.length > 0) target[@"bundleID"] = bundleID;
    if (ideInstance.length > 0 && ideTerminal.length > 0) {
        target[@"ideInstance"] = ideInstance;
        target[@"ideTerminal"] = ideTerminal;
    }
    return target;
}

NSString *FrontmostApplicationBundleIdentifier(void) {
    return NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier ?: @"";
}

static BOOL RunTerminalSelectionScript(NSString *bundleID, NSString *ttyName) {
    if (ttyName.length == 0) return NO;
    NSString *tty = [@"/dev/" stringByAppendingString:ttyName.lastPathComponent];
    NSString *source = nil;
    if ([bundleID isEqualToString:@"com.apple.Terminal"]) {
        source = [NSString stringWithFormat:
            @"tell application \"Terminal\"\n"
             "repeat with terminalWindow in windows\n"
             "repeat with terminalTab in tabs of terminalWindow\n"
             "if (tty of terminalTab) is \"%@\" then\n"
             "set selected tab of terminalWindow to terminalTab\n"
             "set index of terminalWindow to 1\n"
             "activate\n"
             "return true\n"
             "end if\n"
             "end repeat\n"
             "end repeat\n"
             "end tell\n"
             "return false", tty];
    } else if ([bundleID isEqualToString:@"com.googlecode.iterm2"]) {
        source = [NSString stringWithFormat:
            @"tell application \"iTerm2\"\n"
             "repeat with terminalWindow in windows\n"
             "repeat with terminalTab in tabs of terminalWindow\n"
             "repeat with terminalSession in sessions of terminalTab\n"
             "if (tty of terminalSession) is \"%@\" then\n"
             "select terminalSession\n"
             "select terminalWindow\n"
             "activate\n"
             "return true\n"
             "end if\n"
             "end repeat\n"
             "end repeat\n"
             "end repeat\n"
             "end tell\n"
             "return false", tty];
    } else if ([bundleID isEqualToString:@"com.mitchellh.ghostty"]) {
        // Ghostty 1.4 起暴露 tty。先选中所属标签页并激活应用，再聚焦分屏；
        // 不只依赖 focus 内部异步的窗口前置，状态卡本身是 NonactivatingPanel。
        source = [NSString stringWithFormat:
            @"tell application \"Ghostty\"\n"
             "repeat with terminalWindow in windows\n"
             "repeat with terminalTab in tabs of terminalWindow\n"
             "repeat with terminalSurface in terminals of terminalTab\n"
             "if (tty of terminalSurface) is \"%@\" then\n"
             "set targetID to id of terminalSurface\n"
             "select tab terminalTab\n"
             "activate\n"
             "focus (terminal id targetID)\n"
             "return true\n"
             "end if\n"
             "end repeat\n"
             "end repeat\n"
             "end repeat\n"
             "end tell\n"
             "return false", tty];
    }
    if (!source) return NO;
    NSDictionary *error = nil;
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
    NSAppleEventDescriptor *result = [script executeAndReturnError:&error];
    if (error) {
        NSLog(@"Terminal focus failed: bundle=%@ tty=%@ error=%@", bundleID, tty, error);
    } else {
        NSLog(@"Terminal focus: bundle=%@ tty=%@ matched=%@", bundleID, tty,
            result.booleanValue ? @"yes" : @"no");
    }
    return result.booleanValue && error == nil;
}

static NSString *BundleIDForTerminalProgram(NSString *program) {
    NSString *lower = program.lowercaseString;
    if ([lower isEqualToString:@"apple_terminal"]) return @"com.apple.Terminal";
    if ([lower containsString:@"iterm"]) return @"com.googlecode.iterm2";
    if ([lower isEqualToString:@"vscode"]) return @"com.microsoft.VSCode";
    if ([lower containsString:@"warp"]) return @"dev.warp.Warp-Stable";
    if ([lower containsString:@"wezterm"]) return @"com.github.wez.wezterm";
    if ([lower containsString:@"ghostty"]) return @"com.mitchellh.ghostty";
    return @"";
}

// TERM_PROGRAM=vscode 是整个 VS Code 家族共用的标记：官方 VS Code、Cursor、Windsurf、
// Antigravity 这些分支全都这么写。它认不出具体是哪一个应用，固定映射到 com.microsoft.
// VSCode 就会把所有分支编辑器的回跳打死——那个 bundle ID 在机器上根本没有进程，激活
// 直接失败，点状态卡片毫无反应。家族内部谁是谁只有捕获到的 bundleID 知道。
static BOOL TerminalProgramIsVSCodeFamily(NSString *program) {
    return [program.lowercaseString isEqualToString:@"vscode"];
}

NSArray<NSString *> *TerminalFocusBundleCandidates(NSDictionary *target) {
    if (![target isKindOfClass:NSDictionary.class]) return @[];
    NSString *program = SanitizedShortString(target[@"program"], 64);
    // 已知 TERM_PROGRAM 比“启动瞬间的前台应用”更可靠：VS Code Task 可能在窗口不位于
    // 前台时启动 shell。JetBrains 等没有稳定统一 bundle ID 的宿主才使用捕获值兜底。
    // vscode 家族是例外，那个值分不出分支，只能反过来让捕获值当第一候选。
    NSString *mapped = BundleIDForTerminalProgram(program);
    NSString *captured = SanitizedShortString(target[@"bundleID"], 128);
    NSArray<NSString *> *ordered = TerminalProgramIsVSCodeFamily(program)
        ? @[captured, mapped] : @[mapped, captured];
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    for (NSString *candidate in ordered) {
        if (candidate.length == 0 || [candidates containsObject:candidate]) continue;
        [candidates addObject:candidate];
    }
    return candidates;
}

// 没有脚本或插件接口的宿主（如 Warp、未装扩展的 VS Code）退回激活应用。activateWithOptions:
// 在 macOS 14 起走协作式激活：状态卡是 NonactivatingPanel，桌宠自己不在前台，请求可能
// 被系统拒绝，窗口在别的桌面时更是不会切过去。改走和点 Dock 图标同一条路，让系统负责
// 切到应用窗口所在的桌面；拿不到 bundleURL 时才退回旧接口。
static BOOL ActivateApplicationAcrossSpaces(NSRunningApplication *application) {
    NSURL *bundleURL = application.bundleURL;
    if (bundleURL) {
        NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
        configuration.activates = YES;
        configuration.addsToRecentItems = NO;
        [NSWorkspace.sharedWorkspace openApplicationAtURL:bundleURL configuration:configuration
            completionHandler:nil];
        return YES;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [application activateWithOptions:
        NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop
}

BOOL ActivateTerminalFocusTarget(NSDictionary *target) {
    if (CCPetsRequestIDETerminalFocus(target)) return YES;
    if (CCPetsRequestVSCodeTerminalFocus(target)) return YES;
    NSString *tty = SanitizedShortString(target[@"tty"], 64);
    // 候选按优先级往下试，没在运行的直接跳过：映射值和捕获值总有一个指向真正承载
    // 会话的那个应用，卡在第一个候选上就会白白丢掉一次可用的回跳。
    for (NSString *bundleID in TerminalFocusBundleCandidates(target)) {
        if (RunTerminalSelectionScript(bundleID, tty)) return YES;
        NSRunningApplication *application =
            [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID].firstObject;
        if (!application) continue;
        return ActivateApplicationAcrossSpaces(application);
    }
    return NO;
}

#pragma mark - Codex 共享服务下的会话 → 终端配对

// Codex 共享服务拉起的 hook 不知道会话在哪个终端（见 TerminalFocusRunsUnderSharedAgentHost）。
// 能确定的只有两头：codex-with-pet 启动时知道自己的终端、工作目录和时刻；hook 知道会话 ID，
// 会话记录（rollout）的第一行又记着会话的工作目录和创建时刻。CLI 启动后可能还要等网络
// 初始化，不能按包装脚本的启动先后猜测归属。多个候选时读取本机 TUI 就绪日志的 PID，
// 仅在会话创建前后一秒内存在唯一就绪候选时配对；信息不足就留空，之后的 Hook 可再试。
static const NSUInteger CodexLaunchThreadLimit = 32;
static const NSTimeInterval CodexClientReadyWindow = 1.0;

static NSTimeInterval ProcessStartTime(pid_t pid) {
    struct kinfo_proc info;
    if (!ProcessInfoForPID(pid, &info)) return 0;
    struct timeval start = info.kp_proc.p_starttime;
    return start.tv_sec + start.tv_usec / 1e6;
}

// pid 会被复用，只看 kill(pid, 0) 可能把登记套到一个毫不相干的新进程上。启动时刻对得上才算同一个。
static BOOL CodexLaunchIsAlive(NSDictionary *entry) {
    pid_t pid = (pid_t)[entry[@"pid"] intValue];
    if (pid <= 1) return NO;
    NSTimeInterval started = ProcessStartTime(pid);
    return started > 0 && fabs(started - [entry[@"processStartedAt"] doubleValue]) < 1.0;
}

static int LockCodexLaunchRegistry(void) {
    NSString *path = CodexLaunchRegistryLockPath();
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil];
    int descriptor = open(path.fileSystemRepresentation, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR);
    if (descriptor < 0) return -1;
    // 同 Claude 额度文件的写锁：拿不到就放弃这一次，hook 不能被一个卡住的写者挂住。
    for (int attempt = 0; attempt < 50; attempt++) {
        if (flock(descriptor, LOCK_EX | LOCK_NB) == 0) return descriptor;
        if (errno != EWOULDBLOCK) break;
        usleep(20 * 1000);
    }
    close(descriptor);
    return -1;
}

static void UnlockCodexLaunchRegistry(int descriptor) {
    flock(descriptor, LOCK_UN);
    close(descriptor);
}

// 读出来时顺手丢掉已经退出的 CLI：它们不可能再是任何新会话的终端。
static NSMutableDictionary<NSString *, NSDictionary *> *LoadLiveCodexLaunches(void) {
    NSData *data = [NSData dataWithContentsOfFile:CodexLaunchRegistryPath()];
    id value = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSMutableDictionary *launches = [NSMutableDictionary dictionary];
    if (![value isKindOfClass:NSDictionary.class]) return launches;
    [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id entry, BOOL *stop) {
        if ([key isKindOfClass:NSString.class] && [entry isKindOfClass:NSDictionary.class] &&
            CodexLaunchIsAlive(entry)) launches[key] = entry;
    }];
    return launches;
}

static void SaveCodexLaunches(NSDictionary *launches) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:launches options:0 error:nil];
    NSString *path = CodexLaunchRegistryPath();
    if (json && [json writeToFile:path options:NSDataWritingAtomic error:nil]) {
        chmod(path.fileSystemRepresentation, S_IRUSR | S_IWUSR);
    }
}

BOOL RegisterCodexLaunchForProcess(pid_t pid, NSString *cwd, NSDictionary *terminal,
    NSTimeInterval launchedAt) {
    NSTimeInterval processStartedAt = ProcessStartTime(pid);
    if (processStartedAt <= 0 || cwd.length == 0 || terminal.count == 0) return NO;
    int lock = LockCodexLaunchRegistry();
    if (lock < 0) return NO;
    NSMutableDictionary *launches = LoadLiveCodexLaunches();
    launches[[NSString stringWithFormat:@"%d", pid]] = @{
        @"pid": @(pid),
        @"processStartedAt": @(processStartedAt),
        @"launchedAt": @(launchedAt),
        @"cwd": cwd.stringByStandardizingPath,
        @"terminal": terminal,
        @"threads": @[]
    };
    SaveCodexLaunches(launches);
    UnlockCodexLaunchRegistry(lock);
    return YES;
}

// codex-with-pet 在 exec 真正的 codex 之前调用；exec 不换 pid，所以父进程就是之后的 CLI。
int RegisterCodexLaunch(void) {
    RegisterCodexLaunchForProcess(getppid(), NSFileManager.defaultManager.currentDirectoryPath,
        TerminalFocusTargetFromEnvironment(), NSDate.date.timeIntervalSince1970);
    return EXIT_SUCCESS;
}

// 会话记录按 sessions/YYYY/MM/DD/rollout-<时间>-<会话 ID>.jsonl 存放，目录名字典序即时间序。
// 刚开始收事件的会话一定在最近几天的目录里；resume 的旧会话找不到也没关系，按工作目录兜底。
static NSString *CodexRolloutPathForThread(NSString *thread, NSString *codexHome) {
    NSString *sessions = [(codexHome.length > 0 ? codexHome : DefaultCodexHomeDirectory())
        stringByAppendingPathComponent:@"sessions"];
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *suffix = [NSString stringWithFormat:@"-%@.jsonl", thread];
    NSUInteger examinedDays = 0;
    NSArray *(^descending)(NSString *) = ^NSArray *(NSString *directory) {
        return [[files contentsOfDirectoryAtPath:directory error:nil]
            sortedArrayUsingSelector:@selector(compare:)].reverseObjectEnumerator.allObjects ?: @[];
    };
    for (NSString *year in descending(sessions)) {
        NSString *yearPath = [sessions stringByAppendingPathComponent:year];
        for (NSString *month in descending(yearPath)) {
            NSString *monthPath = [yearPath stringByAppendingPathComponent:month];
            for (NSString *day in descending(monthPath)) {
                if (++examinedDays > 7) return nil;
                NSString *dayPath = [monthPath stringByAppendingPathComponent:day];
                for (NSString *name in [files contentsOfDirectoryAtPath:dayPath error:nil]) {
                    if ([name hasSuffix:suffix]) return [dayPath stringByAppendingPathComponent:name];
                }
            }
        }
    }
    return nil;
}

// 第一行是 session_meta，带 cwd 和创建时刻；它里面有完整的系统提示词，可能很长，读到换行为止。
static NSDictionary *CodexThreadMeta(NSString *thread, NSDictionary *payload, NSString *codexHome) {
    NSString *path = [payload[@"transcript_path"] isKindOfClass:NSString.class]
        ? payload[@"transcript_path"] : nil;
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        path = CodexRolloutPathForThread(thread, codexHome);
    }
    NSFileHandle *handle = path ? [NSFileHandle fileHandleForReadingAtPath:path] : nil;
    NSMutableData *line = [NSMutableData data];
    while (handle && line.length < 8 * 1024 * 1024) {
        NSData *chunk = [handle readDataOfLength:64 * 1024];
        if (chunk.length == 0) break;
        NSRange newline = [chunk rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0
            range:NSMakeRange(0, chunk.length)];
        if (newline.location != NSNotFound) {
            [line appendData:[chunk subdataWithRange:NSMakeRange(0, newline.location)]];
            break;
        }
        [line appendData:chunk];
    }
    [handle closeFile];
    id root = line.length > 0 ? [NSJSONSerialization JSONObjectWithData:line options:0 error:nil] : nil;
    NSDictionary *meta = [root isKindOfClass:NSDictionary.class] &&
        [root[@"payload"] isKindOfClass:NSDictionary.class] ? root[@"payload"] : @{};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSString *cwd = [meta[@"cwd"] isKindOfClass:NSString.class] ? meta[@"cwd"]
        : ([payload[@"cwd"] isKindOfClass:NSString.class] ? payload[@"cwd"] : nil);
    if (cwd.length > 0) result[@"cwd"] = cwd.stringByStandardizingPath;
    if ([meta[@"timestamp"] isKindOfClass:NSString.class]) {
        NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
            NSISO8601DateFormatWithFractionalSeconds;
        NSDate *created = [formatter dateFromString:meta[@"timestamp"]];
        if (!created) {
            formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
            created = [formatter dateFromString:meta[@"timestamp"]];
        }
        if (created) result[@"createdAt"] = @(created.timeIntervalSince1970);
    }
    return result;
}

// Codex 的本机日志记录每个 TUI 的就绪时刻和带 PID 的 process_uuid。
// 初始会话可能先于首帧就绪（0.167.1 实测晚约 1.56ms 才记录就绪），不能要求就绪
// 一定早于会话创建。前后使用同一窄窗口，并在整个窗口内检查唯一性，避免两侧各有
// 一个候选时误配；SQL 的秒级范围与下面的精确时间过滤必须使用相同的上下界。
// 只读这一类元数据，不读取提示词、输出或 HTTP 日志。内部日志格式改变、日志尚未落盘、
// 多个客户端同时就绪时都不能猜测；sqlite 的读锁等待和返回条数也有上限。
static int CodexLogQueryExpired(void *context) {
    return CFAbsoluteTimeGetCurrent() > *(CFAbsoluteTime *)context;
}

static NSString *ReadyCodexLaunch(NSDictionary<NSString *, NSDictionary *> *launches,
    NSArray<NSString *> *candidates, NSNumber *createdAt, NSString *codexHome) {
    if (!createdAt || createdAt.doubleValue <= 0) return nil;
    NSString *path = [(codexHome.length ? codexHome : DefaultCodexHomeDirectory())
        stringByAppendingPathComponent:@"logs_2.sqlite"];
    sqlite3 *database = NULL;
    if (sqlite3_open_v2(path.fileSystemRepresentation, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        if (database) sqlite3_close(database);
        return nil;
    }
    sqlite3_busy_timeout(database, 50);
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 0.15;
    sqlite3_progress_handler(database, 1000, CodexLogQueryExpired, &deadline);
    sqlite3_stmt *statement = NULL;
    const char *query = "SELECT ts, ts_nanos, process_uuid FROM logs "
        "WHERE ts BETWEEN ? AND ? AND target = 'codex_tui::app::startup' "
        "AND feedback_log_body LIKE 'tui startup initial frame scheduled%' LIMIT 128";
    NSMutableSet<NSString *> *matches = [NSMutableSet set];
    BOOL complete = NO;
    NSTimeInterval earliestReadyAt = createdAt.doubleValue - CodexClientReadyWindow;
    NSTimeInterval latestReadyAt = createdAt.doubleValue + CodexClientReadyWindow;
    if (sqlite3_prepare_v2(database, query, -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, (sqlite3_int64)floor(earliestReadyAt));
        sqlite3_bind_int64(statement, 2, (sqlite3_int64)ceil(latestReadyAt));
        int result;
        NSUInteger rows = 0;
        while ((result = sqlite3_step(statement)) == SQLITE_ROW) {
            rows++;
            double readyAt = sqlite3_column_int64(statement, 0) + sqlite3_column_int64(statement, 1) / 1e9;
            if (readyAt < earliestReadyAt || readyAt > latestReadyAt) continue;
            const unsigned char *value = sqlite3_column_text(statement, 2);
            NSString *process = value ? @((const char *)value) : @"";
            for (NSString *key in candidates) {
                NSDictionary *entry = launches[key];
                NSString *prefix = [NSString stringWithFormat:@"pid:%d:", [entry[@"pid"] intValue]];
                if ([process hasPrefix:prefix] && readyAt >= [entry[@"processStartedAt"] doubleValue] &&
                    readyAt >= [entry[@"launchedAt"] doubleValue]) [matches addObject:key];
            }
        }
        complete = result == SQLITE_DONE && rows < 128;
    }
    if (statement) sqlite3_finalize(statement);
    sqlite3_close(database);
    return complete && matches.count == 1 ? matches.anyObject : nil;
}

// 显式 resume 优先按会话 ID；新会话用客户端就绪证据。多个同目录客户端时不能用
// “最新未绑定的进程”兜底：网络启动延迟和首次发消息的顺序都可能与启动顺序不同。
static NSString *ChooseCodexLaunch(NSDictionary<NSString *, NSDictionary *> *launches,
    NSString *cwd, NSNumber *createdAt, NSString *thread, NSString *codexHome) {
    NSMutableArray<NSString *> *sameDirectory = [NSMutableArray array];
    NSMutableArray<NSString *> *resumed = [NSMutableArray array];
    for (NSString *key in launches) {
        NSDictionary *entry = launches[key];
        if (![entry[@"cwd"] isEqualToString:cwd]) continue;
        [sameDirectory addObject:key];
        NSArray *arguments = ProcessArguments([entry[@"pid"] intValue]);
        NSUInteger resume = [arguments indexOfObject:@"resume"];
        if (resume != NSNotFound && resume + 1 < arguments.count && [arguments[resume + 1] isEqual:thread]) {
            [resumed addObject:key];
        }
    }
    if (resumed.count > 0) return resumed.count == 1 ? resumed.firstObject : nil;
    NSString *ready = ReadyCodexLaunch(launches, sameDirectory, createdAt, codexHome);
    if (ready) return ready;
    return sameDirectory.count == 1 ? sameDirectory.firstObject : nil;
}

static NSDictionary *CodexLaunchTerminalForThreadAtHome(NSString *thread, NSDictionary *payload,
    NSString *codexHome) {
    if (thread.length == 0) return @{};
    int lock = LockCodexLaunchRegistry();
    if (lock < 0) return @{};
    NSMutableDictionary<NSString *, NSDictionary *> *launches = LoadLiveCodexLaunches();
    NSDictionary *terminal = nil;
    for (NSDictionary *entry in launches.allValues) {
        if ([entry[@"threads"] containsObject:thread]) {
            terminal = entry[@"terminal"];
            break;
        }
    }
    if (!terminal) {
        NSDictionary *meta = CodexThreadMeta(thread, payload, codexHome);
        NSString *key = meta[@"cwd"] ? ChooseCodexLaunch(launches, meta[@"cwd"], meta[@"createdAt"], thread, codexHome) : nil;
        if (key) {
            NSMutableDictionary *entry = [launches[key] mutableCopy];
            NSMutableArray *threads = [entry[@"threads"] mutableCopy] ?: [NSMutableArray array];
            [threads addObject:thread];
            while (threads.count > CodexLaunchThreadLimit) [threads removeObjectAtIndex:0];
            entry[@"threads"] = threads;
            launches[key] = entry;
            terminal = entry[@"terminal"];
        }
    }
    SaveCodexLaunches(launches);
    UnlockCodexLaunchRegistry(lock);
    return [terminal isKindOfClass:NSDictionary.class] ? terminal : @{};
}

NSDictionary *CodexLaunchTerminalForThread(NSString *thread, NSDictionary *payload) {
    return CodexLaunchTerminalForThreadAtHome(thread, payload, DefaultCodexHomeDirectory());
}

NSDictionary *TerminalFocusTargetForHook(NSDictionary *payload, NSString *provider) {
    if (!TerminalFocusRunsUnderSharedAgentHost()) return TerminalFocusTargetFromEnvironment();
    if (![provider isEqualToString:@"Codex"]) return @{};
    // 是路径，不能走 SanitizedShortString：它会删掉 `/`，拼出一个不存在的目录。
    NSString *profileHome = NSProcessInfo.processInfo.environment[@"CC_PETS_PROFILE_HOME"];
    profileHome = [profileHome isKindOfClass:NSString.class] && profileHome.isAbsolutePath
        ? profileHome.stringByStandardizingPath : nil;
    return CodexLaunchTerminalForThreadAtHome(
        SanitizedShortString(payload[@"session_id"], 128), payload, profileHome);
}
