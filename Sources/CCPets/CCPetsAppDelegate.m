#import "CCPetsAppDelegate.h"
#import "CCPetsPaths.h"
#import "CCPetsVersion.h"
#import "CCPetsEvents.h"
#import "CCPetsQuotaHistory.h"
#import "CCPetsImageLoader.h"
#import "CCPetsPhrases.h"
#import "CCPetsPhrasesEditor.h"
#import "CCPetsUsage.h"
#import "CCPetsTerminalFocus.h"
#import "MenuToggleSwitch.h"
#import <UserNotifications/UserNotifications.h>
#import <signal.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <sys/sysctl.h>
#import <stdlib.h>

static const NSTimeInterval PendingApprovalTTL = 24 * 60 * 60;
static const NSUInteger PendingApprovalLimit = 100;
static const NSUInteger AgentSessionRecordLimit = 20;
static const NSUInteger AgentSessionMenuLimit = 8;
static const CGFloat PetApprovalBadgeSize = 17.0;
static const unsigned long long UpdateLogSizeLimit = 1024 * 1024;
static NSString *const PetInteractionPhrasesV1MigratedKey =
    @"CCPetsInteractionPhrasesV1Migrated";

@interface CCPetsStatusClickButton : NSButton
@end

@implementation CCPetsStatusClickButton
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}
@end

// 待审批角标。等审批的会话按定义是停住不动的，它的时间戳只会越来越旧——状态卡
// 正文永远显示最新事件，会话列表又按时间倒序，两边都会把最该处理的那条推到看
// 不见的地方。角标把这个数字单独拎出来常驻。
@interface CCPetsApprovalBadgeView : NSView
@property(nonatomic) NSUInteger count;
@end

@implementation CCPetsApprovalBadgeView
- (void)setCount:(NSUInteger)count {
    if (_count == count) return;
    _count = count;
    self.hidden = count == 0;
    self.needsDisplay = YES;
}
// 角标压在圆形状态图标的右上角，但不能把那颗按钮的点击吃掉。
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (void)drawRect:(NSRect)dirtyRect {
    if (self.count == 0) return;
    // 描边是给玻璃卡片准备的：审批色和卡片背景都偏亮，没有这圈白边角标会糊在一起。
    NSRect circle = NSInsetRect(self.bounds, 1.0, 1.0);
    NSBezierPath *fill = [NSBezierPath bezierPathWithOvalInRect:circle];
    [[NSColor colorWithRed:0.86 green:0.24 blue:0.24 alpha:1] setFill];
    [fill fill];
    fill.lineWidth = 1.5;
    [[NSColor colorWithWhite:1 alpha:0.92] setStroke];
    [fill stroke];
    BOOL overflow = self.count > 9;
    NSString *text = overflow ? @"9+" : @(self.count).stringValue;
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:overflow ? 8.5 : 10
            weight:NSFontWeightBold],
        NSForegroundColorAttributeName: NSColor.whiteColor
    };
    NSSize size = [text sizeWithAttributes:attributes];
    [text drawAtPoint:NSMakePoint(NSMidX(self.bounds) - size.width / 2.0,
        NSMidY(self.bounds) - size.height / 2.0) withAttributes:attributes];
}
@end

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

// 碎碎念的话痨程度。四道闸（每小时预算 / 两句间隔 / 静默门槛 / 出话概率）本来是
// 四个互相牵制的常数，单独调任何一个都不会真的变频繁——比如把冷却调到 0，
// 每小时 4 句的预算照样卡死。所以对用户只暴露一个档位，四个值一起走。
//
// normal 档就是改造前的原值，默认不变。
typedef struct {
    NSInteger hourlyBudget;
    NSTimeInterval cooldown;
    NSTimeInterval quietSeconds;    // 距上一次 agent 事件多久才算"没人打扰"
    uint32_t idleChancePercent;     // 每次判定（≤30 秒一次）的出话概率
} PetSpeechRate;

static const PetSpeechRate PetSpeechRateLow    = {2,  480.0, 300.0, 15};
static const PetSpeechRate PetSpeechRateNormal = {4,  240.0, 180.0, 25};
static const PetSpeechRate PetSpeechRateHigh   = {8,  120.0,  90.0, 45};
static const PetSpeechRate PetSpeechRateChatty = {20,  45.0,  45.0, 70};

// 档位写进 defaults 的值。字符串而不是整数：以后加档、调顺序都不会让老配置错位。
NSString *const PetSpeechFrequencyKey = @"CCPetsSpeechFrequency";
static NSString *const PetSpeechFrequencyLow = @"low";
static NSString *const PetSpeechFrequencyNormal = @"normal";
static NSString *const PetSpeechFrequencyHigh = @"high";
static NSString *const PetSpeechFrequencyChatty = @"chatty";

@implementation AppDelegate
- (NSString *)applicationSupportDirectory {
    return ApplicationSupportDirectory();
}
- (void)showUpdateAlertWithTitle:(NSString *)title message:(NSString *)message {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = message;
    [alert addButtonWithTitle:@"好"];
    [alert runModal];
}
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
        [self showUpdateAlertWithTitle:@"无法自动更新"
            message:@"没有找到安装 CC Pets 时使用的 Node.js/npm。请先手动执行一次：\n\n"
                    "npm install -g cc-pets@latest --allow-scripts=cc-pets"];
        return;
    }

    NSString *supportDirectory = [self applicationSupportDirectory];
    NSError *directoryError = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:supportDirectory
        withIntermediateDirectories:YES attributes:nil error:&directoryError];
    if (directoryError) {
        [self showUpdateAlertWithTitle:@"无法自动更新" message:directoryError.localizedDescription];
        return;
    }
    NSString *logPath = [supportDirectory stringByAppendingPathComponent:@"update.log"];
    [NSData.data writeToFile:logPath options:NSDataWritingAtomic error:nil];
    chmod(logPath.fileSystemRepresentation, S_IRUSR | S_IWUSR);
    NSFileHandle *logHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!logHandle) {
        [self showUpdateAlertWithTitle:@"无法自动更新" message:@"无法创建更新日志。"];
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
                if ([strongSelf restartAfterUpdateToVersion:version configuration:configuration]) return;
                [strongSelf showUpdateAlertWithTitle:@"更新完成"
                    message:@"CC Pets 已更新，但没有找到可自动启动的新版应用，请手动重新启动一次。"];
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
            [NSApp activateIgnoringOtherApps:YES];
            NSAlert *alert = [NSAlert new];
            alert.messageText = @"更新失败";
            alert.informativeText = [NSString stringWithFormat:
                @"旧版本仍可继续使用。错误详情已写入：\n%@", logPath];
            [alert addButtonWithTitle:@"打开日志"];
            [alert addButtonWithTitle:@"关闭"];
            if ([alert runModal] == NSAlertFirstButtonReturn) {
                [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:logPath]];
            }
        });
    };
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        self.updating = NO;
        self.updateTask = nil;
        [logHandle closeFile];
        [self showUpdateAlertWithTitle:@"无法启动更新" message:launchError.localizedDescription];
        return;
    }
    // 重试是静默的：第一次已经弹过"正在更新"，再弹一次只会让人以为出了两回事。
    if (attempt == 0) {
        [self showUpdateAlertWithTitle:@"正在更新"
            message:[NSString stringWithFormat:@"正在下载并安装 CC Pets %@。完成后桌宠会自动重启。", version]];
    }
}
- (void)checkForUpdates:(id)sender {
    if (self.checkingForUpdate || self.updating) return;
    self.checkingForUpdate = YES;
    NSURL *url = [NSURL URLWithString:@"https://registry.npmjs.org/cc-pets/latest"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.checkingForUpdate = NO;
            NSHTTPURLResponse *httpResponse = [response isKindOfClass:NSHTTPURLResponse.class]
                ? (NSHTTPURLResponse *)response : nil;
            NSDictionary *metadata = data
                ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSString *latestVersion = [metadata[@"version"] isKindOfClass:NSString.class]
                ? metadata[@"version"] : nil;
            BOOL valid = NO;
            NSComparisonResult comparison = CompareStableVersions(@CC_PETS_VERSION, latestVersion, &valid);
            if (error || httpResponse.statusCode != 200 || !valid) {
                NSString *message = error.localizedDescription ?: @"npm Registry 返回了无效的版本信息，请稍后重试。";
                [strongSelf showUpdateAlertWithTitle:@"检查更新失败" message:message];
                return;
            }
            if (comparison != NSOrderedAscending) {
                [strongSelf showUpdateAlertWithTitle:@"已是最新版本"
                    message:[NSString stringWithFormat:@"当前版本：%@", @CC_PETS_VERSION]];
                return;
            }
            [NSApp activateIgnoringOtherApps:YES];
            NSAlert *alert = [NSAlert new];
            alert.messageText = @"发现新版本";
            alert.informativeText = [NSString stringWithFormat:
                @"当前版本：%@\n最新版本：%@\n\n是否立即更新？", @CC_PETS_VERSION, latestVersion];
            [alert addButtonWithTitle:@"立即更新"];
            [alert addButtonWithTitle:@"稍后"];
            if ([alert runModal] == NSAlertFirstButtonReturn) {
                [strongSelf startUpdateToVersion:latestVersion];
            }
        });
    }];
    [task resume];
}
- (NSString *)systemMetricKeyForTag:(NSInteger)tag {
    if (tag == 1) return SystemCPUEnabledKey;
    if (tag == 2) return SystemTemperatureEnabledKey;
    if (tag == 3) return SystemMemoryEnabledKey;
    return nil;
}
- (void)applySystemMetricPreferences {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.quotaView.systemCPUEnabled = [defaults boolForKey:SystemCPUEnabledKey];
    self.quotaView.systemTemperatureEnabled =
        [defaults boolForKey:SystemTemperatureEnabledKey];
    self.quotaView.systemMemoryEnabled = [defaults boolForKey:SystemMemoryEnabledKey];
    self.quotaView.needsDisplay = YES;
}
- (void)applyUsageDisplayModePreferences {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.quotaView.codexShowsAPIUsage =
        [[defaults stringForKey:CodexUsageDisplayModeKey] isEqualToString:@"api"];
    self.quotaView.claudeShowsAPIUsage =
        [[defaults stringForKey:ClaudeUsageDisplayModeKey] isEqualToString:@"api"];
    self.quotaView.needsDisplay = YES;
}
- (void)setUsageDisplayModeFromControl:(NSButton *)sender {
    NSString *key = sender.tag == 1 ? CodexUsageDisplayModeKey
        : (sender.tag == 2 ? ClaudeUsageDisplayModeKey : nil);
    NSString *mode = sender.state == NSControlStateValueOn ? @"api" : @"subscription";
    if (!key) return;
    [NSUserDefaults.standardUserDefaults setObject:mode forKey:key];
    [self applyUsageDisplayModePreferences];
    // 展示模式决定了会话要回溯多远（订阅 8 天 / API 到上月月初），切换之后必须重新聚合，
    // 否则刚打开 API 视图时手里只有一段按 8 天窗口扫出来的数据。
    [self refreshUsage:nil];
}
- (void)toggleSystemMetric:(NSButton *)sender {
    NSString *key = [self systemMetricKeyForTag:sender.tag];
    if (!key) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL enabled = ![defaults boolForKey:key];
    [defaults setBool:enabled forKey:key];
    sender.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self applySystemMetricPreferences];
    [self updateSystemMetricsTimer];
}
// 开关打开时立刻导入一次，不用等下次启动——用户点开关就是想现在看到那些素材。
- (void)toggleImportCodexPets:(NSButton *)sender {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL enabled = ![defaults boolForKey:ImportCodexPetsKey];
    [defaults setBool:enabled forKey:ImportCodexPetsKey];
    sender.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    if (!enabled) return;
    NSUInteger imported = ImportCodexPets();
    if (imported == 0) return;
    [self invalidatePetOptionsCache];
    [self showImportedCodexPetsAlert:imported];
}
- (void)showImportedCodexPetsAlert:(NSUInteger)imported {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"已导入 Codex 素材";
    [alert addButtonWithTitle:@"好"];
    [alert runModal];
}
- (NSString *)notificationKeyForTag:(NSInteger)tag {
    if (tag == 1) return NotificationCompletionKey;
    if (tag == 2) return NotificationFailureKey;
    if (tag == 3) return NotificationApprovalKey;
    if (tag == 4) return NotificationStallKey;
    return nil;
}
- (void)toggleSpeech:(NSButton *)sender {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id current = [defaults objectForKey:@"CCPetsSpeechEnabled"];
    BOOL enabled = current == nil ? YES : [current boolValue];
    [defaults setBool:!enabled forKey:@"CCPetsSpeechEnabled"];
    sender.state = !enabled ? NSControlStateValueOn : NSControlStateValueOff;
    if (enabled) [self hideSpeechBubble];
}
- (void)togglePetInteraction:(NSButton *)sender {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL enabled = ![defaults boolForKey:PetInteractionEnabledKey];
    [defaults setBool:enabled forKey:PetInteractionEnabledKey];
    sender.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
}
- (void)setPetInteractionHeartThreshold:(NSMenuItem *)sender {
    NSNumber *value = [sender.representedObject isKindOfClass:NSNumber.class] ?
        sender.representedObject : @3;
    [NSUserDefaults.standardUserDefaults setInteger:MAX((NSInteger)2, value.integerValue)
        forKey:PetInteractionHeartThresholdKey];
}
- (void)setPetInteractionAnnoyedThreshold:(NSMenuItem *)sender {
    NSNumber *value = [sender.representedObject isKindOfClass:NSNumber.class] ?
        sender.representedObject : @10;
    NSInteger heart = MAX((NSInteger)2, [NSUserDefaults.standardUserDefaults
        integerForKey:PetInteractionHeartThresholdKey]);
    [NSUserDefaults.standardUserDefaults setInteger:MAX(heart + 1, value.integerValue)
        forKey:PetInteractionAnnoyedThresholdKey];
}
- (void)setPetInteractionInterval:(NSMenuItem *)sender {
    NSNumber *value = [sender.representedObject isKindOfClass:NSNumber.class] ?
        sender.representedObject : @1.2;
    [NSUserDefaults.standardUserDefaults setDouble:MAX(0.4, MIN(3.0, value.doubleValue))
        forKey:PetInteractionIntervalKey];
}
// 频率档位。改完立刻生效——四道闸都是现读的，不缓存。
// 顺手把冷却清掉，否则刚调高档位还要等完上一档的冷却才见效，会让人以为没生效。
- (void)setSpeechFrequency:(NSMenuItem *)sender {
    NSString *value = [sender.representedObject isKindOfClass:NSString.class] ?
        sender.representedObject : PetSpeechFrequencyNormal;
    [NSUserDefaults.standardUserDefaults setObject:value forKey:PetSpeechFrequencyKey];
    self.speechCooldownUntil = 0;
    self.lastIdleSpeechCheck = 0;
}
// 台词交给内置编辑器，不再 openURL: 丢给"文本编辑"。
//
// 换掉的理由是反馈：系统编辑器保存完什么都不会说，小节名拼错、句子超 30 字、槽位
// 写错名字全是静默失效，用户只知道"改了没用"。内置编辑器保存时校验并当场报出来，
// 还能"试说一句"直接听效果。
- (void)editPhrasesFile:(id)sender {
    // 编辑器只管文本，不认识气泡；把"说出来"这一步作为回调注入。
    __weak typeof(self) weakSelf = self;
    [PetPhrasesEditorController setSpeakHandler:^(NSString *text) {
        [weakSelf presentSpeechText:text];
    }];
    [PetPhrasesEditorController present];
}

