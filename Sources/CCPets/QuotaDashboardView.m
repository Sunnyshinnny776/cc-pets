#import "QuotaDashboardView.h"

const CGFloat QuotaLogicalWidth = 760;
const CGFloat QuotaLogicalHeight = 590;
const CGFloat QuotaScale = 0.58;

// 面板高度按"检测到几家 CLI"变化，所以纵向布局不再是一堆绝对坐标，而是自上而下的分段：
// 标题区 → 汇总条 → N × 额度卡 → 脚注区，块之间统一留 QuotaBlockGap。
// QuotaLogicalHeight 保留为两家都装时的高度（590），既是历史默认值，也是预览图尺寸。
static const CGFloat QuotaHeaderHeight = 106;
static const CGFloat QuotaSummaryHeight = 112;
static const CGFloat QuotaCardHeight = 152;
static const CGFloat QuotaBlockGap = 12;
static const CGFloat QuotaFooterHeight = 44;
// 两家都没装时的精简态：只留标题区、三行说明和脚注，汇总条和额度卡整块去掉——
// 没有 provider 的"今日用量/近 7 天"是两行 0，比不显示更让人以为是坏了。
static const CGFloat QuotaEmptyNoticeHeight = 76;

CGFloat QuotaLogicalHeightForProviderCount(NSUInteger count) {
    if (count == 0) return QuotaHeaderHeight + QuotaEmptyNoticeHeight + QuotaFooterHeight;
    return QuotaHeaderHeight + QuotaSummaryHeight +
        count * (QuotaBlockGap + QuotaCardHeight) + QuotaFooterHeight;
}

NSImage *OfficialAppIcon(NSString *bundleIdentifier, NSString *resourceName) {
    NSURL *appURL = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:bundleIdentifier];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    if (appURL) {
        NSBundle *bundle = [NSBundle bundleWithURL:appURL];
        NSString *resourcePath = [bundle pathForResource:resourceName.stringByDeletingPathExtension
            ofType:resourceName.pathExtension];
        if (resourcePath.length > 0) [paths addObject:resourcePath];
    }
    NSString *applicationName = [bundleIdentifier containsString:@"anthropic"] ? @"Claude.app" : @"ChatGPT.app";
    [paths addObject:[@"/Applications" stringByAppendingPathComponent:
        [applicationName stringByAppendingPathComponent:[@"Contents/Resources" stringByAppendingPathComponent:resourceName]]]];
    [paths addObject:[[NSHomeDirectory() stringByAppendingPathComponent:@"Applications"] stringByAppendingPathComponent:
        [applicationName stringByAppendingPathComponent:[@"Contents/Resources" stringByAppendingPathComponent:resourceName]]]];
    for (NSString *path in paths) {
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
        if (image) return image;
    }
    return appURL ? [NSWorkspace.sharedWorkspace iconForFile:appURL.path] : nil;
}

