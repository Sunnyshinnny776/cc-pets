// 额度面板、用量刷新与系统指标。
#import "CCPetsAppDelegate+Private.h"

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
@end