- (void)toggleNotification:(NSButton *)sender {
    NSString *key = [self notificationKeyForTag:sender.tag];
    if (!key) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:key]) {
        [defaults setBool:NO forKey:key];
        sender.state = NSControlStateValueOff;
        return;
    }
    [UNUserNotificationCenter.currentNotificationCenter
        requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
        completionHandler:^(BOOL granted, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (granted) {
                [defaults setBool:YES forKey:key];
                sender.state = NSControlStateValueOn;
            } else {
                sender.state = NSControlStateValueOff;
                NSString *message = error.localizedDescription ?:
                    @"请在“系统设置 → 通知 → CC Pets”中允许通知后重试。";
                [self showUpdateAlertWithTitle:@"无法启用系统通知" message:message];
            }
        });
    }];
}
- (void)sendNotificationWithTitle:(NSString *)title body:(NSString *)body {
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = title;
    content.body = body;
    content.sound = UNNotificationSound.defaultSound;
    NSString *identifier = [@"cc-pets-" stringByAppendingString:NSUUID.UUID.UUIDString];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier
        content:content trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request
        withCompletionHandler:nil];
}
- (void)notifyForRecord:(NSDictionary *)record {
    NSString *event = record[@"event"];
    NSString *state = [record[@"state"] isKindOfClass:NSString.class] ? record[@"state"] : @"";
    NSString *provider = SanitizedShortString(record[@"provider"], 32);
    if (provider.length == 0) provider = @"Agent";
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([event isEqualToString:@"PermissionRequest"] &&
        ![state isEqualToString:@"auto_review"] &&
        [defaults boolForKey:NotificationApprovalKey]) {
        [self sendNotificationWithTitle:@"等待审批"
            body:[NSString stringWithFormat:@"%@ 正在等待操作。", provider]];
    } else if ([event isEqualToString:@"StopFailure"] &&
               [defaults boolForKey:NotificationFailureKey]) {
        [self sendNotificationWithTitle:@"任务失败"
            body:[NSString stringWithFormat:@"%@ 的任务执行失败。", provider]];
    } else if (([event isEqualToString:@"Stop"] || [event isEqualToString:@"SessionEnd"]) &&
               [defaults boolForKey:NotificationCompletionKey]) {
        [self sendNotificationWithTitle:@"任务完成"
            body:[NSString stringWithFormat:@"%@ 已完成当前任务。", provider]];
    }
}
- (NSString *)statusTextForState:(NSString *)state tool:(NSString *)tool {
    if ([state isEqualToString:@"starting"]) return @"正在启动";
    if ([state isEqualToString:@"idle"]) return @"待机中";
    if ([state isEqualToString:@"thinking"]) return @"正在思考";
    if ([state isEqualToString:@"auto_review"]) return @"自动审批中";
    if ([state isEqualToString:@"approval"]) return @"等待审批";
    if ([state isEqualToString:@"subagent"]) return @"子 Agent 工作中";
    if ([state isEqualToString:@"tool_completed"]) return @"操作已完成";
    if ([state isEqualToString:@"tool_failed"]) return @"工具执行失败";
    if ([state isEqualToString:@"completed"]) return @"任务已完成";
    if ([state isEqualToString:@"failed"]) return @"任务失败";
    if ([state isEqualToString:@"notification"]) return @"需要关注";
    if ([state isEqualToString:@"tool"]) {
        NSString *lower = tool.lowercaseString;
        if ([lower containsString:@"bash"] || [lower containsString:@"exec"] ||
            [lower containsString:@"shell"] || [lower containsString:@"terminal"]) return @"正在执行命令";
        if ([lower containsString:@"patch"] || [lower containsString:@"edit"] ||
            [lower containsString:@"write"]) return @"正在编辑文件";
        if ([lower containsString:@"read"] || [lower containsString:@"search"] ||
            [lower containsString:@"find"] || [lower containsString:@"grep"] ||
            [lower containsString:@"glob"] || [lower containsString:@"web"] ||
            [lower hasPrefix:@"mcp__"]) return @"正在查找资料";
        if ([lower containsString:@"task"] || [lower containsString:@"agent"]) return @"子 Agent 工作中";
        return @"正在使用工具";
    }
    return @"正在工作";
}
// 状态卡副行的正文。每个 hook 状态都由宠物来讲，标题仍然给事实。
//
// 这不是"额外说话"，是把原来的样板文案整体换成宠物口吻，所以不受说话预算限制——
// 状态本来就在变，每次变化说一句是应该的。预算只管情绪句那一层。
- (NSString *)petVoiceTagForState:(NSString *)state tool:(NSString *)tool {
    if ([state isEqualToString:@"starting"]) return PetPhraseTagStateStarting;
    if ([state isEqualToString:@"idle"]) return PetPhraseTagStateIdle;
    if ([state isEqualToString:@"thinking"]) return PetPhraseTagStateThinking;
    if ([state isEqualToString:@"auto_review"]) return PetPhraseTagStateAutoReview;
    if ([state isEqualToString:@"approval"]) return PetPhraseTagStateApproval;
    if ([state isEqualToString:@"subagent"]) return PetPhraseTagStateSubagent;
    if ([state isEqualToString:@"tool_completed"]) return PetPhraseTagStateToolDone;
    if ([state isEqualToString:@"tool_failed"]) return PetPhraseTagStateToolFailed;
    if ([state isEqualToString:@"completed"]) return PetPhraseTagStateCompleted;
    if ([state isEqualToString:@"failed"]) return PetPhraseTagStateFailed;
    if ([state isEqualToString:@"notification"]) return PetPhraseTagStateNotification;
    if ([state isEqualToString:@"tool"]) {
        // 工具四分类和标题那边同源。原来副行只有一句"正在调用工具…"覆盖全部四类，
        // 分开之后副行的信息量反而比改造前更大。
        NSString *lower = tool.lowercaseString;
        if ([lower containsString:@"bash"] || [lower containsString:@"exec"] ||
            [lower containsString:@"shell"] || [lower containsString:@"terminal"]) {
            return PetPhraseTagStateToolBash;
        }
        if ([lower containsString:@"patch"] || [lower containsString:@"edit"] ||
            [lower containsString:@"write"]) return PetPhraseTagStateToolEdit;
        if ([lower containsString:@"read"] || [lower containsString:@"search"] ||
            [lower containsString:@"find"] || [lower containsString:@"grep"] ||
            [lower containsString:@"glob"] || [lower containsString:@"web"] ||
            [lower hasPrefix:@"mcp__"]) return PetPhraseTagStateToolRead;
        if ([lower containsString:@"task"] || [lower containsString:@"agent"]) {
            return PetPhraseTagStateSubagent;
        }
        return PetPhraseTagStateTool;
    }
    return PetPhraseTagStateTool;
}
- (NSString *)statusDetailForState:(NSString *)state tool:(NSString *)tool {
    NSString *tag = [self petVoiceTagForState:state tool:tool];
    // 同一个状态连着来一串事件时不重摇，否则副行会不停闪。一次状态转换说一句就够。
    if ([tag isEqualToString:self.lastPetVoiceTag] && self.lastPetVoiceText.length > 0) {
        return self.lastPetVoiceText;
    }
    NSString *text = PetPhraseForTag(tag, [self speechSlots]);
    self.lastPetVoiceTag = tag;
    self.lastPetVoiceText = text;
    return text;
}
- (NSColor *)statusColorForState:(NSString *)state {
    if ([state isEqualToString:@"completed"] || [state isEqualToString:@"tool_completed"]) {
        return [NSColor colorWithRed:0.18 green:0.68 blue:0.35 alpha:1];
    }
    if ([state isEqualToString:@"failed"] || [state isEqualToString:@"tool_failed"]) {
        return [NSColor colorWithRed:0.86 green:0.28 blue:0.28 alpha:1];
    }
    if ([state isEqualToString:@"approval"] || [state isEqualToString:@"notification"]) {
        return [NSColor colorWithRed:0.92 green:0.58 blue:0.12 alpha:1];
    }
    // 待机是"没在干活"，用中性灰和工作中的蓝拉开距离。
    if ([state isEqualToString:@"idle"]) return [NSColor colorWithWhite:0.55 alpha:1];
    return [NSColor colorWithRed:0.33 green:0.53 blue:0.78 alpha:1];
}
- (NSString *)statusSymbolForState:(NSString *)state {
    if ([state isEqualToString:@"completed"] || [state isEqualToString:@"tool_completed"]) return @"checkmark";
    if ([state isEqualToString:@"failed"] || [state isEqualToString:@"tool_failed"]) return @"xmark";
    if ([state isEqualToString:@"approval"] || [state isEqualToString:@"notification"]) return @"exclamationmark";
    if ([state isEqualToString:@"idle"]) return @"zzz";
    return @"ellipsis";
}
// Codex / Claude 退出时不会补发结束事件：包装脚本最后一行是 exec，自身已经被
// 替换掉，装不上 EXIT trap。唯一可靠的退出信号是客户端 pid 文件被回收。
// 没有这一步的话，“正在启动”只能等 60 秒无活动才消失，而另一个 provider 的事件
// 会不断把这 60 秒重置掉——用户关掉所有 Codex 窗口后仍然看到“Codex 正在启动”。
- (void)hideAgentStatusIfClientGone {
    if (!self.hasAgentStatus || self.hasUnlabeledClient) return;
    NSString *provider = self.lastStatusProvider;
    if (provider.length == 0 || [self.liveClientProviders containsObject:provider]) return;
    // 不经包装脚本启动的客户端（直接跑 claude / codex）没有 pid 文件，只能靠
    // “最近还在发事件”证明自己活着，所以这里必须留一段静默宽限再清。
    if ([NSDate.date timeIntervalSince1970] - self.lastStatusTimestamp < AgentStatusOrphanInterval) return;
    [self hideAgentStatus];
}
- (void)hideAgentStatus {
    // 卡在审批的会话不该跟着沉默一起消失。60 秒没有新事件时，气泡不清场，而是回落
    // 到最近那条审批：这样"有人在等你确认"始终有个落点，点卡片就能跳回那个终端，
    // 角标也不会随面板一起被收走。
    //
    // 这不是把旧的"审批全局优先"逻辑搬回来——那一版在事件流里拦截，一个未处理的
    // 审批会把其他 Agent 的所有 Hook 全挡住。这里只在完全没有新事件时才接管，任何
    // 一条新事件都照常刷新正文。
    NSArray<NSDictionary *> *pending = [self pendingApprovalSessionRecords];
    if (self.hasAgentStatus && pending.count > 0) {
        [self performSelector:@selector(hideAgentStatus) withObject:nil
            afterDelay:AgentStatusInactivityInterval];
        [self presentPendingApprovalRecord:pending.firstObject];
        return;
    }
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(enterIdleStatus) object:nil];
    [self.statusPanel orderOut:nil];
    self.hasAgentStatus = NO;
    [self refreshApprovalBadge];
}
// 只改卡片内容和回跳目标，不走 displayAgentRecord：那条路会连带播动画、说一句话、
// 发一次通知，而这里是"气泡闲下来后回落"，重复表演反而吵。
- (void)presentPendingApprovalRecord:(NSDictionary *)record {
    if (record.count == 0) return;
    NSDictionary *terminal = [record[@"terminal"] isKindOfClass:NSDictionary.class]
        ? record[@"terminal"] : nil;
    if (terminal.count > 0) self.lastTerminalFocusTarget = terminal;
    NSString *provider = SanitizedShortString(record[@"provider"], 32);
    NSString *tool = [record[@"tool"] isKindOfClass:NSString.class] ? record[@"tool"] : @"";
    if ([self.lastStatusState isEqualToString:@"approval"] &&
        [self.lastStatusProvider isEqualToString:provider]) return;
    [self applyStatusPresentationForState:@"approval"
        provider:provider.length > 0 ? provider : @"Agent" tool:tool];
}
// 勾选 = 显示气泡。没有 agent 状态时也允许改，这样用户可以提前设好偏好，
// 而不必等下一次会话开始。
- (void)toggleStatusBubbleFromMenu:(NSButton *)sender {
    self.statusBubbleExpanded = !self.statusBubbleExpanded;
    [NSUserDefaults.standardUserDefaults setBool:self.statusBubbleExpanded
        forKey:StatusBubbleExpandedKey];
    sender.state = self.statusBubbleExpanded ? NSControlStateValueOn : NSControlStateValueOff;
    if (self.statusBubbleExpanded && self.hasAgentStatus) {
        [self positionAgentStatus];
        [self.statusPanel orderFrontRegardless];
    } else {
        [self.statusPanel orderOut:nil];
    }
}
// Stop 之后还会飘来 SubagentStop / PostToolUse / TaskCompleted 这类"仍在工作"的尾巴事件
// （实测 Stop 后 4 秒），它们和 UserPromptSubmit 一样都归一成 thinking，只看 state 分不出来，
// 所以必须按事件名判断。终态只能被新一轮真实动作解除（用户提问、工具调用、需要关注），
// 否则"任务已完成"会被打回"正在思考"，看起来像任务又活了。
- (BOOL)isTrailingRecord:(NSDictionary *)record afterState:(NSString *)state {
    if (![state isEqualToString:@"completed"] && ![state isEqualToString:@"failed"]) return NO;
    NSString *event = [record[@"event"] isKindOfClass:NSString.class] ? record[@"event"] : @"";
    return [event isEqualToString:@"SubagentStop"] || [event isEqualToString:@"PostToolUse"] ||
        [event isEqualToString:@"TaskCompleted"];
}
- (void)applyStatusPresentationForState:(NSString *)state provider:(NSString *)provider
    tool:(NSString *)tool {
    self.lastStatusState = state;
    self.lastStatusProvider = provider;
    self.statusTitleLabel.stringValue = [NSString stringWithFormat:@"%@ · %@",
        provider, [self statusTextForState:state tool:tool]];
    self.statusDetailLabel.stringValue = [self statusDetailForState:state tool:tool];
    // 上一句碎碎念借走的副行已经被新状态覆盖，取消那次归还，否则它会把旧文案写回来。
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(restoreStatusDetail) object:nil];
    NSColor *stateColor = [self statusColorForState:state];
    self.statusIconButton.layer.backgroundColor = [stateColor colorWithAlphaComponent:0.28].CGColor;
    NSImage *icon = [NSImage imageWithSystemSymbolName:[self statusSymbolForState:state]
        accessibilityDescription:[self statusTextForState:state tool:tool]];
    self.statusIconButton.image = [icon imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightBold]];
    self.statusIconButton.contentTintColor = [stateColor blendedColorWithFraction:0.18
        ofColor:NSColor.blackColor] ?: stateColor;
    [self resizeStatusCardToFitText];
    [self layoutApprovalBadge];
    [self positionAgentStatus];
    if (self.statusBubbleExpanded) {
        [self.statusPanel orderFrontRegardless];
        // 卡片一出现就收掉独立气泡：两者都是宠物在说话，同时挂着就是重影。
        if (self.speechPanel.isVisible) [self hideSpeechBubble];
    } else {
        [self.statusPanel orderOut:nil];
    }
}
// "正在启动"只在会话拉起的一瞬间成立。之后如果没有任何后续事件，真实情况是会话已就绪、
// 正在等用户输入——继续显示"正在准备当前会话…"会让启动和待机看起来一模一样。
- (void)enterIdleStatus {
    if (!self.hasAgentStatus) return;
    [self applyStatusPresentationForState:@"idle"
        provider:self.lastStatusProvider ?: @"Agent" tool:@""];
}
- (void)showAgentStatusForRecord:(NSDictionary *)record notify:(BOOL)shouldNotify {
    NSString *provider = SanitizedShortString(record[@"provider"], 32);
    if (provider.length == 0) provider = @"Agent";
    NSString *state = [record[@"state"] isKindOfClass:NSString.class]
        ? record[@"state"] : NormalizedStateForEvent(record[@"event"], [record[@"failed"] boolValue]);
    NSString *tool = [record[@"tool"] isKindOfClass:NSString.class] ? record[@"tool"] : @"";
    // 尾巴事件仍然算"客户端还活着"，只是不该改写气泡上的终态。
    self.lastStatusTimestamp = [NSDate.date timeIntervalSince1970];
    if (!self.providerActivityAt) self.providerActivityAt = [NSMutableDictionary dictionary];
    self.providerActivityAt[provider] = @(self.lastStatusTimestamp);
    [self updateQuotaLiveState];
    if (self.hasAgentStatus && [provider isEqualToString:self.lastStatusProvider] &&
        [self isTrailingRecord:record afterState:self.lastStatusState]) return;

    NSDictionary *terminal = [record[@"terminal"] isKindOfClass:NSDictionary.class]
        ? record[@"terminal"] : nil;
    self.lastTerminalFocusTarget = terminal.count > 0 ? terminal : nil;

    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(hideAgentStatus) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(enterIdleStatus) object:nil];
    self.hasAgentStatus = YES;
    [self applyStatusPresentationForState:state provider:provider tool:tool];
    [self.panel orderFrontRegardless];
    [self performSelector:@selector(hideAgentStatus)
        withObject:nil afterDelay:AgentStatusInactivityInterval];
    if ([state isEqualToString:@"starting"]) {
        [self performSelector:@selector(enterIdleStatus) withObject:nil
            afterDelay:AgentStartingGraceInterval];
    }
    if (shouldNotify) [self notifyForRecord:record];
}
- (void)showAgentStatusForRecord:(NSDictionary *)record {
    [self showAgentStatusForRecord:record notify:YES];
}
- (NSString *)approvalKeyForRecord:(NSDictionary *)record {
    NSString *provider = SanitizedShortString(record[@"provider"], 32);
    if (provider.length == 0) provider = @"Agent";
    NSString *session = SanitizedShortString(record[@"session"], 128);
    return session.length > 0
        ? [NSString stringWithFormat:@"%@:%@", provider, session]
        : provider;
}
- (void)prunePendingApprovalRecords {
    NSTimeInterval cutoff = NSDate.date.timeIntervalSince1970 - PendingApprovalTTL;
    for (NSString *key in self.pendingApprovalRecords.allKeys) {
        NSDictionary *record = self.pendingApprovalRecords[key];
        if ([record[@"timestamp"] doubleValue] < cutoff) {
            [self.pendingApprovalRecords removeObjectForKey:key];
        }
    }
    if (self.pendingApprovalRecords.count <= PendingApprovalLimit) return;
    NSArray<NSDictionary *> *oldestFirst = [self.pendingApprovalRecords.allValues
        sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            NSTimeInterval leftTime = [left[@"timestamp"] doubleValue];
            NSTimeInterval rightTime = [right[@"timestamp"] doubleValue];
            if (leftTime < rightTime) return NSOrderedAscending;
            if (leftTime > rightTime) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    NSUInteger removeCount = oldestFirst.count - PendingApprovalLimit;
    for (NSUInteger index = 0; index < removeCount; index++) {
        NSString *key = [self approvalKeyForRecord:oldestFirst[index]];
        [self.pendingApprovalRecords removeObjectForKey:key];
    }
}
- (void)displayAgentRecord:(NSDictionary *)record notify:(BOOL)shouldNotify {
    NSString *event = [record[@"event"] isKindOfClass:NSString.class] ? record[@"event"] : @"";
    NSString *state = [record[@"state"] isKindOfClass:NSString.class] ? record[@"state"] : @"";
    NSString *tool = [record[@"tool"] isKindOfClass:NSString.class] ? record[@"tool"] : @"";
    NSString *animationEvent = [state isEqualToString:@"auto_review"]
        ? @"AutoReviewRequest" : event;
    [self.petView handleAgentEvent:animationEvent tool:tool
        failed:[record[@"failed"] boolValue]];
    [self showAgentStatusForRecord:record notify:shouldNotify];
    // 说话是事件流的新消费者，不改变事件生产。冷启动重放已被 processAgentEventData
    // 的 recentOnly + 5 秒 cutoff 挡住，再加上预算制和冷却，最坏也只多说一句。
    [self considerSpeechForRecord:record];
}
- (NSString *)agentSessionKeyForRecord:(NSDictionary *)record {
    NSString *provider = SanitizedShortString(record[@"provider"], 32);
    NSDictionary *terminal = [record[@"terminal"] isKindOfClass:NSDictionary.class]
        ? record[@"terminal"] : nil;
    NSString *tty = SanitizedShortString(terminal[@"tty"], 64);
    NSString *bundleID = SanitizedShortString(terminal[@"bundleID"], 128);
    if (tty.length > 0) {
        return [NSString stringWithFormat:@"%@|%@|%@", provider, bundleID, tty];
    }
    NSString *session = SanitizedShortString(record[@"session"], 128);
    if (session.length > 0) return [NSString stringWithFormat:@"%@|%@", provider, session];
    return terminal.count > 0 ? [NSString stringWithFormat:@"%@|%@", provider, bundleID] : nil;
}
- (NSString *)onlineAgentSessionKeyForProvider:(NSString *)provider tty:(NSString *)tty {
    provider = SanitizedShortString(provider, 32);
    tty = SanitizedShortString(tty.lastPathComponent, 64);
    if (provider.length == 0 || tty.length == 0) return nil;
    return [NSString stringWithFormat:@"%@|%@", provider, tty];
}
- (NSString *)onlineAgentSessionKeyForRecord:(NSDictionary *)record {
    NSDictionary *terminal = [record[@"terminal"] isKindOfClass:NSDictionary.class]
        ? record[@"terminal"] : nil;
    return [self onlineAgentSessionKeyForProvider:record[@"provider"] tty:terminal[@"tty"]];
}
- (void)pruneOfflineAgentSessionRecords {
    for (NSString *key in self.agentSessionRecords.allKeys) {
        NSString *onlineKey = [self onlineAgentSessionKeyForRecord:self.agentSessionRecords[key]];
        if (onlineKey.length == 0 || ![self.liveAgentSessionKeys containsObject:onlineKey]) {
            [self.agentSessionRecords removeObjectForKey:key];
        }
    }
}
- (void)trackAgentSessionRecord:(NSDictionary *)record {
    NSString *key = [self agentSessionKeyForRecord:record];
    if (key.length == 0) return;
    if (!self.agentSessionRecords) self.agentSessionRecords = [NSMutableDictionary dictionary];
    self.agentSessionRecords[key] = record;
    if (self.agentSessionRecords.count <= AgentSessionRecordLimit) return;
    NSArray<NSDictionary *> *oldestFirst = [self.agentSessionRecords.allValues
        sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            return [left[@"timestamp"] compare:right[@"timestamp"]];
        }];
    NSUInteger removeCount = oldestFirst.count - AgentSessionRecordLimit;
    for (NSUInteger index = 0; index < removeCount; index++) {
        NSString *oldKey = [self agentSessionKeyForRecord:oldestFirst[index]];
        if (oldKey) [self.agentSessionRecords removeObjectForKey:oldKey];
    }
}
- (BOOL)isApprovalSessionRecord:(NSDictionary *)record {
    NSString *state = [record[@"state"] isKindOfClass:NSString.class] ? record[@"state"] : @"";
    return [state isEqualToString:@"approval"];
}
// 卡在审批的在线会话，最近的排前面。角标计数和会话列表置顶共用这一份，两处数字
// 才不会打架。判据是"该会话的最后一条事件是审批"——审批一旦被处理，后续事件会
// 把这条记录顶掉，会话自然退出这个集合，不需要额外的解除信号。
- (NSArray<NSDictionary *> *)pendingApprovalSessionRecords {
    [self pruneOfflineAgentSessionRecords];
    NSMutableArray<NSDictionary *> *pending = [NSMutableArray array];
    for (NSDictionary *record in self.agentSessionRecords.allValues) {
        if ([self isApprovalSessionRecord:record]) [pending addObject:record];
    }
    [pending sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [right[@"timestamp"] compare:left[@"timestamp"]];
    }];
    return pending;
}
- (NSTimeInterval)stallIntervalForState:(NSString *)state {
    if ([state isEqualToString:@"approval"]) return AgentApprovalStallInterval;
    if ([state isEqualToString:@"thinking"]) return AgentThinkingStallInterval;
    return 0;
}
// 会话停在同一个状态太久就提醒一次。去重键带上该会话当时的时间戳：会话一有新
// 事件，时间戳变了，旧键自然失效，于是下一次卡住还会再提醒。每轮用当前有效键
// 求交集，退出的会话不会在集合里留垃圾。
- (void)checkStalledAgentSessions {
    if (self.agentSessionRecords.count == 0) {
        [self.stallNotifiedSessionKeys removeAllObjects];
        return;
    }
    [self pruneOfflineAgentSessionRecords];
    if (!self.stallNotifiedSessionKeys) self.stallNotifiedSessionKeys = [NSMutableSet set];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    BOOL shouldNotify = [NSUserDefaults.standardUserDefaults boolForKey:NotificationStallKey];
    NSMutableSet<NSString *> *valid = [NSMutableSet set];
    NSDictionary *stalled = nil;
    for (NSString *key in self.agentSessionRecords.allKeys) {
        NSDictionary *record = self.agentSessionRecords[key];
        NSTimeInterval timestamp = [record[@"timestamp"] doubleValue];
        NSString *stamp = [NSString stringWithFormat:@"%@|%.0f", key, timestamp];
        [valid addObject:stamp];
        NSString *state = [record[@"state"] isKindOfClass:NSString.class] ? record[@"state"] : @"";
        NSTimeInterval limit = [self stallIntervalForState:state];
        if (limit <= 0 || now - timestamp < limit) continue;
        if ([self.stallNotifiedSessionKeys containsObject:stamp]) continue;
        [self.stallNotifiedSessionKeys addObject:stamp];
        NSString *provider = SanitizedShortString(record[@"provider"], 32);
        if (provider.length == 0) provider = @"Agent";
        if (shouldNotify) {
            NSInteger minutes = (NSInteger)((now - timestamp) / 60.0);
            [self sendNotificationWithTitle:
                [state isEqualToString:@"approval"] ? @"审批仍在等待" : @"Agent 长时间无响应"
                body:[NSString stringWithFormat:@"%@ 已%@ %ld 分钟。",
                    provider, [self statusTextForState:state tool:record[@"tool"]], (long)minutes]];
        }
        // 多个会话同时卡住时只把最旧的那条顶到气泡上：它等得最久。
        if (!stalled || [record[@"timestamp"] doubleValue] < [stalled[@"timestamp"] doubleValue]) {
            stalled = record;
        }
    }
    [self.stallNotifiedSessionKeys intersectSet:valid];
    if (!stalled) return;
    NSString *event = [stalled[@"event"] isKindOfClass:NSString.class] ? stalled[@"event"] : @"";
    NSString *tool = [stalled[@"tool"] isKindOfClass:NSString.class] ? stalled[@"tool"] : @"";
    [self.petView handleAgentEvent:event tool:tool failed:NO];
    [self presentStalledRecord:stalled];
}
// 卡住提醒要把气泡重新推到眼前，所以这里不走 presentPendingApprovalRecord 那条
// 带早退的回落路径——面板此刻很可能已经因为长时间沉默被收走了，必须强制重现。
- (void)presentStalledRecord:(NSDictionary *)record {
    NSDictionary *terminal = [record[@"terminal"] isKindOfClass:NSDictionary.class]
        ? record[@"terminal"] : nil;
    if (terminal.count > 0) self.lastTerminalFocusTarget = terminal;
    NSString *provider = SanitizedShortString(record[@"provider"], 32);
    NSString *state = [record[@"state"] isKindOfClass:NSString.class] ? record[@"state"] : @"";
    self.hasAgentStatus = YES;
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(hideAgentStatus) object:nil];
    [self applyStatusPresentationForState:state
        provider:provider.length > 0 ? provider : @"Agent"
        tool:[record[@"tool"] isKindOfClass:NSString.class] ? record[@"tool"] : @""];
    [self.panel orderFrontRegardless];
    [self performSelector:@selector(hideAgentStatus) withObject:nil
        afterDelay:AgentStatusInactivityInterval];
}
- (void)layoutApprovalBadge {
    if (!self.approvalBadgeView) return;
    // statusIconButton 在玻璃卡片内，角标在卡片外层，差一个 6 点的卡片边距。
    // 再各让出 4 点压到图标身上，看起来才是"贴在图标角上"而不是浮在旁边。
    NSRect icon = self.statusIconButton.frame;
    self.approvalBadgeView.frame = NSMakeRect(
        6 + NSMaxX(icon) - PetApprovalBadgeSize + 4,
        6 + NSMaxY(icon) - PetApprovalBadgeSize + 4,
        PetApprovalBadgeSize, PetApprovalBadgeSize);
}
- (void)refreshApprovalBadge {
    CCPetsApprovalBadgeView *badge = (CCPetsApprovalBadgeView *)self.approvalBadgeView;
    if (!badge) return;
    badge.count = [self pendingApprovalSessionRecords].count;
    [self layoutApprovalBadge];
}
// 等审批的排最前面。纯按时间倒序会把它们推到最底下——它们的时间戳按定义只会
// 越来越旧，而它们恰恰是唯一需要用户动手的那几条。
- (NSArray<NSDictionary *> *)recentAgentSessionRecords {
    [self pruneOfflineAgentSessionRecords];
    NSArray<NSDictionary *> *records = [self.agentSessionRecords.allValues
        sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            BOOL leftApproval = [self isApprovalSessionRecord:left];
            BOOL rightApproval = [self isApprovalSessionRecord:right];
            if (leftApproval != rightApproval) return leftApproval ? NSOrderedAscending : NSOrderedDescending;
            return [right[@"timestamp"] compare:left[@"timestamp"]];
        }];
    if (records.count <= AgentSessionMenuLimit) return records;
    return [records subarrayWithRange:NSMakeRange(0, AgentSessionMenuLimit)];
}
- (NSString *)terminalNameForTarget:(NSDictionary *)target {
    NSString *program = SanitizedShortString(target[@"program"], 64);
    NSString *lower = program.lowercaseString;
    if ([lower isEqualToString:@"apple_terminal"]) return @"Terminal";
    if ([lower containsString:@"iterm"]) return @"iTerm2";
    if ([lower isEqualToString:@"vscode"]) return @"VS Code";
    if ([lower containsString:@"jetbrains"]) return @"JetBrains";
    if ([lower containsString:@"ghostty"]) return @"Ghostty";
    if ([lower containsString:@"warp"]) return @"Warp";
    if ([lower containsString:@"wezterm"]) return @"WezTerm";
    if (program.length > 0) return program;
    NSString *bundleID = SanitizedShortString(target[@"bundleID"], 128);
    return bundleID.length > 0 ? bundleID : @"Terminal";
}
- (void)focusAgentSessionRecord:(NSMenuItem *)sender {
    NSDictionary *record = [sender.representedObject isKindOfClass:NSDictionary.class]
        ? sender.representedObject : nil;
    NSDictionary *target = [record[@"terminal"] isKindOfClass:NSDictionary.class]
        ? record[@"terminal"] : nil;
    if (target.count > 0) ActivateTerminalFocusTarget(target);
}
- (void)showAgentSessionsMenu:(NSButton *)sender {
    NSArray<NSDictionary *> *records = [self recentAgentSessionRecords];
    if (records.count == 0) return;
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"最近 Agent 会话"];
    NSMenuItem *heading = [menu addItemWithTitle:@"最近 Agent 会话" action:nil keyEquivalent:@""];
    heading.enabled = NO;
    [menu addItem:NSMenuItem.separatorItem];
    BOOL separatedApprovals = NO;
    for (NSDictionary *record in records) {
        NSString *provider = SanitizedShortString(record[@"provider"], 32);
        NSString *state = [record[@"state"] isKindOfClass:NSString.class] ? record[@"state"] : @"";
        NSString *tool = [record[@"tool"] isKindOfClass:NSString.class] ? record[@"tool"] : @"";
        NSDictionary *target = record[@"terminal"];
        BOOL approval = [self isApprovalSessionRecord:record];
        // 置顶的审批组和其余会话之间划一道线，免得两段看起来像同一个时间序列。
        if (!approval && !separatedApprovals && record != records.firstObject) {
            [menu addItem:NSMenuItem.separatorItem];
            separatedApprovals = YES;
        }
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:[record[@"timestamp"] doubleValue]];
        NSString *time = [NSDateFormatter localizedStringFromDate:date
            dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle];
        NSString *title = [NSString stringWithFormat:@"%@%@ · %@ · %@ · %@",
            approval ? @"⚠️ " : @"",
            provider.length > 0 ? provider : @"Agent",
            [self statusTextForState:state tool:tool], [self terminalNameForTarget:target], time];
        NSMenuItem *item = [menu addItemWithTitle:title
            action:@selector(focusAgentSessionRecord:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = record;
        if ([target isEqual:self.lastTerminalFocusTarget]) item.state = NSControlStateValueOn;
    }
    [menu popUpMenuPositioningItem:nil
        atLocation:NSMakePoint(0, NSHeight(sender.bounds) + 4) inView:sender];
}
- (BOOL)focusLatestAgentTerminal {
    // 只有 Hook 状态气泡上的透明按钮会调用这里；桌宠本体继续负责原有互动。
    if (!self.hasAgentStatus || self.lastTerminalFocusTarget.count == 0) return NO;
    return ActivateTerminalFocusTarget(self.lastTerminalFocusTarget);
}
- (void)focusLatestAgentTerminal:(id)sender {
    [self focusLatestAgentTerminal];
}
- (NSDictionary *)petManifestInDirectory:(NSString *)directory {
    NSString *jsonPath = [directory stringByAppendingPathComponent:@"pet.json"];
    NSData *jsonData = [NSData dataWithContentsOfFile:jsonPath];
    if (!jsonData) return @{};
    id json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
    return [json isKindOfClass:NSDictionary.class] ? json : @{};
}
- (NSInteger)spriteVersionInDirectory:(NSString *)directory fallbackDirectory:(NSString *)fallbackDirectory {
    NSArray<NSString *> *directories = fallbackDirectory.length > 0
        ? @[directory, fallbackDirectory]
        : @[directory];
    for (NSString *candidate in directories) {
        id value = [self petManifestInDirectory:candidate][@"spriteVersionNumber"];
        if (![value isKindOfClass:NSNumber.class]) continue;
        NSInteger version = [value integerValue];
        if (version == 1 || version == 2) return version;
    }
    return 1;
}
- (NSInteger)spriteRowCountForVersion:(NSInteger)version {
    return version == 2 ? 11 : 9;
}
- (NSString *)spritePathInDirectory:(NSString *)directory {
    NSString *configuredName = nil;
    id value = [self petManifestInDirectory:directory][@"spritesheetPath"];
    if ([value isKindOfClass:NSString.class]) configuredName = [value lastPathComponent];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (configuredName.length > 0) [names addObject:configuredName];
    [names addObjectsFromArray:@[@"spritesheet.webp", @"spritesheet.png"]];
    for (NSString *name in names) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        BOOL isDirectory = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] && !isDirectory) return path;
    }
    return nil;
}
- (NSArray<NSString *> *)petDirectoryNamesAtPath:(NSString *)root {
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil] ?: @[];
    NSMutableArray<NSString *> *directories = [NSMutableArray array];
    for (NSString *entry in entries) {
        if ([entry hasPrefix:@"."]) continue;
        BOOL isDirectory = NO;
        NSString *path = [root stringByAppendingPathComponent:entry];
        if ([NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory) {
            [directories addObject:entry];
        }
    }
    return [directories sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}
// 桌宠只扫 OwnPetsDirectory() 加包内素材，无条件、不看那里有没有东西。~/.petdex/pets 和
// ~/.codex/pets 由别的工具写入，直接扫就永远分不清哪只是自己装的；要用 Codex 的素材就打开
// "导入 Codex 素材"开关，由 ImportCodexPets 复制进来，之后它们和自己装的没有区别。
- (NSArray<NSDictionary *> *)discoverPetOptions {
    NSString *ownRoot = OwnPetsDirectory();
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];

    for (NSString *name in [self petDirectoryNamesAtPath:ownRoot]) {
        NSString *directory = [ownRoot stringByAppendingPathComponent:name];
        NSString *path = [self spritePathInDirectory:directory];
        if (!path) continue;
        NSInteger version = [self spriteVersionInDirectory:directory fallbackDirectory:nil];
        [result addObject:@{
            @"id": [@"external:" stringByAppendingString:name],
            @"name": name,
            @"path": path,
            @"spriteVersionNumber": @(version),
            @"spriteRowCount": @([self spriteRowCountForVersion:version])
        }];
    }

    NSArray<NSString *> *bundled = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:self.binaryDirectory error:nil] ?: @[];
    for (NSString *fileName in [bundled sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        NSString *extension = fileName.pathExtension.lowercaseString;
        if (![extension isEqualToString:@"webp"] && ![extension isEqualToString:@"png"]) continue;
        [result addObject:@{
            @"id": [@"builtin:" stringByAppendingString:fileName],
            @"name": fileName.stringByDeletingPathExtension,
            @"path": [self.binaryDirectory stringByAppendingPathComponent:fileName],
            @"spriteVersionNumber": @1,
            @"spriteRowCount": @9
        }];
    }
    return result;
}
// 素材目录的 mtime。目录里增删条目会改动它，而 `cc-pets pet add` / `remove` 正是在增删
// 条目——所以这一个时间戳就足以判断列表是否需要重扫，不必每次打开菜单都遍历目录。
- (NSDate *)petOptionsStamp {
    NSDictionary *attributes = [NSFileManager.defaultManager
        attributesOfItemAtPath:OwnPetsDirectory() error:nil];
    return attributes[NSFileModificationDate];
}
- (void)invalidatePetOptionsCache {
    self.cachedPetOptions = nil;
    self.cachedPetOptionsStamp = nil;
}
- (NSArray<NSDictionary *> *)petOptions {
    NSDate *stamp = [self petOptionsStamp];
    BOOL stale = !self.cachedPetOptions ||
        (stamp == nil) != (self.cachedPetOptionsStamp == nil) ||
        (stamp && ![stamp isEqualToDate:self.cachedPetOptionsStamp]);
    if (stale) {
        self.cachedPetOptions = [self discoverPetOptions];
        self.cachedPetOptionsStamp = stamp;
    }
    return self.cachedPetOptions;
}
- (NSDictionary *)petOptionWithID:(NSString *)petID inOptions:(NSArray<NSDictionary *> *)options {
    for (NSDictionary *option in options) if ([option[@"id"] isEqualToString:petID]) return option;
    return nil;
}
- (NSArray<NSDictionary *> *)waitForPetOptions {
    while (YES) {
        // 这个循环就是"重新扫描"按钮的实现，必须绕开缓存。
        [self invalidatePetOptionsCache];
        NSArray<NSDictionary *> *options = [self petOptions];
        if (options.count > 0) return options;

        [NSApp activateIgnoringOtherApps:YES];
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"没有找到桌宠素材";
        alert.informativeText = @"用 `cc-pets pet add <名称>` 下载素材，或把 PNG / WebP 精灵图放入 "
            @"~/.cc-pets/pets/<名称>/。桌宠不会去读 ~/.petdex/pets/ 和 ~/.codex/pets/；"
            @"要用 Codex 的素材，请在右键菜单打开“导入 Codex 素材”。完成后点击“重新扫描”。";
        [alert addButtonWithTitle:@"重新扫描"];
        [alert addButtonWithTitle:@"打开素材目录"];
        [alert addButtonWithTitle:@"退出"];
        NSModalResponse response = [alert runModal];
        if (response == NSAlertSecondButtonReturn) {
            NSString *directory = OwnPetsDirectory();
            [NSFileManager.defaultManager createDirectoryAtPath:directory
                withIntermediateDirectories:YES attributes:nil error:nil];
            [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:directory]];
        } else if (response == NSAlertThirdButtonReturn) {
            return @[];
        }
    }
}
// 建一个只有"编辑"的主菜单。
//
// ⌘C/⌘V/⌘A/⌘Z 不是 NSTextView 自己处理的：按键先走 NSApp.mainMenu 的
// performKeyEquivalent:，命中菜单项之后才沿响应者链发 copy: / paste: 这些消息。
// 这个 app 是 LSUIElement，之前从没设过主菜单，所以台词编辑器里这些快捷键全部落空。
//
// LSUIElement 等价于 NSApplicationActivationPolicyAccessory，按定义不显示自己的菜单栏，
// 所以这个菜单只是一张快捷键路由表，用户看不见它。桌宠面板是 NSNonactivatingPanel，
// 点它根本不激活 app，更碰不到这里。
//
// action 一律留给响应者链（target 为 nil），谁是第一响应者谁处理——写死 target 的话
// 编辑器之外的文本框就用不上了。
- (void)installEditMenu {
    if (NSApp.mainMenu) return;
    NSMenu *mainMenu = [NSMenu new];
    NSMenuItem *editItem = [mainMenu addItemWithTitle:@"编辑" action:nil keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];

    NSArray<NSArray *> *entries = @[
        @[@"撤销", NSStringFromSelector(@selector(undo:)), @"z", @(NSEventModifierFlagCommand)],
        @[@"重做", NSStringFromSelector(@selector(redo:)), @"z",
          @(NSEventModifierFlagCommand | NSEventModifierFlagShift)],
        @[@"-", @"", @"", @0],
        @[@"剪切", NSStringFromSelector(@selector(cut:)), @"x", @(NSEventModifierFlagCommand)],
        @[@"拷贝", NSStringFromSelector(@selector(copy:)), @"c", @(NSEventModifierFlagCommand)],
        @[@"粘贴", NSStringFromSelector(@selector(paste:)), @"v", @(NSEventModifierFlagCommand)],
        @[@"删除", NSStringFromSelector(@selector(delete:)), @"", @0],
        @[@"全选", NSStringFromSelector(@selector(selectAll:)), @"a", @(NSEventModifierFlagCommand)],
    ];
    for (NSArray *entry in entries) {
        if ([entry[0] isEqualToString:@"-"]) {
            [editMenu addItem:NSMenuItem.separatorItem];
            continue;
        }
        NSMenuItem *item = [editMenu addItemWithTitle:entry[0]
            action:NSSelectorFromString(entry[1]) keyEquivalent:entry[2]];
        item.keyEquivalentModifierMask = (NSEventModifierFlags)[entry[3] unsignedIntegerValue];
    }
    editItem.submenu = editMenu;
    NSApp.mainMenu = mainMenu;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // 没有主菜单的话，台词编辑器里 ⌘C/⌘V/⌘A/⌘Z 全部没反应。
    [self installEditMenu];
    // 台词全在这个文件里，代码里没有第二份。首次启动先从默认词库拷一份出来，
    // 否则新装的桌宠一句话都不会说。
    PetPhrasesEnsureFileExists();
    if (![NSUserDefaults.standardUserDefaults boolForKey:PetInteractionPhrasesV1MigratedKey] &&
        PetPhrasesEnsureInteractionSections()) {
        [NSUserDefaults.standardUserDefaults setBool:YES
            forKey:PetInteractionPhrasesV1MigratedKey];
    }
    self.managedByCLI = [NSProcessInfo.processInfo.arguments containsObject:@"--managed"];
    NSString *binaryDir = NSProcessInfo.processInfo.arguments.firstObject.stringByStandardizingPath.stringByDeletingLastPathComponent;
    NSBundle *mainBundle = NSBundle.mainBundle;
    BOOL runsFromAppBundle = [mainBundle.bundlePath.pathExtension.lowercaseString isEqualToString:@"app"];
    self.binaryDirectory = runsFromAppBundle && mainBundle.resourcePath.length > 0
        ? mainBundle.resourcePath
        : binaryDir;
    // 必须在 waitForPetOptions 之前：否则自己的目录还空着、素材全在 Codex 那边时，
    // 会先弹一次"没有找到桌宠素材"，等用户点完重新扫描才导入。
    if ([NSUserDefaults.standardUserDefaults boolForKey:ImportCodexPetsKey]) ImportCodexPets();
    NSArray<NSDictionary *> *petOptions = [self waitForPetOptions];
    if (petOptions.count == 0) {
        [NSApp terminate:nil];
        return;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{StatusBubbleExpandedKey: @YES,
        CodexUsageDisplayModeKey: @"subscription",
        ClaudeUsageDisplayModeKey: @"subscription"}];
    [defaults registerDefaults:@{
        SystemCPUEnabledKey: @YES,
        SystemTemperatureEnabledKey: @YES,
        SystemMemoryEnabledKey: @YES,
        PetInteractionEnabledKey: @YES,
        PetInteractionHeartThresholdKey: @3,
        PetInteractionAnnoyedThresholdKey: @10,
        PetInteractionIntervalKey: @1.2
    }];
    if (![defaults boolForKey:StatusBubblePreferenceV2Key]) {
        [defaults setBool:YES forKey:StatusBubbleExpandedKey];
        [defaults setBool:YES forKey:StatusBubblePreferenceV2Key];
    }
    self.statusBubbleExpanded = [defaults boolForKey:StatusBubbleExpandedKey];
    NSString *selected = [defaults stringForKey:@"CCPetsSelectedSprite"];
    if (selected.length > 0 && ![selected containsString:@":"]) selected = [@"builtin:" stringByAppendingString:selected];
    NSDictionary *selectedOption = [self petOptionWithID:selected inOptions:petOptions] ?: petOptions.firstObject;
    selected = selectedOption[@"id"];
    NSString *spritePath = selectedOption[@"path"];
    NSImage *image = LoadPetSpriteImage(spritePath, NSMakeSize(140, 150),
        [selectedOption[@"spriteRowCount"] integerValue] ?: 9);
    if (!image) {
        fprintf(stderr, "无法读取桌宠素材: %s\n", spritePath.UTF8String);
        [NSApp terminate:nil];
        return;
    }

    NSSize size = NSMakeSize(230, 170);
    self.panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    self.panel.opaque = NO;
    self.panel.backgroundColor = NSColor.clearColor;
    self.panel.hasShadow = NO;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    // 与 1.0 一致：透明背景交给 AppKit 原生拖动；PetView 通过
    // mouseDownCanMoveWindow=NO 保留自己的点击和奔跑动画拖动，两条路径按命中区隔离。
    self.panel.movableByWindowBackground = YES;
    self.panel.hidesOnDeactivate = NO;

    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    self.panel.contentView = root;
    NSInteger spriteRowCount = [selectedOption[@"spriteRowCount"] integerValue] ?: 9;
    self.petView = [[PetView alloc] initWithFrame:NSMakeRect(43, 0, 144, 150)
        sheet:image rowCount:spriteRowCount];
    self.petView.currentPetID = selected;
    // 台词层要知道现在是哪只宠物，才能去找它的专属词库。启动这一处和 switchPetToID:
    // 那一处是仅有的两个入口——删除宠物后的回落也走 switchPetToID:。
    PetPhrasesSetCurrentPetID(selected);
    __weak typeof(self) weakSelf = self;
    self.petView.pocketHoverChanged = ^(BOOL hovering) {
        weakSelf.pocketHovering = hovering;
        if (hovering) [weakSelf showQuotaDashboard];
        else [weakSelf scheduleQuotaDashboardHide];
    };
    self.petView.petOptionsRequested = ^NSArray<NSDictionary *> *{
        return [weakSelf petOptions] ?: @[];
    };
    self.petView.switchPetRequested = ^(NSString *petID) {
        [weakSelf switchPetToID:petID];
    };
    self.petView.deletePetRequested = ^BOOL(NSString *petID) {
        return [weakSelf deletePetWithID:petID];
    };
    self.petView.dragStateChanged = ^(BOOL dragging) {
        weakSelf.petDragging = dragging;
        if (!dragging) [weakSelf scheduleQuotaDashboardHide];
    };
    self.petView.interactionPhraseRequested = ^(NSString *tag) {
        NSString *text = PetPhraseForTag(tag, [weakSelf speechSlots]);
        if (text.length > 0) [weakSelf presentSpeechText:text];
    };
    // 附属面板的跟随必须挂在窗口自身的移动通知上，不能只挂 PetView 的拖动回调：
    // panel 开了 movableByWindowBackground，按在 PetView 之外的透明边上时由 AppKit
    // 直接搬窗口，PetView 的 mouseDragged 根本不触发，气泡就会留在原地。
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(petWindowDidMove:)
        name:NSWindowDidMoveNotification object:self.panel];
    [root addSubview:self.petView];

    NSSize statusGlassSize = NSMakeSize(340, PetStatusBodyHeight);
    NSSize statusSize = NSMakeSize(statusGlassSize.width + 12, statusGlassSize.height + 12);
    self.statusPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0,
        statusSize.width, statusSize.height)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    self.statusPanel.opaque = NO;
    self.statusPanel.backgroundColor = NSColor.clearColor;
    self.statusPanel.hasShadow = NO;
    self.statusPanel.ignoresMouseEvents = NO;
    self.statusPanel.level = NSFloatingWindowLevel;
    self.statusPanel.collectionBehavior =
        NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.statusPanel.hidesOnDeactivate = NO;
    NSView *statusRoot = [[NSView alloc] initWithFrame:NSMakeRect(
        0, 0, statusSize.width, statusSize.height)];
    NSView *statusShadow = [[NSView alloc] initWithFrame:NSMakeRect(
        6, 6, statusGlassSize.width, statusGlassSize.height)];
    self.statusShadowView = statusShadow;
    statusShadow.layer.cornerRadius = statusGlassSize.height / 2.0;
    statusShadow.wantsLayer = YES;
    statusShadow.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.01].CGColor;
    statusShadow.layer.cornerCurve = kCACornerCurveContinuous;
    statusShadow.layer.shadowColor = NSColor.blackColor.CGColor;
    statusShadow.layer.shadowOpacity = 0.24;
    statusShadow.layer.shadowRadius = 8;
    statusShadow.layer.shadowOffset = NSMakeSize(0, -3);
    CGPathRef statusShadowPath = CGPathCreateWithRoundedRect(
        statusShadow.bounds, statusGlassSize.height / 2.0,
        statusGlassSize.height / 2.0, NULL);
    statusShadow.layer.shadowPath = statusShadowPath;
    CGPathRelease(statusShadowPath);
    [statusRoot addSubview:statusShadow];

    self.statusGlass = [[NSVisualEffectView alloc]
        initWithFrame:NSMakeRect(6, 6, statusGlassSize.width, statusGlassSize.height)];
    self.statusGlass.material = NSVisualEffectMaterialPopover;
    self.statusGlass.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    self.statusGlass.state = NSVisualEffectStateActive;
    self.statusGlass.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    self.statusGlass.wantsLayer = YES;
    self.statusGlass.layer.cornerRadius = statusGlassSize.height / 2.0;
    self.statusGlass.layer.cornerCurve = kCACornerCurveContinuous;
    self.statusGlass.layer.masksToBounds = YES;
    self.statusGlass.layer.borderWidth = 1;
    self.statusGlass.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.48].CGColor;

    self.statusTitleLabel = [NSTextField labelWithString:@""];
    // 层级是反的：宠物是主角，事实退成眉标。
    // 标题 11 Medium 浅灰只负责"到底在干什么"这个锚点，副行 14 Medium 深色才是正文。
    self.statusTitleLabel.frame = NSMakeRect(20, 34, statusGlassSize.width - 80, 14);
    self.statusTitleLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.statusTitleLabel.textColor = [NSColor colorWithWhite:0.42 alpha:0.90];
    self.statusTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.statusGlass addSubview:self.statusTitleLabel];

    self.statusDetailLabel = [NSTextField labelWithString:@""];
    self.statusDetailLabel.frame = NSMakeRect(20, 10, statusGlassSize.width - 80, 22);
    self.statusDetailLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
    self.statusDetailLabel.textColor = [NSColor colorWithWhite:0.12 alpha:0.96];
    self.statusDetailLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.statusGlass addSubview:self.statusDetailLabel];

    self.statusIconButton = [[CCPetsStatusClickButton alloc] initWithFrame:NSMakeRect(
        statusGlassSize.width - 48, 12, 34, 34)];
    self.statusIconButton.bordered = NO;
    self.statusIconButton.imagePosition = NSImageOnly;
    self.statusIconButton.wantsLayer = YES;
    self.statusIconButton.layer.cornerRadius = 17;
    self.statusIconButton.layer.masksToBounds = YES;
    self.statusIconButton.toolTip = @"查看最近 Agent 会话";
    self.statusIconButton.target = self;
    self.statusIconButton.action = @selector(showAgentSessionsMenu:);
    [self.statusGlass addSubview:self.statusIconButton];
    [statusRoot addSubview:self.statusGlass];
    CCPetsStatusClickButton *statusClick = [[CCPetsStatusClickButton alloc]
        initWithFrame:NSMakeRect(6, 6, statusGlassSize.width - 56, statusGlassSize.height)];
    statusClick.bordered = NO;
    statusClick.transparent = YES;
    statusClick.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    statusClick.title = @"";
    statusClick.toolTip = @"返回触发此状态的 Agent 终端";
    statusClick.target = self;
    statusClick.action = @selector(focusLatestAgentTerminal:);
    self.statusClickButton = statusClick;
    [statusRoot addSubview:statusClick];
    // 角标挂在 statusRoot 而不是 statusGlass 里：玻璃卡片是 masksToBounds 的胶囊，
    // 右上角正好落在圆角外面，放进去会被裁掉一半。
    CCPetsApprovalBadgeView *badge = [[CCPetsApprovalBadgeView alloc]
        initWithFrame:NSMakeRect(0, 0, PetApprovalBadgeSize, PetApprovalBadgeSize)];
    badge.hidden = YES;
    self.approvalBadgeView = badge;
    [statusRoot addSubview:badge];
    [self layoutApprovalBadge];
    self.statusPanel.contentView = statusRoot;

    NSSize quotaSize = NSMakeSize(QuotaLogicalWidth * QuotaScale, QuotaLogicalHeight * QuotaScale);
    self.quotaPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, quotaSize.width, quotaSize.height)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    self.quotaPanel.opaque = NO;
    self.quotaPanel.backgroundColor = NSColor.clearColor;
    self.quotaPanel.hasShadow = YES;
    self.quotaPanel.acceptsMouseMovedEvents = YES;
    self.quotaPanel.ignoresMouseEvents = NO;
    self.quotaPanel.level = NSFloatingWindowLevel;
    self.quotaPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.quotaPanel.hidesOnDeactivate = NO;
    NSView *quotaRoot = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, quotaSize.width, quotaSize.height)];
    NSVisualEffectView *glass = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0,
        quotaSize.width, quotaSize.height)];
    glass.material = NSVisualEffectMaterialUnderWindowBackground;
    glass.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    glass.state = NSVisualEffectStateActive;
    glass.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    glass.wantsLayer = YES;
    glass.layer.cornerRadius = 13;
    glass.layer.masksToBounds = YES;
    [quotaRoot addSubview:glass];
    self.quotaView = [[QuotaDashboardView alloc] initWithFrame:NSMakeRect(0, 0, quotaSize.width, quotaSize.height)];
    [self applySystemMetricPreferences];
    [self applyUsageDisplayModePreferences];
    self.quotaView.codexLogo = OfficialAppIcon(@"com.openai.codex", @"icon-chatgpt.icns");
    self.quotaView.claudeLogo = OfficialAppIcon(@"com.anthropic.claudefordesktop", @"electron.icns");
    self.quotaView.hoverChanged = ^(BOOL hovering) {
        weakSelf.dashboardHovering = hovering;
        if (!hovering) [weakSelf scheduleQuotaDashboardHide];
    };
    self.quotaView.refreshRequested = ^{
        [weakSelf refreshUsage:nil];
    };
    [quotaRoot addSubview:self.quotaView];
    self.quotaPanel.contentView = quotaRoot;
    // 先探测再第一次显示：否则面板会先按两张卡的高度弹出来再收缩一下。
    [self refreshDetectedProviders];

    NSScreen *screen = NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;
    [self.panel setFrameOrigin:NSMakePoint(NSMaxX(visible) - size.width - 24, NSMinY(visible) + 18)];
    [self.panel orderFrontRegardless];
    self.usageMonitor = [CCPetsUsageMonitor new];
    self.systemMonitor = [CCPetsSystemMonitor new];
    self.agentEventPartialLine = [NSMutableData data];
    self.pendingApprovalRecords = [NSMutableDictionary dictionary];
    self.stallNotifiedSessionKeys = [NSMutableSet set];
    self.usageMonitor.changeHandler = ^(NSDictionary *codexUsage, NSDictionary *claudeUsage) {
        [weakSelf applyCodexUsage:codexUsage claudeUsage:claudeUsage];
        [weakSelf considerQuotaSpeech];
    };
    [self.usageMonitor start];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--preview-dashboard"]) {
        self.pocketHovering = YES;
        [self showQuotaDashboard];
    }
    [self rescheduleUsageTimer];
    [self refreshClientLifecycle:nil];
    NSTimer *lifecycleTimer = [NSTimer scheduledTimerWithTimeInterval:ClientLifecycleInterval
        target:self selector:@selector(refreshClientLifecycle:) userInfo:nil repeats:YES];
    lifecycleTimer.tolerance = ClientLifecycleInterval * 0.3;
    [self startAgentEventReader];
    NSTimer *readerTimer = [NSTimer scheduledTimerWithTimeInterval:AgentEventReaderCheckInterval
        target:self selector:@selector(ensureAgentEventReader:) userInfo:nil repeats:YES];
    readerTimer.tolerance = AgentEventReaderCheckInterval * 0.3;
    // 这里刻意不使用 occlusionState / NSWindowDidChangeOcclusionStateNotification：
    // 桌宠是置顶的（NSFloatingWindowLevel + FullScreenAuxiliary），全屏应用也压不住它，
    // 所以“被遮挡”几乎不会真实发生，收益接近零；而实测中 occlusionState 会在
    // Space / 全屏过渡期间报出长达十几秒的“不可见”，那会把一只用户正看着的桌宠冻在
    // 某一帧上。显示器睡眠则是无歧义的信号：屏幕灭了，桌宠必定不可见。
    NSNotificationCenter *workspaceCenter = NSWorkspace.sharedWorkspace.notificationCenter;
    [workspaceCenter addObserver:self selector:@selector(screensDidSleep:)
        name:NSWorkspaceScreensDidSleepNotification object:nil];
    [workspaceCenter addObserver:self selector:@selector(screensDidWake:)
        name:NSWorkspaceScreensDidWakeNotification object:nil];
}
- (void)screensDidSleep:(NSNotification *)notification {
    [self.petView setAnimationSuspended:YES];
}
- (void)screensDidWake:(NSNotification *)notification {
    [self.petView setAnimationSuspended:NO];
}
- (void)rescheduleUsageTimer {
    NSTimeInterval interval = self.quotaPanel.isVisible
        ? UsageRefreshIntervalVisible : UsageRefreshIntervalHidden;
    if (self.usageTimer.isValid && self.usageTimer.timeInterval == interval) return;
    [self.usageTimer invalidate];
    self.usageTimer = [NSTimer scheduledTimerWithTimeInterval:interval target:self
        selector:@selector(refreshUsage:) userInfo:nil repeats:YES];
    self.usageTimer.tolerance = interval * 0.2;
}
// 全量聚合是同步的主线程活儿（本机实测数十毫秒，会话目录越大越久），而面板恰好由"鼠标
// 停在口袋上"触发——那正是用户可能马上按下并拖动的时刻。事件被这几十毫秒挡住，mouseDown
// 和 mouseDragged 就会成批迟到，手感上像是"鼠标走远了宠物才跟上"。
// 因此：左键按着的时候不刷（拖动期间没人看数字），刚刷过的也不重刷（进出热区会反复触发）。
static const NSTimeInterval UsageRefreshCoalesceWindow = 2.0;
- (BOOL)shouldRefreshUsageForDashboard {
    if (CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft)) {
        return NO;
    }
    return NSDate.date.timeIntervalSince1970 - self.lastUsageRefreshAt >= UsageRefreshCoalesceWindow;
}
- (void)showQuotaDashboard {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideQuotaDashboardIfNeeded) object:nil];
    if ([self shouldRefreshUsageForDashboard]) [self refreshUsage:nil];
    [self positionQuotaDashboard];
    [self.quotaPanel orderFrontRegardless];
    [self.panel orderFrontRegardless];
    [self rescheduleUsageTimer];
    [self startQuotaClock];
    [self updateSystemMetricsTimer];
}
- (BOOL)hasEnabledSystemMetric {
    return self.quotaView.systemCPUEnabled || self.quotaView.systemTemperatureEnabled ||
        self.quotaView.systemMemoryEnabled;
}
- (void)refreshSystemMetrics:(id)sender {
    if (![self hasEnabledSystemMetric]) return;
    BOOL cpuEnabled = self.quotaView.systemCPUEnabled;
    BOOL memoryEnabled = self.quotaView.systemMemoryEnabled;
    BOOL temperatureEnabled = self.quotaView.systemTemperatureEnabled;
    __weak typeof(self) weakSelf = self;
    [self.systemMonitor sampleCPU:cpuEnabled memory:memoryEnabled
        temperature:temperatureEnabled completion:^(NSNumber *cpu, NSNumber *memory,
            NSNumber *temperature) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (cpuEnabled) strongSelf.quotaView.systemCPUPercent = cpu;
        if (memoryEnabled) strongSelf.quotaView.systemMemoryPercent = memory;
        if (temperatureEnabled) strongSelf.quotaView.systemTemperatureCelsius = temperature;
        strongSelf.quotaView.needsDisplay = YES;
    }];
}
- (void)updateSystemMetricsTimer {
    BOOL shouldRun = self.quotaPanel.isVisible && [self hasEnabledSystemMetric];
    if (!shouldRun) {
        [self.systemMetricsTimer invalidate];
        self.systemMetricsTimer = nil;
        return;
    }
    if (self.systemMetricsTimer.isValid) return;
    [self refreshSystemMetrics:nil];
    __weak typeof(self) weakSelf = self;
    self.systemMetricsTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES
        block:^(NSTimer *timer) { [weakSelf refreshSystemMetrics:timer]; }];
    self.systemMetricsTimer.tolerance = 0.4;
}
// "数据刷新" 显示的是相对时间，没有新数据也得自己走字。面板隐藏时不需要这个定时器，
// 隐藏的窗口本来就不会重绘。
- (void)startQuotaClock {
    if (self.quotaClockTimer.isValid) return;
    self.quotaClockTimer = [NSTimer scheduledTimerWithTimeInterval:QuotaClockInterval
        target:self selector:@selector(tickQuotaClock:) userInfo:nil repeats:YES];
    self.quotaClockTimer.tolerance = QuotaClockInterval * 0.3;
}
- (void)tickQuotaClock:(id)sender {
    if (!self.quotaPanel.isVisible) {
        [self.quotaClockTimer invalidate];
        self.quotaClockTimer = nil;
        [self updateSystemMetricsTimer];
        return;
    }
    self.quotaView.needsDisplay = YES;
}
- (void)positionQuotaDashboard {
    NSRect petFrame = self.panel.frame;
    NSRect visible = (self.panel.screen ?: NSScreen.mainScreen).visibleFrame;
    NSSize size = self.quotaPanel.frame.size;
    const CGFloat margin = 12;
    const CGFloat gap = 8;
    CGFloat minX = NSMinX(visible) + margin;
    CGFloat maxX = NSMaxX(visible) - size.width - margin;
    CGFloat minY = NSMinY(visible) + margin;
    CGFloat maxY = NSMaxY(visible) - size.height - margin;
    CGFloat leftX = NSMinX(petFrame) - size.width - gap;
    CGFloat rightX = NSMaxX(petFrame) + gap;
    CGFloat x;
    CGFloat y = fmax(minY, fmin(NSMinY(petFrame) + 112, maxY));

    // 优先放在宠物左侧，其次右侧；两个可点击窗口之间始终留出间隔。
    if (leftX >= minX) {
        x = leftX;
    } else if (rightX <= maxX) {
        x = rightX;
    } else {
        // 横向空间不足时改放上/下方，避免屏幕边缘钳位后重新盖住宠物。
        x = fmax(minX, fmin(NSMidX(petFrame) - size.width / 2.0, maxX));
        CGFloat aboveY = NSMaxY(petFrame) + gap;
        CGFloat belowY = NSMinY(petFrame) - size.height - gap;
        if (aboveY <= maxY) y = aboveY;
        else if (belowY >= minY) y = belowY;
        else y = fmax(minY, fmin(aboveY, maxY));
    }
    [self.quotaPanel setFrameOrigin:NSMakePoint(x, y)];
}
- (void)petWindowDidMove:(NSNotification *)notification {
    if (self.quotaPanel.isVisible) [self positionQuotaDashboard];
    if (self.statusPanel.isVisible) [self positionAgentStatus];
    if (self.speechPanel.isVisible) [self positionSpeechPanel];
}
#pragma mark - 说话气泡



