#import "MenuToggleSwitch.h"
#import "CCPetsL10n.h"

@implementation MenuToggleSwitch
- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) {
        self.bordered = NO;
        self.title = @"";
        self.buttonType = NSButtonTypeToggle;
        self.focusRingType = NSFocusRingTypeNone;
        [self setAccessibilityRole:NSAccessibilityCheckBoxRole];
    }
    return self;
}
- (void)setState:(NSControlStateValue)value {
    [super setState:value];
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    NSRect track = NSInsetRect(self.bounds, 1, 2);
    BOOL enabled = self.state == NSControlStateValueOn;
    NSColor *trackColor = enabled
        ? [NSColor.controlAccentColor colorWithAlphaComponent:self.highlighted ? 0.72 : 0.96]
        : [NSColor colorWithWhite:self.highlighted ? 0.38 : 0.46 alpha:0.82];
    [trackColor setFill];
    NSBezierPath *trackPath = [NSBezierPath bezierPathWithRoundedRect:track
        xRadius:NSHeight(track) / 2.0 yRadius:NSHeight(track) / 2.0];
    [trackPath fill];
    [[NSColor colorWithWhite:0 alpha:enabled ? 0.08 : 0.16] setStroke];
    trackPath.lineWidth = 0.8;
    [trackPath stroke];

    CGFloat diameter = NSHeight(track) - 4;
    CGFloat knobX = enabled
        ? NSMaxX(track) - diameter - 2
        : NSMinX(track) + 2;
    NSRect knob = NSMakeRect(knobX, NSMidY(track) - diameter / 2.0, diameter, diameter);
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.24];
    shadow.shadowBlurRadius = 1.5;
    shadow.shadowOffset = NSMakeSize(0, -0.5);
    [shadow set];
    [NSColor.whiteColor setFill];
    [[NSBezierPath bezierPathWithOvalInRect:knob] fill];
    [NSGraphicsContext restoreGraphicsState];
}
@end


@implementation MenuUsageModeButton

- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) {
        self.bordered = NO;
        self.title = @"";
        self.buttonType = NSButtonTypeToggle;
        self.focusRingType = NSFocusRingTypeNone;
        [self setAccessibilityRole:NSAccessibilityButtonRole];
    }
    return self;
}

- (void)setState:(NSControlStateValue)value {
    [super setState:value];
    [self setAccessibilityValue:value == NSControlStateValueOn ? L(@"API") : L(@"Plan")];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    BOOL usesAPI = self.state == NSControlStateValueOn;
    NSRect pill = NSInsetRect(self.bounds, 1, 2);
    NSColor *pillColor = usesAPI
        ? [NSColor colorWithRed:0.12 green:0.52 blue:0.96 alpha:self.highlighted ? 0.78 : 0.96]
        : [NSColor colorWithRed:0.20 green:0.68 blue:0.36 alpha:self.highlighted ? 0.78 : 0.96];
    [pillColor setFill];
    NSBezierPath *pillPath = [NSBezierPath bezierPathWithRoundedRect:pill
        xRadius:NSHeight(pill) / 2.0 yRadius:NSHeight(pill) / 2.0];
    [pillPath fill];
    [[NSColor colorWithWhite:0 alpha:0.10] setStroke];
    pillPath.lineWidth = 0.8;
    [pillPath stroke];

    NSString *title = usesAPI ? L(@"API") : L(@"Plan");
    NSDictionary<NSAttributedStringKey, id> *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.whiteColor,
    };
    NSSize titleSize = [title sizeWithAttributes:attributes];
    NSPoint titleOrigin = NSMakePoint(
        round(NSMidX(self.bounds) - titleSize.width / 2.0),
        round(NSMidY(self.bounds) - titleSize.height / 2.0));
    [title drawAtPoint:titleOrigin withAttributes:attributes];
}

@end
