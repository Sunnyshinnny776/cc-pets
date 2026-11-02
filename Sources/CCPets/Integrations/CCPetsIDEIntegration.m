#import "CCPetsIDEIntegration.h"
#import "CCPetsEvents.h"
#import "CCPetsL10n.h"
#import <sys/stat.h>
#import <sys/time.h>
#import <unistd.h>

static NSString *const IDEPluginID = @"com.ccpets.terminal";

// Any IntelliJ-platform IDE (IDEA, PyCharm, WebStorm, GoLand, Rider, Android Studio…)
// can host the plugin. The registration is still bound to the running PID and app path.
static BOOL IDEBundleIsJetBrains(NSString *bundleID) {
    if (![bundleID isKindOfClass:NSString.class]) return NO;
    return [bundleID hasPrefix:@"com.jetbrains."] || [bundleID isEqualToString:@"com.google.android.studio"];
}

static NSString *IDERegistryDirectory(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/CC Pets/ide-instances"];
}

// A registration never chooses an arbitrary URL. Only authenticated IPv4 loopback
// is used, with redirects and system proxies disabled.
@interface CCPetsIDELocalSession : NSObject <NSURLSessionTaskDelegate>
@end
@implementation CCPetsIDELocalSession
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(nil);
}
@end

static NSDictionary *IDERequest(NSDictionary *instance, NSString *route, NSDictionary *body) {
    NSInteger port = [instance[@"port"] integerValue];
    NSString *token = instance[@"token"];
    if (port < 1 || port > 65535 || ![token isKindOfClass:NSString.class] || token.length < 32) return nil;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld/%@", (long)port, route]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body ?: @{} options:0 error:nil];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    NSTimeInterval timeout = [route isEqualToString:@"focus"] ? 4 : 1;
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = timeout;
    configuration.timeoutIntervalForResource = timeout;
    configuration.connectionProxyDictionary = @{};
    configuration.URLCache = nil;
    configuration.HTTPCookieStorage = nil;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration
        delegate:[CCPetsIDELocalSession new] delegateQueue:nil];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *result = nil;
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (!error && data.length < 65536 && status >= 200 && status < 500) {
            id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if ([value isKindOfClass:NSDictionary.class]) result = value;
        }
        dispatch_semaphore_signal(done);
    }];
    [task resume];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 0.2) * NSEC_PER_SEC)))) {
        [task cancel];
        [session invalidateAndCancel];
        return nil;
    }
    [session finishTasksAndInvalidate];
    return result;
}

static NSArray<NSDictionary *> *IDEInstances(void) {
    NSMutableArray *instances = [NSMutableArray array];
    NSString *directory = IDERegistryDirectory();
    for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil]) {
        if (![file.pathExtension isEqualToString:@"json"]) continue;
        NSString *path = [directory stringByAppendingPathComponent:file];
        struct stat info;
        if (lstat(path.fileSystemRepresentation, &info) || !S_ISREG(info.st_mode) ||
            info.st_uid != getuid() || (info.st_mode & 0077) || info.st_size > 65536) continue;
        NSData *data = [NSData dataWithContentsOfFile:path];
        id record = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![record isKindOfClass:NSDictionary.class] || [record[@"schemaVersion"] integerValue] != 1 ||
            ![record[@"instanceID"] isKindOfClass:NSString.class] ||
            ![[file stringByDeletingPathExtension] isEqualToString:record[@"instanceID"]]) continue;
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:[record[@"pid"] intValue]];
        if (app.terminated || !IDEBundleIsJetBrains(app.bundleIdentifier) ||
            ![app.bundleURL.path isEqualToString:record[@"appPath"]]) continue;
        [instances addObject:record];
        if (instances.count >= 16) break;
    }
    return instances;
}

static NSString *IDEPluginArchive(void) {
    NSString *relative = @"IDEPlugins/cc-pets-terminal.zip";
    NSString *bundled = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:relative];
    if ([NSFileManager.defaultManager fileExistsAtPath:bundled]) return bundled;
    NSString *besideBinary = [[NSProcessInfo.processInfo.arguments.firstObject stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:relative];
    return [NSFileManager.defaultManager fileExistsAtPath:besideBinary] ? besideBinary : nil;
}

