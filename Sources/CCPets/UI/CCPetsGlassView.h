#import <Cocoa/Cocoa.h>

extern NSString *const CCPetsPanelThemeKey;
NSString *CCPetsPanelTheme(void);
// 桌面小组件式玻璃背后压暗层的实际不透明度（百分比），0–45 之间连续可调，默认 25。
// 界面上统一换算成 0–100 的“强度”展示：100 对应实际 45。
// 主窗口用滑块连续调；右键菜单只列 CCPetsGlassDimLevels() 四档，勾选最接近当前值的那档。
extern NSString *const CCPetsGlassDimKey;
extern const NSInteger CCPetsGlassDimMaximum;
// 实际不透明度百分比（0–45，可带小数）。
double CCPetsGlassDimLevel(void);
// 展示用强度（0–100）。
NSInteger CCPetsGlassDimPercent(void);
// 强度（0–100）换算成实际不透明度百分比（0–45）。
double CCPetsGlassDimLevelForPercent(double percent);
// 菜单四档，单位是展示强度（0–100）。
NSArray<NSNumber *> *CCPetsGlassDimLevels(void);
// 四档里离 percent 最近的一档；两档等距时取较小的。
NSInteger CCPetsNearestGlassDimLevel(NSInteger percent);
// 额度卡片衬底的不透明度，跟随压暗档位：卡片区域同时受背后压暗和衬底两层影响，
// 衬底固定的话选「通透」时卡片仍然很深。
CGFloat CCPetsGlassCardScrimAlpha(void);
// 同上，但按传入的实际压暗值（0–45）计算；设置页预览拖动滑块时用。
CGFloat CCPetsGlassCardScrimAlphaForLevel(double level);

// 宠物说话气泡的样式：真实气泡和设置页的 Liquid Glass 预览共用，改一处两边同步。
static const CGFloat CCPetsSpeechBubbleHeight = 38.0;
static const CGFloat CCPetsSpeechBubblePadding = 16.0;
static const CGFloat CCPetsSpeechBubbleFontSize = 13.0;
static const CGFloat CCPetsSpeechBubbleEdgeShadeHeight = 9.0;
static const CGFloat CCPetsSpeechBubbleEdgeShadeAlpha = 0.6;
// 玻璃上白字的贴字形投影（状态卡、气泡、额度面板一致）。
NSShadow *CCPetsGlassTextShadow(void);
// 运行系统和构建 SDK 都支持 NSGlassEffectView 时才为 YES。
BOOL CCPetsLiquidGlassAvailable(void);

// 固定的内容容器使主题切换不影响文字、按钮和悬停状态。
@interface CCPetsGlassView : NSView
@property(nonatomic, readonly) NSView *contentView;
@property(nonatomic, readonly) BOOL usesLiquidGlass;
@property(nonatomic) CGFloat cornerRadius;
// 桌面小组件式玻璃：背景清晰、边缘折射，并在玻璃背后垫一层压暗托住白字。只适合白字面板。
@property(nonatomic) BOOL usesWidgetGlass;
// 上下沿压高光暗带的高度和最深处不透明度，默认 12pt / 0.6（额度面板实测值）。
// 胶囊形的状态卡、气泡比较矮，要在设置 usesWidgetGlass 之前调小。
@property(nonatomic) CGFloat edgeShadeHeight;
@property(nonatomic) CGFloat edgeShadeAlpha;
// 不看当前主题，始终用原生玻璃（设置页的 Liquid Glass 预览用）；系统不支持时仍退回磨砂。
@property(nonatomic) BOOL forcesLiquidGlass;
- (instancetype)initWithFrame:(NSRect)frame material:(NSVisualEffectMaterial)material
    appearance:(NSAppearanceName)appearance cornerRadius:(CGFloat)cornerRadius;
- (void)applyTheme;
// 只按当前档位更新压暗层透明度，不重建玻璃。
- (void)applyDimLevel;
// 按指定的实际压暗值（0–45）更新压暗层，不读偏好；预览拖动滑块时用。
- (void)applyDimLevel:(double)level;
@end
