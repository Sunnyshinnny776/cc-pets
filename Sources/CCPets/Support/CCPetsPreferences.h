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

// 布尔设置。碎碎念这类"没写过就算开"的键在这里统一兜底，调用方不必各自判 nil。
BOOL CCPetsPrefBool(NSString *key);
void CCPetsPrefSetBool(NSString *key, BOOL value);

// 写字符串或数字。数值键会先钳到合法范围（宠物缩放、点击互动阈值与间隔）；
// 规整后不合法（NaN 之类）时不写，返回 NO。value 为 nil 表示删除该键，交回默认值。
BOOL CCPetsPrefSetObject(NSString *key, id value);

// 规整后的值，不写入。供测试和需要回显钳制结果的控件使用；不合法时返回 nil。
id CCPetsPrefNormalizedValue(NSString *key, id value);

// 不经过上面两个 setter、由其他模块自己写 defaults 的键（台词来源、界面语言）改完后补发广播。
void CCPetsPrefPostChange(NSString *key);
