#import <Cocoa/Cocoa.h>

// 设置页要 AppDelegate 做的事：写设置并让桌宠界面当场生效。与右键菜单调的是同一组
// update 方法（见 CCPetsAppDelegate+Settings.m），这里只声明契约，页面不 import AppDelegate 的私有头。
//
// AppDelegate 不在声明上采纳这个协议：这些方法分散实现在好几个 category 里，采纳后编译器会
// 逐个 category 报"协议方法由主类实现"。签名一致由 tests/test.sh 的检查守着。
@protocol CCPetsSettingsActions <NSObject>
- (void)updatePetScale:(double)scale;
- (void)updateStatusBubbleExpanded:(BOOL)expanded;
- (void)updateSystemMetric:(NSString *)key enabled:(BOOL)enabled;
- (void)updateUsageDisplayMode:(NSString *)mode forKey:(NSString *)key;
- (void)updateImportCodexPets:(BOOL)enabled;
- (void)updatePanelTheme:(NSString *)theme;
- (void)updateGlassDimLevel:(NSNumber *)level;
- (void)updateSpeechEnabled:(BOOL)enabled;
- (void)updatePetInteractionEnabled:(BOOL)enabled;
- (void)updatePetInteractionValue:(NSNumber *)value forKey:(NSString *)key;
- (void)updateSpeechFrequency:(NSString *)value;
- (void)updatePhrasesSource:(NSString *)source;
- (void)updateNotification:(NSString *)key enabled:(BOOL)enabled
    completion:(void (^)(BOOL enabled))completion;
- (void)updateBridgeBadgeEnabled:(BOOL)enabled;
- (void)editPhrasesFile:(id)sender;
@end

// 主窗口的「设置」页：右键菜单里的设置按组摊开，外加菜单里放不下的连续调节和文件夹入口。
// 控件状态一律现读 defaults；收到 CCPetsPreferencesDidChangeNotification（比如在右键菜单里
// 改了）就整体重读一遍，两边始终一致。
@interface CCPetsSettingsPage : NSViewController
@end
