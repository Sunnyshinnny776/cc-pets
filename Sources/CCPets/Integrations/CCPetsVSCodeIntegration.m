#import "CCPetsVSCodeIntegration.h"
#import "CCPetsEvents.h"
#import "CCPetsIDEIntegration.h"
#import "CCPetsL10n.h"
#import "CCPetsTerminalFocus.h"
#import <signal.h>
#import <sqlite3.h>
#import <sys/stat.h>
#import <unistd.h>

// 扩展的工作方式见 plugins/vscode/extension.js 开头的注释。这里负责三件事：识别 VS Code
// 家族应用并列出扩展状态、调用应用自带的 CLI 安装 VSIX、点卡片时按 TTY 让对应窗口选中
// 终端再把这个窗口前置。

static NSString *const VSCodeExtensionID = @"ccpets.cc-pets-terminal";
static NSString *const VSCodeMinimumVersion = @"1.80.0";

#pragma mark - Product metadata

// VS Code 家族的共同点是 Contents/Resources/app/product.json：applicationName 是 CLI 名
// （code / cursor / windsurf …），dataFolderName 是 ~ 下的数据目录（.vscode / .cursor …），
// nameShort 是 Application Support 下的用户数据目录。文件有几十 KB，按路径和 mtime 缓存。
static NSDictionary *VSCodeProduct(NSString *appPath) {
    if (appPath.length == 0) return nil;
    static NSMutableDictionary<NSString *, id> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    NSString *file = [appPath stringByAppendingPathComponent:@"Contents/Resources/app/product.json"];
    struct stat info;
    if (stat(file.fileSystemRepresentation, &info) || !S_ISREG(info.st_mode) || info.st_size > 4 * 1024 * 1024) return nil;
    NSString *key = [NSString stringWithFormat:@"%@|%lld|%ld", file, (long long)info.st_size, (long)info.st_mtimespec.tv_sec];
    @synchronized(cache) {
        id cached = cache[key];
        if (cached) return cached == NSNull.null ? nil : cached;
    }
    NSData *data = [NSData dataWithContentsOfFile:file];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *product = nil;
    if ([json isKindOfClass:NSDictionary.class]) {
        NSString *cli = json[@"applicationName"], *dataFolder = json[@"dataFolderName"];
        BOOL safeName = [cli isKindOfClass:NSString.class] && cli.length > 0 && cli.length < 64 &&
            ![cli containsString:@"/"] && ![cli hasPrefix:@"."];
        BOOL safeFolder = [dataFolder isKindOfClass:NSString.class] && [dataFolder hasPrefix:@"."] &&
            dataFolder.length < 64 && ![dataFolder containsString:@"/"] && ![dataFolder isEqualToString:@".."];
        if (safeName && safeFolder) {
            NSMutableDictionary *picked = [@{@"applicationName": cli, @"dataFolderName": dataFolder} mutableCopy];
            for (NSString *field in @[@"version", @"nameShort", @"nameLong"]) {
                if ([json[field] isKindOfClass:NSString.class]) picked[field] = json[field];
            }
            product = picked;
        }
    }
    @synchronized(cache) { cache[key] = product ?: NSNull.null; }
    return product;
}

// 同一 bundle ID 可能对应多个安装：老版 Antigravity 是 VS Code 分支，2.x 不是，两者都叫
// com.google.antigravity。LaunchServices 只给一个"首选"路径，未必是正在运行的那个，所以先看
// 运行中的实例（承载终端的必然在运行），任一属于 VS Code 家族即可；都没运行才问 LaunchServices。
BOOL CCPetsBundleIsVSCodeFamily(NSString *bundleID) {
    if (![bundleID isKindOfClass:NSString.class] || bundleID.length == 0) return NO;
    NSArray<NSRunningApplication *> *running = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID];
    for (NSRunningApplication *app in running) {
        if (VSCodeProduct(app.bundleURL.path)) return YES;
    }
    if (running.count) return NO;
    NSURL *url = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:bundleID];
    return VSCodeProduct(url.path) != nil;
}