void CCPetsShowIDEPluginInstaller(void) {
    NSString *archive = IDEPluginArchive();
    NSAlert *alert = [NSAlert new];
    alert.messageText = L(@"Install the JetBrains plugin");
    if (!archive) {
        alert.informativeText = L(@"The JetBrains plugin ZIP is missing from this CC Pets installation. Reinstall CC Pets to restore it.");
        [alert addButtonWithTitle:L(@"OK")];
        [alert runModal];
        return;
    }
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:archive]]];
    alert.informativeText = L(@"In your JetBrains IDE, open Settings → Plugins → ⚙ → Install Plugin from Disk, then choose cc-pets-terminal.zip. Restart the IDE if prompted. Open a project and use the Reworked terminal; CC Pets connects automatically.");
    [alert addButtonWithTitle:L(@"Copy ZIP Path")];
    [alert addButtonWithTitle:L(@"Done")];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:archive forType:NSPasteboardTypeString];
    }
}

#pragma mark - Plugin versions

static NSString *const IDEPluginFolder = @"cc-pets-terminal";
static NSString *const IDEPluginJar = @"cc-pets-terminal/lib/cc-pets-terminal.jar";

static NSData *IDEUnzipEntry(NSString *archive, NSString *entry) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/unzip"];
    task.arguments = @[@"-p", archive, entry];
    NSPipe *output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:nil]) return nil;
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    return task.terminationStatus == 0 && data.length < 4 * 1024 * 1024 ? data : nil;
}

static NSString *IDEVersionFromPluginXML(NSData *xml) {
    NSString *text = xml ? [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding] : nil;
    if (!text) return nil;
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:
        @"<version>\\s*([0-9A-Za-z.\\-]{1,32})\\s*</version>" options:0 error:nil];
    NSTextCheckingResult *match = [pattern firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    return match ? [text substringWithRange:[match rangeAtIndex:1]] : nil;
}

// Reading a version spawns unzip, so results are cached by path, size and mtime.
static NSString *IDECachedVersion(NSString *path, NSString *(^read)(void)) {
    static NSMutableDictionary<NSString *, NSString *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    struct stat info;
    if (stat(path.fileSystemRepresentation, &info)) return nil;
    NSString *key = [NSString stringWithFormat:@"%@|%lld|%ld.%09ld", path, (long long)info.st_size,
        (long)info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec];
    @synchronized(cache) {
        if (cache[key]) return cache[key].length ? cache[key] : nil;
    }
    NSString *version = read() ?: @"";
    @synchronized(cache) { cache[key] = version; }
    return version.length ? version : nil;
}

static NSString *IDEInstalledPluginVersion(NSString *jar) {
    return IDECachedVersion(jar, ^NSString *{
        return IDEVersionFromPluginXML(IDEUnzipEntry(jar, @"META-INF/plugin.xml"));
    });
}

static NSString *IDEBundledPluginVersion(void) {
    NSString *archive = IDEPluginArchive();
    if (!archive) return nil;
    return IDECachedVersion(archive, ^NSString *{
        NSData *jar = IDEUnzipEntry(archive, IDEPluginJar);
        if (!jar) return nil;
        NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"cc-pets-plugin-%@.jar", NSUUID.UUID.UUIDString]];
        if (![jar writeToFile:temporary options:NSDataWritingAtomic error:nil]) return nil;
        NSString *version = IDEVersionFromPluginXML(IDEUnzipEntry(temporary, @"META-INF/plugin.xml"));
        [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
        return version;
    });
}

#pragma mark - Paths

static BOOL IDEOwnedDirectory(NSString *path) {
    struct stat info;
    return path.length && !lstat(path.fileSystemRepresentation, &info) && S_ISDIR(info.st_mode) &&
        info.st_uid == getuid();
}

