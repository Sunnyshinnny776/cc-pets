#import <Foundation/Foundation.h>

extern NSNotificationName const CCPetsAuthenticationModesDidChangeNotification;
// 只缓存认证类型，不缓存或输出密钥。必须在后台调用；按账号 Home 隔离，最多每分钟探测一次。
void CCPetsRefreshProfileAuthenticationModes(NSArray<NSDictionary *> *profiles);
// api / subscription / unknown。UI 只读内存快照，不启动 CLI。
NSString *CCPetsProfileAuthenticationMode(NSDictionary *profile);
NSString *CCPetsUsageModePreferenceKey(NSDictionary *profile);
BOOL CCPetsProfileShowsAPIUsage(NSDictionary *profile);
BOOL CCPetsProfileCanSwitchUsageMode(NSDictionary *profile);
