#import "CCPetsUsagePage.h"
#import "CCPetsFormBuilder.h"
#import "CCPetsL10n.h"
#import "CCPetsUsage.h"

// 四栏的固定颜色，条形图、柱状图、图例共用。次序即堆叠次序（自下而上）。
static NSArray<NSString *> *UsageKinds(void) {
    return @[@"cacheRead", @"input", @"cacheWrite", @"output"];
}

static NSColor *UsageKindColor(NSString *kind) {
    if ([kind isEqualToString:@"cacheRead"]) return NSColor.systemTealColor;
    if ([kind isEqualToString:@"input"]) return NSColor.systemBlueColor;
    if ([kind isEqualToString:@"cacheWrite"]) return NSColor.systemOrangeColor;
    return NSColor.systemPurpleColor;
}

static NSString *UsageKindTitle(NSString *kind) {
    if ([kind isEqualToString:@"cacheRead"]) return L(@"Cache Read");
    if ([kind isEqualToString:@"input"]) return L(@"Input");
    if ([kind isEqualToString:@"cacheWrite"]) return L(@"Cache Write");
    return L(@"Output");
}

static unsigned long long Count(NSDictionary *counts, NSString *key) {
    return [counts[key] unsignedLongLongValue];
}

static unsigned long long TotalTokens(NSDictionary *counts) {
    unsigned long long total = 0;
    for (NSString *kind in UsageKinds()) total += Count(counts, kind);
    return total;
}

// 1234 -> 1.23K，1234567 -> 1.23M：卡片里放不下一长串数字，精确值在悬停时给。
// 先按三位有效数字舍入再定单位：999,950 直接格式化会得到 "1000K"，9,995 会得到 "10.00K"。
static NSString *FormatTokens(unsigned long long value) {
    if (value < 1000) return [NSString stringWithFormat:@"%llu", value];
    double scaled = (double)value;
    NSUInteger unit = 0;
    NSArray<NSString *> *suffixes = @[@"K", @"M", @"B", @"T"];
    while (unit < suffixes.count) {
        scaled /= 1000;
        double rounded = scaled >= 100 ? round(scaled) : (scaled >= 10 ? round(scaled * 10) / 10 : round(scaled * 100) / 100);
        if (rounded < 1000 || unit == suffixes.count - 1) {
            scaled = rounded;
            break;
        }
        unit++;
    }
    return [NSString stringWithFormat:scaled >= 100 ? @"%.0f%@" : (scaled >= 10 ? @"%.1f%@" : @"%.2f%@"),
        scaled, suffixes[unit]];
}

// 命中率 = 缓存读 / 全部输入侧（非缓存输入 + 缓存读 + 缓存写）。两家的原始口径不同，
// 但 CCPetsModelUsage 已经统一成四栏互不重叠，所以这里同一个公式。
static NSString *HitRateText(NSDictionary *counts) {
    unsigned long long side = Count(counts, @"input") + Count(counts, @"cacheRead") + Count(counts, @"cacheWrite");
    if (side == 0) return @"–";
    return [NSString stringWithFormat:@"%.0f%%", 100.0 * Count(counts, @"cacheRead") / side];
}

static NSString *ProviderTitle(NSString *provider) {
    return [provider isEqualToString:@"claude"] ? @"Claude Code" : @"Codex";
}

// 数据层把认不出模型的用量记在 "unknown" 名下（旧格式会话、没见过 turn_context 的续读段），
// 这个名字是内部占位，显示时换成本地化文案。
static NSString *ModelTitle(NSString *model) {
    return [model isEqualToString:@"unknown"] ? L(@"Unknown Model") : model;
}

// 页面一次统计这么多天，切换 7 / 30 / 90 天只在本地截取，不再回数据层重算。
// 数据层按请求的起点清理缓存，区间来回切会让 90 天里较早的会话缓存被删了又重读。
static const NSInteger UsageMaximumRangeDays = 90;