// idea.config.path / idea.plugins.path overrides make the inferred folder unreliable.
static BOOL IDEPropertiesOverridePaths(NSString *file) {
    NSString *text = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([line hasPrefix:@"idea.config.path"] || [line hasPrefix:@"idea.plugins.path"]) return YES;
    }
    return NO;
}

#pragma mark - Snapshot

NSArray<NSDictionary *> *CCPetsIDEIntegrationSnapshot(void) {
    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];
    NSMutableDictionary<NSString *, NSString *> *bundleIDs = [NSMutableDictionary dictionary];
    for (NSString *directory in @[@"/Applications", [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]]) {
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil]) {
            if (![name.pathExtension isEqualToString:@"app"]) continue;
            NSString *path = [directory stringByAppendingPathComponent:name];
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:
                [path stringByAppendingPathComponent:@"Contents/Info.plist"]];
            if (!IDEBundleIsJetBrains(plist[@"CFBundleIdentifier"])) continue;
            [paths addObject:path];
            bundleIDs[path] = plist[@"CFBundleIdentifier"];
        }
    }
    NSMutableDictionary<NSString *, NSDate *> *launched = [NSMutableDictionary dictionary];
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        NSString *path = app.bundleURL.path;
        if (!IDEBundleIsJetBrains(app.bundleIdentifier) || !path) continue;
        [paths addObject:path];
        bundleIDs[path] = app.bundleIdentifier;
        launched[path] = app.launchDate ?: NSDate.distantPast;
    }
    NSArray *instances = IDEInstances();
    NSMutableDictionary *connected = [NSMutableDictionary dictionary];
    for (NSDictionary *instance in instances) {
        NSDictionary *status = IDERequest(instance, @"status", nil);
        if ([status[@"instanceID"] isEqual:instance[@"instanceID"]] && [status[@"schemaVersion"] integerValue] == 1)
            connected[instance[@"appPath"]] = status;
    }
    NSString *bundledVersion = IDEBundledPluginVersion();
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *path in paths) {
        NSData *data = [NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Resources/product-info.json"]];
        id info = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![info isKindOfClass:NSDictionary.class]) continue;
        NSString *version = [info[@"version"] isKindOfClass:NSString.class] ? info[@"version"] : @"";
        NSString *build = [info[@"buildNumber"] isKindOfClass:NSString.class] ? info[@"buildNumber"] : @"";
        // Some products prefix the build with their product code (e.g. "AI-251.…").
        NSString *bareBuild = [build componentsSeparatedByString:@"-"].lastObject;
        NSInteger baseline = [bareBuild componentsSeparatedByString:@"."].firstObject.integerValue;
        BOOL compatible = baseline == 262 || baseline == 263;
        // product-info.json names the per-product config folder (e.g. PyCharm2026.2,
        // Google/AndroidStudio2025.1); fall back to the IDEA layout for older metadata.
        NSString *dataDirectory = [info[@"dataDirectoryName"] isKindOfClass:NSString.class] ? info[@"dataDirectoryName"] : nil;
        if (dataDirectory.length == 0) {
            NSArray *parts = [version componentsSeparatedByString:@"."];
            NSString *suffix = parts.count >= 2 ? [NSString stringWithFormat:@"%@.%@", parts[0], parts[1]] : version;
            dataDirectory = [@"IntelliJIdea" stringByAppendingString:suffix];
        }
        BOOL google = [dataDirectory hasPrefix:@"AndroidStudio"];
        NSString *config = [[NSHomeDirectory() stringByAppendingPathComponent:
            google ? @"Library/Application Support/Google" : @"Library/Application Support/JetBrains"]
            stringByAppendingPathComponent:dataDirectory];
        NSString *plugins = [config stringByAppendingPathComponent:@"plugins"];
        // A live registration supplies the IDE's real paths (Toolbox, idea.config.path, …).
        BOOL registered = NO;
        for (NSDictionary *instance in instances) {
            if (![instance[@"appPath"] isEqual:path]) continue;
            if ([instance[@"configPath"] isKindOfClass:NSString.class]) config = instance[@"configPath"];
            if ([instance[@"pluginsPath"] isKindOfClass:NSString.class]) plugins = instance[@"pluginsPath"];
            registered = YES;
        }
        BOOL customPaths = !registered &&
            (IDEPropertiesOverridePaths([path stringByAppendingPathComponent:@"Contents/bin/idea.properties"]) ||
             IDEPropertiesOverridePaths([config stringByAppendingPathComponent:@"idea.properties"]));
        // The IDE must have run once so its config folder exists; never create it ourselves.
        BOOL autoInstall = compatible && !customPaths && IDEOwnedDirectory(config);

        NSString *pluginDirectory = [plugins stringByAppendingPathComponent:IDEPluginFolder];
        NSString *jar = [plugins stringByAppendingPathComponent:IDEPluginJar];
        BOOL installed = [NSFileManager.defaultManager fileExistsAtPath:jar];
        NSString *installedVersion = installed ? IDEInstalledPluginVersion(jar) : nil;
        NSDictionary *status = connected[path];
        NSString *runningVersion = [status[@"pluginVersion"] isKindOfClass:NSString.class] ? status[@"pluginVersion"] : nil;
        BOOL outdated = installed && bundledVersion.length && installedVersion.length &&
            [installedVersion compare:bundledVersion options:NSNumericSearch] == NSOrderedAscending;
        // Installed or updated after the IDE started: files are in place but not loaded yet.
        struct stat folder;
        BOOL changedSinceLaunch = launched[path] && installed &&
            !stat(pluginDirectory.fileSystemRepresentation, &folder) &&
            folder.st_mtimespec.tv_sec > (time_t)launched[path].timeIntervalSince1970;
        BOOL pendingRestart = launched[path] && installed &&
            (status ? (runningVersion.length && ![runningVersion isEqualToString:@"unknown"] && installedVersion.length &&
                       ![runningVersion isEqualToString:installedVersion])
                    : changedSinceLaunch);

        NSString *disabled = [NSString stringWithContentsOfFile:[config stringByAppendingPathComponent:@"disabled_plugins.txt"]
            encoding:NSUTF8StringEncoding error:nil];
        BOOL isDisabled = [[disabled componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] containsObject:IDEPluginID];
        NSString *state;
        if (!compatible && !status) state = @"unsupported";
        else if (isDisabled && !status) state = @"disabled";
        else if (!installed && !status) state = @"missing";
        else if (outdated) state = @"outdated";
        else if (pendingRestart) state = @"pendingRestart";
        else if (status) state = @"connected";
        else state = @"installed";
        NSMutableDictionary *row = [@{@"name": [path.lastPathComponent stringByDeletingPathExtension],
            @"version": version, @"state": state, @"path": path, @"compatible": @(compatible),
            @"autoInstall": @(autoInstall), @"running": @(launched[path] != nil),
            @"configPath": config, @"pluginsPath": plugins} mutableCopy];
        if (bundleIDs[path]) row[@"bundleID"] = bundleIDs[path];
        if (installedVersion) row[@"pluginVersion"] = installedVersion;
        if (bundledVersion) row[@"bundledVersion"] = bundledVersion;
        [rows addObject:row];
    }
    return rows;
}