@implementation QuotaDashboardView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        NSTrackingArea *tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
            options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved |
                    NSTrackingActiveAlways | NSTrackingInVisibleRect
            owner:self userInfo:nil];
        [self addTrackingArea:tracking];
    }
    return self;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)mouseEntered:(NSEvent *)event {
    if (self.hoverChanged) self.hoverChanged(YES);
    [self mouseMoved:event];
}
- (void)mouseExited:(NSEvent *)event {
    self.refreshHovered = NO;
    self.refreshPressed = NO;
    [NSCursor.arrowCursor set];
    self.needsDisplay = YES;
    if (self.hoverChanged) self.hoverChanged(NO);
}
// detectedProviders 未赋值时按"两家都有"渲染。这是刻意的兜底：探测是 App 侧的额外信号，
// 拿不到时宁可多画一张卡，也不要让有额度的用户看不到自己的卡片。
- (NSArray<NSString *> *)visibleProviders {
    NSArray<NSString *> *order = @[@"Codex", @"Claude"];
    if (!self.detectedProviders) return order;
    NSMutableArray<NSString *> *visible = [NSMutableArray array];
    for (NSString *name in order) {
        if ([self.detectedProviders containsObject:name]) [visible addObject:name];
    }
    return visible;
}
- (CGFloat)logicalHeight {
    return QuotaLogicalHeightForProviderCount([self visibleProviders].count);
}
- (NSRect)logicalRefreshRect { return NSMakeRect(QuotaLogicalWidth - 54, [self logicalHeight] - 52, 34, 32); }
- (NSRect)refreshRect {
    NSRect logical = [self logicalRefreshRect];
    return NSMakeRect(logical.origin.x * QuotaScale, logical.origin.y * QuotaScale,
        logical.size.width * QuotaScale, logical.size.height * QuotaScale);
}
- (NSRect)logicalSummaryRect {
    return NSMakeRect(20, [self logicalHeight] - QuotaHeaderHeight - QuotaSummaryHeight,
        QuotaLogicalWidth - 40, QuotaSummaryHeight);
}
// 刷新时间挪去了右上角，这一版块整宽留给两个统计格，各占一半。
- (NSRect)logicalSummaryCellRectAtIndex:(NSUInteger)index {
    NSRect summary = [self logicalSummaryRect];
    CGFloat width = NSWidth(summary) / 2;
    return index < 2
        ? NSMakeRect(NSMinX(summary) + index * width, NSMinY(summary), width, NSHeight(summary))
        : NSZeroRect;
}
- (void)mouseMoved:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    BOOL hovering = NSPointInRect(point, [self refreshRect]);
    if (hovering != self.refreshHovered) {
        self.refreshHovered = hovering;
        self.needsDisplay = YES;
    }
    if (hovering) [NSCursor.pointingHandCursor set];
    else [NSCursor.arrowCursor set];
}
- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(point, [self refreshRect])) {
        self.refreshPressed = YES;
        self.needsDisplay = YES;
    }
}
- (void)mouseUp:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    BOOL shouldRefresh = self.refreshPressed && NSPointInRect(point, [self refreshRect]);
    self.refreshPressed = NO;
    if (shouldRefresh) {
        if (self.refreshRequested) self.refreshRequested();
        self.refreshedUntil = NSDate.date.timeIntervalSince1970 + 1.2;
        [[NSHapticFeedbackManager defaultPerformer] performFeedbackPattern:NSHapticFeedbackPatternAlignment
            performanceTime:NSHapticFeedbackPerformanceTimeNow];
        [self performSelector:@selector(clearRefreshConfirmation) withObject:nil afterDelay:1.2];
    }
    self.needsDisplay = YES;
}
- (void)clearRefreshConfirmation {
    self.refreshedUntil = 0;
    self.needsDisplay = YES;
}
- (NSDictionary *)quota:(NSDictionary *)usage key:(NSString *)key {
    id value = usage[key];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
- (NSDictionary *)tokenTotals:(NSDictionary *)usage key:(NSString *)key {
    NSDictionary *tokenUsage = [usage[@"tokenUsage"] isKindOfClass:NSDictionary.class]
        ? usage[@"tokenUsage"] : nil;
    return [tokenUsage[key] isKindOfClass:NSDictionary.class] ? tokenUsage[key] : nil;
}
- (NSString *)formattedTokenValue:(double)value {
    if (value >= 1000000000) return [NSString stringWithFormat:@"%.2fB", value / 1000000000.0];
    if (value >= 1000000) return [NSString stringWithFormat:@"%.2fM", value / 1000000.0];
    if (value >= 1000) return [NSString stringWithFormat:@"%.1fK", value / 1000.0];
    return [NSString stringWithFormat:@"%.0f", value];
}
- (NSString *)formattedTokenCount:(NSDictionary *)totals {
    NSNumber *number = [totals[@"total_tokens"] isKindOfClass:NSNumber.class]
        ? totals[@"total_tokens"] : nil;
    return number ? [self formattedTokenValue:number.doubleValue] : @"--";
}
- (NSString *)formattedRequestCount:(NSDictionary *)totals {
    NSNumber *number = [totals[@"request_count"] isKindOfClass:NSNumber.class]
        ? totals[@"request_count"] : nil;
    return number ? [NSNumberFormatter localizedStringFromNumber:number
        numberStyle:NSNumberFormatterDecimalStyle] : @"--";
}
- (NSDictionary *)comparisonForCurrent:(double)current previous:(double)previous
    color:(NSColor *)color {
    if (previous <= 0) {
        return @{ @"text": current > 0 ? @"较上月同期 新增" : @"较上月同期 持平",
            @"color": current > 0 ? color : self.secondaryColor };
    }
    double change = (current - previous) * 100.0 / previous;
    if (fabs(change) < 0.05) {
        return @{ @"text": @"较上月同期 持平", @"color": self.secondaryColor };
    }
    return @{ @"text": [NSString stringWithFormat:@"较上月同期 %@%.1f%%",
        change > 0 ? @"↑" : @"↓", fabs(change)], @"color": color };
}
// 输入取 total - output，而不是把几个 input_* 字段加起来：两家的包含关系是相反的。
// Codex 的 cached_input_tokens 是 input_tokens 的子集（实测 input+output == total），
// 相加会把缓存部分算两遍；Claude 的 input_tokens 不含缓存读写，两者是并列项，不加又会漏。
// total - output 对两家都成立，也保证"输入 + 输出"正好等于卡片上那个已用 Token。
- (NSString *)formattedTokenSplit:(NSDictionary *)totals wantsOutput:(BOOL)wantsOutput {
    NSNumber *total = [totals[@"total_tokens"] isKindOfClass:NSNumber.class]
        ? totals[@"total_tokens"] : nil;
    if (!total) return @"--";
    NSNumber *output = [totals[@"output_tokens"] isKindOfClass:NSNumber.class]
        ? totals[@"output_tokens"] : nil;
    double outputValue = output ? output.doubleValue : 0;
    return [self formattedTokenValue:
        wantsOutput ? outputValue : fmax(0, total.doubleValue - outputValue)];
}
// 两个窗口共用。resets_at 是整分对齐的，带秒只会多占宽度。
- (NSString *)clockText:(NSTimeInterval)value {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    formatter.timeZone = NSTimeZone.localTimeZone;
    formatter.dateFormat = @"M/d HH:mm";
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:value]];
}
- (NSString *)resetText:(NSDictionary *)quota {
    NSNumber *reset = [quota[@"resets_at"] isKindOfClass:NSNumber.class] ? quota[@"resets_at"] : nil;
    return reset ? [self clockText:reset.doubleValue] : @"--";
}
// 汇总条的最近 7 天是共享的自然日口径。优先显示聚合结果携带的真实边界；兼容旧缓存时，
// 再按同一规则（含今天在内的 7 个自然日）现场计算，避免界面暂时退回到没有起期。
- (NSString *)recentWeekUsageLabel {
    NSNumber *start = nil;
    for (NSDictionary *usage in @[self.codexUsage ?: @{}, self.claudeUsage ?: @{}]) {
        NSDictionary *tokenUsage = [usage[@"tokenUsage"] isKindOfClass:NSDictionary.class]
            ? usage[@"tokenUsage"] : nil;
        if ([tokenUsage[@"recentWeekStartsAt"] isKindOfClass:NSNumber.class]) {
            start = tokenUsage[@"recentWeekStartsAt"];
            break;
        }
    }
    if (!start) {
        NSCalendar *calendar = NSCalendar.currentCalendar;
        NSDate *midnight = [calendar startOfDayForDate:NSDate.date];
        NSDate *date = [calendar dateByAddingUnit:NSCalendarUnitDay value:-6 toDate:midnight
            options:0];
        start = @((date ?: midnight).timeIntervalSince1970);
    }
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    formatter.timeZone = NSTimeZone.localTimeZone;
    formatter.dateFormat = @"yyyy-MM-dd";
    return [NSString stringWithFormat:@"近 7 天累计用量（%@ 至今·滚动记录）",
        [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:start.doubleValue]]];
}
// 在线 = 这一家还有活着的客户端，和有没有额度数据无关：额度会一直缓存着，
// 拿它当在线信号会恒亮。身份不明的老客户端无法归属到某一家，保守地都算在线。
- (BOOL)isProviderOnline:(NSString *)name {
    return [self.liveProviders containsObject:name] || self.hasUnlabeledClient;
}
- (NSColor *)primaryColor { return [NSColor colorWithWhite:0.97 alpha:1]; }
- (NSColor *)secondaryColor { return [NSColor colorWithWhite:0.68 alpha:1]; }
- (NSColor *)accentColor { return [NSColor colorWithRed:0.30 green:0.82 blue:0.90 alpha:1]; }
// 有 Agent 在线才用绿色，否则整块转灰，避免"暂无 Agent 在线"配一个绿点。
- (NSColor *)agentStatusColor {
    return self.activeAgentCount > 0 ? NSColor.systemGreenColor : self.secondaryColor;
}
- (void)drawSystemMetricsEndingAtX:(CGFloat)rightEdge y:(CGFloat)y {
    NSMutableArray<NSDictionary *> *metrics = [NSMutableArray array];
    if (self.systemCPUEnabled) {
        NSString *value = self.systemCPUPercent
            ? [NSString stringWithFormat:@"%.0f%%", self.systemCPUPercent.doubleValue] : @"--";
        [metrics addObject:@{@"symbol": @"cpu", @"label": [NSString stringWithFormat:@"CPU  %@", value],
            @"color": [NSColor colorWithRed:245.0 / 255.0 green:166.0 / 255.0
                blue:35.0 / 255.0 alpha:1]}];
    }
    if (self.systemTemperatureEnabled) {
        NSString *value = self.systemTemperatureCelsius
            ? [NSString stringWithFormat:@"%.0f°C", self.systemTemperatureCelsius.doubleValue] : @"--°C";
        double temperature = self.systemTemperatureCelsius.doubleValue;
        NSColor *color = temperature >= 90 ? NSColor.systemRedColor :
            (temperature >= 80 ? [NSColor colorWithRed:1.00 green:0.35 blue:0.16 alpha:1] :
                [NSColor colorWithRed:1.00 green:107.0 / 255.0 blue:74.0 / 255.0 alpha:1]);
        [metrics addObject:@{@"symbol": @"thermometer.medium", @"label": value,
            @"color": color}];
    }
    if (self.systemMemoryEnabled) {
        NSString *value = self.systemMemoryPercent
            ? [NSString stringWithFormat:@"%.0f%%", self.systemMemoryPercent.doubleValue] : @"--";
        [metrics addObject:@{@"symbol": @"memorychip", @"label": [NSString stringWithFormat:@"MEM  %@", value],
            @"color": [NSColor colorWithRed:32.0 / 255.0 green:214.0 / 255.0
                blue:165.0 / 255.0 alpha:1]}];
    }
    NSFont *font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    NSMutableAttributedString *statusLine = [NSMutableAttributedString new];
    for (NSUInteger index = 0; index < metrics.count; index++) {
        NSDictionary *metric = metrics[index];
        NSString *label = metric[@"label"];
        NSColor *color = metric[@"color"];
        NSDictionary *attributes = @{NSFontAttributeName: font,
            NSForegroundColorAttributeName: color};
        NSImage *icon = [NSImage imageWithSystemSymbolName:metric[@"symbol"]
            accessibilityDescription:label];
        NSImageSymbolConfiguration *sizeConfiguration =
            [NSImageSymbolConfiguration configurationWithPointSize:
                [metric[@"symbol"] isEqualToString:@"thermometer.medium"] ? 16 : 14
                weight:NSFontWeightSemibold];
        NSImageSymbolConfiguration *colorConfiguration =
            [NSImageSymbolConfiguration configurationWithHierarchicalColor:metric[@"color"]];
        icon = [icon imageWithSymbolConfiguration:
            [sizeConfiguration configurationByApplyingConfiguration:colorConfiguration]];
        NSTextAttachment *attachment = [NSTextAttachment new];
        attachment.image = icon;
        CGFloat iconSize = [metric[@"symbol"] isEqualToString:@"thermometer.medium"] ? 18 : 16;
        attachment.bounds = NSMakeRect(0, (font.capHeight - iconSize) / 2.0,
            iconSize, iconSize);
        [statusLine appendAttributedString:[NSAttributedString
            attributedStringWithAttachment:attachment]];
        [statusLine appendAttributedString:[[NSAttributedString alloc]
            initWithString:@"  " attributes:attributes]];
        [statusLine appendAttributedString:[[NSAttributedString alloc]
            initWithString:label attributes:attributes]];
        if (index + 1 < metrics.count) {
            NSDictionary *separatorAttributes = @{NSFontAttributeName:
                [NSFont systemFontOfSize:12 weight:NSFontWeightRegular],
                NSForegroundColorAttributeName: [NSColor colorWithWhite:0.42 alpha:0.7]};
            [statusLine appendAttributedString:[[NSAttributedString alloc]
                initWithString:@"    │    " attributes:separatorAttributes]];
        }
    }
    CGFloat width = ceil(statusLine.size.width);
    [statusLine drawInRect:NSMakeRect(rightEdge - width, y, width + 1, 20)];
}
- (NSString *)formattedTokenCountForUsage:(NSDictionary *)usage key:(NSString *)key {
    return [self formattedTokenCount:[self tokenTotals:usage key:key] ?: @{}];
}
- (NSString *)formattedTokenSplitForUsage:(NSDictionary *)usage key:(NSString *)key
    wantsOutput:(BOOL)wantsOutput {
    return [self formattedTokenSplit:[self tokenTotals:usage key:key] ?: @{}
        wantsOutput:wantsOutput];
}
- (NSNumber *)usedForQuota:(NSDictionary *)quota usedKey:(NSString *)usedKey {
    NSNumber *used = [quota[usedKey] isKindOfClass:NSNumber.class] ? quota[usedKey] : nil;
    return used ? @(fmax(0, fmin(100, used.doubleValue))) : nil;
}
- (NSString *)refreshAgeText {
    if (self.lastUpdatedAt <= 0) return @"等待数据";
    NSTimeInterval age = fmax(0, NSDate.date.timeIntervalSince1970 - self.lastUpdatedAt);
    if (age < 5) return @"刚刚";
    if (age < 60) return [NSString stringWithFormat:@"%.0f 秒前", age];
    if (age < 3600) return [NSString stringWithFormat:@"%.0f 分钟前", floor(age / 60)];
    return [NSString stringWithFormat:@"%.0f 小时前", floor(age / 3600)];
}
- (NSDictionary *)textAttributesWithSize:(CGFloat)size color:(NSColor *)color weight:(NSFontWeight)weight {
    return @{NSFontAttributeName: [NSFont systemFontOfSize:size weight:weight],
             NSForegroundColorAttributeName: color};
}
- (NSDictionary *)rightAlignedTextAttributesWithSize:(CGFloat)size color:(NSColor *)color
    weight:(NSFontWeight)weight {
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentRight;
    return @{NSFontAttributeName: [NSFont systemFontOfSize:size weight:weight],
             NSForegroundColorAttributeName: color,
             NSParagraphStyleAttributeName: style};
}
- (NSDictionary *)centeredTextAttributesWithSize:(CGFloat)size color:(NSColor *)color weight:(NSFontWeight)weight {
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentCenter;
    return @{NSFontAttributeName: [NSFont systemFontOfSize:size weight:weight],
             NSForegroundColorAttributeName: color,
             NSParagraphStyleAttributeName: style};
}
- (void)fillRoundedRect:(NSRect)rect radius:(CGFloat)radius color:(NSColor *)color {
    [color setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] fill];
}
- (NSArray<NSDictionary *> *)curvePointsFromHistory:(NSArray<NSDictionary *> *)history
    currentUsed:(NSNumber *)currentUsed {
    // 历史只能补充当前快照，不能替代当前快照。当前窗口还没有采集到额度时继续画旧历史，
    // 会让“等待数据”的卡片同时出现一条悬在中间的曲线；此时只保留图表底部基线。
    if (!currentUsed) return @[];

    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSTimeInterval cutoff = now - 7 * 24 * 60 * 60;
    NSMutableArray<NSDictionary *> *points = [NSMutableArray array];
    for (NSDictionary *sample in history) {
        if (![sample isKindOfClass:NSDictionary.class]) continue;
        NSNumber *timestamp = [sample[@"timestamp"] isKindOfClass:NSNumber.class]
            ? sample[@"timestamp"] : nil;
        NSNumber *remaining = [sample[@"remaining"] isKindOfClass:NSNumber.class]
            ? sample[@"remaining"] : nil;
        if (!timestamp || !remaining || timestamp.doubleValue < cutoff) continue;
        double used = 100.0 - fmax(0, fmin(100, remaining.doubleValue));
        [points addObject:@{@"timestamp": timestamp, @"used": @(used)}];
    }
    // 终点必须和卡片上的当前官方额度同源；历史落盘最多会慢 15 分钟，不能直接拿它
    // 冒充“当前”，否则同一张卡里会出现两个不同百分比。
    [points addObject:@{@"timestamp": @(now), @"used": currentUsed}];
    return points;
}
- (void)appendCurveFromPoint:(NSPoint)from toPoint:(NSPoint)to path:(NSBezierPath *)path {
    CGFloat controlOffset = (to.x - from.x) / 3.0;
    [path curveToPoint:to
        controlPoint1:NSMakePoint(from.x + controlOffset, from.y)
        controlPoint2:NSMakePoint(to.x - controlOffset, to.y)];
}
- (void)drawCurveSegment:(NSArray<NSValue *> *)segment inRect:(NSRect)rect color:(NSColor *)color {
    if (segment.count == 0) return;
    NSBezierPath *line = [NSBezierPath bezierPath];
    NSPoint first = segment.firstObject.pointValue;
    [line moveToPoint:first];
    NSPoint previous = first;
    for (NSUInteger index = 1; index < segment.count; index++) {
        NSPoint point = segment[index].pointValue;
        [self appendCurveFromPoint:previous toPoint:point path:line];
        previous = point;
    }

    NSBezierPath *fill = [line copy];
    [fill lineToPoint:NSMakePoint(previous.x, NSMinY(rect))];
    [fill lineToPoint:NSMakePoint(first.x, NSMinY(rect))];
    [fill closePath];
    [NSGraphicsContext saveGraphicsState];
    [fill addClip];
    NSGradient *area = [[NSGradient alloc]
        initWithStartingColor:[color colorWithAlphaComponent:0.34]
        endingColor:[color colorWithAlphaComponent:0.025]];
    [area drawFromPoint:NSMakePoint(NSMidX(rect), NSMaxY(rect))
        toPoint:NSMakePoint(NSMidX(rect), NSMinY(rect)) options:0];
    [NSGraphicsContext restoreGraphicsState];

    [[color colorWithAlphaComponent:0.95] setStroke];
    line.lineWidth = 2;
    [line stroke];
}
- (void)drawUsageCurve:(NSArray<NSDictionary *> *)points inRect:(NSRect)rect
    color:(NSColor *)color {
    [[NSColor colorWithWhite:1 alpha:0.08] setStroke];
    [NSBezierPath strokeLineFromPoint:NSMakePoint(NSMinX(rect), NSMinY(rect))
        toPoint:NSMakePoint(NSMaxX(rect), NSMinY(rect))];
    if (points.count == 0) return;

    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSTimeInterval cutoff = now - 7 * 24 * 60 * 60;
    // 曲线始终连成一段：采样缺口只代表桌宠当时没在运行，不代表没有消耗，
    // 缺口两端直接插值比断开更接近真实轨迹；窗口重置带来的回落本身也是真实变化。
    NSMutableArray<NSValue *> *allPoints = [NSMutableArray arrayWithCapacity:points.count];
    for (NSDictionary *sample in points) {
        NSTimeInterval timestamp = [sample[@"timestamp"] doubleValue];
        double used = fmax(0, fmin(100, [sample[@"used"] doubleValue]));
        CGFloat x = NSMinX(rect) + NSWidth(rect) * (timestamp - cutoff) / (now - cutoff);
        CGFloat y = NSMinY(rect) + NSHeight(rect) * used / 100.0;
        [allPoints addObject:[NSValue valueWithPoint:NSMakePoint(
            fmax(NSMinX(rect), fmin(NSMaxX(rect), x)), y)]];
    }
    [self drawCurveSegment:allPoints inRect:rect color:color];
}
- (void)drawMonthlyTokenCurve:(NSArray<NSDictionary *> *)series inRect:(NSRect)rect
    color:(NSColor *)color {
    [[NSColor colorWithWhite:1 alpha:0.08] setStroke];
    [NSBezierPath strokeLineFromPoint:NSMakePoint(NSMinX(rect), NSMinY(rect))
        toPoint:NSMakePoint(NSMaxX(rect), NSMinY(rect))];
    if (series.count == 0) return;
    // 横轴铺满整个自然月，曲线只画到今天：把月末还没到的日子当成 0 画出去，看起来会像
    // 用量突然归零。留白本身就是"这个月还剩多少天"的刻度。
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    double peak = 0;
    NSUInteger elapsed = 0;
    for (NSDictionary *day in series) {
        if ([day[@"timestamp"] doubleValue] > now) break;
        NSDictionary *totals = [day[@"totals"] isKindOfClass:NSDictionary.class]
            ? day[@"totals"] : nil;
        peak = fmax(peak, [totals[@"total_tokens"] doubleValue]);
        elapsed += 1;
    }
    if (peak <= 0 || elapsed == 0) return;
    NSMutableArray<NSValue *> *points = [NSMutableArray arrayWithCapacity:elapsed];
    for (NSUInteger index = 0; index < elapsed; index++) {
        NSDictionary *totals = [series[index][@"totals"] isKindOfClass:NSDictionary.class]
            ? series[index][@"totals"] : nil;
        double value = [totals[@"total_tokens"] doubleValue];
        CGFloat progress = series.count > 1 ? (CGFloat)index / (series.count - 1) : 1;
        [points addObject:[NSValue valueWithPoint:NSMakePoint(
            NSMinX(rect) + NSWidth(rect) * progress,
            NSMinY(rect) + NSHeight(rect) * value / peak)]];
    }
    [self drawCurveSegment:points inRect:rect color:color];
}
- (NSDictionary *)paceStatusForQuota:(NSDictionary *)quota currentUsed:(NSNumber *)currentUsed
    color:(NSColor *)providerColor {
    if (!currentUsed) {
        return @{@"label": @"数据不足", @"tip": @"等待官方额度数据",
                 @"color": self.secondaryColor};
    }
    NSNumber *reset = [quota[@"resets_at"] isKindOfClass:NSNumber.class]
        ? quota[@"resets_at"] : nil;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    const NSTimeInterval sevenDaySeconds = 7 * 24 * 60 * 60;
    NSTimeInterval start = reset ? reset.doubleValue - sevenDaySeconds : 0;
    NSTimeInterval elapsed = now - start;
    double projectedRemaining = NAN;
    const NSTimeInterval paceObservationSeconds = 24 * 60 * 60;
    // 满 24 小时就全额外推的话，放大倍数还有 7 倍：窗口第 25 小时，任何已用超过 14.3%
    // 的用户都会被判成"重置前用尽"。更糟的是两家的窗口起点差几个小时，就会出现一家
    // 已外推、另一家还没到门槛的断层——剩 80% 的报高风险，剩 61% 的却显示平稳。
    // 因此在 24 小时到窗口 1/3（56 小时）之间按观测时长加权，从"按当前已用"平滑过渡
    // 到"完全信任外推"，门槛处不再有跳变。
    const NSTimeInterval paceFullTrustSeconds = sevenDaySeconds / 3.0;
    if (reset && reset.doubleValue > now && elapsed >= paceObservationSeconds) {
        double linearUsed = currentUsed.doubleValue * sevenDaySeconds / elapsed;
        double confidence = fmin(1.0, (elapsed - paceObservationSeconds) /
            (paceFullTrustSeconds - paceObservationSeconds));
        double projectedUsed = currentUsed.doubleValue +
            (linearUsed - currentUsed.doubleValue) * confidence;
        projectedRemaining = 100.0 - projectedUsed;
    }

    // 四个档位从轻到重排成阶梯，后面的仲裁只在这上面挪档位，不再各写一套 label/tip/color。
    double remaining = 100.0 - currentUsed.doubleValue;
    NSArray<NSArray *> *ladder = @[
        @[@"充足", @"当前额度余量充足", NSColor.systemGreenColor],
        @[@"平稳", @"当前额度余量平稳", providerColor],
        @[@"需关注", @"建议关注额度余量", NSColor.systemOrangeColor],
        @[@"高风险", @"当前额度余量较低", NSColor.systemRedColor]
    ];
    NSUInteger baseRank = remaining >= 70 ? 0
        : (remaining >= 40 ? 1 : (remaining >= 15 ? 2 : 3));

    // 当前窗口开始满 24 小时后才按消耗节奏预测；此前 projectedRemaining 是 NAN，只看事实。
    NSInteger projectedRank = -1;
    NSString *projectedTip = nil;
    if (!isnan(projectedRemaining)) {
        if (remaining <= 5 || projectedRemaining < 0) {
            projectedRank = 3;
            projectedTip = @"预计重置前额度用尽";
        } else if (projectedRemaining < 10) {
            projectedRank = 2;
            projectedTip = @"建议减少高消耗任务";
        } else if (projectedRemaining >= 30) {
            projectedRank = 0;
            projectedTip = @"按当前节奏额度充足";
        }
    }

    // 仲裁：有预测就以预测为准，但事实划两条不可逾越的线。预测是关于未来的猜测，
    // 剩余额度是此刻的事实；让猜测把事实盖掉，两个方向都会出错——
    //   剩 80% 被外推成"高风险"是虚惊，剩 10% 被外推成"需关注"是漏报，后者更危险。
    NSUInteger rank = projectedRank >= 0 ? (NSUInteger)projectedRank : baseRank;
    BOOL demotedByFact = NO;
    if (remaining < 15) rank = 3;                       // 只剩一成，再乐观的预测也压不下来
    else if (remaining < 40 && rank < 1) rank = 1;      // 不到四成就别标"充足"
    if (remaining >= 70 && rank > 2) {                  // 还有七成，再难看的预测也不报"高风险"
        rank = 2;
        demotedByFact = YES;
    }

    NSString *label = ladder[rank][0];
    NSString *tip = ladder[rank][1];
    if (demotedByFact) tip = @"消耗偏快，注意节奏";
    else if (projectedRank >= 0 && rank == (NSUInteger)projectedRank) tip = projectedTip;
    return @{@"label": label, @"tip": tip, @"color": ladder[rank][2]};
}
- (void)drawProvider:(NSString *)name usage:(NSDictionary *)usage usedKey:(NSString *)usedKey
    color:(NSColor *)color cardRect:(NSRect)card {
    NSColor *primary = self.primaryColor;
    NSColor *secondary = self.secondaryColor;
    NSDictionary *five = [self quota:usage key:@"fiveHour"];
    NSDictionary *week = [self quota:usage key:@"week"];
    NSDictionary *fiveTokens = [self tokenTotals:usage key:@"fiveHour"];
    NSDictionary *weekTokens = [self tokenTotals:usage key:@"week"];
    NSDictionary *monthTokens = [self tokenTotals:usage key:@"month"];
    // 同比两侧都只数到最后一个完整自然日（见 CalendarMonthWindows），因此不能拿含今天的
    // monthTokens 去比不含同日的上月——那样每天都会凭空多出小半天的增量。
    NSDictionary *monthComparable = [self tokenTotals:usage key:@"monthComparable"];
    NSDictionary *previousMonthTokens = [self tokenTotals:usage key:@"previousMonthToDate"];
    NSDictionary *tokenUsage = [usage[@"tokenUsage"] isKindOfClass:NSDictionary.class]
        ? usage[@"tokenUsage"] : nil;
    NSArray<NSDictionary *> *monthDaily = [tokenUsage[@"monthDaily"] isKindOfClass:NSArray.class]
        ? tokenUsage[@"monthDaily"] : @[];
    BOOL apiMode = [name isEqualToString:@"Codex"]
        ? self.codexShowsAPIUsage : self.claudeShowsAPIUsage;
    NSNumber *fiveUsed = [self usedForQuota:five usedKey:usedKey];
    NSNumber *weekUsed = [self usedForQuota:week usedKey:usedKey];
    // usage_limit_exceeded 只能说明某次请求被额度限制，不能说明耗尽的是 5 小时还是
    // 7 天窗口；切到 credits 后请求还能继续成功，但 rate_limits 可能一直为空。因此把它
    // 作为独立的“额度受限”状态，不再拿一个无窗口归属的事件覆盖两个官方百分比。
    BOOL exhausted = [usage[@"exhaustedAt"] isKindOfClass:NSNumber.class];
    BOOL hasData = apiMode ? (monthTokens != nil)
        : (fiveUsed || weekUsed || fiveTokens || weekTokens || exhausted);
    BOOL online = [self isProviderOnline:name];

    NSBezierPath *cardPath = [NSBezierPath bezierPathWithRoundedRect:card xRadius:18 yRadius:18];
    NSGradient *cardGlass = [[NSGradient alloc]
        initWithStartingColor:[NSColor colorWithWhite:1 alpha:0.085]
        endingColor:[color colorWithAlphaComponent:0.025]];
    [cardGlass drawInBezierPath:cardPath angle:-25];
    [[NSColor colorWithWhite:1 alpha:0.18] setStroke];
    cardPath.lineWidth = 1;
    [cardPath stroke];

    NSArray<NSNumber *> *separators = @[@(NSMinX(card) + 190), @(NSMinX(card) + 370),
        @(NSMinX(card) + 540)];
    [[NSColor colorWithWhite:1 alpha:0.10] setStroke];
    for (NSNumber *value in separators) {
        [NSBezierPath strokeLineFromPoint:NSMakePoint(value.doubleValue, NSMinY(card) + 14)
            toPoint:NSMakePoint(value.doubleValue, NSMaxY(card) - 14)];
    }

    NSRect icon = NSMakeRect(NSMinX(card) + 28, NSMinY(card) + 53, 54, 54);
    NSImage *logo = [name isEqualToString:@"Codex"] ? self.codexLogo : self.claudeLogo;
    if (logo) {
        [NSGraphicsContext saveGraphicsState];
        [[NSBezierPath bezierPathWithRoundedRect:icon xRadius:14 yRadius:14] addClip];
        [logo drawInRect:icon fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0
            respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
        [NSGraphicsContext restoreGraphicsState];
    } else {
        [self fillRoundedRect:icon radius:14 color:[color colorWithAlphaComponent:0.7]];
        [name drawInRect:NSInsetRect(icon, 4, 17)
            withAttributes:[self centeredTextAttributesWithSize:13 color:NSColor.whiteColor weight:NSFontWeightBold]];
    }
    [name drawInRect:NSMakeRect(NSMinX(card) + 94, NSMinY(card) + 84, 88, 30)
        withAttributes:[self textAttributesWithSize:22 color:primary weight:NSFontWeightBold]];
    // 四态：额度被拒 → 额度受限（百分比仍是上次官方快照）；没有任何额度数据 → 等待数据；
    // 有数据但客户端已退出 → 离线；两者都有 → 在线。
    NSString *statusText = (!apiMode && exhausted) ? @"额度受限"
        : (!hasData ? @"等待数据" : (online ? @"● 在线" : @"离线"));
    NSColor *statusColor = (!apiMode && exhausted) ? NSColor.systemOrangeColor
        : (online && hasData ? NSColor.systemGreenColor : secondary);
    NSDictionary *statusAttributes = [self textAttributesWithSize:11 color:statusColor
        weight:NSFontWeightMedium];
    CGFloat statusWidth = ceil([statusText sizeWithAttributes:statusAttributes].width) + 18;
    NSRect status = NSMakeRect(NSMinX(card) + 94, NSMinY(card) + 55, statusWidth, 24);
    [self fillRoundedRect:status radius:12 color:[statusColor colorWithAlphaComponent:0.13]];
    [statusText drawInRect:NSInsetRect(status, 9, 4) withAttributes:statusAttributes];

    if (apiMode) {
        CGFloat callX = NSMinX(card) + 214;
        CGFloat tokenX = NSMinX(card) + 394;
        [@"本月调用" drawInRect:NSMakeRect(callX, NSMinY(card) + 114, 130, 20)
            withAttributes:[self textAttributesWithSize:13 color:secondary weight:NSFontWeightRegular]];
        [@"本月消耗" drawInRect:NSMakeRect(tokenX, NSMinY(card) + 114, 130, 20)
            withAttributes:[self textAttributesWithSize:13 color:secondary weight:NSFontWeightRegular]];

        NSString *requests = [NSString stringWithFormat:@"%@ 次",
            [self formattedRequestCount:monthTokens ?: @{}]];
        [requests drawInRect:NSMakeRect(callX, NSMinY(card) + 75, 150, 34)
            withAttributes:[self textAttributesWithSize:24 color:primary weight:NSFontWeightBold]];
        // 曲线铺满整个自然月，月末那些还没到的日子不能算进"已过天数"，否则日均会被稀释。
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        NSUInteger recordedDays = 0;
        for (NSDictionary *day in monthDaily) {
            if ([day[@"timestamp"] doubleValue] <= now) recordedDays += 1;
        }
        NSUInteger elapsedDays = MAX((NSUInteger)1, recordedDays);
        NSNumber *requestCount = [monthTokens[@"request_count"] isKindOfClass:NSNumber.class]
            ? monthTokens[@"request_count"] : nil;
        NSString *average = requestCount
            ? [NSString stringWithFormat:@"日均 %@ 次",
                [NSNumberFormatter localizedStringFromNumber:
                    @(llround(requestCount.doubleValue / elapsedDays))
                    numberStyle:NSNumberFormatterDecimalStyle]]
            : @"日均 --";
        [average drawInRect:NSMakeRect(callX, NSMinY(card) + 48, 150, 20)
            withAttributes:[self textAttributesWithSize:12 color:secondary weight:NSFontWeightRegular]];

        // 这里不再重复"本月消耗"的合计：输入与输出各自的量级才是按量计费时要看的东西，
        // 合计随时可以由这两个数得到，而它原先占掉了最显眼的一行。
        NSArray<NSDictionary *> *splits = @[
            @{@"label": @"输入", @"value": [self formattedTokenSplit:monthTokens ?: @{}
                wantsOutput:NO], @"y": @(NSMinY(card) + 76)},
            @{@"label": @"输出", @"value": [self formattedTokenSplit:monthTokens ?: @{}
                wantsOutput:YES], @"y": @(NSMinY(card) + 48)}
        ];
        for (NSDictionary *split in splits) {
            CGFloat y = [split[@"y"] doubleValue];
            [split[@"label"] drawInRect:NSMakeRect(tokenX, y + 4, 28, 16)
                withAttributes:[self textAttributesWithSize:11 color:secondary
                    weight:NSFontWeightRegular]];
            [split[@"value"] drawInRect:NSMakeRect(tokenX + 32, y, 122, 26)
                withAttributes:[self textAttributesWithSize:18 color:primary
                    weight:NSFontWeightBold]];
        }

        NSDictionary *requestComparison = [self comparisonForCurrent:
            [monthComparable[@"request_count"] doubleValue]
            previous:[previousMonthTokens[@"request_count"] doubleValue] color:color];
        [requestComparison[@"text"] drawInRect:NSMakeRect(callX, NSMinY(card) + 22, 158, 18)
            withAttributes:[self textAttributesWithSize:11 color:requestComparison[@"color"]
                weight:NSFontWeightMedium]];
        NSDictionary *tokenComparison = [self comparisonForCurrent:
            [monthComparable[@"total_tokens"] doubleValue]
            previous:[previousMonthTokens[@"total_tokens"] doubleValue] color:color];
        [tokenComparison[@"text"] drawInRect:NSMakeRect(tokenX, NSMinY(card) + 22, 158, 18)
            withAttributes:[self textAttributesWithSize:11 color:tokenComparison[@"color"]
                weight:NSFontWeightMedium]];

        CGFloat trendX = NSMinX(card) + 564;
        // 「按日 Token」跟在标题后面，与标题同一行：它是标题的限定语，单独占一行既浪费
        // 竖向空间，也把曲线和脚注挤得没法与左边两列对齐。
        [@"本月趋势" drawInRect:NSMakeRect(trendX, NSMinY(card) + 114, 60, 20)
            withAttributes:[self textAttributesWithSize:13 color:secondary weight:NSFontWeightRegular]];
        NSDictionary *pillAttributes = [self textAttributesWithSize:11 color:color
            weight:NSFontWeightSemibold];
        NSRect pill = NSMakeRect(trendX + 59, NSMinY(card) + 113, 76, 22);
        [self fillRoundedRect:pill radius:11 color:[color colorWithAlphaComponent:0.14]];
        [@"按日 Token" drawInRect:NSInsetRect(pill, 9, 3) withAttributes:pillAttributes];
        NSRect curveRect = NSMakeRect(trendX, NSMinY(card) + 62, 135, 38);
        [self drawMonthlyTokenCurve:monthDaily inRect:curveRect color:color];
        double peak = 0;
        NSDictionary *todayTotals = nil;
        for (NSDictionary *day in monthDaily) {
            if ([day[@"timestamp"] doubleValue] > now) break;
            NSDictionary *totals = [day[@"totals"] isKindOfClass:NSDictionary.class]
                ? day[@"totals"] : nil;
            peak = fmax(peak, [totals[@"total_tokens"] doubleValue]);
            todayTotals = totals;
        }
        NSString *peakText = recordedDays > 0
            ? [NSString stringWithFormat:@"峰值 %@", [self formattedTokenValue:peak]] : @"峰值 --";
        NSString *todayText = todayTotals
            ? [NSString stringWithFormat:@"今日 %@",
                [self formattedTokenValue:[todayTotals[@"total_tokens"] doubleValue]]] : @"今日 --";
        [peakText drawInRect:NSMakeRect(trendX, NSMinY(card) + 42, 74, 16)
            withAttributes:[self textAttributesWithSize:10 color:secondary weight:NSFontWeightRegular]];
        [todayText drawInRect:NSMakeRect(trendX + 61, NSMinY(card) + 42, 74, 16)
            withAttributes:[self rightAlignedTextAttributesWithSize:10 color:secondary
                weight:NSFontWeightRegular]];
        // 与左边两列的"较上月同期"同一条基线（+22），三列脚注才在一条水平线上。
        [[NSString stringWithFormat:@"本月已记录 %lu / %lu 天",
            (unsigned long)recordedDays, (unsigned long)monthDaily.count]
            drawInRect:NSMakeRect(trendX, NSMinY(card) + 22, 145, 18)
            withAttributes:[self textAttributesWithSize:11 color:color weight:NSFontWeightMedium]];
        return;
    }

    // 层级：官方剩余额度是订阅限额的权威值，占主位；本机 Token 是参考量，降一级并用
    // 强调色区分；重置时间最小。反过来会让最抢眼的数字恰好是最不该照着做决定的那个。
    NSArray<NSDictionary *> *windows = @[
        @{@"x": @(NSMinX(card) + 214), @"title": @"官方 5 小时窗口", @"quota": five ?: @{},
          @"tokens": fiveTokens ?: @{}, @"used": fiveUsed ?: NSNull.null,
          @"rolling": @"官方额度待刷新"},
        @{@"x": @(NSMinX(card) + 394), @"title": @"官方 7 天窗口", @"quota": week ?: @{},
          @"tokens": weekTokens ?: @{}, @"used": weekUsed ?: NSNull.null,
          @"rolling": @"官方额度待刷新"}
    ];
    for (NSDictionary *window in windows) {
        CGFloat x = [window[@"x"] doubleValue];
        [window[@"title"] drawInRect:NSMakeRect(x, NSMinY(card) + 114, 130, 20)
            withAttributes:[self textAttributesWithSize:13 color:secondary weight:NSFontWeightRegular]];
        NSNumber *used = [window[@"used"] isKindOfClass:NSNumber.class] ? window[@"used"] : nil;
        double remaining = used ? 100.0 - used.doubleValue : 0;
        NSString *official = used ? [NSString stringWithFormat:@"%.0f%%", remaining] : @"--";
        // 百分比是"剩余"、Token 是"已用"，方向相反。后缀直接贴在数字右侧、
        // 前缀写进 Token 行，否则两个数字并排看会被当成同一口径。
        NSDictionary *valueAttributes = [self textAttributesWithSize:25
            color:exhausted ? NSColor.systemOrangeColor : primary
            weight:NSFontWeightBold];
        CGFloat valueWidth = ceil([official sizeWithAttributes:valueAttributes].width);
        [official drawInRect:NSMakeRect(x, NSMinY(card) + 74, valueWidth + 4, 34)
            withAttributes:valueAttributes];
        // 没有数字可标时不给口径标签："-- 剩余"看起来像一个真实的 0 值，而实际上是
        // 官方快照待刷新。下方的状态文字会说明它为何不可用。
        NSString *valueLabel = !used ? @"" : (exhausted ? @"快照" : @"剩余");
        if (valueLabel.length > 0) {
            [valueLabel drawInRect:NSMakeRect(x + valueWidth + 7, NSMinY(card) + 78, 60, 20)
                withAttributes:[self textAttributesWithSize:12 color:secondary
                    weight:NSFontWeightRegular]];
        }
        // 官方窗口拿不到时（账号没有这个窗口、或响应里没带），Token 走的是本机滚动窗口。
        // 说清楚这一行的口径，比留一个 `--` 让人以为是渲染坏了要好。
        NSString *resetValue = [self resetText:window[@"quota"]];
        NSString *reset = [resetValue isEqualToString:@"--"]
            ? window[@"rolling"] : [NSString stringWithFormat:@"重置时间 %@", resetValue];
        [reset drawInRect:NSMakeRect(x, NSMinY(card) + 46, 150, 18)
            withAttributes:[self textAttributesWithSize:11 color:secondary weight:NSFontWeightRegular]];
        NSString *tokenText = [NSString stringWithFormat:@"已用 Token %@",
            [self formattedTokenCount:window[@"tokens"]]];
        [tokenText drawInRect:NSMakeRect(x, NSMinY(card) + 22, 150, 22)
            withAttributes:[self textAttributesWithSize:14 color:color weight:NSFontWeightSemibold]];
    }

    CGFloat trendX = NSMinX(card) + 564;
    // 与 API 卡同一套骨架：标题行带 pill、中间曲线、脚注和左边两列齐平。
    [@"使用趋势" drawInRect:NSMakeRect(trendX, NSMinY(card) + 114, 60, 20)
        withAttributes:[self textAttributesWithSize:13 color:secondary weight:NSFontWeightRegular]];
    NSArray<NSDictionary *> *history = [name isEqualToString:@"Codex"]
        ? self.codexHistory : self.claudeHistory;
    NSNumber *currentUsed = weekUsed;
    NSArray<NSDictionary *> *points = [self curvePointsFromHistory:history currentUsed:currentUsed];
    NSDictionary *pace = exhausted
        ? @{ @"label": @"待刷新", @"tip": @"等待新的官方额度快照",
             @"color": NSColor.systemOrangeColor }
        : [self paceStatusForQuota:week currentUsed:currentUsed color:color];
    NSColor *paceColor = pace[@"color"];
    NSDictionary *pillAttributes = [self textAttributesWithSize:11 color:paceColor
        weight:NSFontWeightSemibold];
    // 档位标签跟在标题后面。宽度仍按文字算：四个档位不一样长，最宽的"数据不足"到
    // trendX + 131，列宽 145 放得下。
    CGFloat pillWidth = ceil([pace[@"label"] sizeWithAttributes:pillAttributes].width) + 18;
    NSRect pill = NSMakeRect(trendX + 59, NSMinY(card) + 113, pillWidth, 22);
    [self fillRoundedRect:pill radius:11 color:[paceColor colorWithAlphaComponent:0.14]];
    [pace[@"label"] drawInRect:NSInsetRect(pill, 9, 3) withAttributes:pillAttributes];

    NSRect curveRect = NSMakeRect(trendX, NSMinY(card) + 62, 135, 38);
    [self drawUsageCurve:points inRect:curveRect color:color];
    double peak = 0;
    for (NSDictionary *point in points) peak = fmax(peak, [point[@"used"] doubleValue]);
    NSString *peakText = points.count > 0
        ? [NSString stringWithFormat:@"最高 %.0f%%", peak] : @"最高 --";
    NSString *currentText = currentUsed
        ? [NSString stringWithFormat:@"当前 %.0f%%", currentUsed.doubleValue] : @"当前 --";
    [peakText drawInRect:NSMakeRect(trendX, NSMinY(card) + 42, 72, 16)
        withAttributes:[self textAttributesWithSize:10 color:secondary weight:NSFontWeightRegular]];
    [currentText drawInRect:NSMakeRect(trendX + 66, NSMinY(card) + 42, 69, 16)
        withAttributes:[self rightAlignedTextAttributesWithSize:10 color:secondary
            weight:NSFontWeightRegular]];
    // 与左边两列的"已用 Token"同一条基线（+22），也和 API 卡的脚注行对齐。
    [pace[@"tip"] drawInRect:NSMakeRect(trendX, NSMinY(card) + 22, 145, 18)
        withAttributes:[self textAttributesWithSize:11 color:paceColor weight:NSFontWeightMedium]];
}
- (void)drawRect:(NSRect)dirtyRect {
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *scale = [NSAffineTransform transform];
    [scale scaleBy:QuotaScale];
    [scale concat];
    NSArray<NSString *> *visibleProviders = [self visibleProviders];
    const CGFloat height = [self logicalHeight];
    NSRect logicalBounds = NSMakeRect(0, 0, QuotaLogicalWidth, height);
    NSRect outer = NSInsetRect(logicalBounds, 1, 1);
    NSBezierPath *background = [NSBezierPath bezierPathWithRoundedRect:outer xRadius:24 yRadius:24];
    NSGradient *gradient = [[NSGradient alloc]
        initWithStartingColor:[NSColor colorWithRed:0.025 green:0.055 blue:0.095 alpha:0.88]
        endingColor:[NSColor colorWithRed:0.07 green:0.12 blue:0.19 alpha:0.80]];
    [gradient drawInBezierPath:background angle:-20];

    [NSGraphicsContext saveGraphicsState];
    [background addClip];
    NSGradient *topGlow = [[NSGradient alloc]
        initWithStartingColor:[NSColor colorWithWhite:1 alpha:0.34]
        endingColor:[NSColor colorWithWhite:1 alpha:0.0]];
    // 两处光晕原本是按 H=590 定的绝对点。面板会变矮，改成跟着高度走：顶部光源始终悬在
    // 面板上沿之外，冷色光晕落在内容区中段。
    NSPoint topGlowCenter = NSMakePoint(700, height + 60);
    [topGlow drawFromCenter:topGlowCenter radius:0
        toCenter:topGlowCenter radius:250 options:0];
    NSGradient *cyanGlow = [[NSGradient alloc]
        initWithStartingColor:[NSColor colorWithRed:0.18 green:0.72 blue:1 alpha:0.11]
        endingColor:[NSColor colorWithRed:0.18 green:0.88 blue:1 alpha:0.0]];
    NSPoint cyanGlowCenter = NSMakePoint(660, height * 0.42);
    [cyanGlow drawFromCenter:cyanGlowCenter radius:0
        toCenter:cyanGlowCenter radius:260 options:0];
    [NSGraphicsContext restoreGraphicsState];

    [[NSColor colorWithWhite:1 alpha:0.34] setStroke];
    background.lineWidth = 1.5;
    [background stroke];
    NSBezierPath *innerGlassBorder = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(outer, 2, 2)
        xRadius:22 yRadius:22];
    [[NSColor colorWithRed:0.58 green:0.82 blue:1 alpha:0.22] setStroke];
    innerGlassBorder.lineWidth = 0.8;
    [innerGlassBorder stroke];
    NSColor *primary = self.primaryColor;
    NSColor *secondary = self.secondaryColor;
    NSColor *cyan = self.accentColor;
    NSColor *agentColor = self.agentStatusColor;
    [@"Agent Usage" drawInRect:NSMakeRect(28, height - 65, 260, 42)
        withAttributes:[self textAttributesWithSize:30 color:primary weight:NSFontWeightBold]];
    [@"实时状态与滚动用量" drawInRect:NSMakeRect(30, height - 94, 130, 22)
        withAttributes:[self textAttributesWithSize:14 color:secondary weight:NSFontWeightRegular]];
    [agentColor setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(174, height - 88, 9, 9)] fill];
    NSString *agentText = self.activeAgentCount > 0
        ? [NSString stringWithFormat:@"%ld 个 Agent 在线", (long)self.activeAgentCount]
        : @"暂无 Agent 在线";
    [agentText drawInRect:NSMakeRect(190, height - 95, 160, 22)
        withAttributes:[self textAttributesWithSize:14 color:agentColor weight:NSFontWeightMedium]];
    [self drawSystemMetricsEndingAtX:QuotaLogicalWidth - 28 y:height - 95];

    BOOL recentlyRefreshed = self.refreshedUntil > NSDate.date.timeIntervalSince1970;
    CGFloat buttonAlpha = self.refreshPressed ? 0.18 : (self.refreshHovered ? 0.12 : 0.06);
    NSRect logicalRefreshRect = [self logicalRefreshRect];
    NSRect refreshRect = self.refreshPressed ? NSInsetRect(logicalRefreshRect, 1.5, 1.5) : logicalRefreshRect;
    [self fillRoundedRect:refreshRect radius:10 color:[NSColor colorWithWhite:1 alpha:buttonAlpha]];
    [recentlyRefreshed ? @"✓" : @"↻" drawInRect:NSInsetRect(refreshRect, 8, 4)
        withAttributes:[self textAttributesWithSize:19 color:[NSColor colorWithWhite:0.9 alpha:1] weight:NSFontWeightRegular]];
    // 贴着刷新按钮左侧右对齐：它说明的正是这个按钮上次生效的时间，挨着放才不用再标一遍
    // "数据刷新"是什么意思。放回汇总条里会挤掉一整格 Provider 数据。
    [[NSString stringWithFormat:@"数据刷新 %@", [self refreshAgeText]]
        drawInRect:NSMakeRect(NSMinX(logicalRefreshRect) - 206, NSMinY(logicalRefreshRect) + 7, 200, 18)
        withAttributes:[self rightAlignedTextAttributesWithSize:11 color:secondary
            weight:NSFontWeightRegular]];

    if (visibleProviders.count > 0) {
        [self drawSummaryForProviders:visibleProviders primary:primary secondary:secondary
            accent:cyan];
    }
    NSDictionary *cardSpecs = @{
        @"Codex": @{@"usage": self.codexUsage ?: @{}, @"usedKey": @"used_percent",
                    @"color": cyan},
        @"Claude": @{@"usage": self.claudeUsage ?: @{}, @"usedKey": @"used_percentage",
                     @"color": [NSColor colorWithRed:0.66 green:0.43 blue:0.94 alpha:1]}
    };
    // 卡片从汇总条下方依次向下排。少一家就少一张卡，脚注跟着上移；这里的分段账必须和
    // QuotaLogicalHeightForProviderCount 完全一致，否则面板会多出或少掉一段空白。
    CGFloat cardTop = height - QuotaHeaderHeight - QuotaSummaryHeight;
    for (NSString *name in visibleProviders) {
        NSDictionary *spec = cardSpecs[name];
        cardTop -= QuotaBlockGap;
        [self drawProvider:name usage:spec[@"usage"] usedKey:spec[@"usedKey"]
            color:spec[@"color"]
            cardRect:NSMakeRect(20, cardTop - QuotaCardHeight,
                QuotaLogicalWidth - 40, QuotaCardHeight)];
        cardTop -= QuotaCardHeight;
    }
    if (visibleProviders.count == 0) {
        // 精简态。说清楚是"没检测到 CLI"，而不是让用户对着一片空白猜面板是不是坏了。
        // 两行说明刻意分开：卡片出现只取决于装没装 CLI，探测每 ClientLifecycleInterval
        // 跑一次，装完几秒内自己就冒出来，既不用重装也不用重启桌宠。而 cc-pets install
        // 解决的是另一件事——Agent 动画，以及 Claude 额度（statusline 是它唯一的来源）。
        // 把两者写成一句会让人以为不执行 install 卡片就不出现。
        CGFloat noticeTop = height - QuotaHeaderHeight;
        [@"未检测到 Codex / Claude Code CLI" drawInRect:NSMakeRect(28, noticeTop - 30, 460, 26)
            withAttributes:[self textAttributesWithSize:17 color:primary weight:NSFontWeightMedium]];
        [@"安装 Codex 或 Claude Code 后，额度卡会自动出现"
            drawInRect:NSMakeRect(28, noticeTop - 52, 560, 20)
            withAttributes:[self textAttributesWithSize:12 color:secondary weight:NSFontWeightRegular]];
        [@"重新执行 cc-pets install 可启用 Agent 动画与 Claude 额度采集"
            drawInRect:NSMakeRect(28, noticeTop - 72, 560, 18)
            withAttributes:[self textAttributesWithSize:11
                color:[NSColor colorWithWhite:0.52 alpha:1] weight:NSFontWeightRegular]];
    }
    BOOL hasAPICard = ([visibleProviders containsObject:@"Codex"] && self.codexShowsAPIUsage) ||
        ([visibleProviders containsObject:@"Claude"] && self.claudeShowsAPIUsage);
    NSString *footer = visibleProviders.count == 0
        ? @"ⓘ  桌宠与系统状态不受影响；额度卡只在检测到对应 CLI 时显示"
        : (hasAPICard
            ? @"ⓘ  API 用量 = 本机会话统计（输入含缓存读写）；环比按上月相同时间进度计算"
            : @"ⓘ  百分比 = 官方订阅额度的剩余比例；Token = 本机统计的已用量（输入含缓存读写），两者口径不同");
    // 最后一块的底边距面板底 QuotaFooterHeight：脚注与其留约 8pt，底部留白 16pt，
    // 和顶部标题的留白大致对称。
    [footer drawInRect:NSMakeRect(28, 16, 650, 20)
        withAttributes:[self textAttributesWithSize:11 color:[NSColor colorWithWhite:0.58 alpha:1] weight:NSFontWeightRegular]];
    [NSGraphicsContext restoreGraphicsState];
}

