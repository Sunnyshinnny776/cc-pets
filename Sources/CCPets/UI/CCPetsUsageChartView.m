#import "CCPetsUsageChartView.h"
#import "CCPetsUIStyle.h"

@interface CCPetsUsageChartView ()
@property(nonatomic) NSInteger hoverIndex;
@end

@implementation CCPetsUsageChartView

static const CGFloat ChartLeft = 50, ChartBottom = 24, ChartTop = 10, ChartRight = 4;

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _hoverIndex = -1;
        [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
            options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow |
                    NSTrackingInVisibleRect owner:self userInfo:nil]];
    }
    return self;
}

- (BOOL)isFlipped {
    return NO;
}

- (void)reloadData {
    self.hoverIndex = -1;
    self.needsDisplay = YES;
}

// 纵轴分四格，步长取 1 / 2 / 2.5 / 5 × 10^n：每条刻度都是整齐的数，不会出现 133M / 66.7M。
static double NiceStep(double peak) {
    if (peak <= 0) return 1;
    double raw = peak / 4;
    double magnitude = pow(10, floor(log10(raw)));
    for (NSNumber *step in @[@1, @2, @2.5, @5, @10]) {
        if (raw <= step.doubleValue * magnitude) return step.doubleValue * magnitude;
    }
    return 10 * magnitude;
}

- (NSRect)plotRect {
    return NSMakeRect(ChartLeft, ChartBottom, NSWidth(self.bounds) - ChartLeft - ChartRight,
        NSHeight(self.bounds) - ChartBottom - ChartTop);
}

- (double)totalAtIndex:(NSUInteger)index {
    double total = 0;
    for (NSDictionary *layer in self.series) total += [layer[@"values"][index] doubleValue];
    return total;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect plot = [self plotRect];
    NSUInteger count = self.days.count;
    double peak = 0;
    for (NSUInteger index = 0; index < count; index++) peak = MAX(peak, [self totalAtIndex:index]);
    double step = NiceStep(peak);
    double top = step * 4;
    NSDictionary *axisAttributes = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10
        weight:NSFontWeightRegular], NSForegroundColorAttributeName: CCPetsTertiaryInkColor()};

    // 网格：底线实线，其余虚线，都很淡，让柱子当主角。
    for (int line = 0; line <= 4; line++) {
        CGFloat y = round(NSMinY(plot) + plot.size.height * line / 4.0) + 0.5;
        NSBezierPath *path = [NSBezierPath bezierPath];
        [path moveToPoint:NSMakePoint(NSMinX(plot), y)];
        [path lineToPoint:NSMakePoint(NSMaxX(plot), y)];
        path.lineWidth = 1;
        if (line > 0) {
            CGFloat dash[] = {3, 3};
            [path setLineDash:dash count:2 phase:0];
        }
        [CCPetsLineColor() set];
        [path stroke];
        NSString *label = MetricText(self.metric, (unsigned long long)(step * line));
        NSSize size = [label sizeWithAttributes:axisAttributes];
        [label drawAtPoint:NSMakePoint(NSMinX(plot) - size.width - 8, y - size.height / 2)
            withAttributes:axisAttributes];
    }
    if (count == 0) return;

    CGFloat slot = plot.size.width / count;
    CGFloat barWidth = MAX(2, MIN(26, slot * 0.62));
    if (self.hoverIndex >= 0 && self.hoverIndex < (NSInteger)count) {
        [CCPetsHoverColor() set];
        NSRectFillUsingOperation(NSMakeRect(NSMinX(plot) + slot * self.hoverIndex, NSMinY(plot), slot,
            plot.size.height), NSCompositingOperationSourceOver);
    }
    for (NSUInteger index = 0; index < count; index++) {
        CGFloat x = round(NSMinX(plot) + slot * index + (slot - barWidth) / 2);
        CGFloat y = NSMinY(plot) + 1;
        NSMutableArray<NSValue *> *segments = [NSMutableArray array];
        NSMutableArray<NSColor *> *colors = [NSMutableArray array];
        for (NSDictionary *layer in self.series) {
            double value = [layer[@"values"][index] doubleValue];
            if (value <= 0) continue;
            CGFloat height = MAX(1, plot.size.height * value / top);
            [segments addObject:[NSValue valueWithRect:NSMakeRect(x, y, barWidth, height)]];
            [colors addObject:layer[@"color"]];
            y += height;
        }
        // 堆叠段之间留 1pt 的底色缝，相邻两色分得清；最顶上一段圆角。
        for (NSUInteger part = 0; part < segments.count; part++) {
            NSRect rect = segments[part].rectValue;
            BOOL last = part == segments.count - 1;
            if (!last && rect.size.height > 2) rect.size.height -= 1;
            [colors[part] set];
            if (last && rect.size.height >= 3) {
                CGFloat radius = MIN(2.5, barWidth / 3);
                NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius];
                [path fill];
                NSRectFill(NSMakeRect(rect.origin.x, rect.origin.y, rect.size.width, MIN(radius, rect.size.height)));
            } else {
                NSRectFill(rect);
            }
        }
    }
    [self drawDateLabelsInPlot:plot slot:slot attributes:axisAttributes];
    if (self.hoverIndex >= 0 && self.hoverIndex < (NSInteger)count) [self drawTooltipInPlot:plot slot:slot];
}

