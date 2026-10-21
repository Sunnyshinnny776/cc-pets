#import "QuotaDashboardView+Private.h"

@implementation QuotaDashboardView (Primitives)
- (NSColor *)primaryColor {
    return [NSColor colorWithWhite:0.97 alpha:1];
}
- (NSColor *)secondaryColor {
    // 没有深色底托着时，0.68 的灰在亮壁纸上会发虚。
    return [NSColor colorWithWhite:self.usesLiquidGlass ? 0.84 : 0.68 alpha:1];
}
// 原生玻璃背后只有一层压暗，原来的紫在上面偏暗，提亮到和青色相近的明度。
- (NSColor *)claudeColor {
    return self.usesLiquidGlass ? [NSColor colorWithRed:0.80 green:0.66 blue:1.00 alpha:1]
        : [NSColor colorWithRed:0.66 green:0.43 blue:0.94 alpha:1];
}
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
            NSForegroundColorAttributeName: [self textColor:color]};
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
    if (self.lastUpdatedAt <= 0) return L(@"Waiting for data");
    NSTimeInterval age = fmax(0, NSDate.date.timeIntervalSince1970 - self.lastUpdatedAt);
    if (age < 5) return L(@"just now");
    if (age < 60) return [NSString stringWithFormat:L(@"%.0fs ago"), age];
    if (age < 3600) return [NSString stringWithFormat:L(@"%.0fm ago"), floor(age / 60)];
    return [NSString stringWithFormat:L(@"%.0fh ago"), floor(age / 3600)];
}
// 两个主题共用字号、字重和等宽数字，切换主题时保持文字大小一致。
// 小字统一抬到逻辑 14（屏幕约 8.1pt），这是 440pt 宽面板在不改版式的前提下放得下的上限；
// 再往上要放大面板或删行。数字用等宽字形，跳动时不左右晃；汉字不受影响。
- (NSFont *)fontWithSize:(CGFloat)size weight:(NSFontWeight)weight {
    if (size < 14) size = 14;
    else if (size <= 16) size += 1;
    if (weight < NSFontWeightMedium) weight = NSFontWeightMedium;
    else if (weight < NSFontWeightSemibold) weight = NSFontWeightSemibold;
    else if (weight < NSFontWeightBold) weight = NSFontWeightBold;
    return [NSFont monospacedDigitSystemFontOfSize:size weight:weight];
}
// 局部衬底：只垫在卡片和汇总区下面，面板边缘和卡片间隙保持通透。衬底本身不能带
// 文字投影，否则卡片边缘会多一圈黑晕。
// 原生玻璃下在文字前画一个彩色小圆点，替代原来的彩色字；经典主题照旧画彩色字。
- (void)drawText:(NSString *)text inRect:(NSRect)rect size:(CGFloat)size
    weight:(NSFontWeight)weight color:(NSColor *)color dotColor:(NSColor *)dotColor {
    if (!self.usesLiquidGlass) {
        NSMutableDictionary *attributes = [[self textAttributesWithSize:size color:color
            weight:weight] mutableCopy];
        NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
        style.lineBreakMode = NSLineBreakByTruncatingTail;
        attributes[NSParagraphStyleAttributeName] = style;
        [text drawInRect:rect withAttributes:[self attributes:attributes fittingText:text
            inWidth:NSWidth(rect)]];
        return;
    }
    NSMutableDictionary *attributes = [[self textAttributesWithSize:size color:color
        weight:weight] mutableCopy];
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineBreakMode = NSLineBreakByTruncatingTail;
    attributes[NSParagraphStyleAttributeName] = style;
    NSFont *font = attributes[NSFontAttributeName];
    NSRect textRect = rect;
    if (dotColor) {
        CGFloat diameter = 9;
        // drawInRect: 从矩形顶部开始排版，圆点对齐到首行小写字母的中线。
        CGFloat baselineMid = NSMaxY(rect) - font.ascender + font.xHeight / 2.0;
        [NSGraphicsContext saveGraphicsState];
        [[NSShadow new] set];
        [dotColor setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMinX(rect), baselineMid - diameter / 2.0,
            diameter, diameter)] fill];
        [NSGraphicsContext restoreGraphicsState];
        textRect.origin.x += diameter + 6;
        textRect.size.width -= diameter + 6;
    }
    [text drawInRect:textRect withAttributes:[self attributes:attributes fittingText:text
        inWidth:NSWidth(textRect)]];
}
// 译文长短差得多，固定宽度的格子迟早有放不下的语言。放不下时先把字号往下收，最多收 2pt
// （liquid 下即从 14 收到 12）——比截成"…"好认；还放不下才交给截断。放得下就原样返回，
// 中文和多数英文不受影响。
- (NSDictionary *)attributes:(NSDictionary *)attributes fittingText:(NSString *)text
    inWidth:(CGFloat)width {
    NSFont *font = attributes[NSFontAttributeName];
    if (!font || text.length == 0 || [text sizeWithAttributes:attributes].width <= width) {
        return attributes;
    }
    NSMutableDictionary *fitted = [attributes mutableCopy];
    for (CGFloat size = font.pointSize - 0.5; size >= font.pointSize - 2; size -= 0.5) {
        fitted[NSFontAttributeName] = [NSFont fontWithDescriptor:font.fontDescriptor size:size];
        if ([text sizeWithAttributes:fitted].width <= width) break;
    }
    return fitted;
}
// 风险提示只保留文字，和 Max / Now 使用同一条左边界。
- (void)drawTip:(NSString *)text inRect:(NSRect)rect color:(NSColor *)color {
    if (text.length == 0) return;
    [self drawText:text inRect:rect size:11 weight:NSFontWeightMedium color:color dotColor:nil];
}
- (void)fillLiquidScrim:(NSBezierPath *)path {
    [NSGraphicsContext saveGraphicsState];
    [[NSShadow new] set];
    [[NSColor colorWithWhite:0 alpha:self.cardScrimAlpha] setFill];
    [path fill];
    [NSGraphicsContext restoreGraphicsState];
}
- (NSColor *)textColor:(NSColor *)color {
    if (!self.usesLiquidGlass) return color;
    NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!rgb) return color;
    CGFloat r, g, b, a;
    [rgb getRed:&r green:&g blue:&b alpha:&a];
    CGFloat saturation = MAX(r, MAX(g, b)) - MIN(r, MIN(g, b));
    if (saturation < 0.05) return [NSColor colorWithWhite:MAX(MAX(r, MAX(g, b)), 0.84) alpha:a];
    // 彩色字在任意亮度的背景上对比都不稳定，原生玻璃下文字一律用白色；颜色的语义改由
    // 字前的小圆点、图标和曲线承担（见 drawText:inRect:size:weight:color:dotColor:）。
    return [NSColor colorWithWhite:0.96 alpha:a];
}
- (NSDictionary *)textAttributesWithSize:(CGFloat)size color:(NSColor *)color weight:(NSFontWeight)weight {
    return @{NSFontAttributeName: [self fontWithSize:size weight:weight],
             NSForegroundColorAttributeName: [self textColor:color]};
}
- (NSDictionary *)rightAlignedTextAttributesWithSize:(CGFloat)size color:(NSColor *)color
    weight:(NSFontWeight)weight {
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentRight;
    return @{NSFontAttributeName: [self fontWithSize:size weight:weight],
             NSForegroundColorAttributeName: [self textColor:color],
             NSParagraphStyleAttributeName: style};
}
- (NSDictionary *)centeredTextAttributesWithSize:(CGFloat)size color:(NSColor *)color weight:(NSFontWeight)weight {
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentCenter;
    return @{NSFontAttributeName: [self fontWithSize:size weight:weight],
             NSForegroundColorAttributeName: [self textColor:color],
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
@end
