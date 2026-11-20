#import <Foundation/Foundation.h>

// 用户设置的统一写入口。右键菜单和主窗口设置页都走这里，保证两边写进去的值经过同一套
// 钳制，且任何一边改了都会发出 CCPetsPreferencesDidChangeNotification，另一边据此刷新。
//
// 只管 defaults 本身：写值、规整、广播。改完之后要让界面生效（换主题、重排气泡、重新聚合
// 用量……）是 AppDelegate (Settings) 里 update* 方法的事，这一层不认识任何视图。

// userInfo[CCPetsPreferencesChangedKeyKey] 是被改的 defaults 键。只有值真的变了才发。
extern NSNotificationName const CCPetsPreferencesDidChangeNotification;
extern NSString *const CCPetsPreferencesChangedKeyKey;

extern NSString *const PetSpeechEnabledKey;
extern NSString *const PetInteractionEnabledKey;
extern NSString *const PetInteractionHeartThresholdKey;
extern NSString *const PetInteractionAnnoyedThresholdKey;
extern NSString *const PetInteractionIntervalKey;
// 启动保护按代理软件分别保存；增加软件时定义独立的布尔键。
extern NSString *const CCPetsShadowrocketLaunchCheckKey;
extern NSString *const CCPetsLaunchProtectionStrictRoutingKey;

// 显示位置：仅桌宠（默认）/ 桌宠 + 菜单栏 / 仅菜单栏。字符串而不是整数，以后加模式不错位。
extern NSString *const CCPetsDisplayModeKey;
extern NSString *const CCPetsDisplayModePet;
extern NSString *const CCPetsDisplayModeBoth;
extern NSString *const CCPetsDisplayModeMenuBar;
// 菜单栏图标旁常驻显示最低的 5 小时剩余额度。默认关；低于 20% 时不论开关都会显示。
extern NSString *const CCPetsMenuBarShowsPercentKey;
// 悬停额度卡使用稳定的 Provider key 保存顺序，空数组表示自动排序。
extern NSString *const CCPetsQuotaCardOrderKey;
NSArray<NSString *> *CCPetsQuotaCardOrder(void);
// 规整后的显示位置：没写过或写了未知值都按仅桌宠处理。
NSString *CCPetsDisplayMode(void);

// 布尔设置。碎碎念这类"没写过就算开"的键在这里统一兜底，调用方不必各自判 nil。
BOOL CCPetsPrefBool(NSString *key);
void CCPetsPrefSetBool(NSString *key, BOOL value);

// 写字符串、数字或额度卡顺序。数值键会先钳到合法范围（宠物缩放、点击互动阈值与间隔）；
// 规整后不合法（NaN 之类）时不写，返回 NO。value 为 nil 表示删除该键，交回默认值。
BOOL CCPetsPrefSetObject(NSString *key, id value);

// 规整后的值，不写入。供测试和需要回显钳制结果的控件使用；不合法时返回 nil。
id CCPetsPrefNormalizedValue(NSString *key, id value);

// 不经过上面两个 setter、由其他模块自己写 defaults 的键（台词来源、界面语言）改完后补发广播。
void CCPetsPrefPostChange(NSString *key);
