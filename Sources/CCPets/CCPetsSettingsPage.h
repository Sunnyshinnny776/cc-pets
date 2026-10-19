#import <Cocoa/Cocoa.h>
#import "CCPetsMainWindow.h"

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
- (void)updateUsageDisplayMode:(NSString *)mode forProfileID:(NSString *)profileID;
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
// 按当前台词来源抽一句闲话，不说出来、不占碎碎念的预算和冷却。
- (NSString *)sampleSpeechLine;
// 让桌宠当场说这句（和台词编辑器的"试说一句"同一条路）。
- (void)presentSpeechText:(NSString *)text;
// 可选的宠物：id、name、path（精灵图）、rowCount、builtin（是否包内自带）。
- (NSArray<NSDictionary *> *)petPickerOptions;
- (NSString *)currentPetID;
- (void)switchPetToID:(NSString *)petID;
@end

// 设置拆成三页，共用这个基类：控件状态一律现读 defaults；收到 CCPetsPreferencesDidChangeNotification
// （比如在右键菜单里改了）就整体重读一遍，两边始终一致。
@interface CCPetsSettingsPageBase : NSViewController
@end

// 宠物：选哪只、多大、碎碎念、戳它的反应。
@interface CCPetsPetPage : CCPetsSettingsPageBase
@end

// 提醒：系统通知、桌面状态卡与 CC Bridge 角标。
@interface CCPetsAlertsPage : CCPetsSettingsPageBase
@end

// 通用：语言、主窗口外观（跟随系统 / 浅色 / 深色）、浮层外观（主题、玻璃压暗）、悬停面板显示什么、数据文件夹。
@interface CCPetsGeneralPage : CCPetsSettingsPageBase
@end
