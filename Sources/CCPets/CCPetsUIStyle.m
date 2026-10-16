#import "CCPetsUIStyle.h"
#import <QuartzCore/QuartzCore.h>

static BOOL AppearanceIsDark(NSAppearance *appearance) {
    return [[appearance bestMatchFromAppearancesWithNames:
        @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
}

static NSColor *RGBA(uint32_t rgb, CGFloat alpha) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xff) / 255.0 green:((rgb >> 8) & 0xff) / 255.0
        blue:(rgb & 0xff) / 255.0 alpha:alpha];
}

// 一对浅色 / 深色取值的动态色。
static NSColor *Dynamic(uint32_t light, CGFloat lightAlpha, uint32_t dark, CGFloat darkAlpha) {
    NSColor *lightColor = RGBA(light, lightAlpha), *darkColor = RGBA(dark, darkAlpha);
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        return AppearanceIsDark(appearance) ? darkColor : lightColor;
    }];
}

// 每个颜色只建一次：动态色本身就会随外观解析，没必要每次调用都新建。
#define CACHED_COLOR(expr) \
    static NSColor *color; \
    static dispatch_once_t once; \
    dispatch_once(&once, ^{ color = (expr); }); \
    return color

NSColor *CCPetsAccentColor(void) { CACHED_COLOR(Dynamic(0x0b8ea3, 1, 0x4fd3e6, 1)); }
NSColor *CCPetsAccentInkColor(void) { CACHED_COLOR(Dynamic(0xffffff, 1, 0x062a31, 1)); }
NSColor *CCPetsBackgroundColor(void) { CACHED_COLOR(Dynamic(0xf6f7f9, 1, 0x1a1d22, 1)); }
NSColor *CCPetsCardColor(void) { CACHED_COLOR(Dynamic(0xffffff, 1, 0x24282e, 1)); }
NSColor *CCPetsLineColor(void) { CACHED_COLOR(Dynamic(0xe3e6ec, 1, 0x33383f, 1)); }
NSColor *CCPetsInkColor(void) { CACHED_COLOR(Dynamic(0x161b22, 1, 0xeceff3, 1)); }
NSColor *CCPetsSecondaryInkColor(void) { CACHED_COLOR(Dynamic(0x5a6472, 1, 0xa3acb8, 1)); }
NSColor *CCPetsTertiaryInkColor(void) { CACHED_COLOR(Dynamic(0x8c95a3, 1, 0x77808d, 1)); }
NSColor *CCPetsHoverColor(void) { CACHED_COLOR(Dynamic(0x162846, 0.05, 0xffffff, 0.05)); }
NSColor *CCPetsSelectionColor(void) { CACHED_COLOR(Dynamic(0x0e9db3, 0.13, 0x4fdceb, 0.16)); }
NSColor *CCPetsRingTrackColor(void) { CACHED_COLOR(Dynamic(0xe3e7ee, 1, 0x343a42, 1)); }

NSColor *CCPetsProviderColor(NSString *provider) {
    static NSColor *claude, *codex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        claude = Dynamic(0xc8643b, 1, 0xe07a50, 1);
        codex = Dynamic(0x3d4655, 1, 0xb9c2cf, 1);
    });
    return [provider.lowercaseString isEqualToString:@"claude"] ? claude : codex;
}

NSColor *CCPetsStatusColor(CCPetsStatusKind kind) {
    static NSArray<NSColor *> *colors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        colors = @[Dynamic(0x8c95a3, 1, 0x8a93a0, 1), Dynamic(0x0b8ea3, 1, 0x4fd3e6, 1),
                   Dynamic(0xb86e00, 1, 0xf2b33d, 1), Dynamic(0x1f8a4c, 1, 0x4fc97f, 1),
                   Dynamic(0xc8352f, 1, 0xff7a70, 1)];
    });
    return colors[(NSUInteger)MAX(0, MIN(kind, (NSInteger)colors.count - 1))];
}