static NSMutableDictionary *SummedCounts(NSArray<NSDictionary *> *list) {
    NSMutableDictionary *sum = [NSMutableDictionary dictionary];
    for (NSDictionary *counts in list) {
        for (NSString *key in @[@"input", @"cacheRead", @"cacheWrite", @"output", @"reasoning", @"requests"]) {
            sum[key] = @(Count(sum, key) + Count(counts, key));
        }
    }
    return sum;
}

#pragma mark - 部件

// 一个模型的四栏占比条。
@interface CCPetsUsageProportionBar : NSView
@property(nonatomic) NSDictionary *counts;
@end

@implementation CCPetsUsageProportionBar
- (NSSize)intrinsicContentSize {
    return NSMakeSize(NSViewNoIntrinsicMetric, 6);
}
- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    [NSGraphicsContext saveGraphicsState];
    [[NSBezierPath bezierPathWithRoundedRect:bounds xRadius:3 yRadius:3] addClip];
    [[NSColor.quaternaryLabelColor colorWithAlphaComponent:0.5] set];
    NSRectFill(bounds);
    double total = (double)TotalTokens(self.counts);
    CGFloat x = 0;
    for (NSString *kind in UsageKinds()) {
        if (total <= 0) break;
        CGFloat width = bounds.size.width * Count(self.counts, kind) / total;
        [UsageKindColor(kind) set];
        NSRectFill(NSMakeRect(x, 0, width, bounds.size.height));
        x += width;
    }
    [NSGraphicsContext restoreGraphicsState];
}
@end

// 列表里的一行：点一下选中。
@interface CCPetsUsageModelRow : NSView
@property(nonatomic) BOOL selected;
// 会换行的那行说明。自动布局算不出换行标签的高度（宽度没定之前它只会按一行算），
// 所以行宽确定后手动把宽度告诉它。
@property(nonatomic, weak) NSTextField *wrappingDetail;
@property(nonatomic, copy) void (^onClick)(void);
@end

@implementation CCPetsUsageModelRow
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) self.wantsLayer = YES;
    return self;
}
- (void)layout {
    CGFloat width = NSWidth(self.bounds) - 28;
    if (self.wrappingDetail && width > 0 && fabs(self.wrappingDetail.preferredMaxLayoutWidth - width) > 0.5) {
        self.wrappingDetail.preferredMaxLayoutWidth = width;
    }
    [super layout];
}
- (BOOL)wantsUpdateLayer {
    return YES;
}
- (void)updateLayer {
    self.layer.backgroundColor = self.selected
        ? [NSColor.controlAccentColor colorWithAlphaComponent:0.12].CGColor : NSColor.clearColor.CGColor;
}
- (void)setSelected:(BOOL)selected {
    _selected = selected;
    self.needsDisplay = YES;
}
- (void)mouseDown:(NSEvent *)event {
    if (self.onClick) self.onClick();
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}
@end

// 每日堆叠柱状图：横轴是天，纵轴是 Token，四栏堆叠。鼠标移上去报告是哪一天。
@interface CCPetsUsageChartView : NSView
// 每项：timestamp（日零点）、counts。
@property(nonatomic, copy) NSArray<NSDictionary *> *days;
@property(nonatomic, copy) void (^hoverChanged)(NSInteger index);
@end

@interface CCPetsUsageChartView ()
@property(nonatomic) NSInteger hoverIndex;
@end

@implementation CCPetsUsageChartView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _hoverIndex = -1;
        [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
            options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow |
                    NSTrackingInVisibleRect owner:self userInfo:nil]];
    }
    return self;
}
- (NSSize)intrinsicContentSize {
    return NSMakeSize(NSViewNoIntrinsicMetric, 200);
}
- (void)setDays:(NSArray<NSDictionary *> *)days {
    _days = [days copy];
    self.hoverIndex = -1;
    self.needsDisplay = YES;
}

static const CGFloat ChartLeft = 46, ChartBottom = 22, ChartTop = 8, ChartRight = 4;