// 横轴只标六个左右的日期，最后一个写"今天"；天数多了标满会挤成一团。
- (void)drawDateLabelsInPlot:(NSRect)plot slot:(CGFloat)slot attributes:(NSDictionary *)attributes {
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"M/d";
    });
    NSUInteger count = self.days.count;
    NSUInteger labelStep = MAX(1, (NSUInteger)ceil(count / 6.0));
    CGFloat lastRight = -CGFLOAT_MAX;
    // 从今天往回标：保证"今天"一定出现，其余按步长倒推。
    NSMutableArray<NSNumber *> *indexes = [NSMutableArray array];
    for (NSInteger index = (NSInteger)count - 1; index >= 0; index -= (NSInteger)labelStep) [indexes insertObject:@(index) atIndex:0];
    for (NSNumber *number in indexes) {
        NSUInteger index = number.unsignedIntegerValue;
        NSString *label = index == count - 1 ? L(@"today")
            : [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:self.days[index].doubleValue]];
        NSSize size = [label sizeWithAttributes:attributes];
        CGFloat x = NSMinX(plot) + slot * index + slot / 2 - size.width / 2;
        x = MIN(MAX(x, NSMinX(plot) - 4), NSMaxX(self.bounds) - size.width);
        if (x < lastRight + 6) continue;
        [label drawAtPoint:NSMakePoint(x, 5) withAttributes:attributes];
        lastRight = x + size.width;
    }
}