NSColor *CCPetsStatusBackgroundColor(CCPetsStatusKind kind) {
    static NSArray<NSColor *> *colors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        colors = @[Dynamic(0x6e7887, 0.12, 0x8c96a5, 0.15), Dynamic(0x0b8ea3, 0.12, 0x4fd3e6, 0.14),
                   Dynamic(0xe59a00, 0.14, 0xf2b33d, 0.15), Dynamic(0x1f8a4c, 0.11, 0x4fc97f, 0.13),
                   Dynamic(0xc8352f, 0.11, 0xff7a70, 0.14)];
    });
    return colors[(NSUInteger)MAX(0, MIN(kind, (NSInteger)colors.count - 1))];
}

CCPetsStatusKind CCPetsStatusKindForAgentState(NSString *state) {
    if ([state isEqualToString:@"approval"] || [state isEqualToString:@"notification"]) return CCPetsStatusWarn;
    if ([state isEqualToString:@"failed"] || [state isEqualToString:@"tool_failed"]) return CCPetsStatusError;
    if ([state isEqualToString:@"completed"] || [state isEqualToString:@"tool_completed"]) return CCPetsStatusOK;
    if (state.length == 0 || [state isEqualToString:@"idle"]) return CCPetsStatusIdle;
    return CCPetsStatusWork;
}

const NSInteger CCPetsChartColorCount = 8;

// 浅色、深色两套都用色盲模拟校验过：相邻两色在红、绿色盲下色差不低于 8，正常视力下不低于 15。
NSColor *CCPetsChartColor(NSInteger slot) {
    static NSArray<NSColor *> *colors;
    static NSColor *other;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const uint32_t light[] = {0x1597ac, 0xe05c86, 0x6874dc, 0xdd9a1f, 0x9a62d0, 0x3fa577, 0x3a7fc6, 0x8a9a2b};
        const uint32_t dark[] = {0x22a2b8, 0xd65f86, 0x7d87e8, 0xb8841f, 0xa77ad8, 0x3fa577, 0x4c95dc, 0x879733};
        NSMutableArray<NSColor *> *list = [NSMutableArray array];
        for (NSInteger index = 0; index < CCPetsChartColorCount; index++) {
            [list addObject:Dynamic(light[index], 1, dark[index], 1)];
        }
        colors = list;
        other = Dynamic(0x9aa3af, 1, 0x66707c, 1);
    });
    return slot >= 0 && slot < CCPetsChartColorCount ? colors[(NSUInteger)slot] : other;
}

NSTextField *CCPetsLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField labelWithString:text ?: @""];
    label.font = [NSFont systemFontOfSize:size > 0 ? size : NSFont.systemFontSize weight:weight];
    label.textColor = color ?: CCPetsInkColor();
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

NSTextField *CCPetsNumberLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = CCPetsLabel(text, size, weight, color);
    label.font = [NSFont monospacedDigitSystemFontOfSize:size > 0 ? size : NSFont.systemFontSize weight:weight];
    return label;
}

@interface CCPetsWrappingField : NSTextField
@end

@implementation CCPetsWrappingField
- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    if (width > 0 && fabs(self.preferredMaxLayoutWidth - width) > 0.5) {
        self.preferredMaxLayoutWidth = width;
        [self invalidateIntrinsicContentSize];
    }
}
@end

NSTextField *CCPetsWrappingLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    CCPetsWrappingField *label = [CCPetsWrappingField wrappingLabelWithString:text ?: @""];
    label.font = [NSFont systemFontOfSize:size > 0 ? size : NSFont.systemFontSize weight:weight];
    label.textColor = color ?: CCPetsInkColor();
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
        forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

