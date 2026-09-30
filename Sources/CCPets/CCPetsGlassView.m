#import "CCPetsGlassView.h"
#import <QuartzCore/QuartzCore.h>

NSString *const CCPetsPanelThemeKey = @"CCPetsPanelTheme";

NSString *CCPetsPanelTheme(void) {
    NSString *theme = [NSUserDefaults.standardUserDefaults stringForKey:CCPetsPanelThemeKey];
    // 早期版本有过 "system" 选项，行为与 liquid 完全一致，读到时按 liquid 处理。
    if ([theme isEqualToString:@"system"]) return @"liquid";
    return [theme isEqualToString:@"liquid"] ? theme : @"classic";
}

NSString *const CCPetsGlassDimKey = @"CCPetsGlassDim";

NSArray<NSNumber *> *CCPetsGlassDimLevels(void) { return @[@0, @15, @25, @45]; }

// 档位来自对照实测：0 最通透但亮背景下小字看不清；25 在暗、亮壁纸上都基本可读；
// 45 最清楚但明显偏暗。没设置过或值不在档位里时用 25。
NSInteger CCPetsGlassDimLevel(void) {
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:CCPetsGlassDimKey];
    if (![stored isKindOfClass:NSNumber.class]) return 25;
    return [CCPetsGlassDimLevels() containsObject:stored] ? [stored integerValue] : 25;
}

CGFloat CCPetsGlassCardScrimAlpha(void) {
    switch (CCPetsGlassDimLevel()) {
        case 0: return 0.06;
        case 15: return 0.10;
        case 45: return 0.16;
        default: return 0.12;
    }
}

BOOL CCPetsLiquidGlassAvailable(void) {
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if (@available(macOS 26.0, *)) return YES;
#endif
    return NO;
}

// 上下沿各一条从边缘向内渐隐的暗带，压 variant 11 自带的上下高光线。
@interface CCPetsEdgeShadeView : NSView
@property(nonatomic) CGFloat bandHeight;
@property(nonatomic) CGFloat bandAlpha;
@end

@implementation CCPetsEdgeShadeView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.masksToBounds = YES;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        for (int index = 0; index < 2; index++) [self.layer addSublayer:[CAGradientLayer layer]];
    }
    return self;
}
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self updateBands];
}
- (void)updateBands {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    id dark = (id)[NSColor colorWithWhite:0 alpha:self.bandAlpha].CGColor;
    id clear = (id)[NSColor colorWithWhite:0 alpha:0].CGColor;
    NSArray<CAGradientLayer *> *bands = (NSArray<CAGradientLayer *> *)self.layer.sublayers;
    // 底带暗色贴下沿，顶带暗色贴上沿；CAGradientLayer 的颜色顺序沿 layer 坐标 y 递增。
    bands[0].frame = CGRectMake(0, 0, NSWidth(self.bounds), self.bandHeight);
    bands[0].colors = @[dark, clear];
    bands[1].frame = CGRectMake(0, NSHeight(self.bounds) - self.bandHeight,
        NSWidth(self.bounds), self.bandHeight);
    bands[1].colors = @[clear, dark];
    [CATransaction commit];
}
@end

@interface CCPetsGlassView ()
@property(nonatomic) NSView *contentView;
@property(nonatomic) NSView *effectView;
@property(nonatomic) NSView *backdropDimView;
@property(nonatomic) CCPetsEdgeShadeView *edgeShadeView;
@property(nonatomic) BOOL experimentalVariantApplied;
@property(nonatomic) BOOL usesLiquidGlass;
@property(nonatomic) NSVisualEffectMaterial fallbackMaterial;
@end

@implementation CCPetsGlassView
- (instancetype)initWithFrame:(NSRect)frame material:(NSVisualEffectMaterial)material
    appearance:(NSAppearanceName)appearance cornerRadius:(CGFloat)cornerRadius {
    self = [super initWithFrame:frame];
    if (self) {
        _fallbackMaterial = material;
        _cornerRadius = cornerRadius;
        _edgeShadeHeight = 12;
        _edgeShadeAlpha = 0.6;
        self.appearance = [NSAppearance appearanceNamed:appearance];
        _contentView = [[NSView alloc] initWithFrame:self.bounds];
        _contentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self applyTheme];
    }
    return self;
}

- (void)applyTheme {
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if (@available(macOS 26.0, *)) {
        if ([self.effectView isKindOfClass:NSGlassEffectView.class]) {
            ((NSGlassEffectView *)self.effectView).contentView = nil;
        }
    }
#endif
    [self.contentView removeFromSuperview];
    // NSGlassEffectView 接管 contentView 时会把它改成 Auto Layout（关掉自动转换约束）。
    // 移到别的父视图后若不恢复，布局引擎会按固有尺寸把它压成 0 宽，里面的滚动视图随之
    // 变成 0×0、内容全被裁掉（实测）。重建时统一恢复成按 autoresizingMask 布局。
    self.contentView.translatesAutoresizingMaskIntoConstraints = YES;
    [self.effectView removeFromSuperview];
    [self.backdropDimView removeFromSuperview];
    self.backdropDimView = nil;
    [self.edgeShadeView removeFromSuperview];
    self.edgeShadeView = nil;
    self.experimentalVariantApplied = NO;
    self.usesLiquidGlass = NO;
    self.contentView.frame = self.bounds;
    // 编译期和运行期双重保护，仍能用旧 SDK 构建并在 macOS 13 上运行。
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if (@available(macOS 26.0, *)) {
        if ([CCPetsPanelTheme() isEqualToString:@"liquid"]) {
            NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:self.bounds];
            glass.style = self.usesWidgetGlass
                ? NSGlassEffectViewStyleClear : NSGlassEffectViewStyleRegular;
            if (self.usesWidgetGlass) glass = [self applyWidgetGlass:glass];
            glass.cornerRadius = self.cornerRadius;
            // 暗带要盖在玻璃上、又不能盖住文字，所以私有 variant 生效时内容改放到玻璃
            // 外面最上层；玻璃只拿一个空的 contentView。
            glass.contentView = self.experimentalVariantApplied
                ? [[NSView alloc] initWithFrame:self.bounds] : self.contentView;
            self.effectView = glass;
            self.usesLiquidGlass = YES;
        }
    }
