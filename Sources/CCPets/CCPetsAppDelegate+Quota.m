// 额度面板、用量刷新与系统指标。
#import "CCPetsAppDelegate+Private.h"
#import "CCPetsWorkbench.h"

@implementation AppDelegate (Quota)
- (void)rescheduleUsageTimer {
    NSTimeInterval interval = self.quotaPanel.isVisible
        ? UsageRefreshIntervalVisible : UsageRefreshIntervalHidden;
    if (self.usageTimer.isValid && self.usageTimer.timeInterval == interval) return;
    [self.usageTimer invalidate];
    self.usageTimer = [NSTimer scheduledTimerWithTimeInterval:interval target:self
        selector:@selector(refreshUsage:) userInfo:nil repeats:YES];
    self.usageTimer.tolerance = interval * 0.2;
}
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
// 在线判定合并两个信号：包装脚本写出的客户端 pid 文件，以及该 provider 最近是否还在
// 发事件。只看前者会把直接跑 claude / codex 的会话误判成离线；只看后者则在客户端退出后
// 还要挂满一整个静默窗口。额度数据本身不是在线信号——它一直缓存着，用它判定会恒亮。
- (void)updateQuotaLiveState {
    NSMutableSet<NSString *> *online = [self.liveClientProviders mutableCopy] ?: [NSMutableSet set];
    NSMutableSet<NSString *> *onlineProfiles = [self.liveClientProfileIDs mutableCopy]
        ?: [NSMutableSet set];
    NSMutableSet<NSString *> *unscopedProviders = [self.liveUnscopedClientProviders mutableCopy]
        ?: [NSMutableSet set];
    NSMutableSet<NSString *> *approvalProfiles = [NSMutableSet set];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    for (NSString *provider in self.providerActivityAt) {
        NSTimeInterval last = [self.providerActivityAt[provider] doubleValue];
        if (now - last < AgentStatusInactivityInterval) [online addObject:provider];
    }
    for (NSDictionary *record in self.agentSessionRecords.allValues) {
        NSString *profileID = [record[@"profileId"] isKindOfClass:NSString.class]
            ? record[@"profileId"] : nil;
        if (![self isAgentSessionRecordLive:record]) continue;
        if (profileID.length > 0) {
            [onlineProfiles addObject:profileID];
            if ([record[@"state"] isEqualToString:@"approval"]) [approvalProfiles addObject:profileID];
        } else {
            NSString *provider = [record[@"provider"] isKindOfClass:NSString.class]
                ? record[@"provider"] : nil;
            if (provider.length > 0) [unscopedProviders addObject:provider];
        }
    }
    NSInteger count = MAX(self.liveClientCount, (NSInteger)online.count);
    if (self.quotaView.activeAgentCount == count &&
        [self.quotaView.liveProviders isEqualToSet:online] &&
        [self.quotaView.liveProfileIDs isEqualToSet:onlineProfiles] &&
        [self.quotaView.liveUnscopedProviders isEqualToSet:unscopedProviders] &&
        [self.quotaView.pendingApprovalProfileIDs isEqualToSet:approvalProfiles] &&
        self.quotaView.hasUnlabeledClient == self.hasUnlabeledClient) return;
    self.quotaView.activeAgentCount = count;
    self.quotaView.liveProviders = online;
    self.quotaView.liveProfileIDs = onlineProfiles;
    self.quotaView.liveUnscopedProviders = unscopedProviders;
    self.quotaView.pendingApprovalProfileIDs = approvalProfiles;
    self.quotaView.hasUnlabeledClient = self.hasUnlabeledClient;
    self.quotaView.needsDisplay = YES;
    [NSNotificationCenter.defaultCenter postNotificationName:CCPetsWorkbenchQuotasDidChangeNotification object:nil];
}
// 面板高度取决于渲染几张额度卡。调整玻璃容器后，内部内容随 autoresizingMask 铺满。
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
// 卡片来自自动登记的官方 Home 与用户明确登记的自定义 Home。自定义目录不会被扫描；
// 目录暂时不可用时 profile 仍留在注册表，所以卡片也不会抖动消失。
- (void)refreshDetectedProviders {
    // 运行期间后来安装 CLI、或首次生成官方 Home 时也应自动出现卡片；只检查两个
    // 官方路径，自定义 Home 仍必须从主窗口的多账号页手动添加。
    NSString *profileError = nil;
    if (!CCPetsEnsureOfficialDefaultProfiles(&profileError) && profileError.length > 0) {
        fprintf(stderr, "%s\n", profileError.UTF8String);
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableSet<NSString *> *detected = [NSMutableSet set];
    for (NSDictionary *profile in CCPetsProfiles()) {
        if ([profile[@"provider"] isEqualToString:CCPetsProfileProviderCodex]) [detected addObject:@"Codex"];
        if ([profile[@"provider"] isEqualToString:CCPetsProfileProviderClaude]) [detected addObject:@"Claude"];
    }
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
    history = RecordProfileQuotaHistory(self.usageMonitor.profileUsages, self.usageMonitor.profiles);
    NSMutableDictionary *profileHistories = [NSMutableDictionary dictionary];
    for (NSDictionary *profile in self.usageMonitor.profiles) {
        NSString *profileID = profile[@"id"];
        if (profileID.length > 0) profileHistories[profileID] = QuotaHistorySeriesForProfile(history, profileID);
    }
    self.quotaView.profileHistories = profileHistories;
    self.quotaView.codexHistory = QuotaHistorySeries(history, @"codex");
    self.quotaView.claudeHistory = QuotaHistorySeries(history, @"claude");
    self.quotaView.lastUpdatedAt = NSDate.date.timeIntervalSince1970;
    self.quotaView.needsDisplay = YES;
    [NSNotificationCenter.defaultCenter postNotificationName:CCPetsWorkbenchQuotasDidChangeNotification object:nil];
}
- (void)refreshUsage:(id)sender {
    self.lastUsageRefreshAt = NSDate.date.timeIntervalSince1970;
    [self.usageMonitor refreshNow];
}
@end