// 悬停明细：深色日期条 + 每行一个色条、名字、数值 + 合计。全部模型时按当天量从大到小列各模型
// （当天为 0 的不列）；单个模型时列它的输入、缓存写、输出、缓存读和请求。
- (void)drawTooltipInPlot:(NSRect)plot slot:(CGFloat)slot {
    NSUInteger index = (NSUInteger)self.hoverIndex;
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    if (self.singleModel) {
        NSDictionary *layer = self.series.firstObject;
        NSDictionary *counts = layer[@"counts"][index];
        NSColor *color = layer[@"color"];
        for (NSArray *part in @[@[L(@"Input"), @"input"], @[L(@"Cache Write"), @"cacheWrite"],
                                @[L(@"Output"), @"output"], @[L(@"Cached Input"), @"cacheRead"]]) {
            [rows addObject:@{@"title": part[0], @"value": CCPetsFormatTokens(Count(counts, part[1])), @"color": color}];
        }
        [rows addObject:@{@"title": L(@"Requests"), @"value": FormatCount(Count(counts, @"requests")), @"color": color}];
    } else {
        NSMutableArray<NSDictionary *> *layers = [NSMutableArray array];
        for (NSDictionary *layer in self.series) {
            if ([layer[@"values"][index] doubleValue] > 0) [layers addObject:layer];
        }
        [layers sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"values"][index] compare:a[@"values"][index]];
        }];
        for (NSDictionary *layer in layers) {
            [rows addObject:@{@"title": layer[@"title"], @"color": layer[@"color"],
                @"value": MetricText(self.metric, [layer[@"values"][index] unsignedLongLongValue])}];
        }
    }
    NSString *total = MetricText(self.metric, (unsigned long long)[self totalAtIndex:index]);

    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.dateStyle = NSDateFormatterMediumStyle;
        formatter.timeStyle = NSDateFormatterNoStyle;
    });
    NSString *date = [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:self.days[index].doubleValue]];

    NSDictionary *nameAttributes = @{NSFontAttributeName: [NSFont systemFontOfSize:11],
                                     NSForegroundColorAttributeName: CCPetsSecondaryInkColor()};
    NSDictionary *valueAttributes = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11
        weight:NSFontWeightMedium], NSForegroundColorAttributeName: CCPetsInkColor()};
    NSDictionary *totalAttributes = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11
        weight:NSFontWeightSemibold], NSForegroundColorAttributeName: CCPetsInkColor()};
    NSDictionary *dateAttributes = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
                                     NSForegroundColorAttributeName: CCPetsCardColor()};
    CGFloat width = [date sizeWithAttributes:dateAttributes].width + 24;
    for (NSDictionary *row in rows) {
        width = MAX(width, [row[@"title"] sizeWithAttributes:nameAttributes].width +
            [row[@"value"] sizeWithAttributes:valueAttributes].width + 46);
    }
    NSString *totalTitle = self.singleModel ? [NSString stringWithFormat:@"%@ · %@", L(@"Total"),
        [self metricTitle]] : L(@"Total");
    NSDictionary *totalTitleAttributes = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
                                           NSForegroundColorAttributeName: CCPetsInkColor()};
    width = MAX(width, [totalTitle sizeWithAttributes:totalTitleAttributes].width +
        [total sizeWithAttributes:totalAttributes].width + 36);
    width = MIN(MAX(width, 150), 300);
    const CGFloat headerHeight = 24, rowHeight = 18, padding = 6;
    CGFloat height = headerHeight + padding + rows.count * rowHeight + 1 + rowHeight + padding;

    // 放在柱子右边，放不下就放左边；竖直方向贴着绘图区顶部，超出时往下压。
    CGFloat barCenter = NSMinX(plot) + slot * index + slot / 2;
    CGFloat x = barCenter + slot / 2 + 8;
    if (x + width > NSMaxX(self.bounds) - 2) x = barCenter - slot / 2 - 8 - width;
    x = MAX(2, x);
    CGFloat y = MAX(2, NSMaxY(plot) - height);
    NSRect box = NSMakeRect(x, y, width, height);

    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.18];
    shadow.shadowBlurRadius = 10;
    shadow.shadowOffset = NSMakeSize(0, -3);
    [shadow set];
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:box xRadius:8 yRadius:8];
    [CCPetsCardColor() set];
    [outline fill];
    [NSGraphicsContext restoreGraphicsState];
    [CCPetsLineColor() set];
    [outline stroke];

    [NSGraphicsContext saveGraphicsState];
    [outline addClip];
    [CCPetsInkColor() set];
    NSRectFill(NSMakeRect(NSMinX(box), NSMaxY(box) - headerHeight, width, headerHeight));
    [NSGraphicsContext restoreGraphicsState];
    [date drawAtPoint:NSMakePoint(NSMinX(box) + 10, NSMaxY(box) - headerHeight + 5) withAttributes:dateAttributes];

    CGFloat rowY = NSMaxY(box) - headerHeight - padding - rowHeight;
    for (NSDictionary *row in rows) {
        [(NSColor *)row[@"color"] set];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMinX(box) + 10, rowY + 3, 3, 12) xRadius:1.5 yRadius:1.5] fill];
        NSString *title = row[@"title"];
        CGFloat valueWidth = [row[@"value"] sizeWithAttributes:valueAttributes].width;
        [title drawWithRect:NSMakeRect(NSMinX(box) + 19, rowY + 2, width - 19 - valueWidth - 18, 14)
            options:NSStringDrawingTruncatesLastVisibleLine | NSStringDrawingUsesLineFragmentOrigin
            attributes:nameAttributes];
        [row[@"value"] drawAtPoint:NSMakePoint(NSMaxX(box) - 10 - valueWidth, rowY + 2) withAttributes:valueAttributes];
        rowY -= rowHeight;
    }
    [CCPetsLineColor() set];
    NSRectFill(NSMakeRect(NSMinX(box) + 10, rowY + rowHeight, width - 20, 1));
    rowY -= 1;
    [totalTitle drawAtPoint:NSMakePoint(NSMinX(box) + 10, rowY + 2) withAttributes:totalTitleAttributes];
    CGFloat totalWidth = [total sizeWithAttributes:totalAttributes].width;
    [total drawAtPoint:NSMakePoint(NSMaxX(box) - 10 - totalWidth, rowY + 2) withAttributes:totalAttributes];
}

- (NSString *)metricTitle {
    return MetricTitle(self.metric);
}

- (NSInteger)indexForEvent:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect plot = [self plotRect];
    if (self.days.count == 0 || !NSPointInRect(point, NSInsetRect(plot, 0, -ChartTop))) return -1;
    NSInteger index = (NSInteger)floor((point.x - NSMinX(plot)) / (plot.size.width / self.days.count));
    return index >= 0 && index < (NSInteger)self.days.count ? index : -1;
}

- (void)mouseMoved:(NSEvent *)event {
    NSInteger index = [self indexForEvent:event];
    if (index == self.hoverIndex) return;
    self.hoverIndex = index;
    self.needsDisplay = YES;
}

- (void)mouseExited:(NSEvent *)event {
    if (self.hoverIndex < 0) return;
    self.hoverIndex = -1;
    self.needsDisplay = YES;
}

@end
