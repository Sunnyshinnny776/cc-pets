#import "CCPetsSettingsPreview.h"
#import "CCPetsGlassView.h"
#import "CCPetsPetSize.h"
#import "CCPetsUIStyle.h"
#import "QuotaDashboardView.h"
#import <QuartzCore/QuartzCore.h>

// 预览台高度与各元素相对真实尺寸的缩放。宠物 200% 时仍要放得下，所以宠物按 0.55 缩；
// 额度面板单独再缩一档，给宠物和气泡留出位置。
static const CGFloat PreviewStageHeight = 230;
static const CGFloat PreviewPetFactor = 0.55;
static const CGFloat PreviewBubbleFactor = 0.8;
static const CGFloat PreviewQuotaFactor = 0.5;
// 与桌面上的气泡（CCPetsAppDelegate+Speech.m）一致。
static const NSSize PreviewBubbleSize = {210, 38};

@interface CCPetsSettingsPreview ()
@property(nonatomic) NSImageView *backdrop;
@property(nonatomic) CAGradientLayer *fallbackBackdrop;
@property(nonatomic) CCPetsSpriteView *sprite;
@property(nonatomic) CCPetsGlassView *bubbleGlass;
@property(nonatomic) NSTextField *bubbleLabel;
@property(nonatomic) CCPetsGlassView *quotaGlass;
@property(nonatomic, readwrite) QuotaDashboardView *quotaView;
@end

@implementation CCPetsSettingsPreview

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 12;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.masksToBounds = YES;
        [self.heightAnchor constraintEqualToConstant:PreviewStageHeight].active = YES;

        // 读不到壁纸时的底：偏冷的对角渐变，深浅色下都能托住白字和深字。
        CAGradientLayer *gradient = [CAGradientLayer layer];
        gradient.colors = @[(id)[NSColor colorWithSRGBRed:0.20 green:0.45 blue:0.62 alpha:1].CGColor,
                            (id)[NSColor colorWithSRGBRed:0.36 green:0.27 blue:0.58 alpha:1].CGColor];
        gradient.startPoint = CGPointMake(0, 1);
        gradient.endPoint = CGPointMake(1, 0);
        [self.layer addSublayer:gradient];
        self.fallbackBackdrop = gradient;

        NSImageView *backdrop = [NSImageView new];
        backdrop.imageScaling = NSImageScaleAxesIndependently;
        backdrop.wantsLayer = YES;
        backdrop.layer.contentsGravity = kCAGravityResizeAspectFill;
        [self addSubview:backdrop];
        self.backdrop = backdrop;

        self.quotaGlass = [[CCPetsGlassView alloc] initWithFrame:NSZeroRect
            material:NSVisualEffectMaterialUnderWindowBackground
            appearance:NSAppearanceNameDarkAqua cornerRadius:13 * PreviewQuotaFactor];
        self.quotaGlass.usesWidgetGlass = YES;
        [self addSubview:self.quotaGlass];
        self.quotaView = [[QuotaDashboardView alloc] initWithFrame:NSZeroRect];
        [self.quotaGlass.contentView addSubview:self.quotaView];

        CCPetsSpriteView *sprite = [[CCPetsSpriteView alloc] initWithFrame:NSZeroRect];
        [self addSubview:sprite];
        self.sprite = sprite;

        self.bubbleGlass = [[CCPetsGlassView alloc] initWithFrame:NSZeroRect
            material:NSVisualEffectMaterialPopover appearance:NSAppearanceNameAqua cornerRadius:15];
        self.bubbleGlass.edgeShadeHeight = 9;
        self.bubbleGlass.edgeShadeAlpha = 0.6;
        self.bubbleGlass.usesWidgetGlass = YES;
        NSTextField *label = [NSTextField labelWithString:@""];
        label.alignment = NSTextAlignmentCenter;
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.bubbleGlass.contentView addSubview:label];
        self.bubbleLabel = label;
        [self addSubview:self.bubbleGlass];

        [self loadWallpaper];
        [self reloadAppearance];
    }
    return self;
}

// 壁纸可能是几十兆的 HEIC，放到后台解码，别卡住打开窗口。
- (void)loadWallpaper {
    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
    NSURL *url = screen ? [NSWorkspace.sharedWorkspace desktopImageURLForScreen:screen] : nil;
    if (!url) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSImage *image = [[NSImage alloc] initWithContentsOfURL:url];
        CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
        if (!cgImage) return;
        CGImageRetain(cgImage);
        dispatch_async(dispatch_get_main_queue(), ^{
            // 走 layer.contents 才能用 AspectFill；NSImageView 自己只会拉伸或留边。
            weakSelf.backdrop.layer.contents = (__bridge id)cgImage;
            CGImageRelease(cgImage);
        });
    });
}

- (void)setSheet:(NSImage *)sheet rowCount:(NSInteger)rowCount state:(NSString *)state {
    [self.sprite setSheet:sheet rowCount:rowCount];
    self.sprite.state = state;
}