static NSString *VSCodeCLIPath(NSString *appPath, NSDictionary *product) {
    NSString *cli = [appPath stringByAppendingPathComponent:
        [@"Contents/Resources/app/bin" stringByAppendingPathComponent:product[@"applicationName"]]];
    struct stat info;
    // 必须是包内的普通可执行文件，不跟随符号链接到包外。
    if (lstat(cli.fileSystemRepresentation, &info) || !S_ISREG(info.st_mode) || !(info.st_mode & S_IXUSR)) return nil;
    return cli;
}

static NSString *VSCodeAppVersion(NSString *appPath, NSDictionary *product) {
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:
        [appPath stringByAppendingPathComponent:@"Contents/Info.plist"]];
    NSString *version = plist[@"CFBundleShortVersionString"];
    return [version isKindOfClass:NSString.class] ? version : (product[@"version"] ?: @"");
}

#pragma mark - Extension versions

static NSString *VSCodeExtensionArchive(void) {
    NSString *relative = @"IDEPlugins/cc-pets-terminal.vsix";
    NSString *bundled = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:relative];
    if ([NSFileManager.defaultManager fileExistsAtPath:bundled]) return bundled;
    NSString *besideBinary = [[NSProcessInfo.processInfo.arguments.firstObject stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:relative];
    return [NSFileManager.defaultManager fileExistsAtPath:besideBinary] ? besideBinary : nil;
}

static NSString *VersionFromPackageJSON(NSData *data) {
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *version = [json isKindOfClass:NSDictionary.class] ? json[@"version"] : nil;
    return [version isKindOfClass:NSString.class] && version.length < 32 ? version : nil;
}

static NSString *VSCodeBundledVersion(void) {
    NSString *archive = VSCodeExtensionArchive();
    if (!archive) return nil;
    static NSString *cachedKey, *cachedVersion;
    struct stat info;
    if (stat(archive.fileSystemRepresentation, &info)) return nil;
    NSString *key = [NSString stringWithFormat:@"%@|%lld|%ld", archive, (long long)info.st_size, (long)info.st_mtimespec.tv_sec];
    @synchronized(VSCodeExtensionID) {
        if ([cachedKey isEqualToString:key]) return cachedVersion.length ? cachedVersion : nil;
    }
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/unzip"];
    task.arguments = @[@"-p", archive, @"extension/package.json"];
    NSPipe *output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSString *version = nil;
    if ([task launchAndReturnError:nil]) {
        NSData *data = [output.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        if (task.terminationStatus == 0 && data.length < 65536) version = VersionFromPackageJSON(data);
    }
    @synchronized(VSCodeExtensionID) {
        cachedKey = key;
        cachedVersion = version ?: @"";
    }
    return version;
}

// 扩展目录里的 ccpets.cc-pets-terminal-<版本>，排除已标记删除（.obsolete）的旧版本。
static NSString *VSCodeInstalledVersion(NSString *extensionsPath) {
    NSData *obsoleteData = [NSData dataWithContentsOfFile:[extensionsPath stringByAppendingPathComponent:@".obsolete"]];
    id obsolete = obsoleteData ? [NSJSONSerialization JSONObjectWithData:obsoleteData options:0 error:nil] : nil;
    if (![obsolete isKindOfClass:NSDictionary.class]) obsolete = @{};
    NSString *prefix = [VSCodeExtensionID stringByAppendingString:@"-"];
    NSString *best = nil;
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:extensionsPath error:nil]) {
        if (![name.lowercaseString hasPrefix:prefix] || [obsolete[name] boolValue]) continue;
        NSString *manifest = [[extensionsPath stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"package.json"];
        struct stat info;
        if (lstat(manifest.fileSystemRepresentation, &info) || !S_ISREG(info.st_mode) || info.st_size > 65536) continue;
        NSString *version = VersionFromPackageJSON([NSData dataWithContentsOfFile:manifest]);
        if (version && (!best || [version compare:best options:NSNumericSearch] == NSOrderedDescending)) best = version;
    }
    return best;
}