NSView *CCPetsMetricRow(NSArray<NSArray<NSString *> *> *items) {
    NSMutableArray<NSView *> *cells = [NSMutableArray array];
    for (NSArray<NSString *> *item in items) {
        NSTextField *title = CCPetsLabel(item[0], 11, NSFontWeightRegular, CCPetsSecondaryInkColor());
        NSTextField *value = CCPetsNumberLabel(item[1], 20, NSFontWeightBold, CCPetsInkColor());
        NSTextField *detail = CCPetsLabel(item.count > 2 && item[2].length > 0 ? item[2] : @" ", 11,
            NSFontWeightRegular, CCPetsTertiaryInkColor());
        NSView *heading = title;
        if (item.count > 3 && item[3].length > 0) {
            NSImageView *icon = [NSImageView imageViewWithImage:
                [NSImage imageWithSystemSymbolName:@"info.circle" accessibilityDescription:item[3]]];
            icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:10
                weight:NSFontWeightRegular];
            icon.contentTintColor = CCPetsTertiaryInkColor();
            icon.toolTip = item[3];
            [icon setContentHuggingPriority:NSLayoutPriorityRequired
                forOrientation:NSLayoutConstraintOrientationHorizontal];
            NSStackView *line = [NSStackView stackViewWithViews:@[title, icon]];
            line.alignment = NSLayoutAttributeCenterY;
            line.spacing = 3;
            heading = line;
        }
        NSStackView *stack = [NSStackView stackViewWithViews:@[heading, value, detail]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.alignment = NSLayoutAttributeLeading;
        stack.spacing = 3;
        for (NSTextField *label in @[title, value, detail]) {
            [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                forOrientation:NSLayoutConstraintOrientationHorizontal];
        }
        // 格宽不跟着数字长短走，数字变了也不会左右挪。
        NSView *cell = [NSView new];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:stack];
        CGFloat inset = cells.count == 0 ? 0 : 12;
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:inset],
            [stack.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-4],
            [stack.topAnchor constraintEqualToAnchor:cell.topAnchor],
            [stack.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor],
        ]];
        if (cells.count > 0) {
            CCPetsLineView *rule = [CCPetsLineView new];
            rule.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:rule];
            [NSLayoutConstraint activateConstraints:@[
                [rule.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor],
                [rule.widthAnchor constraintEqualToConstant:1],
                [rule.topAnchor constraintEqualToAnchor:cell.topAnchor constant:2],
                [rule.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor constant:-2],
            ]];
        }
        [cells addObject:cell];
    }
    NSStackView *row = [NSStackView stackViewWithViews:cells];
    row.distribution = NSStackViewDistributionFillEqually;
    row.alignment = NSLayoutAttributeTop;
    row.spacing = 12;
    return row;
}

@implementation CCPetsCardView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        _cornerRadius = 10;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 1;
        self.layer.masksToBounds = YES;
    }
    return self;
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

// 颜色放在 updateLayer 里取，切换深浅色时 AppKit 会再调一次，CGColor 才会跟着变。
- (void)updateLayer {
    self.layer.cornerRadius = self.cornerRadius;
    self.layer.backgroundColor = (self.fillColor ?: CCPetsCardColor()).CGColor;
    self.layer.borderColor = (self.selected ? CCPetsAccentColor() : CCPetsLineColor()).CGColor;
    self.layer.borderWidth = self.selected ? 1.5 : 1;
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    self.needsDisplay = YES;
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    _cornerRadius = cornerRadius;
    self.needsDisplay = YES;
}

- (void)setFillColor:(NSColor *)fillColor {
    _fillColor = fillColor;
    self.needsDisplay = YES;
}

- (void)setStripeColor:(NSColor *)stripeColor {
    _stripeColor = stripeColor;
    self.needsLayout = YES;
    self.needsDisplay = YES;
}

- (void)layout {
    [super layout];
    CALayer *stripe = nil;
    for (CALayer *layer in self.layer.sublayers) {
        if ([layer.name isEqualToString:@"stripe"]) stripe = layer;
    }
    if (!self.stripeColor) {
        [stripe removeFromSuperlayer];
        return;
    }
    if (!stripe) {
        stripe = [CALayer layer];
        stripe.name = @"stripe";
        [self.layer addSublayer:stripe];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    stripe.frame = CGRectMake(0, 0, 3, NSHeight(self.bounds));
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        stripe.backgroundColor = self.stripeColor.CGColor;
    }];
    [CATransaction commit];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsLayout = YES;
}

