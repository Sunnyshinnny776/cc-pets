#import "CCPetsProviderRegistry.h"

// 缺少百分比的窗口不包含 used；原始 quota 和 token 桶只读。
NSDictionary *CCPetsNormalizedUsage(CCPetsProviderDescriptor *provider, NSDictionary *rawUsage, BOOL showsAPIUsage);
NSDictionary *CCPetsTrendWindow(NSArray<NSDictionary *> *windows);
