#import <Foundation/Foundation.h>

extern NSString *const CCPetsProfileProviderClaude;
extern NSString *const CCPetsProfileProviderCodex;
extern NSNotificationName const CCPetsProfilesDidChangeNotification;

NSString *CCPetsProfilesPath(void);
NSArray<NSDictionary *> *CCPetsProfiles(void);
NSArray<NSDictionary *> *CCPetsProfilesForProvider(NSString *provider);
NSDictionary *CCPetsProfileWithID(NSString *profileID);
NSDictionary *CCPetsProfileForHome(NSString *provider, NSString *home);
// 集成状态：state 取下面三个值之一；界面显示的文字统一走 CCPetsProfileStateTitle。
extern NSString *const CCPetsProfileStateIntegrated;
extern NSString *const CCPetsProfileStateRepair;
extern NSString *const CCPetsProfileStateUnavailable;
NSDictionary *CCPetsProfileStatus(NSDictionary *profile);
NSString *CCPetsProfileStateTitle(NSString *state);
NSString *CCPetsProfileID(NSString *provider, NSString *home);
NSString *CCPetsProfileSlug(NSString *home);
NSString *CCPetsProfileDefaultDisplayName(NSString *provider, NSString *home);
BOOL CCPetsProfileIsOfficialDefault(NSDictionary *profile);
// 文件夹像不像这家的 Agent Home：有本家特征文件，且没有另一家独有的文件。添加和重新定位前用它挡住选错的目录。
BOOL CCPetsProfileHomeMatchesProvider(NSString *provider, NSString *home);

// 添加或更新登记。Home 必须是现有目录；保存前会解析真实路径。
// existingID 非空用于“重新定位”，保留原身份与历史。
NSDictionary *CCPetsRegisterProfile(NSString *provider, NSString *home,
    NSString *displayName, NSString *existingID, NSString **errorMessage);
BOOL CCPetsForgetProfile(NSString *profileID, NSString **errorMessage);
BOOL CCPetsSetProfileNeedsRepair(NSString *profileID, BOOL needsRepair, NSString **errorMessage);

// 只迁移已经存在 CC Pets 管理标记的默认配置，不扫描任何其他目录。
BOOL CCPetsMigrateManagedDefaultProfiles(NSString **errorMessage);
// 自动发现官方 ~/.claude / ~/.codex（目录已存在或 CLI 已安装）；不发现任何自定义 Home。
BOOL CCPetsEnsureOfficialDefaultProfiles(NSString **errorMessage);

// profile CLI：list/ensure-defaults/add/repair/remove。add/repair 会执行实际集成适配。
int CCPetsProfileCommandMain(NSArray<NSString *> *arguments);