@end

@implementation CCPetsTileView

- (void)mouseDown:(NSEvent *)event {
    // 按下不立刻触发，松开时还在卡片上才算一次点击，和按钮一个手感。
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (self.onClick && NSPointInRect(point, self.bounds)) self.onClick();
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (void)resetCursorRects {
    if (self.onClick) [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}

- (BOOL)isAccessibilityElement {
    return self.onClick != nil;
}

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityButtonRole;
}

- (BOOL)accessibilityPerformPress {
    if (!self.onClick) return NO;
    self.onClick();
    return YES;
}

@end

@implementation CCPetsPillButton

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.bordered = NO;
        self.wantsLayer = YES;
        self.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        [self.widthAnchor constraintEqualToConstant:56].active = YES;
        [self.heightAnchor constraintEqualToConstant:22].active = YES;
    }
    return self;
}

- (void)setTitle:(NSString *)title {
    // 白字压在饱和色上，深浅色下都够对比度，所以不跟随外观。
    self.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.whiteColor}];
}

- (void)setFillColor:(NSColor *)fillColor {
    _fillColor = fillColor;
    [self applyFill];
}

// 按钮要靠 cell 画标题，不能走 updateLayer；底色在外观变化时手动按当前外观解析一次。
- (void)applyFill {
    self.layer.cornerRadius = 11;
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self.layer.backgroundColor = (self.fillColor ?: CCPetsAccentColor()).CGColor;
    }];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self applyFill];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self applyFill];
}

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}

@end

@implementation CCPetsColorDot

- (instancetype)initWithColor:(NSColor *)color diameter:(CGFloat)diameter {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, diameter, diameter)])) {
        self.wantsLayer = YES;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.layer.cornerRadius = diameter / 2;
        _color = color;
        [NSLayoutConstraint activateConstraints:@[
            [self.widthAnchor constraintEqualToConstant:diameter],
            [self.heightAnchor constraintEqualToConstant:diameter],
        ]];
    }
    return self;
}

- (void)setColor:(NSColor *)color {
    _color = color;
    self.needsDisplay = YES;
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)updateLayer {
    self.layer.backgroundColor = self.color.CGColor;
}

@end

@implementation CCPetsLineView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) self.wantsLayer = YES;
    return self;
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)updateLayer {
    self.layer.backgroundColor = CCPetsLineColor().CGColor;
}

@end

@interface CCPetsChipView ()
@property(nonatomic) NSTextField *label;
@property(nonatomic) NSView *dot;
@property(nonatomic) NSLayoutConstraint *labelLeading;
@end

@implementation CCPetsChipView