- (void)setBubbleText:(NSString *)bubbleText {
    _bubbleText = [bubbleText copy];
    self.bubbleLabel.stringValue = bubbleText ?: @"";
    self.bubbleGlass.hidden = bubbleText.length == 0;
    [self setNeedsLayout:YES];
}

- (void)reloadAppearance {
    [self.quotaGlass applyTheme];
    [self.quotaGlass applyDimLevel];
    [self.bubbleGlass applyTheme];
    [self.bubbleGlass applyDimLevel];
    self.quotaView.usesLiquidGlass = self.quotaGlass.usesLiquidGlass;
    self.quotaView.cardScrimAlpha = CCPetsGlassCardScrimAlpha();
    self.quotaView.needsDisplay = YES;
    // 文字配色与桌面气泡同一规则（applyBubbleTextStyle）：原生清透玻璃上用白字加投影，
    // 经典磨砂上用深字。
    BOOL liquid = self.bubbleGlass.usesLiquidGlass;
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.45];
    shadow.shadowBlurRadius = 2;
    shadow.shadowOffset = NSMakeSize(0, -0.5);
    self.bubbleLabel.textColor = liquid ? [NSColor colorWithWhite:1 alpha:0.97]
        : [NSColor colorWithWhite:0.10 alpha:0.96];
    self.bubbleLabel.shadow = liquid ? shadow : nil;
    [self setNeedsLayout:YES];
}

- (void)layout {
    [super layout];
    NSRect bounds = self.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.fallbackBackdrop.frame = bounds;
    [CATransaction commit];
    self.backdrop.frame = bounds;

    // 额度面板贴右，垂直居中；高度按当前有几家 CLI 决定，和桌面上那张一样。
    NSSize quotaReal = NSMakeSize(QuotaLogicalWidth * QuotaScale,
        QuotaLogicalHeightForProviderCount(MAX((NSUInteger)1, self.quotaView.visibleProviders.count)) * QuotaScale);
    NSSize quotaSize = NSMakeSize(round(quotaReal.width * PreviewQuotaFactor),
        round(quotaReal.height * PreviewQuotaFactor));
    self.quotaGlass.frame = NSMakeRect(NSMaxX(bounds) - quotaSize.width - 20,
        round(NSMidY(bounds) - quotaSize.height / 2), quotaSize.width, quotaSize.height);
    // 面板按真实尺寸画、整体缩小显示：frame 是预览尺寸，bounds 是真实尺寸。
    self.quotaView.frame = self.quotaGlass.contentView.bounds;
    self.quotaView.bounds = NSMakeRect(0, 0, quotaReal.width, quotaReal.height);

    // 宠物站在左侧地面上，尺寸跟「宠物大小」走。
    CGFloat scale = CCPetsPetScalePreference();
    NSSize petSize = NSMakeSize(round(140 * scale * PreviewPetFactor), round(150 * scale * PreviewPetFactor));
    CGFloat petCenterX = MIN(NSMinX(self.quotaGlass.frame) / 2, 150);
    self.sprite.frame = NSMakeRect(round(petCenterX - petSize.width / 2), 14, petSize.width, petSize.height);

    // 气泡在宠物头顶，和桌面一样随宠物缩小、但放大时不超过原尺寸。
    CGFloat bubbleScale = CCPetsBubbleScalePreference() * PreviewBubbleFactor;
    // 先定字号再量宽度，否则量到的是上一次的字号。
    self.bubbleLabel.font = [NSFont systemFontOfSize:13 * bubbleScale weight:NSFontWeightMedium];
    // 字号已经缩过了，量出来的宽度就是预览尺寸；只有内边距和上下限要再按比例缩。
    CGFloat labelWidth = ceil(self.bubbleLabel.fittingSize.width) + 2;
    CGFloat bubbleWidth = MIN(MAX(labelWidth + 28 * bubbleScale, 90 * bubbleScale),
        PreviewBubbleSize.width * 1.4 * bubbleScale);
    NSSize bubbleSize = NSMakeSize(round(bubbleWidth), round(PreviewBubbleSize.height * bubbleScale));
    CGFloat bubbleX = MAX(12, MIN(petCenterX - bubbleSize.width / 2,
        NSMinX(self.quotaGlass.frame) - bubbleSize.width - 12));
    self.bubbleGlass.frame = NSMakeRect(round(bubbleX), NSMaxY(self.sprite.frame) + 6,
        bubbleSize.width, bubbleSize.height);
    self.bubbleGlass.cornerRadius = bubbleSize.height / 2;
    CGFloat labelHeight = ceil(self.bubbleLabel.fittingSize.height);
    self.bubbleLabel.frame = NSMakeRect(10 * bubbleScale, round((bubbleSize.height - labelHeight) / 2),
        bubbleSize.width - 20 * bubbleScale, labelHeight);
}

@end
