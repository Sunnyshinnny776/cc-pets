#import "CCPetsAppDelegate+Private.h"
#import "CCPetsCLISupport.h"

@implementation AppDelegate (Profiles)

- (void)addClaudeProfile:(id)sender {
    [self chooseProfileHomeForProvider:CCPetsProfileProviderClaude];
}

- (void)addCodexProfile:(id)sender {
    [self chooseProfileHomeForProvider:CCPetsProfileProviderCodex];
}

// 设置页的按钮在命令执行期间仍可点，被挡下时要告诉用户，不能悄悄什么都不做。
- (BOOL)rejectWhileProfileCommandRunning {
    if (!self.profileCommandRunning) return NO;
    [self showAlertWithTitle:L(@"Agent Profile Setup") message:L(@"Another Agent profile is still being configured.")];
    return YES;
}

- (void)chooseProfileHomeForProvider:(NSString *)provider {
    if ([self rejectWhileProfileCommandRunning]) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.allowsMultipleSelection = NO;
    panel.canCreateDirectories = NO;
    panel.showsHiddenFiles = YES;
    panel.prompt = L(@"Choose Home");
    panel.message = [provider isEqualToString:CCPetsProfileProviderClaude]
        ? L(@"Choose an existing Claude Home folder, such as ~/.claude-work.")
        : L(@"Choose an existing Codex Home folder, such as ~/.codex-work.");
    panel.directoryURL = [NSURL fileURLWithPath:CCPetsHomeDirectory() isDirectory:YES];
    [NSApp activateIgnoringOtherApps:YES];
    if ([panel runModal] != NSModalResponseOK) return;
    NSString *home = panel.URL.path;
    if (!CCPetsProfileHomeMatchesProvider(provider, home)) {
        [self showAlertWithTitle:L(@"This folder doesn't look like an Agent Home")
            message:[provider isEqualToString:CCPetsProfileProviderClaude]
                ? L(@"Choose a folder containing Claude settings, state, or projects.")
                : L(@"Choose a folder containing Codex config, hooks, or sign-in state.")];
        return;
    }
    NSString *name = CCPetsProfileDefaultDisplayName(provider, home);
    NSAlert *confirm = [NSAlert new];
    confirm.messageText = [NSString stringWithFormat:L(@"Integrate %@?"), name];
    NSString *bridge = CCBridgeEnabled()
        ? L(@"Pet Hooks, usage collection, CC Bridge Hooks, permissions, and MCP will be configured.")
        : L(@"Pet Hooks and usage collection will be configured. CC Bridge will be added automatically if you enable it later.");
    confirm.informativeText = [NSString stringWithFormat:@"%@\n\n%@", CCPetsTildePath(home), bridge];
    [confirm addButtonWithTitle:L(@"Start Setup")];
    [confirm addButtonWithTitle:L(@"Cancel")];
    if ([confirm runModal] != NSAlertFirstButtonReturn) return;
    // 首次名称只是 Home 文件夹名，不算用户自定义；这样以后重新定位 Home 时，
    // 未主动重命名的账号名称仍会跟随新的文件夹名。
    [self runProfileCommand:@[@"add", @"--provider", provider, @"--home", home]
        title:[NSString stringWithFormat:L(@"Configuring %@"), name]
        completionMessage:[provider isEqualToString:CCPetsProfileProviderClaude]
            ? L(@"The Claude Home is integrated. Restart Claude to load newly registered MCP tools.")
            : L(@"The Codex Home is integrated. Restart Codex, then trust the CC Pets hooks in /hooks.")];
}

- (void)repairAgentProfile:(NSMenuItem *)sender {
    NSString *profileID = [sender.representedObject isKindOfClass:NSString.class] ? sender.representedObject : nil;
    NSDictionary *profile = CCPetsProfileWithID(profileID);
    if (!profile || [self rejectWhileProfileCommandRunning]) return;
    [self runProfileCommand:@[@"repair", @"--id", profileID]
        title:[NSString stringWithFormat:L(@"Repairing %@"), profile[@"displayName"]]
        completionMessage:L(@"The Agent profile integration was repaired.")];
}