// 今日与最近 7 天都按 Provider 分开展示。底层本来就是两套独立的自然日统计，
// 不在展示层相加，避免用户无法判断 Token 来自 Codex 还是 Claude。
// 每格内是一张 2×2 表：标题独占一行，每个 Provider 独占一行；输入/输出标签放在
// 对应数值上方。这样既能完整展示 7 天统计起期，也不会挤乱两家的数据行。
- (void)drawSummaryForProviders:(NSArray<NSString *> *)providers primary:(NSColor *)primary
    secondary:(NSColor *)secondary accent:(NSColor *)cyan {
    NSRect summary = [self logicalSummaryRect];
    NSBezierPath *summaryPath = [NSBezierPath bezierPathWithRoundedRect:summary xRadius:18 yRadius:18];
    [[NSColor colorWithWhite:1 alpha:0.065] setFill];
    [summaryPath fill];
    [[NSColor colorWithWhite:1 alpha:0.16] setStroke];
    [summaryPath stroke];

    NSArray<NSDictionary *> *cells = @[
        @{@"icon": @"◔", @"headerSymbol": @"calendar", @"key": @"today",
          @"label": @"今日用量"},
        @{@"icon": @"◉", @"headerSymbol": @"calendar.badge.clock", @"key": @"recentWeek",
          @"label": [self recentWeekUsageLabel]}
    ];
    NSDictionary *rowSpecs = @{
        @"Codex": @{@"usage": self.codexUsage ?: @{}, @"color": cyan},
        @"Claude": @{@"usage": self.claudeUsage ?: @{},
                     @"color": [NSColor colorWithRed:0.66 green:0.43 blue:0.94 alpha:1]}
    };
    // 两行版的槽位是写死的。只装了一家时改用居中的单行槽位，否则汇总条会空出半格，
    // 看着像数据没加载出来。
    NSArray<NSDictionary *> *slots = providers.count == 1
        ? @[@{@"iconY": @24, @"nameY": @33, @"labelY": @49, @"valueY": @28}]
        : @[@{@"iconY": @43, @"nameY": @52, @"labelY": @68, @"valueY": @47},
            @{@"iconY": @5, @"nameY": @14, @"labelY": @30, @"valueY": @9}];
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (NSUInteger index = 0; index < providers.count && index < slots.count; index++) {
        NSMutableDictionary *row = [slots[index] mutableCopy];
        [row addEntriesFromDictionary:rowSpecs[providers[index]]];
        row[@"name"] = providers[index];
        [rows addObject:row];
    }

    [[NSColor colorWithWhite:1 alpha:0.10] setStroke];
    for (NSUInteger index = 1; index < cells.count; index++) {
        CGFloat x = NSMinX([self logicalSummaryCellRectAtIndex:index]);
        [NSBezierPath strokeLineFromPoint:NSMakePoint(x, NSMinY(summary) + 16)
            toPoint:NSMakePoint(x, NSMaxY(summary) - 16)];
    }
    for (NSUInteger index = 0; index < cells.count; index++) {
        NSDictionary *cell = cells[index];
        NSString *key = cell[@"key"];
        CGFloat x = NSMinX([self logicalSummaryCellRectAtIndex:index]);
        const CGFloat inputX = x + 176;
        const CGFloat outputX = x + 276;
        NSFont *headerFont = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
        NSDictionary *headerAttributes = @{NSFontAttributeName: headerFont,
            NSForegroundColorAttributeName: secondary};
        NSImage *headerIcon = [NSImage imageWithSystemSymbolName:cell[@"headerSymbol"]
            accessibilityDescription:cell[@"label"]];
        NSImageSymbolConfiguration *headerIconConfiguration =
            [NSImageSymbolConfiguration configurationWithPointSize:11
                weight:NSFontWeightRegular];
        headerIconConfiguration = [headerIconConfiguration configurationByApplyingConfiguration:
            [NSImageSymbolConfiguration configurationWithHierarchicalColor:secondary]];
        headerIcon = [headerIcon imageWithSymbolConfiguration:headerIconConfiguration];
        NSTextAttachment *headerAttachment = [NSTextAttachment new];
        headerAttachment.image = headerIcon;
        const CGFloat headerIconSize = 13;
        headerAttachment.bounds = NSMakeRect(0,
            (headerFont.capHeight - headerIconSize) / 2.0, headerIconSize, headerIconSize);
        NSMutableAttributedString *header = [[NSMutableAttributedString alloc]
            initWithAttributedString:[NSAttributedString
                attributedStringWithAttachment:headerAttachment]];
        [header appendAttributedString:[[NSAttributedString alloc]
            initWithString:@"  " attributes:headerAttributes]];
        [header appendAttributedString:[[NSAttributedString alloc]
            initWithString:cell[@"label"] attributes:headerAttributes]];
        [header drawInRect:NSMakeRect(x + 24, NSMinY(summary) + 89,
            NSWidth([self logicalSummaryCellRectAtIndex:index]) - 48, 18)];
        for (NSDictionary *row in rows) {
            NSDictionary *usage = row[@"usage"];
            NSColor *rowColor = row[@"color"];
            CGFloat iconY = NSMinY(summary) + [row[@"iconY"] doubleValue];
            CGFloat nameY = NSMinY(summary) + [row[@"nameY"] doubleValue];
            CGFloat labelY = NSMinY(summary) + [row[@"labelY"] doubleValue];
            CGFloat valueY = NSMinY(summary) + [row[@"valueY"] doubleValue];
            [cell[@"icon"] drawInRect:NSMakeRect(x + 20, iconY, 42, 42)
                withAttributes:[self textAttributesWithSize:30 color:rowColor
                    weight:NSFontWeightRegular]];
            [row[@"name"] drawInRect:NSMakeRect(x + 66, nameY, 76, 22)
                withAttributes:[self textAttributesWithSize:14 color:rowColor
                    weight:NSFontWeightMedium]];
            [@"输入" drawInRect:NSMakeRect(inputX, labelY, 76, 16)
                withAttributes:headerAttributes];
            [@"输出" drawInRect:NSMakeRect(outputX, labelY, 76, 16)
                withAttributes:headerAttributes];
            NSDictionary *valueAttributes = [self textAttributesWithSize:16 color:primary
                weight:NSFontWeightBold];
            [[self formattedTokenSplitForUsage:usage key:key wantsOutput:NO]
                drawInRect:NSMakeRect(inputX, valueY, 86, 23) withAttributes:valueAttributes];
            [[self formattedTokenSplitForUsage:usage key:key wantsOutput:YES]
                drawInRect:NSMakeRect(outputX, valueY, 76, 23) withAttributes:valueAttributes];
        }
    }

}
@end