// 气泡停留时长。
static const NSTimeInterval PetSpeechDwell = 4.5;
// 气泡与状态卡的本体高度。
//
// 不要再加尾巴（三角、锥形、思考圆点都试过）：药丸的圆角等于高度一半，整条边都是弧，
// 尾巴只能从弧上长出来，怎么调都像贴上去的；换成圆角矩形能配尾巴，但那要放弃
// layer.cornerRadius + kCACornerCurveContinuous 改用位图 maskImage 裁形，
// squircle 和 GPU 端矢量裁切的质感一起丢了，得不偿失。
// 结论：保持药丸 + 原生圆角，靠贴近宠物来表达归属。
static const CGFloat PetSpeechBodyHeight = 38.0;
static const CGFloat PetStatusBodyHeight = 58.0;
// 副行没东西可显示时的高度，只放得下标题一行。
static const CGFloat PetStatusSingleLineHeight = 40.0;

- (BOOL)speechEnabled {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    // 缺省开启；用户可在右键菜单里关掉。
    id value = [defaults objectForKey:@"CCPetsSpeechEnabled"];
    return value == nil ? YES : [value boolValue];
}
// 当前档位。现读，右键菜单里改完立刻生效不用重启。
- (PetSpeechRate)speechRate {
    NSString *value = [NSUserDefaults.standardUserDefaults stringForKey:PetSpeechFrequencyKey];
    if ([value isEqualToString:PetSpeechFrequencyLow]) return PetSpeechRateLow;
    if ([value isEqualToString:PetSpeechFrequencyHigh]) return PetSpeechRateHigh;
    if ([value isEqualToString:PetSpeechFrequencyChatty]) return PetSpeechRateChatty;
    return PetSpeechRateNormal;
}
// 预算与冷却。两道闸门都过了才允许说。
// 默认跟随上面的档位；下面这两个键是更细的手动覆盖，写了就压过档位，
// 现读，改完立刻生效不用重启：
//   defaults write com.universewang.cc-pets CCPetsSpeechCooldown -float 0
//   defaults write com.universewang.cc-pets CCPetsSpeechHourlyBudget -int 100
//   defaults delete com.universewang.cc-pets CCPetsSpeechCooldown          # 交回档位
// 域名是 bundle identifier，不是 "cc-pets"——写错域的话键会落在另一个 plist 里，
// 桌宠永远看不到，表现为"设了没反应"。
- (NSTimeInterval)speechCooldownSeconds {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:@"CCPetsSpeechCooldown"];
    if (![value isKindOfClass:NSNumber.class]) return [self speechRate].cooldown;
    return MAX(0.0, [value doubleValue]);
}
- (NSInteger)speechHourlyBudget {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:@"CCPetsSpeechHourlyBudget"];
    if (![value isKindOfClass:NSNumber.class]) return [self speechRate].hourlyBudget;
    return MAX((NSInteger)1, [value integerValue]);
}
// agent 是不是正在干活。只有"待机中"和状态卡压根没显示这两种情况算闲——
// thinking / tool / subagent / approval / notification / completed / failed
// 副行上都带着用户还需要看的信息，闲话一律让路。
// 用 hasAgentStatus 而不是 statusPanel.isVisible：用户把状态卡折叠起来时卡片是隐藏的，
// 但 agent 照样在干活，这时候冒气泡等于绕过折叠又把话糊到脸上。
- (BOOL)agentBusyForSpeech {
    if (!self.hasAgentStatus) return NO;
    return ![self.lastStatusState isEqualToString:@"idle"];
}
- (BOOL)canSpeakNow {
    if (![self speechEnabled]) return NO;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now < self.speechCooldownUntil) return NO;
    if (!self.speechTimestamps) self.speechTimestamps = [NSMutableArray array];
    while (self.speechTimestamps.count > 0 &&
           now - self.speechTimestamps.firstObject.doubleValue > 3600.0) {
        [self.speechTimestamps removeObjectAtIndex:0];
    }
    return (NSInteger)self.speechTimestamps.count < [self speechHourlyBudget];
}
// 当前可用的槽位值。取不到的键就不放进去，模板层会因此跳过需要它的那些条目。
- (NSDictionary<NSString *, NSString *> *)speechSlots {
    return [self speechSlotsWithTool:self.lastSpeechTool];
}
- (NSDictionary<NSString *, NSString *> *)speechSlotsWithTool:(NSString *)tool {
    NSMutableDictionary<NSString *, NSString *> *slots = [NSMutableDictionary dictionary];
    NSCalendar *calendar = NSCalendar.currentCalendar;
    slots[@"hour"] = [@([calendar component:NSCalendarUnitHour fromDate:NSDate.date]) stringValue];
    if (self.consecutiveFailures > 0) {
        slots[@"failCount"] = [@(self.consecutiveFailures) stringValue];
    }
    if (self.sessionStartedAt > 0) {
        NSInteger minutes = (NSInteger)((NSDate.date.timeIntervalSince1970 -
            self.sessionStartedAt) / 60.0);
        if (minutes > 0) slots[@"sessionMin"] = [@(minutes) stringValue];
    }
    NSInteger remaining = [self remainingFiveHourQuotaPercent];
    if (remaining >= 0) {
        slots[@"quota5h"] = [NSString stringWithFormat:@"%ld%%", (long)remaining];
    }
    NSString *reset = [self fiveHourResetTimeText];
    if (reset.length > 0) slots[@"resetTime"] = reset;
    // 工具名此前从来没被填过，导致 "{toolName} 这货不靠谱。" 这类台词永远被跳过。
    NSString *trimmed = [tool stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceCharacterSet];
    if (trimmed.length > 0 && trimmed.length <= 24) slots[@"toolName"] = trimmed;
    return slots;
}
// 5 小时窗口的剩余百分比，取不到返回 -1。Claude 和 Codex 的字段名不一样，都认。
- (NSInteger)remainingFiveHourQuotaPercent {
    NSDictionary *usage = LatestClaudeUsage() ?: LatestUsage();
    NSDictionary *fiveHour = [usage[@"fiveHour"] isKindOfClass:NSDictionary.class]
        ? usage[@"fiveHour"] : nil;
    id used = fiveHour[@"used_percentage"] ?: fiveHour[@"used_percent"];
    if (![used isKindOfClass:NSNumber.class]) return -1;
    NSInteger remaining = 100 - [used integerValue];
    return MAX((NSInteger)0, MIN((NSInteger)100, remaining));
}
// 回血时间，按本机时区格式化。没有这个槽位的话，带 {resetTime} 的词条会被整条跳过。
- (NSString *)fiveHourResetTimeText {
    NSDictionary *usage = LatestClaudeUsage() ?: LatestUsage();
    NSDictionary *fiveHour = [usage[@"fiveHour"] isKindOfClass:NSDictionary.class]
        ? usage[@"fiveHour"] : nil;
    id resets = fiveHour[@"resets_at"];
    if (![resets isKindOfClass:NSNumber.class]) return nil;
    NSTimeInterval at = [resets doubleValue];
    if (at <= NSDate.date.timeIntervalSince1970) return nil;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm";
    formatter.timeZone = NSTimeZone.systemTimeZone;
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:at]];
}
// 额度是"跨阈值"事件，不是状态事件，所以单独判档。
//
// 只在向下穿档时说一次：低于 20%% 就一直念叨会变成唠叨，而额度刷新是每分钟级别的，
// 不设档位的话一小时预算瞬间就被烧光。回血（档位回升）时把标记还回去，
// 下个周期才能再触发。
- (void)considerQuotaSpeech {
    NSInteger remaining = [self remainingFiveHourQuotaPercent];
    if (remaining < 0) return;
    NSInteger tier;
    if (remaining <= 5) tier = 0;
    else if (remaining <= 10) tier = 1;
    else if (remaining <= 20) tier = 2;
    else tier = 3;

    NSInteger previous = self.lastQuotaTier;
    self.lastQuotaTier = tier;
    // 首次拿到数据只记档不出声，免得每次启动都通报一遍额度。
    // （lastQuotaTier 的初值 0 恰好是最低档，不加这道判断的话冷启动必然误判成"刚跌到 5%"。）
    if (!self.lastQuotaTierInitialized) {
        self.lastQuotaTierInitialized = YES;
        return;
    }
    if (tier >= previous) return;  // 回血或没跨档
    [self speakWithTag:PetPhraseTagQuotaLow];
}
- (void)buildSpeechPanelIfNeeded {
    if (self.speechPanel) return;
    NSSize glassSize = NSMakeSize(210, PetSpeechBodyHeight);
    NSSize size = NSMakeSize(glassSize.width + 12, glassSize.height + 12);
    self.speechPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    self.speechPanel.opaque = NO;
    self.speechPanel.backgroundColor = NSColor.clearColor;
    self.speechPanel.hasShadow = NO;
    self.speechPanel.level = NSFloatingWindowLevel;
    self.speechPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary;
    // 气泡不抢焦点、不接受点击：它是纯播报，挡住宠物就本末倒置了。
    self.speechPanel.ignoresMouseEvents = YES;

    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    self.speechGlass = [[NSVisualEffectView alloc]
        initWithFrame:NSMakeRect(6, 6, glassSize.width, glassSize.height)];
    self.speechGlass.material = NSVisualEffectMaterialPopover;
    self.speechGlass.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    self.speechGlass.state = NSVisualEffectStateActive;
    self.speechGlass.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    self.speechGlass.wantsLayer = YES;
    // 圆角交给 layer 自己：cornerRadius 是 GPU 端矢量裁切，配 continuous 曲率就是
    // macOS 那个 squircle。位图 maskImage 换不来这个质感。
    self.speechGlass.layer.cornerRadius = glassSize.height / 2.0;
    self.speechGlass.layer.cornerCurve = kCACornerCurveContinuous;
    self.speechGlass.layer.masksToBounds = YES;
    self.speechGlass.layer.borderWidth = 1;
    self.speechGlass.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.48].CGColor;

    self.speechLabel = [NSTextField labelWithString:@""];
    self.speechLabel.frame = NSMakeRect(14, 10, glassSize.width - 28, 18);
    // 独立气泡里这句话是唯一元素，不与标题争，比并入状态卡时大半档。
    self.speechLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    self.speechLabel.textColor = [NSColor colorWithWhite:0.10 alpha:0.96];
    self.speechLabel.alignment = NSTextAlignmentCenter;
    self.speechLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.speechGlass addSubview:self.speechLabel];
    [root addSubview:self.speechGlass];
    self.speechPanel.contentView = root;
}
// 独立气泡只在没有状态卡时出现（有状态卡时话并进它的副行），所以固定放宠物头顶即可，
// 不用再和状态卡抢位置。
- (void)positionSpeechPanel {
    NSRect petFrame = self.panel.frame;
    NSRect visible = (self.panel.screen ?: NSScreen.mainScreen).visibleFrame;
    NSSize size = self.speechPanel.frame.size;
    CGFloat x = NSMidX(petFrame) - size.width / 2.0;
    // 头顶放不下就翻到脚下，尾巴跟着改朝向长在顶边。
    CGFloat aboveY = NSMaxY(petFrame) - 6;
    BOOL fitsAbove = aboveY + size.height <= NSMaxY(visible) - 10;
    CGFloat y = fitsAbove ? aboveY : NSMinY(petFrame) - size.height + 6;
    x = fmax(NSMinX(visible) + 10, fmin(x, NSMaxX(visible) - size.width - 10));
    y = fmax(NSMinY(visible) + 10, fmin(y, NSMaxY(visible) - size.height - 10));
    [self.speechPanel setFrameOrigin:NSMakePoint(x, y)];
}
// 说一句。tag 取不到词条、预算用完、或状态卡正展开时都直接不说——
// 两个泡同时挂在宠物头上会很吵。
- (void)speakWithTag:(NSString *)tag {
    if (![self canSpeakNow]) return;
    NSString *text = PetPhraseForTag(tag, [self speechSlots]);
    if (text.length == 0) return;

    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    [self.speechTimestamps addObject:@(now)];
    self.speechCooldownUntil = now + [self speechCooldownSeconds];

    [self presentSpeechText:text];
}
// 话往哪儿显示只在这一处决定：有状态卡就并进它的副行，没有才起独立气泡。
// 调试触发也必须走这里——否则看到的是现实中不会出现的画面（两个泡叠着）。
- (void)presentSpeechText:(NSString *)text {
    if (text.length == 0) return;
    if (self.statusPanel.isVisible) {
        self.statusDetailLabel.stringValue = text;
        [self resizeStatusCardToFitText];
        [self positionAgentStatus];
        // 上一句的独立气泡可能还没淡完，收掉它，别和状态卡叠着。
        [self hideSpeechBubble];
        // 副行是状态卡的正文，借走说一句之后必须还回去，否则闲话会一直挂着，
        // 看起来像状态卡卡死了。
        //
        // 这里刻意不写 lastPetVoiceText/lastPetVoiceTag：那两个是状态文案的
        // 去重缓存，被闲话污染的话 restoreStatusDetail 就没有东西可还，而且
        // 下一次同状态事件会把闲话当成"该状态的文案"复读出来。
        [NSObject cancelPreviousPerformRequestsWithTarget:self
            selector:@selector(restoreStatusDetail) object:nil];
        [self performSelector:@selector(restoreStatusDetail) withObject:nil
            afterDelay:PetSpeechDwell];
        return;
    }
    [self showSpeechBubbleWithText:text];
}
// 把副行还给状态文案。lastPetVoiceText 里存的就是当前状态本该显示的那句。
- (void)restoreStatusDetail {
    if (!self.statusPanel.isVisible || self.lastPetVoiceText.length == 0) return;
    self.statusDetailLabel.stringValue = self.lastPetVoiceText;
    [self resizeStatusCardToFitText];
    [self positionAgentStatus];
}
- (void)showSpeechBubbleWithText:(NSString *)text {
    [self buildSpeechPanelIfNeeded];
    self.speechLabel.stringValue = text;
    [self resizeSpeechBubbleToFitText];
    [self positionSpeechPanel];
    self.speechPanel.alphaValue = 0;
    [self.speechPanel orderFront:nil];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.18;
        self.speechPanel.animator.alphaValue = 1.0;
    } completionHandler:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(hideSpeechBubble) object:nil];
    [self performSelector:@selector(hideSpeechBubble) withObject:nil afterDelay:PetSpeechDwell];
}
// 调试触发：写一个标签进 defaults，下一跳（≤3 秒）就强制弹一次独立气泡，
// 绕开安静期、概率、预算和状态卡判断，弹完自动把键删掉，不会残留。
//   defaults write com.universewang.cc-pets CCPetsSpeechDebugTag -string idle
// 标签可填 idle / done / fail / quota_low / late_night / long_session / wake
- (void)consumeSpeechDebugTrigger {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id value = [defaults objectForKey:@"CCPetsSpeechDebugTag"];
    if (![value isKindOfClass:NSString.class] || [value length] == 0) return;
    [defaults removeObjectForKey:@"CCPetsSpeechDebugTag"];
    NSString *text = PetPhraseForTag(value, [self speechSlots]);
    if (text.length == 0) text = @"（这个标签取不到词条）";
    [self presentSpeechText:text];
}
- (void)hideSpeechBubble {
    if (!self.speechPanel) return;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.22;
        self.speechPanel.animator.alphaValue = 0;
    } completionHandler:^{
        if (self.speechPanel.alphaValue <= 0.01) [self.speechPanel orderOut:nil];
    }];
}
// 闲着时候的自发说话。
//
// 光挂在 agent 事件流上是不够的：那样宠物永远只会就着工作说话，late_night /
// long_session / idle 这些词条根本没有属于自己的触发时机，独立气泡也永远不会出现
// （agent 事件必定先把状态卡显示出来，话就并进去了）。
//
// 挂在已有的客户端存活定时器上，不新起 timer——常驻唤醒一个都不该多。
- (void)considerIdleSpeech {
    [self consumeSpeechDebugTrigger];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    // 真正的判断最多 30 秒做一次，3 秒一跳的定时器上不必每次都算。
    if (now - self.lastIdleSpeechCheck < 30.0) return;
    self.lastIdleSpeechCheck = now;
    // agent 正在干活时闭嘴——工作文案优先级最高，闲话不许顶掉它。
    // 注意判断的是"在不在干活"，不是"状态卡在不在"：状态卡只要客户端活着就常驻，
    // 用它当闸门等于开着终端就永远不碎碎念。
    if ([self agentBusyForSpeech]) return;
    if (![self canSpeakNow]) return;

    // 安静多久才算"没人打扰"。复用无聊曲线那个缩放旋钮，测试时一并压缩。
    double scale = 1.0;
    id scaleValue = [NSUserDefaults.standardUserDefaults objectForKey:@"CCPetsBoredomScale"];
    if ([scaleValue isKindOfClass:NSNumber.class] && [scaleValue doubleValue] > 0) {
        scale = MIN([scaleValue doubleValue], 10.0);
    }
    PetSpeechRate rate = [self speechRate];
    NSTimeInterval quiet = self.lastAgentEventAt > 0 ? now - self.lastAgentEventAt : now;
    if (quiet < rate.quietSeconds * scale) return;

    // 不是每次够条件都说：概率化，免得变成整点报时。
    if (arc4random_uniform(100) >= rate.idleChancePercent) return;

    NSInteger hour = [NSCalendar.currentCalendar component:NSCalendarUnitHour fromDate:NSDate.date];
    NSTimeInterval sessionLength = self.sessionStartedAt > 0 ? now - self.sessionStartedAt : 0;
    if (hour >= 1 && hour < 5) [self speakWithTag:PetPhraseTagLateNight];
    else if (sessionLength > 90 * 60.0) [self speakWithTag:PetPhraseTagLongSession];
    else [self speakWithTag:PetPhraseTagIdle];
}
// 只在显著时刻说话，不是每个 agent 事件都冒泡。
- (void)considerSpeechForRecord:(NSDictionary *)record {
    self.lastAgentEventAt = NSDate.date.timeIntervalSince1970;
    NSString *tool = [record[@"tool"] isKindOfClass:NSString.class] ? record[@"tool"] : nil;
    if (tool.length > 0) self.lastSpeechTool = tool;
    NSString *state = [record[@"state"] isKindOfClass:NSString.class] ? record[@"state"] : @"";
    NSString *event = [record[@"event"] isKindOfClass:NSString.class] ? record[@"event"] : @"";
    BOOL failed = [record[@"failed"] boolValue];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;

    if ([event isEqualToString:@"SessionStart"]) {
        // 久别重逢：距上次会话超过 4 小时才算，不然每开一个终端都要寒暄一遍。
        BOOL longGap = self.sessionStartedAt <= 0 || now - self.sessionStartedAt > 4 * 3600.0;
        self.sessionStartedAt = now;
        self.consecutiveFailures = 0;
        if (longGap) [self speakWithTag:PetPhraseTagWake];
        return;
    }
    if (failed) {
        self.consecutiveFailures += 1;
        // 单次失败很常见，连续两次才值得出声。
        if (self.consecutiveFailures >= 2) [self speakWithTag:PetPhraseTagFail];
        return;
    }
    if ([state isEqualToString:@"completed"]) {
        self.consecutiveFailures = 0;
        NSInteger hour = [NSCalendar.currentCalendar component:NSCalendarUnitHour
            fromDate:NSDate.date];
        NSTimeInterval sessionLength = self.sessionStartedAt > 0 ? now - self.sessionStartedAt : 0;
        // 同一时刻可能同时满足几个情境，按"更值得一提"的顺序挑一个说，不叠着说。
        if (hour >= 1 && hour < 5) [self speakWithTag:PetPhraseTagLateNight];
        else if (sessionLength > 90 * 60.0) [self speakWithTag:PetPhraseTagLongSession];
        else [self speakWithTag:PetPhraseTagDone];
    }
}
#pragma mark - 宽度自适应

