#import <Cocoa/Cocoa.h>

extern NSString *const CCPetsPanelThemeKey;
NSString *CCPetsPanelTheme(void);
// 桌面小组件式玻璃背后压暗层的档位：0 / 15 / 25 / 45（百分比），默认 25。
extern NSString *const CCPetsGlassDimKey;
NSInteger CCPetsGlassDimLevel(void);
NSArray<NSNumber *> *CCPetsGlassDimLevels(void);
// 额度卡片衬底的不透明度，跟随压暗档位：卡片区域同时受背后压暗和衬底两层影响，
// 衬底固定的话选「通透」时卡片仍然很深。
CGFloat CCPetsGlassCardScrimAlpha(void);
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
- (instancetype)initWithFrame:(NSRect)frame material:(NSVisualEffectMaterial)material
    appearance:(NSAppearanceName)appearance cornerRadius:(CGFloat)cornerRadius;
- (void)applyTheme;
// 只按当前档位更新压暗层透明度，不重建玻璃。
- (void)applyDimLevel;
@end
