#import "CCPetsProviderRegistry.h"

@interface CCPetsProviderDescriptor (Testing)
- (instancetype)initWithName:(NSString *)name key:(NSString *)key
    usedKey:(NSString *)usedKey profileProvider:(NSString *)profileProvider
    standardColorRGB:(NSArray<NSNumber *> *)standardColorRGB glassColorRGB:(NSArray<NSNumber *> *)glassColorRGB
    logoBundleIdentifier:(NSString *)logoBundleIdentifier logoResourceName:(NSString *)logoResourceName
    usageDisplayModeDefaultsKey:(NSString *)usageDisplayModeDefaultsKey billing:(NSString *)billing
    windowSpecs:(NSArray<NSDictionary *> *)windowSpecs normalizer:(CCPetsUsageNormalizer)normalizer;
@end

// 测试期间在主线程安装；传 nil 恢复产品注册表。
void CCPetsProviderRegistrySetOverride(NSArray<CCPetsProviderDescriptor *> *providers);