- (instancetype)initWithText:(NSString *)text kind:(CCPetsStatusKind)kind {
    if ((self = [super initWithFrame:NSZeroRect])) {
        self.wantsLayer = YES;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        NSView *dot = [NSView new];
        dot.wantsLayer = YES;
        dot.layer.cornerRadius = 2.5;
        dot.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *label = CCPetsLabel(text, 11, NSFontWeightSemibold, nil);
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [label setContentCompressionResistancePriority:NSLayoutPriorityRequired
            forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self addSubview:dot];
        [self addSubview:label];
        self.dot = dot;
        self.label = label;
        self.labelLeading = [label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:17];
        [NSLayoutConstraint activateConstraints:@[
            [dot.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
            [dot.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [dot.widthAnchor constraintEqualToConstant:5],
            [dot.heightAnchor constraintEqualToConstant:5],
            self.labelLeading,
            [label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
            [label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.heightAnchor constraintEqualToConstant:20],
        ]];
        [self setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        _kind = kind;
        [self applyKind];
    }
    return self;
}

- (NSString *)text {
    return self.label.stringValue;
}

- (void)setText:(NSString *)text {
    self.label.stringValue = text ?: @"";
}

- (void)setKind:(CCPetsStatusKind)kind {
    _kind = kind;
    [self applyKind];
}

- (void)setHidesDot:(BOOL)hidesDot {
    _hidesDot = hidesDot;
    self.dot.hidden = hidesDot;
    self.labelLeading.constant = hidesDot ? 8 : 17;
}

- (void)applyKind {
    self.label.textColor = CCPetsStatusColor(self.kind);
    self.needsDisplay = YES;
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)updateLayer {
    self.layer.cornerRadius = 10;
    self.layer.backgroundColor = CCPetsStatusBackgroundColor(self.kind).CGColor;
    self.dot.layer.backgroundColor = CCPetsStatusColor(self.kind).CGColor;
}

@end

@interface CCPetsCountBadge ()
@property(nonatomic) NSTextField *label;
@end

@implementation CCPetsCountBadge

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        NSTextField *label = CCPetsNumberLabel(@"", 11, NSFontWeightSemibold, CCPetsSecondaryInkColor());
        label.alignment = NSTextAlignmentCenter;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:label];
        self.label = label;
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:6],
            [label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
            [label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.heightAnchor constraintEqualToConstant:18],
            [self.widthAnchor constraintGreaterThanOrEqualToConstant:18],
        ]];
        self.hidden = YES;
    }
    return self;
}

- (void)setCount:(NSInteger)count {
    _count = count;
    self.label.stringValue = [NSString stringWithFormat:@"%ld", (long)count];
    self.hidden = count <= 0;
}

- (void)setWarn:(BOOL)warn {
    _warn = warn;
    self.label.textColor = warn ? CCPetsStatusColor(CCPetsStatusWarn) : CCPetsSecondaryInkColor();
    self.needsDisplay = YES;
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)updateLayer {
    self.layer.cornerRadius = 9;
    self.layer.backgroundColor = (self.warn ? CCPetsStatusBackgroundColor(CCPetsStatusWarn)
        : CCPetsStatusBackgroundColor(CCPetsStatusIdle)).CGColor;
}

@end

// 和 PetView.handleAgentEvent: 用的行一致：{行, 最后一帧}。
static void SpriteRowForState(NSString *state, NSInteger *row, NSInteger *lastFrame) {
    NSDictionary<NSString *, NSArray<NSNumber *> *> *rows = @{
        @"thinking": @[@5, @7], @"starting": @[@4, @4], @"auto_review": @[@8, @5],
        @"approval": @[@4, @4], @"notification": @[@4, @4],
        @"tool": @[@8, @5], @"subagent": @[@6, @5],
        @"tool_completed": @[@7, @5], @"completed": @[@3, @3],
        @"tool_failed": @[@5, @7], @"failed": @[@5, @7],
    };
    NSArray<NSNumber *> *entry = rows[state ?: @""] ?: @[@0, @5];
    *row = entry[0].integerValue;
    *lastFrame = entry[1].integerValue;
}

static const NSTimeInterval SpriteFrameInterval = 0.16;

@interface CCPetsSpriteView ()
@property(nonatomic) CGImageRef sheetImage;
@property(nonatomic) NSImage *sheet;
@property(nonatomic) NSInteger rowCount;
@property(nonatomic) NSInteger row;
@property(nonatomic) NSInteger lastFrame;
@property(nonatomic) NSInteger frameIndex;
@property(nonatomic) NSTimer *timer;
@end

@implementation CCPetsSpriteView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        // 像素素材放大用最近邻，和桌宠本体一致。
        self.layer.magnificationFilter = kCAFilterNearest;
        self.layer.minificationFilter = kCAFilterNearest;
        self.layer.contentsGravity = kCAGravityResizeAspect;
        _lastFrame = 5;
        _playing = YES;
        [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self
            selector:@selector(updateTimer)
            name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [_timer invalidate];
    if (_sheetImage) CGImageRelease(_sheetImage);
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}