// 纵轴只画 0、一半、顶三条线，顶取 1/2/4/5/8 × 10^n：一半也是整齐的数，不会出现 133M / 66.7M。
static double NiceMaximum(double value) {
    if (value <= 0) return 1;
    double magnitude = pow(10, floor(log10(value)));
    for (NSNumber *step in @[@1, @2, @4, @5, @8, @10]) {
        if (value <= step.doubleValue * magnitude) return step.doubleValue * magnitude;
    }
    return 10 * magnitude;
}

- (NSRect)plotRect {
    return NSMakeRect(ChartLeft, ChartBottom, NSWidth(self.bounds) - ChartLeft - ChartRight,
        NSHeight(self.bounds) - ChartBottom - ChartTop);
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect plot = [self plotRect];
    NSUInteger count = self.days.count;
    double peak = 0;
    for (NSDictionary *day in self.days) peak = MAX(peak, (double)TotalTokens(day[@"counts"]));
    double top = NiceMaximum(peak);
    NSDictionary *labelAttributes = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10
        weight:NSFontWeightRegular], NSForegroundColorAttributeName: NSColor.secondaryLabelColor};

    // 横向网格线 + 纵轴刻度。
    for (int line = 0; line <= 2; line++) {
        CGFloat y = NSMinY(plot) + plot.size.height * line / 2.0;
        [(line == 0 ? NSColor.separatorColor : [NSColor.separatorColor colorWithAlphaComponent:0.4]) set];
        NSRectFill(NSMakeRect(NSMinX(plot), y - 0.5, plot.size.width, 1));
        NSString *label = FormatTokens((unsigned long long)(top * line / 2.0));
        NSSize size = [label sizeWithAttributes:labelAttributes];
        [label drawAtPoint:NSMakePoint(NSMinX(plot) - size.width - 6, y - size.height / 2)
            withAttributes:labelAttributes];
    }
    if (count == 0) return;

    CGFloat slot = plot.size.width / count;
    CGFloat barWidth = MAX(2, MIN(28, slot * 0.68));
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"M/d";
    });
    // 横轴只标几个日期，天数多了标满会挤成一团。
    NSUInteger labelStep = MAX(1, (NSUInteger)ceil(count / 6.0));
    for (NSUInteger index = 0; index < count; index++) {
        NSDictionary *counts = self.days[index][@"counts"];
        CGFloat x = NSMinX(plot) + slot * index + (slot - barWidth) / 2;
        CGFloat y = NSMinY(plot);
        if ((NSInteger)index == self.hoverIndex) {
            [[NSColor.labelColor colorWithAlphaComponent:0.07] set];
            NSRectFill(NSMakeRect(NSMinX(plot) + slot * index, NSMinY(plot), slot, plot.size.height));
        }
        for (NSString *kind in UsageKinds()) {
            CGFloat height = plot.size.height * Count(counts, kind) / top;
            if (height <= 0) continue;
            [UsageKindColor(kind) set];
            NSRectFill(NSMakeRect(x, y, barWidth, MAX(height, 0.5)));
            y += height;
        }
        if (index % labelStep == 0 || index == count - 1) {
            NSDate *date = [NSDate dateWithTimeIntervalSince1970:[self.days[index][@"timestamp"] doubleValue]];
            NSString *label = [formatter stringFromDate:date];
            NSSize size = [label sizeWithAttributes:labelAttributes];
            if (index % labelStep == 0 || slot * (count - 1 - index) > size.width) {
                [label drawAtPoint:NSMakePoint(NSMinX(plot) + slot * index + slot / 2 - size.width / 2, 4)
                    withAttributes:labelAttributes];
            }
        }
    }
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
    if (self.hoverChanged) self.hoverChanged(index);
}
- (void)mouseExited:(NSEvent *)event {
    if (self.hoverIndex < 0) return;
    self.hoverIndex = -1;
    self.needsDisplay = YES;
    if (self.hoverChanged) self.hoverChanged(-1);
}
@end

#pragma mark - 页面

@interface CCPetsUsageHandler : NSObject
@property(nonatomic, copy) void (^block)(id sender);
- (void)invoke:(id)sender;
@end

@implementation CCPetsUsageHandler
- (void)invoke:(id)sender {
    if (self.block) self.block(sender);
}
@end