// 用户在扩展视图里禁用后，ID 记在全局状态库的 extensionsIdentifiers/disabled 里。
static BOOL VSCodeExtensionDisabled(NSDictionary *product) {
    NSString *userData = product[@"nameShort"];
    if (userData.length == 0 || [userData containsString:@"/"]) return NO;
    NSString *database = [NSString stringWithFormat:@"%@/Library/Application Support/%@/User/globalStorage/state.vscdb",
        NSHomeDirectory(), userData];
    if (![NSFileManager.defaultManager fileExistsAtPath:database]) return NO;
    sqlite3 *db = NULL;
    BOOL disabled = NO;
    if (sqlite3_open_v2(database.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
        sqlite3_busy_timeout(db, 200);
        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = 'extensionsIdentifiers/disabled'",
                -1, &statement, NULL) == SQLITE_OK && sqlite3_step(statement) == SQLITE_ROW) {
            const void *bytes = sqlite3_column_blob(statement, 0);
            int length = sqlite3_column_bytes(statement, 0);
            NSData *data = bytes && length > 0 && length < 1024 * 1024 ? [NSData dataWithBytes:bytes length:length] : nil;
            id list = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if ([list isKindOfClass:NSArray.class]) {
                for (id entry in list) {
                    NSString *identifier = [entry isKindOfClass:NSDictionary.class] ? entry[@"id"] : nil;
                    if ([identifier isKindOfClass:NSString.class] &&
                        [identifier caseInsensitiveCompare:VSCodeExtensionID] == NSOrderedSame) disabled = YES;
                }
            }
        }
        sqlite3_finalize(statement);
    }
    sqlite3_close(db);
    return disabled;
}

#pragma mark - Instances

static BOOL ProcessIsAlive(pid_t pid) {
    return pid > 0 && (kill(pid, 0) == 0 || errno == EPERM);
}

// 主进程活着不代表窗口还在：关掉的窗口留下的注册文件，靠 extension host 的 PID 排除。
static NSArray<NSDictionary *> *VSCodeInstances(NSArray<NSString *> *bundleIDs) {
    return CCPetsIDEBridgeInstances(^BOOL(NSDictionary *record, NSRunningApplication *app) {
        if (![record[@"kind"] isEqual:@"vscode"] || !VSCodeProduct(app.bundleURL.path)) return NO;
        if (!ProcessIsAlive([record[@"extensionHostPid"] intValue])) return NO;
        return bundleIDs.count == 0 || [bundleIDs containsObject:app.bundleIdentifier ?: @""];
    });
}

#pragma mark - Snapshot