- (void)renameAgentProfile:(NSMenuItem *)sender {
    NSString *profileID = [sender.representedObject isKindOfClass:NSString.class] ? sender.representedObject : nil;
    NSDictionary *profile = CCPetsProfileWithID(profileID);
    if (!profile || [self rejectWhileProfileCommandRunning]) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = L(@"Rename Agent Profile");
    alert.informativeText = L(@"This changes only the name shown in CC Pets.");
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
    field.stringValue = profile[@"displayName"] ?: @"";
    alert.accessoryView = field;
    [alert addButtonWithTitle:L(@"Save")];
    [alert addButtonWithTitle:L(@"Cancel")];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    NSString *name = [field.stringValue stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (name.length == 0) return;
    [self runProfileCommand:@[@"update", @"--id", profileID, @"--name", name]
        title:[NSString stringWithFormat:L(@"Updating %@"), name]
        completionMessage:L(@"The Agent profile name was updated.")];
}

- (void)relocateAgentProfile:(NSMenuItem *)sender {
    NSString *profileID = [sender.representedObject isKindOfClass:NSString.class] ? sender.representedObject : nil;
    NSDictionary *profile = CCPetsProfileWithID(profileID);
    if (!profile || [self rejectWhileProfileCommandRunning]) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.allowsMultipleSelection = NO;
    panel.canCreateDirectories = NO;
    panel.showsHiddenFiles = YES;
    panel.prompt = L(@"Choose Home");
    panel.message = L(@"Choose the new location for this Agent Home.");
    panel.directoryURL = [NSURL fileURLWithPath:profile[@"home"] isDirectory:YES];
    [NSApp activateIgnoringOtherApps:YES];
    if ([panel runModal] != NSModalResponseOK) return;
    NSString *home = panel.URL.path;
    if (!CCPetsProfileHomeMatchesProvider(profile[@"provider"], home)) {
        [self showAlertWithTitle:L(@"This folder doesn't look like an Agent Home")
            message:L(@"Choose a folder containing the selected Agent's settings or state.")];
        return;
    }
    [self runProfileCommand:@[@"update", @"--id", profileID, @"--home", home]
        title:[NSString stringWithFormat:L(@"Relocating %@"), profile[@"displayName"]]
        completionMessage:L(@"The Agent Home was relocated and its integration was updated.")];
}

- (void)removeAgentProfile:(NSMenuItem *)sender {
    NSString *profileID = [sender.representedObject isKindOfClass:NSString.class] ? sender.representedObject : nil;
    NSDictionary *profile = CCPetsProfileWithID(profileID);
    if (!profile || [self rejectWhileProfileCommandRunning]) return;
    NSAlert *confirm = [NSAlert new];
    confirm.alertStyle = NSAlertStyleWarning;
    confirm.messageText = [NSString stringWithFormat:L(@"Remove integration for %@?"), profile[@"displayName"]];
    confirm.informativeText = L(@"Only CC Pets-managed Hooks, usage integration, Bridge settings, and the profile card will be removed. The Agent Home, login, and session history will be kept.");
    [confirm addButtonWithTitle:L(@"Remove Integration")];
    [confirm addButtonWithTitle:L(@"Cancel")];
    if ([confirm runModal] != NSAlertFirstButtonReturn) return;
    [self runProfileCommand:@[@"remove", @"--id", profileID]
        title:[NSString stringWithFormat:L(@"Removing %@"), profile[@"displayName"]]
        completionMessage:L(@"The CC Pets integration was removed. The Agent Home and its data were kept.")];
}

- (void)showProfileProgressWithTitle:(NSString *)title {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 360, 112)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.title = L(@"Agent Profile Setup");
    window.releasedWhenClosed = NO;
    NSTextField *label = [NSTextField labelWithString:title ?: L(@"Configuring Agent profile…")];
    label.frame = NSMakeRect(24, 57, 312, 24);
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSProgressIndicator *indicator = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(24, 28, 312, 16)];
    indicator.style = NSProgressIndicatorStyleBar;
    indicator.indeterminate = YES;
    [window.contentView addSubview:label];
    [window.contentView addSubview:indicator];
    [indicator startAnimation:nil];
    [window center];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    self.profileProgressWindow = window;
    self.profileProgressLabel = label;
    self.profileProgressIndicator = indicator;
}