#endif
    if (!self.usesLiquidGlass) {
        NSVisualEffectView *blur = [[NSVisualEffectView alloc] initWithFrame:self.bounds];
        blur.material = self.fallbackMaterial;
        blur.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        blur.state = NSVisualEffectStateActive;
        blur.wantsLayer = YES;
        blur.layer.cornerRadius = self.cornerRadius;
        blur.layer.cornerCurve = kCACornerCurveContinuous;
        blur.layer.masksToBounds = YES;
        if (self.fallbackMaterial == NSVisualEffectMaterialPopover) {
            blur.layer.borderWidth = 1;
            blur.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.48].CGColor;
        }
        [blur addSubview:self.contentView];
        self.effectView = blur;
    }
    self.effectView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:self.effectView];
    if (self.experimentalVariantApplied) {
        CCPetsEdgeShadeView *shade = [[CCPetsEdgeShadeView alloc] initWithFrame:self.bounds];
        shade.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        shade.layer.cornerRadius = self.cornerRadius;
        // 默认 12pt / 0.6 是额度面板的对照实测值：再深会在亮背景上压出一条明显的黑带，
        // 再浅压不住深色背景上的亮线。
        shade.bandHeight = self.edgeShadeHeight;
        shade.bandAlpha = self.edgeShadeAlpha;
        [shade updateBands];
        [self addSubview:shade];
        self.edgeShadeView = shade;
        [self addSubview:self.contentView];
        self.contentView.frame = self.bounds;
    }
}

#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
// macOS 27 上实测：公开的 Clear/Regular 在 App 未激活、窗口不是 key 时会被换成磨砂的
// 非激活样式；桌宠永远是 nonactivating 面板，在这个系统上公开样式基本是一块奶白。未公开的
// _variant 不跟随 key 状态，能保持清透和折射。扫过 0–35：只有 11 有厚玻璃的边缘折射，
// 但它上下沿自带很亮的高光线，深色背景下扎眼，由 CCPetsEdgeShadeView 压下去；14 没有亮线，
// 但折射也几乎没了，看起来不像玻璃。它是实现细节而不是
// API：只在验证过的系统主版本上启用，并可用 defaults 关掉，其余情况一律用公开 Clear。
static BOOL CCPetsExperimentalGlassVariantEnabled(void) {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"CCPetsDisableExperimentalGlass"]) return NO;
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27;
}
//
// 可读性不能靠 tintColor 或 contentView 里的深色底：前者对这个 variant 无效，后者会被
// 玻璃的 vibrant 混合吃掉。有效的做法是把压暗层放在玻璃背后，让玻璃采样到的背景本身
// 变暗，折射和高光都还在。
//
// 压暗层在私有 variant 失败、被关闭或系统版本不符时同样保留：此时公开 Clear 在非 key
// 窗口里是磨砂，没有这层垫底白字会更难读。这是刻意的设计，不是遗留。
- (NSGlassEffectView *)applyWidgetGlass:(NSGlassEffectView *)glass API_AVAILABLE(macos(26.0)) {
    if (CCPetsExperimentalGlassVariantEnabled() &&
        [glass respondsToSelector:NSSelectorFromString(@"set_variant:")]) {
        @try {
            [glass setValue:@11 forKey:@"_variant"];
            self.experimentalVariantApplied = YES;
        } @catch (NSException *exception) {
            // 赋值抛到一半时内部状态不可信，换一个全新的公开 Clear 实例。
            glass = [[NSGlassEffectView alloc] initWithFrame:self.bounds];
            glass.style = NSGlassEffectViewStyleClear;
        }
    }
    NSView *dim = [[NSView alloc] initWithFrame:self.bounds];
    dim.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    dim.wantsLayer = YES;
    dim.layer.cornerRadius = self.cornerRadius;
    dim.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:dim];
    self.backdropDimView = dim;
    [self applyDimLevel];
    return glass;
}
#endif

- (void)applyDimLevel {
    CGFloat alpha = CCPetsGlassDimLevel() / 100.0;
    self.backdropDimView.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:alpha].CGColor;
    self.backdropDimView.hidden = alpha <= 0;
}

- (void)setUsesWidgetGlass:(BOOL)usesWidgetGlass {
    if (_usesWidgetGlass == usesWidgetGlass) return;
    _usesWidgetGlass = usesWidgetGlass;
    [self applyTheme];
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    _cornerRadius = cornerRadius;
    self.backdropDimView.layer.cornerRadius = cornerRadius;
    self.edgeShadeView.layer.cornerRadius = cornerRadius;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if (@available(macOS 26.0, *)) {
        if (self.usesLiquidGlass) {
            ((NSGlassEffectView *)self.effectView).cornerRadius = cornerRadius;
            return;
        }
    }
#endif
    self.effectView.layer.cornerRadius = cornerRadius;
}
@end