NSArray<NSDictionary *> *CCPetsVSCodeIntegrationSnapshot(void) {
    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];
    for (NSString *directory in @[@"/Applications", [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]]) {
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil]) {
            NSString *path = [directory stringByAppendingPathComponent:name];
            if ([name.pathExtension isEqualToString:@"app"] && VSCodeProduct(path)) [paths addObject:path];
        }
    }
    NSMutableDictionary<NSString *, NSRunningApplication *> *running = [NSMutableDictionary dictionary];
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        NSString *path = app.bundleURL.path;
        if (!path || !VSCodeProduct(path)) continue;
        [paths addObject:path];
        running[path] = app;
    }
    if (paths.count == 0) return @[];

    // 每个应用可能开着多个窗口；任一窗口应答即视为已连接，同时取它报告的真实扩展目录。
    NSMutableDictionary<NSString *, NSDictionary *> *connected = [NSMutableDictionary dictionary];
    for (NSDictionary *instance in VSCodeInstances(nil)) {
        NSString *appPath = instance[@"appPath"];
        if (connected[appPath]) continue;
        NSDictionary *status = CCPetsIDEBridgeRequest(instance, @"status", nil);
        if (![status[@"instanceID"] isEqual:instance[@"instanceID"]] || [status[@"schemaVersion"] integerValue] != 1) continue;
        NSMutableDictionary *merged = [status mutableCopy];
        if ([instance[@"extensionsPath"] isKindOfClass:NSString.class]) merged[@"extensionsPath"] = instance[@"extensionsPath"];
        connected[appPath] = merged;
    }

    NSString *bundledVersion = VSCodeBundledVersion();
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *path in paths) {
        NSDictionary *product = VSCodeProduct(path);
        NSDictionary *status = connected[path];
        NSString *engine = product[@"version"];
        BOOL compatible = engine.length == 0 ||
            [engine compare:VSCodeMinimumVersion options:NSNumericSearch] != NSOrderedAscending;
        NSString *extensions = [status[@"extensionsPath"] isKindOfClass:NSString.class] ? status[@"extensionsPath"]
            : [[NSHomeDirectory() stringByAppendingPathComponent:product[@"dataFolderName"]]
                stringByAppendingPathComponent:@"extensions"];
        NSString *installedVersion = VSCodeInstalledVersion(extensions);
        NSString *runningVersion = [status[@"pluginVersion"] isKindOfClass:NSString.class] ? status[@"pluginVersion"] : nil;
        BOOL outdated = installedVersion.length && bundledVersion.length &&
            [installedVersion compare:bundledVersion options:NSNumericSearch] == NSOrderedAscending;
        BOOL pendingRestart = status && installedVersion.length && runningVersion.length &&
            ![runningVersion isEqualToString:installedVersion];
        NSString *cli = VSCodeCLIPath(path, product);

        NSString *state;
        if (!compatible && !status) state = @"unsupported";
        else if (!installedVersion && !status) state = @"missing";
        else if (outdated) state = @"outdated";
        else if (pendingRestart) state = @"pendingRestart";
        else if (status) state = @"connected";
        else if (VSCodeExtensionDisabled(product)) state = @"disabled";
        else state = @"installed";

        NSString *name = [path.lastPathComponent stringByDeletingPathExtension];
        NSMutableDictionary *row = [@{@"name": name, @"version": VSCodeAppVersion(path, product),
            @"state": state, @"path": path, @"compatible": @(compatible), @"autoInstall": @(cli != nil),
            @"running": @(running[path] != nil), @"extensionsPath": extensions} mutableCopy];
        NSString *bundleID = running[path].bundleIdentifier ?: [NSBundle bundleWithPath:path].bundleIdentifier;
        if (bundleID) row[@"bundleID"] = bundleID;
        if (cli) row[@"cliPath"] = cli;
        if (installedVersion) row[@"pluginVersion"] = installedVersion;
        if (bundledVersion) row[@"bundledVersion"] = bundledVersion;
        [rows addObject:row];
    }
    return rows;
}

#pragma mark - Install

static NSError *VSCodeInstallError(NSString *message) {
    return [NSError errorWithDomain:@"CCPetsVSCodeExtension" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

// CLI 在 VS Code 终端里会把请求转给那个窗口（VSCODE_IPC_HOOK_CLI），从而装进别的应用；
// ELECTRON_RUN_AS_NODE 等也会改变它的行为。Pet 自己可能就是从 VS Code 终端启动的。
// 用户用来改数据目录的几个变量应用本身也认，保留。
static NSDictionary *VSCodeCLIEnvironment(void) {
    NSSet *kept = [NSSet setWithArray:@[@"VSCODE_EXTENSIONS", @"VSCODE_APPDATA", @"VSCODE_PORTABLE"]];
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    for (NSString *key in environment.allKeys) {
        if (([key hasPrefix:@"VSCODE_"] && ![kept containsObject:key]) || [key hasPrefix:@"ELECTRON_"]) {
            [environment removeObjectForKey:key];
        }
    }
    return environment;
}

BOOL CCPetsInstallVSCodeExtension(NSDictionary *app, NSError **error) {
    NSString *archive = VSCodeExtensionArchive();
    if (!archive) {
        if (error) *error = VSCodeInstallError(L(@"The VS Code extension is missing from this CC Pets installation. Reinstall CC Pets to restore it."));
        return NO;
    }
    NSString *path = app[@"path"];
    NSDictionary *product = VSCodeProduct(path);
    NSString *cli = product ? VSCodeCLIPath(path, product) : nil;
    if (!cli || ![cli isEqualToString:app[@"cliPath"]]) {
        if (error) *error = VSCodeInstallError(L(@"This app's command line tool was not found."));
        return NO;
    }
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:cli];
    task.arguments = @[@"--install-extension", archive, @"--force"];
    task.environment = VSCodeCLIEnvironment();
    task.currentDirectoryURL = [NSURL fileURLWithPath:NSHomeDirectory()];
    NSPipe *output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = output;
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    dispatch_semaphore_t exited = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask *finished) { dispatch_semaphore_signal(exited); };
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (error) *error = VSCodeInstallError(launchError.localizedDescription ?: L(@"Installation failed."));
        return NO;
    }
    // 边跑边读，免得输出塞满管道把 CLI 卡住。
    __block NSData *log = nil;
    dispatch_semaphore_t drained = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        log = [output.fileHandleForReading readDataToEndOfFile];
        dispatch_semaphore_signal(drained);
    });
    if (dispatch_semaphore_wait(exited, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC))) {
        [task terminate];
        if (error) *error = VSCodeInstallError(L(@"The command line tool did not finish in time."));
        return NO;
    }
    dispatch_semaphore_wait(drained, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    NSString *text = log ? [[NSString alloc] initWithData:log encoding:NSUTF8StringEncoding] : @"";
    if (task.terminationStatus == 0 && ![text localizedCaseInsensitiveContainsString:@"failed"]) return YES;
    // 把 CLI 最后一行有内容的输出交给用户，通常就是失败原因。
    NSString *reason = nil;
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet].reverseObjectEnumerator) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (trimmed.length) { reason = trimmed.length > 300 ? [trimmed substringToIndex:300] : trimmed; break; }
    }
    if (error) *error = VSCodeInstallError(reason ?: L(@"Installation failed."));
    return NO;
}