- (void)updateProfileProgressForText:(NSString *)text fallback:(NSString *)fallback {
    NSDictionary<NSString *, NSString *> *stages = @{
        @"stage=registered": L(@"Profile registered…"),
        @"stage=hooks": L(@"Installing Pet Hooks and usage collection…"),
        @"stage=bridge": L(@"Configuring CC Bridge and MCP…"),
        @"stage=verify": L(@"Verifying integration…")
    };
    __block NSString *message = fallback;
    [stages enumerateKeysAndObjectsUsingBlock:^(NSString *stage, NSString *label, BOOL *stop) {
        if ([text containsString:stage]) message = label;
    }];
    dispatch_async(dispatch_get_main_queue(), ^{ self.profileProgressLabel.stringValue = message; });
}

- (void)runProfileCommand:(NSArray<NSString *> *)arguments
    title:(NSString *)title completionMessage:(NSString *)completionMessage {
    if (self.profileCommandRunning) return;
    self.profileCommandRunning = YES;
    [self showProfileProgressWithTitle:title];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:CCPetsExecutablePath()];
    task.arguments = [@[@"profile"] arrayByAddingObjectsFromArray:arguments];
    NSMutableDictionary<NSString *, NSString *> *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    NSDictionary *locator = CCBridgeCLILocator();
    NSString *path = locator[@"path"];
    if (path.length == 0) path = CCPetsLoginShellPath();
    if (path.length > 0) environment[@"PATH"] = path;
    task.environment = environment;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    __block NSMutableData *captured = [NSMutableData data];
    __weak typeof(self) weakSelf = self;
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (data.length == 0) return;
        @synchronized (captured) { [captured appendData:data]; }
        NSString *chunk = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        [weakSelf updateProfileProgressForText:chunk fallback:title];
    };
    task.terminationHandler = ^(NSTask *finished) {
        pipe.fileHandleForReading.readabilityHandler = nil;
        NSData *tail = [pipe.fileHandleForReading readDataToEndOfFile];
        @synchronized (captured) { if (tail.length > 0) [captured appendData:tail]; }
        NSString *output = [[NSString alloc] initWithData:captured encoding:NSUTF8StringEncoding] ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.profileProgressIndicator stopAnimation:nil];
            [strongSelf.profileProgressWindow close];
            strongSelf.profileProgressWindow = nil;
            strongSelf.profileProgressLabel = nil;
            strongSelf.profileProgressIndicator = nil;
            strongSelf.profileTask = nil;
            strongSelf.profileCommandRunning = NO;
            // 子进程即使适配失败也可能已经更新注册表，让打开的设置页同步账号。
            [NSNotificationCenter.defaultCenter postNotificationName:CCPetsProfilesDidChangeNotification object:nil];
            if (finished.terminationStatus == EXIT_SUCCESS) {
                [strongSelf refreshUsage:nil];
                [strongSelf showAlertWithTitle:L(@"Agent Profile Ready") message:completionMessage];
            } else {
                NSString *detail = [output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                [strongSelf showAlertWithTitle:L(@"Agent Profile Setup Failed")
                    message:detail.length > 0 ? detail : L(@"The command failed.")];
            }
        });
    };
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        pipe.fileHandleForReading.readabilityHandler = nil;
        self.profileCommandRunning = NO;
        [self.profileProgressIndicator stopAnimation:nil];
        [self.profileProgressWindow close];
        self.profileProgressWindow = nil;
        [self showAlertWithTitle:L(@"Agent Profile Setup Failed") message:error.localizedDescription];
        return;
    }
    self.profileTask = task;
}

@end
