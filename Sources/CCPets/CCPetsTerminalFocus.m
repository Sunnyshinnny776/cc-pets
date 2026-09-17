#import "CCPetsTerminalFocus.h"
#import "CCPetsEvents.h"
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <stdlib.h>
#import <unistd.h>

static BOOL ProcessInfoForPID(pid_t pid, struct kinfo_proc *info) {
    if (pid <= 0) return NO;
    size_t length = sizeof(*info);
    int name[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    return sysctl(name, 4, info, &length, NULL, 0) == 0 && length > 0;
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

static NSString *TerminalTargetValue(NSDictionary<NSString *, NSString *> *environment,
    NSString *key, NSUInteger maximumLength) {
    return SanitizedShortString(environment[key], maximumLength);
}

NSDictionary *TerminalFocusTargetFromEnvironment(void) {
    NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
    NSString *tty = environment[@"CC_PETS_TERMINAL_TTY"];
    if ([tty isKindOfClass:NSString.class]) tty = tty.lastPathComponent;
    tty = SanitizedShortString(tty, 64);
    NSString *program = TerminalTargetValue(environment, @"CC_PETS_TERMINAL_PROGRAM", 64);
    NSString *session = TerminalTargetValue(environment, @"CC_PETS_TERMINAL_SESSION", 128);
    NSString *bundleID = TerminalTargetValue(environment, @"CC_PETS_TERMINAL_BUNDLE_ID", 128);
    if (tty.length == 0) tty = SanitizedShortString(ControllingTerminalName(), 64);
    if (bundleID.length == 0) {
        bundleID = SanitizedShortString(HostApplicationBundleIdentifier(), 128);
    }
    if (tty.length == 0 && program.length == 0 && session.length == 0 && bundleID.length == 0) {
        return @{};
    }
    NSMutableDictionary *target = [NSMutableDictionary dictionary];
    if (tty.length > 0) target[@"tty"] = tty;
    if (program.length > 0) target[@"program"] = program;
    if (session.length > 0) target[@"session"] = session;
    if (bundleID.length > 0) target[@"bundleID"] = bundleID;
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
    }
    if (!source) return NO;
    NSDictionary *error = nil;
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
    NSAppleEventDescriptor *result = [script executeAndReturnError:&error];
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

BOOL ActivateTerminalFocusTarget(NSDictionary *target) {
    if (![target isKindOfClass:NSDictionary.class]) return NO;
    NSString *tty = SanitizedShortString(target[@"tty"], 64);
    // 已知 TERM_PROGRAM 比“启动瞬间的前台应用”更可靠：VS Code Task 可能在窗口不位于
    // 前台时启动 shell。JetBrains 等没有稳定统一 bundle ID 的宿主才使用捕获值兜底。
    NSString *bundleID = BundleIDForTerminalProgram(
        SanitizedShortString(target[@"program"], 64));
    if (bundleID.length == 0) bundleID = SanitizedShortString(target[@"bundleID"], 128);
    if (bundleID.length == 0) return NO;
    if (RunTerminalSelectionScript(bundleID, tty)) return YES;

    NSArray<NSRunningApplication *> *applications =
        [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID];
    NSRunningApplication *application = applications.firstObject;
    if (!application) return NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [application activateWithOptions:
        NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop
}