void CCPetsShowVSCodeExtensionInstaller(NSString *appName) {
    NSString *archive = VSCodeExtensionArchive();
    NSAlert *alert = [NSAlert new];
    alert.messageText = L(@"Install the VS Code extension");
    if (!archive) {
        alert.informativeText = L(@"The VS Code extension is missing from this CC Pets installation. Reinstall CC Pets to restore it.");
        [alert addButtonWithTitle:L(@"OK")];
        [alert runModal];
        return;
    }
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:archive]]];
    alert.informativeText = [NSString stringWithFormat:
        L(@"In %@, open the Extensions view, choose ⋯ → Install from VSIX…, then pick cc-pets-terminal.vsix. Open windows connect automatically; reload a window if it does not."),
        appName.length ? appName : @"VS Code"];
    [alert addButtonWithTitle:L(@"Copy VSIX Path")];
    [alert addButtonWithTitle:L(@"Done")];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:archive forType:NSPasteboardTypeString];
    }
}

void CCPetsPromptInstallVSCodeExtension(NSDictionary *app, void (^completion)(void)) {
    NSString *name = app[@"name"];
    if (![app[@"autoInstall"] boolValue]) {
        CCPetsShowVSCodeExtensionInstaller(name);
        if (completion) completion();
        return;
    }
    BOOL update = [app[@"state"] isEqualToString:@"outdated"];
    NSAlert *confirm = [NSAlert new];
    confirm.messageText = [NSString stringWithFormat:
        update ? L(@"Update CC Pets Terminal in %@?") : L(@"Install CC Pets Terminal in %@?"), name];
    NSString *how = [NSString stringWithFormat:L(@"CC Pets installs the extension with %@'s command line tool."), name];
    NSString *after = ![app[@"running"] boolValue] ? [NSString stringWithFormat:L(@"It loads the next time %@ starts."), name]
        : (update ? L(@"Reload open windows afterwards to load the new version.")
                  : L(@"Open windows connect automatically; reload a window if it does not."));
    confirm.informativeText = [NSString stringWithFormat:@"%@ %@", how, after];
    [confirm addButtonWithTitle:update ? L(@"Update") : L(@"Install")];
    [confirm addButtonWithTitle:L(@"Cancel")];
    if ([confirm runModal] != NSAlertFirstButtonReturn) {
        if (completion) completion();
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL ok = CCPetsInstallVSCodeExtension(app, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) {
                NSAlert *alert = [NSAlert new];
                alert.alertStyle = NSAlertStyleWarning;
                alert.messageText = L(@"Could not install the extension automatically");
                alert.informativeText = error.localizedDescription ?: L(@"Installation failed.");
                [alert addButtonWithTitle:L(@"Install Manually…")];
                [alert addButtonWithTitle:L(@"OK")];
                if ([alert runModal] == NSAlertFirstButtonReturn) CCPetsShowVSCodeExtensionInstaller(name);
            }
            if (completion) completion();
        });
    });
}

