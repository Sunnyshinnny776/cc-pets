#import "MenuPetSizeView.h"
#import "CCPetsPetSize.h"
#import "CCPetsL10n.h"

@interface MenuPetSizeView ()
@property NSSlider *slider;
@property NSTextField *percentage;
@property(weak) id target;
@property SEL action;
@end

@implementation MenuPetSizeView
- (instancetype)initWithScale:(CGFloat)scale target:(id)target action:(SEL)action {
    CGFloat resetWidth = ceil([L(@"Reset Size") sizeWithAttributes:
        @{NSFontAttributeName: [NSFont menuFontOfSize:12]}].width) + 24;
    CGFloat width = MAX(220, resetWidth + 94);
    self = [super initWithFrame:NSMakeRect(0, 0, width, 92)];
    if (!self) return nil;
    self.autoresizingMask = NSViewWidthSizable;
    self.target = target;
    self.action = action;

    self.percentage = [NSTextField labelWithString:@""];
    self.percentage.frame = NSMakeRect(14, 65, width - 28, 18);
    self.percentage.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
    self.percentage.alignment = NSTextAlignmentCenter;
    self.percentage.autoresizingMask = NSViewWidthSizable;
    [self addSubview:self.percentage];

    self.slider = [NSSlider sliderWithValue:scale minValue:CCPetsPetMinimumScale
        maxValue:CCPetsPetMaximumScale target:self action:@selector(sliderChanged:)];
    self.slider.frame = NSMakeRect(14, 37, width - 28, 24);
    self.slider.continuous = YES;
    self.slider.autoresizingMask = NSViewWidthSizable;
    self.slider.accessibilityLabel = L(@"Pet Size");
    [self addSubview:self.slider];

    NSTextField *minimum = [NSTextField labelWithString:@"50%"];
    minimum.frame = NSMakeRect(14, 10, 44, 16);
    minimum.font = [NSFont menuFontOfSize:11];
    minimum.textColor = NSColor.secondaryLabelColor;
    [self addSubview:minimum];
    NSTextField *maximum = [NSTextField labelWithString:@"200%"];
    maximum.frame = NSMakeRect(width - 58, 10, 44, 16);
    maximum.font = minimum.font;
    maximum.textColor = minimum.textColor;
    maximum.alignment = NSTextAlignmentRight;
    maximum.autoresizingMask = NSViewMinXMargin;
    [self addSubview:maximum];

    NSButton *reset = [NSButton buttonWithTitle:L(@"Reset Size") target:self action:@selector(resetSize:)];
    reset.bezelStyle = NSBezelStyleRounded;
    reset.font = [NSFont menuFontOfSize:12];
    reset.frame = NSMakeRect((width - resetWidth) / 2, 5, resetWidth, 26);
    reset.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin;
    [self addSubview:reset];
    [self updatePercentage];
    return self;
}
- (void)updatePercentage {
    self.percentage.stringValue = [NSString stringWithFormat:@"%.0f%%", self.slider.doubleValue * 100];
}
- (void)sliderChanged:(NSSlider *)sender {
    [NSApp sendAction:self.action to:self.target from:sender];
    [self updatePercentage];
}
- (void)resetSize:(id)sender {
    self.slider.doubleValue = 1.0;
    [self sliderChanged:self.slider];
}
// 消费行内空白处的点击，菜单保持打开以便继续调整。
- (void)mouseDown:(NSEvent *)event {}
@end