@interface CCPetsUsagePage ()
@property(nonatomic) CCPetsFormBuilder *form;
@property(nonatomic) NSSegmentedControl *sourceControl;
@property(nonatomic) NSPopUpButton *rangeControl;
@property(nonatomic) NSProgressIndicator *spinner;
@property(nonatomic) NSMutableArray<CCPetsUsageHandler *> *handlers;
// 最近 UsageMaximumRangeDays 天的结果：provider -> CCPetsModelUsage 的返回值。
@property(nonatomic) NSDictionary<NSString *, NSDictionary *> *results;
// 当前筛选下的模型条目：provider、model、counts、days（每天的 counts）。
@property(nonatomic) NSArray<NSDictionary *> *entries;
@property(nonatomic) NSArray<CCPetsUsageModelRow *> *rows;
@property(nonatomic) NSInteger selectedIndex;
@property(nonatomic) CCPetsUsageChartView *chart;
@property(nonatomic) NSTextField *chartCaption;
@property(nonatomic) NSTextField *chartDetail;
@property(nonatomic) NSUInteger generation;
@end

@implementation CCPetsUsagePage

- (void)bind:(NSControl *)control to:(void (^)(id sender))block {
    CCPetsUsageHandler *handler = [CCPetsUsageHandler new];
    handler.block = block;
    [self.handlers addObject:handler];
    control.target = handler;
    control.action = @selector(invoke:);
}

- (void)loadView {
    self.handlers = [NSMutableArray array];
    self.form = [CCPetsFormBuilder new];
    self.selectedIndex = 0;
    __weak typeof(self) weakSelf = self;

    NSSegmentedControl *source = [NSSegmentedControl segmentedControlWithLabels:
        @[L(@"All"), @"Claude Code", @"Codex"] trackingMode:NSSegmentSwitchTrackingSelectOne
        target:nil action:nil];
    source.selectedSegment = 0;
    [self bind:source to:^(id sender) {
        weakSelf.selectedIndex = 0;
        [weakSelf render];
    }];
    self.sourceControl = source;

    NSPopUpButton *range = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSNumber *days in @[@7, @30, @90]) {
        [range addItemWithTitle:[NSString stringWithFormat:L(@"Last %ld Days"), (long)days.integerValue]];
        range.lastItem.representedObject = days;
    }
    [range selectItemAtIndex:1];
    [self bind:range to:^(id sender) {
        weakSelf.selectedIndex = 0;
        [weakSelf render];
    }];
    self.rangeControl = range;

    NSProgressIndicator *spinner = [NSProgressIndicator new];
    spinner.style = NSProgressIndicatorStyleSpinning;
    spinner.controlSize = NSControlSizeSmall;
    spinner.displayedWhenStopped = NO;
    self.spinner = spinner;

    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *header = [NSStackView stackViewWithViews:@[source, spacer, spinner, range]];
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.alignment = NSLayoutAttributeCenterY;
    header.spacing = 8;
    header.edgeInsets = NSEdgeInsetsMake(14, 28, 10, 28);
    header.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 560)];
    NSScrollView *scroll = self.form.scrollView;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:header];
    [root addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:root.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];
    self.view = root;
    [self reload];
}

- (void)dealloc {
    // 已经在跑的统计取消不了，但页面没了就没人接结果；generation 变了回调会直接丢弃。
    self.generation++;
}