// 卡片和气泡都按文案实际宽度伸缩。固定宽度下"收工！"和"到处翻资料呢。"占一样长的条，
// 前者会拖着一大截空白，看着像没加载完。
// 用控件自己的 fittingSize 量，不要用 sizeWithAttributes:。
// NSTextField 的 cell 有一点内部留白，纯按字符串量出来的宽度会比控件真正需要的小几个点，
// 结果就是明明算着"刚好够"，显示出来最后一两个字变成省略号。
static CGFloat PetMeasuredLabelWidth(NSTextField *label) {
    if (label.stringValue.length == 0) return 0;
    return ceil(label.fittingSize.width) + 2;
}
// 状态卡：左内边距 20 + 文字 + 间隙 8 + 图标 34 + 右内边距 14。
- (void)resizeStatusCardToFitText {
    const CGFloat leading = 20, gap = 8, iconWidth = 34, trailing = 14;
    // 副行没内容时收成单行，而不是留一块空白。
    //
    // 台词全在 speech.txt 里，代码里没有兜底文案：用户把某个 state_ 小节清空了，
    // 副行就真的没有东西可显示。编辑器保存时会拦下这种文件，但外部编辑器绕得过去，
    // 所以显示层必须自己站得住。
    BOOL hasDetail = self.statusDetailLabel.stringValue.length > 0;
    CGFloat height = hasDetail ? PetStatusBodyHeight : PetStatusSingleLineHeight;
    CGFloat textWidth = PetMeasuredLabelWidth(self.statusTitleLabel);
    if (hasDetail) {
        textWidth = fmax(textWidth, PetMeasuredLabelWidth(self.statusDetailLabel));
    }
    CGFloat glassWidth = leading + textWidth + gap + iconWidth + trailing;
    glassWidth = fmax(210.0, fmin(glassWidth, 420.0));
    // 高度也要参与早退判断，否则单行/双行之间切换时尺寸不会更新。
    if (fabs(NSWidth(self.statusGlass.frame) - glassWidth) < 0.5 &&
        fabs(NSHeight(self.statusGlass.frame) - height) < 0.5) return;

    NSSize panelSize = NSMakeSize(glassWidth + 12, height + 12);
    [self.statusPanel setContentSize:panelSize];
    self.statusPanel.contentView.frame = NSMakeRect(0, 0, panelSize.width, panelSize.height);
    self.statusGlass.frame = NSMakeRect(6, 6, glassWidth, height);
    self.statusShadowView.frame = NSMakeRect(6, 6, glassWidth, height);
    // shadowPath 是按旧尺寸算死的，卡片变宽后不重算，阴影会留在原来的形状上。
    CGPathRef path = CGPathCreateWithRoundedRect(self.statusShadowView.bounds,
        height / 2.0, height / 2.0, NULL);
    self.statusShadowView.layer.shadowPath = path;
    CGPathRelease(path);

    CGFloat labelWidth = glassWidth - leading - gap - iconWidth - trailing;
    self.statusDetailLabel.hidden = !hasDetail;
    if (hasDetail) {
        self.statusTitleLabel.frame = NSMakeRect(leading, 34, labelWidth, 14);
        self.statusDetailLabel.frame = NSMakeRect(leading, 10, labelWidth, 22);
    } else {
        self.statusTitleLabel.frame = NSMakeRect(leading, (height - 14) / 2.0, labelWidth, 14);
    }
    self.statusIconButton.frame = NSMakeRect(glassWidth - trailing - iconWidth,
        (height - iconWidth) / 2.0, iconWidth, iconWidth);
    self.statusClickButton.frame = NSMakeRect(6, 6, glassWidth - 56, height);
}

