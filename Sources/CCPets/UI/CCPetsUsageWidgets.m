#import "CCPetsUsageWidgets.h"
#import "CCPetsUIStyle.h"

@interface CCPetsFlowView ()
@property(nonatomic) CGFloat laidOutHeight;
@end

@implementation CCPetsFlowView

- (BOOL)isFlipped {
    return YES;
}

- (CGFloat)heightForWidth:(CGFloat)width layout:(BOOL)apply {
    CGFloat x = 0, y = 0, lineHeight = 0;
    for (NSView *view in self.subviews) {
        NSSize size = view.fittingSize;
        if (x > 0 && x + size.width > width) {
            x = 0;
            y += lineHeight + self.lineSpacing;
            lineHeight = 0;
        }
        if (apply) view.frame = NSMakeRect(x, y, size.width, size.height);
        x += size.width + self.spacing;
        lineHeight = MAX(lineHeight, size.height);
    }
    return y + lineHeight;
}

// 折行后的高度变了才通知自动布局；每次都通知会让布局一轮接一轮地重排。
- (void)layout {
    [super layout];
    CGFloat height = [self heightForWidth:NSWidth(self.bounds) layout:YES];
    if (fabs(height - self.laidOutHeight) > 0.5) {
        self.laidOutHeight = height;
        [self invalidateIntrinsicContentSize];
    }
}

- (NSSize)intrinsicContentSize {
    CGFloat width = NSWidth(self.bounds) > 0 ? NSWidth(self.bounds) : 600;
    return NSMakeSize(NSViewNoIntrinsicMetric, [self heightForWidth:width layout:NO]);
}

- (void)setFrameSize:(NSSize)size {
    BOOL widthChanged = fabs(size.width - NSWidth(self.frame)) > 0.5;
    [super setFrameSize:size];
    if (widthChanged) [self invalidateIntrinsicContentSize];
}

@end

@interface CCPetsLegendItem ()
@property(nonatomic) CCPetsColorDot *dot;
@property(nonatomic) NSTextField *label;
@property(nonatomic) NSColor *color;
@end

@implementation CCPetsLegendItem

- (instancetype)initWithTitle:(NSString *)title color:(NSColor *)color {
    if ((self = [super initWithFrame:NSZeroRect])) {
        self.wantsLayer = YES;
        self.color = color;
        CCPetsColorDot *dot = [[CCPetsColorDot alloc] initWithColor:color diameter:8];
        NSTextField *label = CCPetsLabel(title, 11, NSFontWeightMedium, CCPetsSecondaryInkColor());
        label.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];
        for (NSView *view in @[dot, label]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:view];
        }
        [NSLayoutConstraint activateConstraints:@[
            [dot.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
            [dot.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [label.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:6],
            [label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
            [label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.heightAnchor constraintEqualToConstant:24],
        ]];
        self.dot = dot;
        self.label = label;
    }
    return self;
}

- (void)setDimmed:(BOOL)dimmed {
    _dimmed = dimmed;
    self.alphaValue = dimmed ? 0.45 : 1;
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    self.label.textColor = selected ? CCPetsInkColor() : CCPetsSecondaryInkColor();
    self.label.font = [NSFont monospacedSystemFontOfSize:11 weight:selected ? NSFontWeightBold : NSFontWeightMedium];
    self.needsDisplay = YES;
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)updateLayer {
    self.layer.cornerRadius = 6;
    self.layer.backgroundColor = self.selected ? CCPetsSelectionColor().CGColor : NSColor.clearColor.CGColor;
}

- (void)mouseUp:(NSEvent *)event {
    if (self.onClick) self.onClick();
}

- (void)mouseDown:(NSEvent *)event {
}

- (void)resetCursorRects {
    if (self.onClick) [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}

- (BOOL)isAccessibilityElement {
    return YES;
}

- (NSAccessibilityRole)accessibilityRole {
    return self.onClick ? NSAccessibilityButtonRole : NSAccessibilityStaticTextRole;
}

- (NSString *)accessibilityLabel {
    return self.label.stringValue;
}

- (BOOL)accessibilityPerformPress {
    if (self.onClick) self.onClick();
    return self.onClick != nil;
}

@end

@implementation CCPetsUsageModelRow

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) self.wantsLayer = YES;
    return self;
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)updateLayer {
    self.layer.backgroundColor = self.selected ? CCPetsSelectionColor().CGColor : NSColor.clearColor.CGColor;
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    self.needsDisplay = YES;
}

- (void)setDimmed:(BOOL)dimmed {
    _dimmed = dimmed;
    for (NSView *view in self.subviews) view.alphaValue = dimmed ? 0.45 : 1;
}

- (void)mouseDown:(NSEvent *)event {
}

- (void)mouseUp:(NSEvent *)event {
    if (self.onClick) self.onClick();
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (BOOL)isAccessibilityElement {
    return YES;
}

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityButtonRole;
}

- (BOOL)accessibilityPerformPress {
    if (self.onClick) self.onClick();
    return YES;
}

@end

@implementation CCPetsShareBar
- (NSSize)intrinsicContentSize {
    return NSMakeSize(NSViewNoIntrinsicMetric, 4);
}
- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    [CCPetsRingTrackColor() set];
    [[NSBezierPath bezierPathWithRoundedRect:bounds xRadius:2 yRadius:2] fill];
    NSRect fill = bounds;
    fill.size.width = MAX(3, bounds.size.width * MIN(1, MAX(0, self.fraction)));
    [self.color set];
    [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:2 yRadius:2] fill];
}
@end