// 区间是 [今天往前数 N-1 天的零点, 明天零点)，含今天。始终统计最长的那档，显示时再截取。
- (void)reload {
    NSInteger days = UsageMaximumRangeDays;
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *end = [calendar dateByAddingUnit:NSCalendarUnitDay value:1
        toDate:[calendar startOfDayForDate:NSDate.date] options:0];
    NSDate *start = [calendar dateByAddingUnit:NSCalendarUnitDay value:-days toDate:end options:0];
    NSUInteger generation = ++self.generation;
    [self.spinner startAnimation:nil];
    __weak typeof(self) weakSelf = self;
    // 串行队列：快速连切区间时，后一次等前一次算完再开始，不会两份同时写同一批缓存文件。
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.ccpets.model-usage", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(queue, ^{
        NSMutableDictionary *results = [NSMutableDictionary dictionary];
        for (NSString *provider in @[@"claude", @"codex"]) {
            // 页面已经被换掉就别白算了。
            if (weakSelf.generation != generation) return;
            NSDictionary *usage = CCPetsModelUsage(provider, start.timeIntervalSince1970,
                end.timeIntervalSince1970);
            if (usage) results[provider] = usage;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            CCPetsUsagePage *page = weakSelf;
            if (!page || page.generation != generation) return;
            page.results = results;
            [page.spinner stopAnimation:nil];
            [page render];
        });
    });
}

// 按当前筛选把结果整理成条目，按 Token 总量从大到小。区间合计由截取后的每日数据现加，
// 不用数据层的 models（那是整整 90 天的）。
- (NSArray<NSDictionary *> *)entriesForSource:(NSInteger)source rangeDays:(NSInteger)rangeDays {
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSArray<NSString *> *providers = source == 1 ? @[@"claude"] : (source == 2 ? @[@"codex"] : @[@"claude", @"codex"]);
    for (NSString *provider in providers) {
        NSArray<NSDictionary *> *daily = self.results[provider][@"daily"];
        if (daily.count > (NSUInteger)rangeDays) {
            daily = [daily subarrayWithRange:NSMakeRange(daily.count - (NSUInteger)rangeDays, (NSUInteger)rangeDays)];
        }
        NSMutableDictionary<NSString *, NSMutableArray *> *perModel = [NSMutableDictionary dictionary];
        for (NSDictionary *day in daily) {
            for (NSString *model in day[@"models"]) {
                if (!perModel[model]) perModel[model] = [NSMutableArray array];
                [perModel[model] addObject:day[@"models"][model]];
            }
        }
        for (NSString *model in perModel) {
            NSDictionary *counts = SummedCounts(perModel[model]);
            if (TotalTokens(counts) == 0 && Count(counts, @"requests") == 0) continue;
            NSMutableArray<NSDictionary *> *days = [NSMutableArray arrayWithCapacity:daily.count];
            for (NSDictionary *day in daily) {
                [days addObject:@{@"timestamp": day[@"timestamp"], @"counts": day[@"models"][model] ?: @{}}];
            }
            [entries addObject:@{@"provider": provider, @"model": model, @"counts": counts, @"days": days}];
        }
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        unsigned long long left = TotalTokens(a[@"counts"]), right = TotalTokens(b[@"counts"]);
        return left == right ? NSOrderedSame : (left > right ? NSOrderedAscending : NSOrderedDescending);
    }];
    return entries;
}

- (NSTextField *)smallLabel:(NSString *)text color:(NSColor *)color {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

- (NSView *)valueRowWithTitle:(NSString *)title value:(NSString *)value {
    NSTextField *label = [NSTextField labelWithString:value];
    label.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightMedium];
    return [CCPetsFormBuilder rowWithTitle:title controls:@[label]];
}