#pragma mark - Install

static NSError *IDEInstallError(NSString *message) {
    return [NSError errorWithDomain:@"CCPetsIDEPlugin" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

// Returns nil on success, otherwise a message for the user.
static NSString *IDESwapInPlugin(NSString *archive, NSString *staging, NSString *target) {
    struct stat info;
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/ditto"];
    task.arguments = @[@"-x", @"-k", archive, staging];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:nil]) return L(@"Installation failed.");
    [task waitUntilExit];
    NSString *fresh = [staging stringByAppendingPathComponent:IDEPluginFolder];
    NSString *freshJar = [staging stringByAppendingPathComponent:IDEPluginJar];
    if (task.terminationStatus != 0 || lstat(freshJar.fileSystemRepresentation, &info) || !S_ISREG(info.st_mode)) {
        return L(@"The bundled plugin ZIP is damaged. Reinstall CC Pets to restore it.");
    }
    NSString *previous = [staging stringByAppendingPathComponent:@"previous"];
    BOOL hadPrevious = lstat(target.fileSystemRepresentation, &info) == 0;
    if (hadPrevious && rename(target.fileSystemRepresentation, previous.fileSystemRepresentation) != 0) {
        return [NSString stringWithFormat:@"%@ (%s)", target, strerror(errno)];
    }
    if (rename(fresh.fileSystemRepresentation, target.fileSystemRepresentation) != 0) {
        NSString *message = [NSString stringWithFormat:@"%@ (%s)", target, strerror(errno)];
        if (hadPrevious) rename(previous.fileSystemRepresentation, target.fileSystemRepresentation);
        return message;
    }
    // The ZIP carries fixed timestamps; mark the folder with the install time so a
    // running IDE can be reported as needing a restart.
    utimes(target.fileSystemRepresentation, NULL);
    return nil;
}

