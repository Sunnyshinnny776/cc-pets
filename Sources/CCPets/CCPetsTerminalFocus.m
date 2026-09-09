#import "CCPetsTerminalFocus.h"
#import "CCPetsEvents.h"

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