- (void)setSheet:(NSImage *)sheet rowCount:(NSInteger)rowCount {
    if (sheet == self.sheet && rowCount == self.rowCount) return;
    self.sheet = sheet;
    self.rowCount = MAX((NSInteger)1, rowCount);
    if (_sheetImage) CGImageRelease(_sheetImage);
    CGImageRef image = [sheet CGImageForProposedRect:NULL context:nil hints:nil];
    _sheetImage = image ? CGImageRetain(image) : NULL;
    [self applyState];
}

- (void)setPlaying:(BOOL)playing {
    if (_playing == playing) return;
    _playing = playing;
    [self updateTimer];
}

- (void)setState:(NSString *)state {
    if ([_state isEqualToString:state]) return;
    _state = [state copy];
    [self applyState];
}

- (void)applyState {
    NSInteger row = 0, lastFrame = 5;
    SpriteRowForState(self.state, &row, &lastFrame);
    if (row >= self.rowCount) {
        row = 0;
        lastFrame = 5;
    }
    self.row = row;
    self.lastFrame = lastFrame;
    self.frameIndex = 0;
    [self showCurrentFrame];
    [self updateTimer];
}

- (void)showCurrentFrame {
    if (!_sheetImage) {
        self.layer.contents = nil;
        return;
    }
    size_t width = CGImageGetWidth(_sheetImage), height = CGImageGetHeight(_sheetImage);
    CGFloat cellWidth = width / 8.0, cellHeight = (CGFloat)height / self.rowCount;
    // CGImage 坐标原点在左上角，行号从上往下数，正好不用翻转。
    CGRect cell = CGRectIntegral(CGRectMake(self.frameIndex * cellWidth, self.row * cellHeight,
        cellWidth, cellHeight));
    CGImageRef frame = CGImageCreateWithImageInRect(_sheetImage, cell);
    [CATransaction begin];
    // 换 contents 默认有 0.25s 淡入，逐帧动画上会拖影。
    [CATransaction setDisableActions:YES];
    self.layer.contents = (__bridge id)frame;
    [CATransaction commit];
    if (frame) CGImageRelease(frame);
}

- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    [super viewWillMoveToWindow:newWindow];
    for (NSNotificationName name in @[NSWindowDidMiniaturizeNotification,
                                      NSWindowDidDeminiaturizeNotification, NSWindowWillCloseNotification]) {
        [NSNotificationCenter.defaultCenter removeObserver:self name:name object:nil];
    }
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) {
        for (NSNotificationName name in @[NSWindowDidMiniaturizeNotification,
                                          NSWindowDidDeminiaturizeNotification]) {
            [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateTimer)
                name:name object:self.window];
        }
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowWillClose:)
            name:NSWindowWillCloseNotification object:self.window];
    }
    [self updateTimer];
}

- (void)windowWillClose:(NSNotification *)notification {
    [self.timer invalidate];
    self.timer = nil;
}

// 窗口在屏幕上才走表，关窗、最小化都不耗电。不看"是否被别的窗口挡住"：那要靠遮挡状态，
// 它在 Space / 全屏过渡期间会误报十几秒不可见，桌宠本体已经因此弃用（见 tests/test.sh）。
- (void)updateTimer {
    BOOL visible = self.window.isVisible && !self.window.isMiniaturized;
    BOOL shouldRun = visible && self.playing && _sheetImage && self.lastFrame > 0 &&
        !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    if (shouldRun == self.timer.isValid) return;
    [self.timer invalidate];
    self.timer = nil;
    if (!shouldRun) {
        self.frameIndex = 0;
        [self showCurrentFrame];
        return;
    }
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:SpriteFrameInterval repeats:YES block:^(NSTimer *timer) {
        CCPetsSpriteView *view = weakSelf;
        if (!view) return;
        view.frameIndex = view.frameIndex >= view.lastFrame ? 0 : view.frameIndex + 1;
        [view showCurrentFrame];
    }];
    self.timer.tolerance = SpriteFrameInterval * 0.25;
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}

@end
