// 检查更新、自动更新、更新气泡 / 角标 / 弹窗，以及「关于」。
#import "CCPetsAppDelegate+Private.h"

static void TrimUpdateLog(NSString *path) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return;
    unsigned long long size = [handle seekToEndOfFile];
    if (size <= UpdateLogSizeLimit) {
        [handle closeFile];
        return;
    }
    [handle seekToFileOffset:size - UpdateLogSizeLimit];
    NSData *tail = [handle readDataToEndOfFile];
    [handle closeFile];
    [tail writeToFile:path options:NSDataWritingAtomic error:nil];
    chmod(path.fileSystemRepresentation, S_IRUSR | S_IWUSR);
}

@implementation AppDelegate (Update)
- (NSDictionary *)updaterConfiguration {
    NSString *path = [[self applicationSupportDirectory] stringByAppendingPathComponent:@"updater.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSDictionary *configuration = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [configuration isKindOfClass:NSDictionary.class] ? configuration : nil;
}
- (BOOL)restartAfterUpdateToVersion:(NSString *)version configuration:(NSDictionary *)configuration {
    NSString *appPath = [configuration[@"appPath"] isKindOfClass:NSString.class]
        ? [configuration[@"appPath"] stringByStandardizingPath] : nil;
    if (appPath.length == 0 &&
        [NSBundle.mainBundle.bundlePath.pathExtension.lowercaseString isEqualToString:@"app"]) {
        appPath = NSBundle.mainBundle.bundlePath.stringByStandardizingPath;
    }
    if (appPath.length == 0) {
        appPath = [[NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]
            stringByAppendingPathComponent:@"CC Pets.app"];
    }

    NSString *infoPath = [appPath stringByAppendingPathComponent:@"Contents/Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
    NSString *installedVersion = [info[@"CFBundleShortVersionString"] isKindOfClass:NSString.class]
        ? info[@"CFBundleShortVersionString"] : nil;
    NSString *executablePath = [appPath stringByAppendingPathComponent:@"Contents/MacOS/cc-pets"];
    if (![installedVersion isEqualToString:version] ||
        ![NSFileManager.defaultManager isExecutableFileAtPath:executablePath]) return NO;

    NSTask *restartTask = [NSTask new];
    restartTask.executableURL = [NSURL fileURLWithPath:executablePath];
    restartTask.arguments = @[
        @"--restart-after-pid",
        [NSString stringWithFormat:@"%d", NSProcessInfo.processInfo.processIdentifier],
        appPath,
        self.managedByCLI ? @"--managed" : @"--standalone"
    ];
    NSError *error = nil;
    if (![restartTask launchAndReturnError:&error]) return NO;
    [NSApp terminate:nil];
    return YES;
}
- (void)startUpdateToVersion:(NSString *)version {
    if (self.updating) return;
    [self startUpdateToVersion:version attempt:0];
}
- (void)retryUpdate:(NSArray *)context {
    self.updating = NO;
    [self refreshUpdateBadge];
    [self startUpdateToVersion:context[0] attempt:[context[1] integerValue]];
}
- (void)startUpdateToVersion:(NSString *)version attempt:(NSInteger)attempt {
    NSDictionary *configuration = [self updaterConfiguration];
    NSString *nodePath = [configuration[@"nodePath"] isKindOfClass:NSString.class]
        ? [configuration[@"nodePath"] stringByStandardizingPath] : nil;
    NSString *npmCliPath = [configuration[@"npmCliPath"] isKindOfClass:NSString.class]
        ? [configuration[@"npmCliPath"] stringByStandardizingPath] : nil;
    BOOL nodeExecutable = nodePath.isAbsolutePath &&
        [NSFileManager.defaultManager isExecutableFileAtPath:nodePath];
    BOOL npmCliExists = npmCliPath.isAbsolutePath &&
        [NSFileManager.defaultManager isReadableFileAtPath:npmCliPath];
    if (!nodeExecutable || !npmCliExists) {
        [self showAlertWithTitle:L(@"Can't Update Automatically")
            message:L(@"The Node.js/npm used to install CC Pets wasn't found. Run this once manually:\n"
        "\n"
        "npm install -g cc-pets@latest --allow-scripts=cc-pets")];
        return;
    }

    NSString *supportDirectory = [self applicationSupportDirectory];
    NSError *directoryError = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:supportDirectory
        withIntermediateDirectories:YES attributes:nil error:&directoryError];
    if (directoryError) {
        [self showAlertWithTitle:L(@"Can't Update Automatically") message:directoryError.localizedDescription];
        return;
    }
    NSString *logPath = [supportDirectory stringByAppendingPathComponent:@"update.log"];
    [NSData.data writeToFile:logPath options:NSDataWritingAtomic error:nil];
    chmod(logPath.fileSystemRepresentation, S_IRUSR | S_IWUSR);
    NSFileHandle *logHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!logHandle) {
        [self showAlertWithTitle:L(@"Can't Update Automatically") message:L(@"Couldn't create the update log.")];
        return;
    }

    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:nodePath];
    NSMutableArray<NSString *> *arguments = [@[
        npmCliPath,
        @"install",
        @"--global",
        [@"cc-pets@" stringByAppendingString:version],
        @"--allow-scripts=cc-pets",
        @"--prefer-online"
    ] mutableCopy];
    if (attempt > 0) {
        // 重试走一个一次性缓存目录：ETARGET 的成因就是本机缓存里的包元数据还没有这个
        // 版本，--prefer-online 只是允许重新校验，命中 304 时依然拿到旧元数据。
        // 换缓存目录能强制冷取，又不动用户真正的 npm 缓存。
        [arguments addObjectsFromArray:@[@"--cache",
            [supportDirectory stringByAppendingPathComponent:@"update-retry-cache"]]];
    }
    task.arguments = arguments;
    NSMutableDictionary<NSString *, NSString *> *environment =
        [NSProcessInfo.processInfo.environment mutableCopy];
    NSString *nodeDirectory = nodePath.stringByDeletingLastPathComponent;
    NSString *existingPath = environment[@"PATH"];
    if (existingPath.length == 0) existingPath = @"/usr/bin:/bin:/usr/sbin:/sbin";
    environment[@"PATH"] = [NSString stringWithFormat:@"%@:%@", nodeDirectory, existingPath];
    task.environment = environment;
    task.currentDirectoryURL = [NSURL fileURLWithPath:NSHomeDirectory()];
    task.standardOutput = logHandle;
    task.standardError = logHandle;
    self.updating = YES;
    [self refreshUpdateBadge];
    self.updateTask = task;
    __weak typeof(self) weakSelf = self;
    task.terminationHandler = ^(NSTask *finishedTask) {
        [logHandle closeFile];
        TrimUpdateLog(logPath);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.updateTask = nil;
            if (finishedTask.terminationStatus == EXIT_SUCCESS) {
                strongSelf.updating = NO;
                [strongSelf refreshUpdateBadge];
                if ([strongSelf restartAfterUpdateToVersion:version configuration:configuration]) return;
                [strongSelf showAlertWithTitle:L(@"Update Complete")
                    message:L(@"CC Pets was updated, but the new app couldn't be relaunched automatically. Please restart it manually.")];
                return;
            }
            // 暂时性故障（典型是刚发布的版本报 ETARGET）自动重试一次再说，
            // 别把一个重试就能过的问题弹成"更新失败"。updating 保持为 YES，
            // 等待期间不接受新的更新请求。
            NSString *log = [NSString stringWithContentsOfFile:logPath
                encoding:NSUTF8StringEncoding error:nil];
            if (attempt == 0 && UpdateFailureIsTransient(log)) {
                [strongSelf performSelector:@selector(retryUpdate:)
                    withObject:@[version, @1] afterDelay:UpdateRetryDelay];
                return;
            }
            strongSelf.updating = NO;
            [strongSelf refreshUpdateBadge];
            [NSApp activateIgnoringOtherApps:YES];
            NSAlert *alert = [NSAlert new];
            alert.messageText = L(@"Update Failed");
            alert.informativeText = [NSString stringWithFormat:
                L(@"You can keep using the current version. Details were written to:\n%@"), logPath];
            [alert addButtonWithTitle:L(@"Open Log")];
            [alert addButtonWithTitle:L(@"Close")];
            if ([alert runModal] == NSAlertFirstButtonReturn) {
                [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:logPath]];
            }
        });
    };
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        self.updating = NO;
        [self refreshUpdateBadge];
        self.updateTask = nil;
        [logHandle closeFile];
        [self showAlertWithTitle:L(@"Can't Start Update") message:launchError.localizedDescription];
        return;
    }
    // 重试是静默的：第一次已经弹过"正在更新"，再弹一次只会让人以为出了两回事。
    if (attempt == 0) {
        [self showAlertWithTitle:L(@"Updating")
            message:[NSString stringWithFormat:L(@"Downloading and installing CC Pets %@. The pet will restart when it's done."), version]];
    }
}
// 关于弹窗与检查更新同用 NSAlert，保持样式一致；版本号用构建时注入的 CC_PETS_VERSION（与检查更新
// 同一口径）。桌宠是 LSUIElement，不先激活的话弹窗会开在其他 App 后面。
- (void)showAboutPanel:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"CC Pets";
    alert.informativeText = [NSString stringWithFormat:
        L(@"Version %@\n\nA desktop pet for Claude Code and Codex CLI."), @CC_PETS_VERSION];
    [alert addButtonWithTitle:L(@"OK")];
    [alert addButtonWithTitle:L(@"Visit Homepage")];
    if ([alert runModal] == NSAlertSecondButtonReturn) {
        [NSWorkspace.sharedWorkspace openURL:
            [NSURL URLWithString:[@"https://github.com/" stringByAppendingString:CCPetsRepositorySlug]]];
    }
}
// 版本号以 npm Registry 为准（自动更新装的就是它），更新说明取同版本 tag 的 GitHub Release
// 描述。Release 没写、没建、或 GitHub 请求失败都只是没有说明，不影响提示更新本身。
- (void)fetchLatestReleaseWithCompletion:(void (^)(NSString *version, NSArray<NSString *> *highlights,
    BOOL highlightsTruncated, NSString *errorMessage))completion {
    NSURL *url = [NSURL URLWithString:@"https://registry.npmjs.org/cc-pets/latest"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = [response isKindOfClass:NSHTTPURLResponse.class]
            ? (NSHTTPURLResponse *)response : nil;
        NSDictionary *metadata = data
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *latestVersion = [metadata isKindOfClass:NSDictionary.class] &&
            [metadata[@"version"] isKindOfClass:NSString.class] ? metadata[@"version"] : nil;
        BOOL valid = NO;
        NSComparisonResult comparison = CompareStableVersions(@CC_PETS_VERSION, latestVersion, &valid);
        if (error || httpResponse.statusCode != 200 || !valid) {
            NSString *message = error.localizedDescription ?: L(@"The npm registry returned invalid version info. Please try again later.");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, nil, NO, message); });
            return;
        }
        if (comparison != NSOrderedAscending) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(latestVersion, nil, NO, nil); });
            return;
        }
        NSString *releaseURL = [NSString stringWithFormat:
            @"https://api.github.com/repos/%@/releases/tags/v%@", CCPetsRepositorySlug, latestVersion];
        NSMutableURLRequest *releaseRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:releaseURL]
            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
        [releaseRequest setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
        [releaseRequest setValue:@"cc-pets/" CC_PETS_VERSION forHTTPHeaderField:@"User-Agent"];
        NSURLSessionDataTask *releaseTask = [NSURLSession.sharedSession dataTaskWithRequest:releaseRequest
            completionHandler:^(NSData *releaseData, NSURLResponse *releaseResponse, NSError *releaseError) {
            NSInteger status = [releaseResponse isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)releaseResponse).statusCode : 0;
            NSDictionary *release = !releaseError && status == 200 && releaseData
                ? [NSJSONSerialization JSONObjectWithData:releaseData options:0 error:nil] : nil;
            NSString *body = [release isKindOfClass:NSDictionary.class] &&
                [release[@"body"] isKindOfClass:NSString.class] ? release[@"body"] : nil;
            BOOL truncated = NO;
            NSArray<NSString *> *highlights = ReleaseNoteHighlightsForLanguage(body,
                CCPetsCurrentLanguage(), UpdateHighlightLimit, UpdateHighlightMaxLength, &truncated);
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(latestVersion, highlights, truncated, nil);
            });
        }];
        [releaseTask resume];
    }];
    [task resume];
}
- (void)checkForUpdates:(id)sender {
    if (self.checkingForUpdate || self.updating) return;
    self.checkingForUpdate = YES;
    __weak typeof(self) weakSelf = self;
    [self fetchLatestReleaseWithCompletion:^(NSString *version, NSArray<NSString *> *highlights,
        BOOL truncated, NSString *errorMessage) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.checkingForUpdate = NO;
        if (errorMessage) {
            [strongSelf showAlertWithTitle:L(@"Update Check Failed") message:errorMessage];
            return;
        }
        BOOL valid = NO;
        if (CompareStableVersions(@CC_PETS_VERSION, version, &valid) != NSOrderedAscending) {
            [strongSelf clearPendingUpdate];
            [strongSelf showAlertWithTitle:L(@"You're Up to Date")
                message:[NSString stringWithFormat:L(@"Version %@"), @CC_PETS_VERSION]];
            return;
        }
        [strongSelf rememberPendingUpdate:version highlights:highlights truncated:truncated];
        [strongSelf showUpdateDialog];
    }];
}
// 启动时（含 CLI 再次 open 一个已在运行的桌宠）静默检查一次：失败一律不打扰，
// 有新版本就让宠物冒一个能点的气泡。距上次联网不到 UpdateSilentCheckInterval 时
// 不重复请求，已知有新版本的话直接再提示一次。
- (void)silentCheckForUpdate {
    if (self.checkingForUpdate || self.updating) return;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (self.lastSilentUpdateCheckAt > 0 && now - self.lastSilentUpdateCheckAt < UpdateSilentCheckInterval) {
        if (self.pendingUpdateVersion) [self showUpdateBubble];
        return;
    }
    self.lastSilentUpdateCheckAt = now;
    self.checkingForUpdate = YES;
    __weak typeof(self) weakSelf = self;
    [self fetchLatestReleaseWithCompletion:^(NSString *version, NSArray<NSString *> *highlights,
        BOOL truncated, NSString *errorMessage) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.checkingForUpdate = NO;
        if (errorMessage || strongSelf.updating) return;
        BOOL valid = NO;
        if (CompareStableVersions(@CC_PETS_VERSION, version, &valid) != NSOrderedAscending) {
            [strongSelf clearPendingUpdate];
            return;
        }
        [strongSelf rememberPendingUpdate:version highlights:highlights truncated:truncated];
        [strongSelf showUpdateBubble];
    }];
}
- (void)rememberPendingUpdate:(NSString *)version highlights:(NSArray<NSString *> *)highlights
    truncated:(BOOL)truncated {
    // 「稍后」只针对当时那个版本；又出了更新的版本就重新提醒。
    if (![version isEqualToString:self.pendingUpdateVersion]) self.updateReminderSnoozed = NO;
    self.pendingUpdateVersion = version;
    self.pendingUpdateHighlights = highlights ?: @[];
    self.pendingUpdateHighlightsTruncated = truncated;
    [self refreshUpdateBadge];
}
- (void)refreshUpdateBadge {
    BOOL show = self.pendingUpdateVersion.length > 0 && !self.updating;
    self.updateBadgeView.hidden = !show;
    self.updateBadgeButton.toolTip = show
        ? [NSString stringWithFormat:L(@"Version %@ is available. Click to view."), self.pendingUpdateVersion] : nil;
}
- (void)clearPendingUpdate {
    self.pendingUpdateVersion = nil;
    self.pendingUpdateHighlights = nil;
    self.pendingUpdateHighlightsTruncated = NO;
    [self refreshUpdateBadge];
    if (self.updateBubbleVisible) [self hideSpeechBubble];
}
// 更新要点放进 accessoryView 而不是 informativeText：后者是一整段纯文本，列表项折行后
// 第二行会顶到「•」下面，几条长说明挤成一坨。这里用悬挂缩进让折行对齐到文字起点。
- (NSView *)updateHighlightsAccessoryView {
    if (self.pendingUpdateHighlights.count == 0) return nil;
    const CGFloat width = 300;
    NSFont *bodyFont = [NSFont systemFontOfSize:12];
    NSString *bullet = @"•\t";
    CGFloat indent = ceil([bullet sizeWithAttributes:@{NSFontAttributeName: bodyFont}].width) + 4;
    NSMutableParagraphStyle *itemStyle = [NSMutableParagraphStyle new];
    itemStyle.tabStops = @[[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft
        location:indent options:@{}]];
    itemStyle.headIndent = indent;
    itemStyle.paragraphSpacing = 5;
    itemStyle.lineSpacing = 1;
    NSMutableParagraphStyle *headerStyle = [NSMutableParagraphStyle new];
    headerStyle.paragraphSpacing = 6;

    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:L(@"What's New\n")
        attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],
                     NSForegroundColorAttributeName: NSColor.labelColor,
                     NSParagraphStyleAttributeName: headerStyle}];
    NSDictionary *itemAttributes = @{NSFontAttributeName: bodyFont,
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
        NSParagraphStyleAttributeName: itemStyle};
    [self.pendingUpdateHighlights enumerateObjectsUsingBlock:^(NSString *item, NSUInteger index, BOOL *stop) {
        NSString *line = [NSString stringWithFormat:@"%@%@%@", bullet, item,
            index + 1 < self.pendingUpdateHighlights.count || self.pendingUpdateHighlightsTruncated
                ? @"\n" : @""];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:line
            attributes:itemAttributes]];
    }];
    if (self.pendingUpdateHighlightsTruncated) {
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:L(@"More changes in the full GitHub release notes")
            attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11],
                         NSForegroundColorAttributeName: NSColor.tertiaryLabelColor,
                         NSParagraphStyleAttributeName: itemStyle}]];
    }
    NSTextField *label = [NSTextField wrappingLabelWithString:@""];
    label.attributedStringValue = text;
    label.preferredMaxLayoutWidth = width;
    NSSize size = [label.cell cellSizeForBounds:NSMakeRect(0, 0, width, CGFLOAT_MAX)];
    label.frame = NSMakeRect(0, 0, width, ceil(size.height));
    return label;
}
- (void)showUpdateDialog {
    NSString *version = self.pendingUpdateVersion;
    if (version.length == 0 || self.updating) return;
    if (self.updateBubbleVisible) [self hideSpeechBubble];
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:L(@"CC Pets %@ Is Available"), version];
    alert.informativeText = [NSString stringWithFormat:L(@"You have %@"), @CC_PETS_VERSION];
    alert.accessoryView = [self updateHighlightsAccessoryView];
    [alert addButtonWithTitle:L(@"Update Now")];
    [alert addButtonWithTitle:L(@"Later")];
    if (self.pendingUpdateHighlights.count > 0) [alert addButtonWithTitle:L(@"Release Notes")];
    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        [self startUpdateToVersion:version];
        return;
    }
    if (response == NSAlertThirdButtonReturn) {
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:[NSString stringWithFormat:
            @"https://github.com/%@/releases/tag/v%@", CCPetsRepositorySlug, version]]];
    }
    // 用户没选立即更新，本次运行不再主动冒气泡；角标和菜单入口照旧在。
    self.updateReminderSnoozed = YES;
    self.updateBubbleDeferred = NO;
}
// 顶层「更新到 x.y.z…」：版本已知，直接打开更新弹窗，不再联网查一遍。
- (void)showPendingUpdate:(id)sender {
    [self showUpdateDialog];
}
// 正在下载安装时，「帮助 ▸ 检查更新…」置灰，免得用户以为点了没反应。
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem.action == @selector(checkForUpdates:)) return !self.updating;
    return YES;
}
// 角标箭头与气泡文字同一套规则：清透玻璃上白色加投影，经典磨砂上深色。
- (void)applyUpdateBadgeStyle {
    if (!self.updateBadgeGlass) return;
    BOOL liquid = self.updateBadgeGlass.usesLiquidGlass;
    self.updateBadgeArrow.contentTintColor = liquid ? [NSColor colorWithWhite:1 alpha:0.97]
        : [NSColor colorWithWhite:0.12 alpha:0.96];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.45];
    shadow.shadowBlurRadius = 2;
    shadow.shadowOffset = NSMakeSize(0, -0.5);
    self.updateBadgeArrow.shadow = liquid ? shadow : nil;
}
// 更新提示：不受碎碎念开关、冷却和每小时预算限制。宠物头上始终只挂一个泡：
// agent 在忙就先记下来，等它闲下来（considerIdleSpeech 每 3 秒一跳）再冒；
// 状态卡只是在待命时，临时把它收起让位，气泡消失后再放回来。
- (void)showUpdateBubble {
    if (self.pendingUpdateVersion.length == 0 || self.updating || self.updateReminderSnoozed) {
        self.updateBubbleDeferred = NO;
        return;
    }
    if ([self agentBusyForSpeech]) {
        self.updateBubbleDeferred = YES;
        return;
    }
    self.updateBubbleDeferred = NO;
    [self showUpdateBubbleWithText:[NSString stringWithFormat:L(@"CC Pets v%@ is out! Click to update"),
        self.pendingUpdateVersion] dwell:UpdateBubbleDwell];
}
// 碎碎念时机里的更新提醒，几句轮换，免得每次都是同一句。
- (NSString *)updateReminderText {
    NSArray<NSString *> *lines = @[
        L(@"{version} is still waiting. Click me!"),
        L(@"{version} is out. See what's new!"),
        L(@"Upgrade to {version}? Click me"),
    ];
    return [lines[arc4random_uniform((uint32_t)lines.count)]
        stringByReplacingOccurrencesOfString:@"{version}" withString:self.pendingUpdateVersion];
}
- (void)showUpdateBubbleWithText:(NSString *)text dwell:(NSTimeInterval)dwell {
    if (self.statusPanel.isVisible) {
        [self.statusPanel orderOut:nil];
        self.updateBubbleSuppressedStatus = YES;
    }
    [self showSpeechBubbleWithText:text dwell:dwell];
    self.updateBubbleVisible = YES;
    self.speechPanel.ignoresMouseEvents = NO;
    self.speechClickButton.hidden = NO;
}
- (void)updateBubbleClicked:(id)sender {
    [self showUpdateDialog];
}
@end