// 独立气泡：左右各 16 内边距，没有图标。
- (void)resizeSpeechBubbleToFitText {
    const CGFloat padding = 16;
    CGFloat width = padding * 2 + PetMeasuredLabelWidth(self.speechLabel);
    width = fmax(96.0, fmin(width, 300.0));
    NSSize panelSize = NSMakeSize(width + 12, PetSpeechBodyHeight + 12);
    [self.speechPanel setContentSize:panelSize];
    self.speechPanel.contentView.frame = NSMakeRect(0, 0, panelSize.width, panelSize.height);
    self.speechGlass.frame = NSMakeRect(6, 6, width, PetSpeechBodyHeight);
    self.speechGlass.layer.cornerRadius = PetSpeechBodyHeight / 2.0;
    self.speechLabel.frame = NSMakeRect(padding, 10, width - padding * 2, 18);
}


// 面板底边到"最小那颗圆点底边"的距离。定位要拿它反推面板该放多高，
// 才能让圆点正好落在宠物头顶而不是悬在空中。
- (void)positionAgentStatus {
    NSRect petFrame = self.panel.frame;
    NSRect visible = (self.panel.screen ?: NSScreen.mainScreen).visibleFrame;
    NSSize size = self.statusPanel.frame.size;
    CGFloat x = NSMidX(petFrame) - size.width / 2.0;
    CGFloat aboveY = NSMaxY(petFrame) + 8;
    CGFloat belowY = NSMinY(petFrame) - size.height - 8;
    BOOL aboveFits = aboveY + size.height <= NSMaxY(visible) - 10;
    BOOL belowFits = belowY >= NSMinY(visible) + 10;
    self.statusBubbleAbove = aboveFits || !belowFits;
    CGFloat y = self.statusBubbleAbove ? aboveY : belowY;
    x = fmax(NSMinX(visible) + 10, fmin(x, NSMaxX(visible) - size.width - 10));
    y = fmax(NSMinY(visible) + 10, fmin(y, NSMaxY(visible) - size.height - 10));
    [self.statusPanel setFrameOrigin:NSMakePoint(x, y)];
}
- (void)scheduleQuotaDashboardHide {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideQuotaDashboardIfNeeded) object:nil];
    [self performSelector:@selector(hideQuotaDashboardIfNeeded) withObject:nil afterDelay:0.28];
}
- (void)hideQuotaDashboardIfNeeded {
    if (!self.pocketHovering && !self.dashboardHovering && !self.petDragging) {
        [self.quotaPanel orderOut:nil];
        [self rescheduleUsageTimer];
        [self.quotaClockTimer invalidate];
        self.quotaClockTimer = nil;
        [self updateSystemMetricsTimer];
    }
}
- (void)switchPetToID:(NSString *)petID {
    NSArray<NSDictionary *> *options = [self petOptions];
    NSDictionary *option = [self petOptionWithID:petID inOptions:options];
    if (!option) return;
    NSInteger spriteRowCount = [option[@"spriteRowCount"] integerValue] ?: 9;
    NSImage *image = LoadPetSpriteImage(option[@"path"], NSMakeSize(140, 150), spriteRowCount);
    if (!image) return;
    [self.petView applySheet:image petID:petID rowCount:spriteRowCount];
    PetPhrasesSetCurrentPetID(petID);
    [NSUserDefaults.standardUserDefaults setObject:petID forKey:@"CCPetsSelectedSprite"];
}
- (BOOL)deletePetWithID:(NSString *)petID {
    if (![petID hasPrefix:@"external:"]) return NO;
    NSArray<NSDictionary *> *options = [self petOptions];
    NSDictionary *option = [self petOptionWithID:petID inOptions:options];
    if (!option) return NO;

    NSString *name = [petID substringFromIndex:@"external:".length];
    if (name.length == 0 || [name containsString:@"/"] || [name isEqualToString:@"."] ||
        [name isEqualToString:@".."]) return NO;
    NSString *root = OwnPetsDirectory().stringByStandardizingPath;
    NSString *directory = [root stringByAppendingPathComponent:name].stringByStandardizingPath;
    NSString *optionDirectory = [[option[@"path"] stringByDeletingLastPathComponent] stringByStandardizingPath];
    if (![directory.stringByDeletingLastPathComponent isEqualToString:root] ||
        ![optionDirectory isEqualToString:directory]) return NO;

    NSError *error = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:directory error:&error]) {
        [self showUpdateAlertWithTitle:@"无法删除素材"
            message:error.localizedDescription ?: @"素材目录删除失败。"];
        return NO;
    }

    [self invalidatePetOptionsCache];
    if ([self.petView.currentPetID isEqualToString:petID]) {
        NSDictionary *fallback = [self petOptions].firstObject;
        if (fallback) [self switchPetToID:fallback[@"id"]];
        else {
            PetPhrasesSetCurrentPetID(nil);
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"CCPetsSelectedSprite"];
        }
    }
    return YES;
}
- (void)prepareAgentEventReader {
    NSString *path = AgentEventPath();
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    if (self.agentEventReaderInitialized) {
        if (size < self.agentEventOffset) {
            self.agentEventOffset = 0;
            [self.agentEventPartialLine setLength:0];
        }
        [self readNewAgentEvents];
        return;
    }
    self.agentEventReaderInitialized = YES;
    self.agentEventOffset = size;
    if (size > 0) {
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
        unsigned long long start = size > 65536 ? size - 65536 : 0;
        [handle seekToFileOffset:start];
        NSData *recent = [handle readDataToEndOfFile];
        [handle closeFile];
        [self processAgentEventData:recent ignoreFirstPartial:start > 0 recentOnly:YES];
    }
}
- (void)consumeAgentEventData:(NSData *)data {
    if (data.length == 0) return;
    [self.agentEventPartialLine appendData:data];
    const uint8_t *bytes = self.agentEventPartialLine.bytes;
    NSUInteger lineStart = 0;
    for (NSUInteger index = 0; index < self.agentEventPartialLine.length; index++) {
        if (bytes[index] != '\n') continue;
        NSData *lineData = [self.agentEventPartialLine subdataWithRange:NSMakeRange(lineStart, index - lineStart)];
        [self processAgentEventData:lineData ignoreFirstPartial:NO recentOnly:NO];
        lineStart = index + 1;
    }
    if (lineStart > 0) {
        NSData *remainder = [self.agentEventPartialLine subdataWithRange:
            NSMakeRange(lineStart, self.agentEventPartialLine.length - lineStart)];
        self.agentEventPartialLine = [remainder mutableCopy];
    }
    if (self.agentEventPartialLine.length > 1024 * 1024) [self.agentEventPartialLine setLength:0];
}
- (void)processAgentEventData:(NSData *)data ignoreFirstPartial:(BOOL)ignoreFirstPartial recentOnly:(BOOL)recentOnly {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) return;
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSTimeInterval cutoff = [NSDate.date timeIntervalSince1970] - 5;
    for (NSUInteger index = 0; index < lines.count; index++) {
        if (ignoreFirstPartial && index == 0) continue;
        NSData *lineData = [lines[index] dataUsingEncoding:NSUTF8StringEncoding];
        if (lineData.length == 0) continue;
        NSDictionary *record = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
        if (![record isKindOfClass:NSDictionary.class]) continue;
        if (recentOnly && [record[@"timestamp"] doubleValue] < cutoff) continue;
        [self trackAgentSessionRecord:record];
        NSString *event = record[@"event"];
        NSString *state = [record[@"state"] isKindOfClass:NSString.class] ? record[@"state"] : @"";
        if ([event isKindOfClass:NSString.class]) {
            if (!self.pendingApprovalRecords) {
                self.pendingApprovalRecords = [NSMutableDictionary dictionary];
            }
            [self prunePendingApprovalRecords];
            NSString *approvalKey = [self approvalKeyForRecord:record];
            BOOL manualApproval = [state isEqualToString:@"approval"];
            if (manualApproval) {
                self.pendingApprovalRecords[approvalKey] = record;
            } else {
                [self.pendingApprovalRecords removeObjectForKey:approvalKey];
            }
            [self prunePendingApprovalRecords];
            // 多会话下不能让一个未处理的审批全局挡住其他 Agent 的所有 Hook。每条事件
            // 都正常驱动气泡和动画；仍在等待的审批保留在多会话记录中供用户回跳。
            [self displayAgentRecord:record notify:YES];
        }
    }
    [self refreshApprovalBadge];
}
- (void)readNewAgentEvents {
    NSString *path = AgentEventPath();
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    if (size < self.agentEventOffset) self.agentEventOffset = 0;
    if (size == self.agentEventOffset) return;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return;
    unsigned long long start = self.agentEventOffset;
    [handle seekToFileOffset:start];
    NSData *data = [handle readDataToEndOfFile];
    [handle closeFile];
    self.agentEventOffset = start + data.length;
    [self consumeAgentEventData:data];
}
- (void)startAgentEventReader {
    if (self.agentEventSource) return;
    NSString *path = AgentEventPath();
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil];
    int creator = open(path.fileSystemRepresentation, O_CREAT | O_WRONLY | O_CLOEXEC, S_IRUSR | S_IWUSR);
    if (creator >= 0) close(creator);
    int descriptor = open(path.fileSystemRepresentation, O_EVTONLY | O_CLOEXEC);
    if (descriptor < 0) return;
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, descriptor,
        DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_DELETE |
        DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE,
        dispatch_get_main_queue());
    if (!source) {
        close(descriptor);
        return;
    }
    self.agentEventSource = source;
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_source_t currentSource = strongSelf.agentEventSource;
        if (!currentSource) return;
        unsigned long flags = dispatch_source_get_data(currentSource);
        [strongSelf readNewAgentEvents];
        if (flags & (DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE)) {
            strongSelf.agentEventSource = nil;
            dispatch_source_cancel(currentSource);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                dispatch_get_main_queue(), ^{ [weakSelf startAgentEventReader]; });
        }
    });
    dispatch_source_set_cancel_handler(source, ^{ close(descriptor); });
    dispatch_resume(source);
    [self prepareAgentEventReader];
}
- (void)ensureAgentEventReader:(id)sender {
    if (!self.agentEventSource) [self startAgentEventReader];
}
// 在线判定合并两个信号：包装脚本写出的客户端 pid 文件，以及该 provider 最近是否还在
// 发事件。只看前者会把直接跑 claude / codex 的会话误判成离线；只看后者则在客户端退出后
// 还要挂满一整个静默窗口。额度数据本身不是在线信号——它一直缓存着，用它判定会恒亮。
- (void)updateQuotaLiveState {
    NSMutableSet<NSString *> *online = [self.liveClientProviders mutableCopy] ?: [NSMutableSet set];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    for (NSString *provider in self.providerActivityAt) {
        NSTimeInterval last = [self.providerActivityAt[provider] doubleValue];
        if (now - last < AgentStatusInactivityInterval) [online addObject:provider];
    }
    NSInteger count = MAX(self.liveClientCount, (NSInteger)online.count);
    if (self.quotaView.activeAgentCount == count &&
        [self.quotaView.liveProviders isEqualToSet:online] &&
        self.quotaView.hasUnlabeledClient == self.hasUnlabeledClient) return;
    self.quotaView.activeAgentCount = count;
    self.quotaView.liveProviders = online;
    self.quotaView.hasUnlabeledClient = self.hasUnlabeledClient;
    self.quotaView.needsDisplay = YES;
}
// 客户端是否真的还在跑。只问 kill(pid, 0) 不够：关掉终端窗口只是销毁 pty，claude /
// codex（Node 进程）不一定跟着 SIGHUP 退出，会变成脱离控制终端的孤儿继续活着。那样
// pid 一直存在，会话就永久挂在"在线"上，最近会话列表里那条也永远不消失。
// 所以再看两件事：进程是否还有控制终端；以及它是不是仍然是 pid 文件里记的那个 TTY
// （pty 会被新开的窗口复用，光看"有 tty"挡不住换了主人的情况）。
// recordedTTY 为空是 1.0.2 及更早的老客户端，只能退回"有控制终端"这一条。
static BOOL ClientProcessAlive(pid_t pid, NSString *recordedTTY) {
    if (pid <= 1) return NO;
    struct kinfo_proc info;
    size_t length = sizeof(info);
    int name[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    if (sysctl(name, 4, &info, &length, NULL, 0) != 0 || length == 0) return NO;
    if (info.kp_proc.p_stat == SZOMB) return NO;
    dev_t device = info.kp_eproc.e_tdev;
    if (device == NODEV) return NO;
    if (recordedTTY.length == 0) return YES;
    const char *current = devname(device, S_IFCHR);
    if (!current) return NO;
    return [recordedTTY isEqualToString:@(current).lastPathComponent];
}
- (void)refreshClientLifecycle:(id)sender {
    [self considerIdleSpeech];
    [self prunePendingApprovalRecords];
    NSString *clientName = [NSString stringWithFormat:@"cc-pets-%u-clients", getuid()];
    NSString *clientDirectory = [PetStateDirectory() stringByAppendingPathComponent:clientName];
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:clientDirectory error:nil] ?: @[];
    NSInteger liveClients = 0;
    NSMutableSet<NSString *> *providers = [NSMutableSet set];
    NSMutableSet<NSString *> *sessionKeys = [NSMutableSet set];
    BOOL unlabeled = NO;
    for (NSString *entry in entries) {
        pid_t pid = (pid_t)entry.intValue;
        NSString *path = [clientDirectory stringByAppendingPathComponent:entry];
        // 包装脚本会把 provider 名写进 pid 文件第一行、TTY 写进第二行。1.0.2 及更早
        // 的版本只 touch 出空文件，升级后仍在运行的老客户端读出来是空的：这类当作
        // “身份不明”，只要还有一个就不清场，避免把仍然活着的会话误判成已退出。
        NSString *contents = [NSString stringWithContentsOfFile:path
            encoding:NSUTF8StringEncoding error:nil] ?: @"";
        NSArray<NSString *> *lines = [contents componentsSeparatedByCharactersInSet:
            NSCharacterSet.newlineCharacterSet];
        NSString *label = [lines.firstObject
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *tty = lines.count > 1 ? [lines[1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
        if (!ClientProcessAlive(pid, tty)) {
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            continue;
        }
        liveClients += 1;
        if (label.length > 0 && label.length <= 32) [providers addObject:label];
        else unlabeled = YES;
        NSString *sessionKey = [self onlineAgentSessionKeyForProvider:label tty:tty];
        if (sessionKey.length > 0) [sessionKeys addObject:sessionKey];
    }
    // 包装脚本启动的客户端有精确的退出信号：pid 文件被回收。这一段不该被为"直接跑
    // claude / codex"准备的 60 秒活跃度宽限盖住，否则退出后还要挂满一分钟才转离线。
    // 因此某一家的 pid 文件一旦从有变无，立刻丢掉它的活跃度记录；从来没有过 pid 文件
    // 的（直接启动）不受影响，继续走宽限。
    NSSet<NSString *> *previousProviders = self.liveClientProviders;
    self.liveClientCount = liveClients;
    self.liveClientProviders = providers;
    self.liveAgentSessionKeys = sessionKeys;
    self.hasUnlabeledClient = unlabeled;
    [self pruneOfflineAgentSessionRecords];
    for (NSString *provider in previousProviders) {
        if (![providers containsObject:provider]) {
            [self.providerActivityAt removeObjectForKey:provider];
        }
    }
    [self updateQuotaLiveState];
    [self refreshDetectedProviders];
    [self hideAgentStatusIfClientGone];
    [self checkStalledAgentSessions];
    [self refreshApprovalBadge];
    // 启动模式在应用生命周期内保持不变。手动启动的桌宠即使后来检测到
    // Codex/Claude 客户端，也不应被转成 CLI 托管模式并随客户端退出。
    if (liveClients == 0 && self.managedByCLI) [NSApp terminate:nil];
}
// 面板高度取决于渲染几张额度卡。quotaRoot / 毛玻璃 / quotaView 三层都是固定 frame、
// 没有 autoresizingMask，所以统一在这里按 contentView 的 subviews 铺一遍，避免漏掉一层。
- (void)resizeQuotaDashboard {
    NSSize size = NSMakeSize(QuotaLogicalWidth * QuotaScale,
        QuotaLogicalHeightForProviderCount([self.quotaView visibleProviders].count) * QuotaScale);
    if (NSEqualSizes(self.quotaPanel.frame.size, size)) return;
    // 只改 size 不动 origin：窗口 frame 的原点在左下，面板会朝上收缩，底边保持贴着宠物。
    NSRect frame = self.quotaPanel.frame;
    frame.size = size;
    [self.quotaPanel setFrame:frame display:NO];
    NSRect bounds = NSMakeRect(0, 0, size.width, size.height);
    self.quotaPanel.contentView.frame = bounds;
    for (NSView *subview in self.quotaPanel.contentView.subviews) subview.frame = bounds;
    self.quotaView.needsDisplay = YES;
    if (self.quotaPanel.isVisible) [self positionQuotaDashboard];
}
// 额度字典"非空"不等于"这家真的在用"。Claude 的 reader 刻意永不返回 nil（见
// CCPetsUsage.m 里 -[ClaudeUsageReader refresh] 的注释：Token 是本机从转录数出来的，
// 不能被缺失的官方额度一票否决），什么都没有时照样返回
// {fiveHour: NSNull, week: NSNull, tokenUsage: 全 0}，count 恒为 3。
// 拿 count > 0 当证据，Claude 就永远算"检测到"，卡片再也去不掉。这里只认实质证据：
// 官方额度块真实存在，或者本机统计出过非零 Token。Codex 侧同一套判据也成立。
static BOOL UsageShowsProviderInUse(NSDictionary *usage) {
    if (usage.count == 0) return NO;
    for (NSString *key in @[@"fiveHour", @"week"]) {
        if ([usage[key] isKindOfClass:NSDictionary.class]) return YES;
    }
    NSDictionary *tokenUsage = [usage[@"tokenUsage"] isKindOfClass:NSDictionary.class]
        ? usage[@"tokenUsage"] : nil;
    for (NSString *key in @[@"fiveHour", @"week", @"today", @"recentWeek"]) {
        NSDictionary *totals = [tokenUsage[key] isKindOfClass:NSDictionary.class]
            ? tokenUsage[key] : nil;
        if ([totals[@"total_tokens"] doubleValue] > 0) return YES;
    }
    return NO;
}
// "这台机器上有哪几家 CLI"。只增不减，并持久化：探测会瞬时失败（配置目录被改名、
// 外置盘没挂上），卡片当着用户的面消失比多留一张更像 bug。
- (void)refreshDetectedProviders {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableSet<NSString *> *detected = [NSMutableSet setWithArray:
        [defaults arrayForKey:DetectedProvidersKey] ?: @[]];
    if (CodexCLIDetected()) [detected addObject:@"Codex"];
    if (ClaudeCLIDetected()) [detected addObject:@"Claude"];
    // 正在跑的客户端和已经拿到的额度数据都是比目录探测更硬的证据：探测漏判也不能
    // 把一个正在工作、或者明明有额度的 provider 藏起来。
    if (self.liveClientProviders.count > 0) [detected unionSet:self.liveClientProviders];
    if (UsageShowsProviderInUse(self.quotaView.codexUsage)) [detected addObject:@"Codex"];
    if (UsageShowsProviderInUse(self.quotaView.claudeUsage)) [detected addObject:@"Claude"];
    if (self.quotaView.detectedProviders &&
        [detected isEqualToSet:self.quotaView.detectedProviders]) return;
    self.quotaView.detectedProviders = detected;
    [defaults setObject:detected.allObjects forKey:DetectedProvidersKey];
    [self resizeQuotaDashboard];
    self.quotaView.needsDisplay = YES;
}
- (void)applyCodexUsage:(NSDictionary *)codexUsage claudeUsage:(NSDictionary *)claudeUsage {
    self.quotaView.codexUsage = codexUsage;
    self.quotaView.claudeUsage = claudeUsage;
    [self refreshDetectedProviders];
    NSDictionary *history = RecordQuotaHistory(self.quotaView.codexUsage,
        self.quotaView.claudeUsage);
    self.quotaView.codexHistory = QuotaHistorySeries(history, @"codex");
    self.quotaView.claudeHistory = QuotaHistorySeries(history, @"claude");
    self.quotaView.lastUpdatedAt = NSDate.date.timeIntervalSince1970;
    self.quotaView.needsDisplay = YES;
}
- (void)refreshUsage:(id)sender {
    self.lastUsageRefreshAt = NSDate.date.timeIntervalSince1970;
    [self.usageMonitor refreshNow];
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.usageMonitor stop];
    [self.systemMetricsTimer invalidate];
    self.systemMetricsTimer = nil;
    if (self.agentEventSource) {
        dispatch_source_cancel(self.agentEventSource);
        self.agentEventSource = nil;
    }
}
@end