// 一个模型一行：名字 + 来源 + 总量，下面是四栏占比条，最下面是各栏数值和命中率。
- (CCPetsUsageModelRow *)rowForEntry:(NSDictionary *)entry index:(NSInteger)index {
    NSDictionary *counts = entry[@"counts"];
    NSTextField *name = [NSTextField labelWithString:ModelTitle(entry[@"model"])];
    name.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold];
    name.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSTextField *provider = [self smallLabel:ProviderTitle(entry[@"provider"]) color:NSColor.secondaryLabelColor];
    NSTextField *total = [NSTextField labelWithString:FormatTokens(TotalTokens(counts))];
    total.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightMedium];
    total.toolTip = [NSString stringWithFormat:@"%llu", TotalTokens(counts)];
    [name setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
        forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *top = [NSStackView stackViewWithViews:@[name, provider, spacer, total]];
    top.alignment = NSLayoutAttributeFirstBaseline;
    top.spacing = 8;

    CCPetsUsageProportionBar *bar = [CCPetsUsageProportionBar new];
    bar.counts = counts;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [bar.heightAnchor constraintEqualToConstant:6].active = YES;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *kind in @[@"input", @"cacheRead", @"cacheWrite", @"output"]) {
        [parts addObject:[NSString stringWithFormat:@"%@ %@", UsageKindTitle(kind), FormatTokens(Count(counts, kind))]];
    }
    [parts addObject:[NSString stringWithFormat:@"%@ %@", L(@"Hit Rate"), HitRateText(counts)]];
    unsigned long long requests = Count(counts, @"requests");
    [parts addObject:requests == 1 ? L(@"1 request") : [NSString stringWithFormat:L(@"%llu requests"), requests]];
    NSTextField *detail = [NSTextField wrappingLabelWithString:[parts componentsJoinedByString:@" · "]];
    detail.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    detail.textColor = NSColor.secondaryLabelColor;

    NSStackView *stack = [NSStackView stackViewWithViews:@[top, bar, detail]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    CCPetsUsageModelRow *row = [[CCPetsUsageModelRow alloc] initWithFrame:NSZeroRect];
    [row addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [stack.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
        [stack.topAnchor constraintEqualToAnchor:row.topAnchor constant:10],
        [stack.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-10],
        [top.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [bar.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [detail.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    ]];
    row.wrappingDetail = detail;
    __weak typeof(self) weakSelf = self;
    row.onClick = ^{ [weakSelf selectEntryAtIndex:index]; };
    return row;
}

- (void)render {
    NSInteger source = self.sourceControl.selectedSegment;
    NSInteger rangeDays = [self.rangeControl.selectedItem.representedObject integerValue] ?: 30;
    self.entries = [self entriesForSource:source rangeDays:rangeDays];
    if (self.selectedIndex >= (NSInteger)self.entries.count) self.selectedIndex = 0;
    [self.form removeAllSections];
    // 还没算完（打开页面后立刻切了来源）：先空着，转圈的指示器已经在说明在算，别闪一下"没有数据"。
    if (!self.results) {
        self.rows = @[];
        self.chart = nil;
        return;
    }

    if (self.entries.count == 0) {
        NSTextField *empty = [NSTextField wrappingLabelWithString:L(@"No usage data in this period.")];
        empty.textColor = NSColor.secondaryLabelColor;
        [self.form addSectionWithID:@"overview" title:L(@"Overview") symbol:@"chart.bar.xaxis"
            color:NSColor.systemBlueColor rows:@[[CCPetsFormBuilder rowWithTitle:empty.stringValue controls:@[]]]
            footer:nil];
        self.rows = @[];
        self.chart = nil;
        return;
    }

    NSMutableDictionary *sum = SummedCounts([self.entries valueForKey:@"counts"]);
    [self.form addSectionWithID:@"overview" title:L(@"Overview") symbol:@"chart.bar.xaxis"
        color:NSColor.systemBlueColor rows:@[
        [self valueRowWithTitle:L(@"Total Tokens") value:FormatTokens(TotalTokens(sum))],
        [self valueRowWithTitle:L(@"Requests") value:[NSString stringWithFormat:@"%llu", Count(sum, @"requests")]],
        [self valueRowWithTitle:L(@"Hit Rate") value:HitRateText(sum)],
    ] footer:L(@"Counted from local session logs. Input excludes cached tokens; Codex cached tokens are subtracted from its input.")];

    NSMutableArray<CCPetsUsageModelRow *> *rows = [NSMutableArray array];
    for (NSUInteger index = 0; index < self.entries.count; index++) {
        [rows addObject:[self rowForEntry:self.entries[index] index:(NSInteger)index]];
    }
    self.rows = rows;
    [self.form addSectionWithID:@"models" title:L(@"By Model") symbol:@"cpu"
        color:NSColor.systemIndigoColor rows:rows footer:nil];

    // 图表：当前选中模型每天的四栏堆叠。
    CCPetsUsageChartView *chart = [CCPetsUsageChartView new];
    chart.translatesAutoresizingMaskIntoConstraints = NO;
    [chart.heightAnchor constraintEqualToConstant:200].active = YES;
    __weak typeof(self) weakSelf = self;
    chart.hoverChanged = ^(NSInteger index) { [weakSelf showDayDetailAtIndex:index]; };
    self.chart = chart;
    self.chartCaption = [self smallLabel:@"" color:NSColor.secondaryLabelColor];
    self.chartDetail = [self smallLabel:@"" color:NSColor.labelColor];

    NSMutableArray<NSView *> *legendItems = [NSMutableArray array];
    for (NSString *kind in @[@"input", @"cacheRead", @"cacheWrite", @"output"]) {
        NSView *swatch = [NSView new];
        swatch.wantsLayer = YES;
        swatch.layer.backgroundColor = UsageKindColor(kind).CGColor;
        swatch.layer.cornerRadius = 2;
        [swatch.widthAnchor constraintEqualToConstant:9].active = YES;
        [swatch.heightAnchor constraintEqualToConstant:9].active = YES;
        NSStackView *item = [NSStackView stackViewWithViews:@[swatch,
            [self smallLabel:UsageKindTitle(kind) color:NSColor.secondaryLabelColor]]];
        item.spacing = 4;
        item.alignment = NSLayoutAttributeCenterY;
        [legendItems addObject:item];
    }
    // 末尾垫一个可拉伸的空视图，图例才会靠左排，不会被撑开到两端。
    NSView *legendSpacer = [NSView new];
    [legendSpacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [legendItems addObject:legendSpacer];
    NSStackView *legend = [NSStackView stackViewWithViews:legendItems];
    legend.spacing = 14;

    NSStackView *chartStack = [NSStackView stackViewWithViews:@[self.chartCaption, chart, legend, self.chartDetail]];
    chartStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    chartStack.alignment = NSLayoutAttributeLeading;
    chartStack.spacing = 8;
    chartStack.edgeInsets = NSEdgeInsetsMake(12, 14, 12, 14);
    [chart.widthAnchor constraintEqualToAnchor:chartStack.widthAnchor constant:-28].active = YES;
    [legend.widthAnchor constraintEqualToAnchor:chart.widthAnchor].active = YES;
    [self.form addSectionWithID:@"daily" title:L(@"Daily Usage") symbol:@"calendar"
        color:NSColor.systemOrangeColor rows:@[chartStack] footer:nil];

    [self selectEntryAtIndex:self.selectedIndex];
}

- (void)selectEntryAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.entries.count) return;
    self.selectedIndex = index;
    for (NSUInteger row = 0; row < self.rows.count; row++) self.rows[row].selected = ((NSInteger)row == index);
    NSDictionary *entry = self.entries[(NSUInteger)index];
    self.chart.days = entry[@"days"];
    self.chartCaption.stringValue = [NSString stringWithFormat:@"%@ · %@", ModelTitle(entry[@"model"]),
        ProviderTitle(entry[@"provider"])];
    self.chartDetail.stringValue = L(@"Hover a bar to see that day's numbers.");
}

- (void)showDayDetailAtIndex:(NSInteger)index {
    NSDictionary *entry = self.entries[(NSUInteger)self.selectedIndex];
    NSArray *days = entry[@"days"];
    if (index < 0 || index >= (NSInteger)days.count) {
        self.chartDetail.stringValue = L(@"Hover a bar to see that day's numbers.");
        return;
    }
    NSDictionary *day = days[(NSUInteger)index];
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterNoStyle;
    NSDictionary *counts = day[@"counts"];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *kind in @[@"input", @"cacheRead", @"cacheWrite", @"output"]) {
        [parts addObject:[NSString stringWithFormat:@"%@ %@", UsageKindTitle(kind), FormatTokens(Count(counts, kind))]];
    }
    self.chartDetail.stringValue = [NSString stringWithFormat:@"%@ — %@ %@ · %@",
        [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:[day[@"timestamp"] doubleValue]]],
        L(@"Total"), FormatTokens(TotalTokens(counts)), [parts componentsJoinedByString:@" · "]];
}

@end