#pragma mark - Focus

static NSWorkspaceOpenConfiguration *ActivatingConfiguration(void) {
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.activates = YES;
    configuration.addsToRecentItems = NO;
    return configuration;
}

// 扩展 API 无法前置系统窗口。把窗口的工作区再交给应用打开一次：已经打开它的窗口会被
// 聚焦并切到所在桌面，与在 Finder 里打开同一个文件夹的效果一样。只交出确实存在的文件夹
// 或 .code-workspace 文件，避免路径失效时开出新窗口；没有工作区的窗口只能激活应用。
static void VSCodeBringWindowForward(NSString *appPath, NSString *workspace) {
    NSURL *application = [NSURL fileURLWithPath:appPath isDirectory:YES];
    BOOL isDirectory = NO;
    BOOL openable = [workspace isKindOfClass:NSString.class] && workspace.isAbsolutePath &&
        [NSFileManager.defaultManager fileExistsAtPath:workspace isDirectory:&isDirectory] &&
        (isDirectory || [workspace.pathExtension isEqualToString:@"code-workspace"]);
    if (openable) {
        [NSWorkspace.sharedWorkspace openURLs:@[[NSURL fileURLWithPath:workspace isDirectory:isDirectory]]
            withApplicationAtURL:application configuration:ActivatingConfiguration() completionHandler:nil];
    } else {
        [NSWorkspace.sharedWorkspace openApplicationAtURL:application
            configuration:ActivatingConfiguration() completionHandler:nil];
    }
}

BOOL CCPetsRequestVSCodeTerminalFocus(NSDictionary *target) {
    if (![target isKindOfClass:NSDictionary.class]) return NO;
    NSString *tty = SanitizedShortString([target[@"tty"] isKindOfClass:NSString.class]
        ? [target[@"tty"] lastPathComponent] : nil, 64);
    if (![tty hasPrefix:@"ttys"]) return NO;
    NSMutableArray<NSString *> *bundles = [NSMutableArray array];
    for (NSString *bundleID in TerminalFocusBundleCandidates(target)) {
        if (CCPetsBundleIsVSCodeFamily(bundleID)) [bundles addObject:bundleID];
    }
    // TERM_PROGRAM=vscode 却没捕获到应用时问遍所有 VS Code 家族窗口：TTY 在本机唯一。
    NSString *program = SanitizedShortString(target[@"program"], 64).lowercaseString;
    if (bundles.count == 0 && ![program isEqualToString:@"vscode"]) return NO;
    // 只读注册文件，不发请求；没有连接中的窗口时立即交还给调用方激活应用。
    NSArray<NSDictionary *> *instances = VSCodeInstances(bundles);
    if (instances.count == 0) return NO;

    static BOOL focusing = NO;
    if (focusing) return YES;
    focusing = YES;
    NSString *fallbackApp = instances.firstObject[@"appPath"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *appPath = nil, *workspace = nil;
        for (NSDictionary *instance in instances) {
            NSDictionary *response = CCPetsIDEBridgeRequest(instance, @"focus", @{@"tty": tty});
            if (![response[@"focused"] boolValue]) continue;
            appPath = instance[@"appPath"];
            workspace = response[@"workspace"];
            break;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            focusing = NO;
            if (appPath) {
                VSCodeBringWindowForward(appPath, workspace);
            } else {
                // 远程窗口或扩展加载前就开着的异常情况：至少回到应用。
                NSLog(@"VS Code terminal focus: no window owns %@", tty);
                VSCodeBringWindowForward(fallbackApp, nil);
            }
        });
    });
    return YES;
}