// Extracts the bundled ZIP next to the target and swaps it in with renames, so a failed
// extraction never leaves a half-written plugin behind.
BOOL CCPetsInstallIDEPlugin(NSDictionary *ide, NSError **error) {
    NSString *archive = IDEPluginArchive();
    NSString *config = ide[@"configPath"];
    NSString *plugins = ide[@"pluginsPath"];
    NSFileManager *files = NSFileManager.defaultManager;
    if (!archive) {
        if (error) *error = IDEInstallError(L(@"The JetBrains plugin ZIP is missing from this CC Pets installation. Reinstall CC Pets to restore it."));
        return NO;
    }
    if (![ide[@"autoInstall"] boolValue] || ![config isKindOfClass:NSString.class] ||
        ![plugins isKindOfClass:NSString.class] || !IDEOwnedDirectory(config)) {
        if (error) *error = IDEInstallError(L(@"This IDE's plugin folder could not be determined safely."));
        return NO;
    }
    struct stat info;
    if (lstat(plugins.fileSystemRepresentation, &info) == 0) {
        if (!IDEOwnedDirectory(plugins)) {
            if (error) *error = IDEInstallError(L(@"This IDE's plugin folder could not be determined safely."));
            return NO;
        }
    } else if (mkdir(plugins.fileSystemRepresentation, 0755) != 0) {
        if (error) *error = IDEInstallError([NSString stringWithFormat:@"%@ (%s)", plugins, strerror(errno)]);
        return NO;
    }
    NSString *target = [plugins stringByAppendingPathComponent:IDEPluginFolder];
    if (lstat(target.fileSystemRepresentation, &info) == 0 && (!S_ISDIR(info.st_mode) || info.st_uid != getuid())) {
        if (error) *error = IDEInstallError(L(@"This IDE's plugin folder could not be determined safely."));
        return NO;
    }
    char pattern[PATH_MAX];
    snprintf(pattern, sizeof pattern, "%s/.cc-pets-terminal-install-XXXXXX", plugins.fileSystemRepresentation);
    if (!mkdtemp(pattern)) {
        if (error) *error = IDEInstallError([NSString stringWithFormat:@"%@ (%s)", plugins, strerror(errno)]);
        return NO;
    }
    NSString *staging = [files stringWithFileSystemRepresentation:pattern length:strlen(pattern)];
    NSString *failure = IDESwapInPlugin(archive, staging, target);
    [files removeItemAtPath:staging error:nil];
    if (failure && error) *error = IDEInstallError(failure);
    return failure == nil;
}

void CCPetsPromptInstallIDEPlugin(NSDictionary *ide, void (^completion)(void)) {
    if (![ide[@"autoInstall"] boolValue]) {
        CCPetsShowIDEPluginInstaller();
        if (completion) completion();
        return;
    }
    BOOL update = [ide[@"state"] isEqualToString:@"outdated"];
    NSString *name = ide[@"name"];
    NSAlert *confirm = [NSAlert new];
    confirm.messageText = [NSString stringWithFormat:
        update ? L(@"Update CC Pets Terminal in %@?") : L(@"Install CC Pets Terminal in %@?"), name];
    NSString *where = [NSString stringWithFormat:L(@"The plugin will be written to %@."),
        [ide[@"pluginsPath"] stringByAbbreviatingWithTildeInPath]];
    confirm.informativeText = [ide[@"running"] boolValue]
        ? [NSString stringWithFormat:@"%@ %@", where, [NSString stringWithFormat:L(@"Restart %@ afterwards to load it."), name]]
        : [NSString stringWithFormat:@"%@ %@", where, L(@"It loads the next time the IDE starts.")];
    [confirm addButtonWithTitle:update ? L(@"Update") : L(@"Install")];
    [confirm addButtonWithTitle:L(@"Cancel")];
    if ([confirm runModal] != NSAlertFirstButtonReturn) {
        if (completion) completion();
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL ok = CCPetsInstallIDEPlugin(ide, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) {
                NSAlert *alert = [NSAlert new];
                alert.alertStyle = NSAlertStyleWarning;
                alert.messageText = L(@"Could not install the plugin automatically");
                alert.informativeText = error.localizedDescription ?: L(@"Installation failed.");
                [alert addButtonWithTitle:L(@"Install Manually…")];
                [alert addButtonWithTitle:L(@"OK")];
                if ([alert runModal] == NSAlertFirstButtonReturn) CCPetsShowIDEPluginInstaller();
            }
            if (completion) completion();
        });
    });
}

static void IDEFocusNotice(BOOL pluginMissing, NSString *bundleID) {
    NSAlert *alert = [NSAlert new];
    alert.messageText = L(@"JetBrains terminal jump");
    alert.informativeText = pluginMissing
        ? L(@"Install and enable CC Pets Terminal in your JetBrains IDE, then open a project. The plugin connects automatically and selects the terminal for this card.")
        : L(@"The matching JetBrains terminal is unavailable. Use a local Reworked terminal and trigger a new agent event. If the IDE is showing a dialog, close it and try again.");
    if (pluginMissing) [alert addButtonWithTitle:L(@"Install Plugin…")];
    [alert addButtonWithTitle:L(@"OK")];
    if ([alert runModal] != NSAlertFirstButtonReturn || !pluginMissing) return;
    // Install straight into the IDE that hosts this card when it is unambiguous.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *matches = [NSMutableArray array];
        for (NSDictionary *ide in CCPetsIDEIntegrationSnapshot()) {
            if ([ide[@"bundleID"] isEqualToString:bundleID] && [ide[@"running"] boolValue]) [matches addObject:ide];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (matches.count == 1) CCPetsPromptInstallIDEPlugin(matches.firstObject, nil);
            else CCPetsShowIDEPluginInstaller();
        });
    });
}

BOOL CCPetsRequestIDETerminalFocus(NSDictionary *target) {
    NSString *bundle = [target[@"bundleID"] isKindOfClass:NSString.class] ? target[@"bundleID"] : @"";
    NSString *instanceID = SanitizedShortString(target[@"ideInstance"], 64);
    NSString *terminalID = SanitizedShortString(target[@"ideTerminal"], 64);
    NSString *tty = SanitizedShortString([target[@"tty"] isKindOfClass:NSString.class]
        ? [target[@"tty"] lastPathComponent] : nil, 64);
    if (!IDEBundleIsJetBrains(bundle) && instanceID.length == 0) return NO;
    // AppKit stays responsive while the IDE selects its content on its own UI thread.
    static BOOL focusing = NO;
    if (focusing) return YES;
    focusing = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *instances = IDEInstances();
        BOOL found = NO, focused = NO;
        for (NSDictionary *instance in instances) {
            if (instanceID.length && ![instance[@"instanceID"] isEqualToString:instanceID]) continue;
            NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:[instance[@"pid"] intValue]];
            if (!instanceID.length && ![app.bundleIdentifier isEqualToString:bundle]) continue;
            found = YES;
            NSDictionary *response = IDERequest(instance, @"focus", @{@"tty": tty ?: @"", @"terminalID": terminalID ?: @""});
            if ([response[@"focused"] boolValue]) { focused = YES; break; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            focusing = NO;
            if (!focused) IDEFocusNotice(!found, bundle);
        });
    });
    return YES;
}
