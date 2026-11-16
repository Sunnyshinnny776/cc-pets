#import "CCPetsProviderRegistry.h"
#import "CCPetsProfiles.h"
#import "CCPetsPaths.h"

@interface CCPetsProviderDescriptor ()
- (instancetype)initWithName:(NSString *)name key:(NSString *)key
    usedKey:(NSString *)usedKey profileProvider:(NSString *)profileProvider
    standardColorRGB:(NSArray<NSNumber *> *)standardColorRGB glassColorRGB:(NSArray<NSNumber *> *)glassColorRGB
    logoBundleIdentifier:(NSString *)logoBundleIdentifier logoResourceName:(NSString *)logoResourceName
    usageDisplayModeDefaultsKey:(NSString *)usageDisplayModeDefaultsKey;
@end

@implementation CCPetsProviderDescriptor
- (instancetype)initWithName:(NSString *)name key:(NSString *)key
    usedKey:(NSString *)usedKey profileProvider:(NSString *)profileProvider
    standardColorRGB:(NSArray<NSNumber *> *)standardColorRGB glassColorRGB:(NSArray<NSNumber *> *)glassColorRGB
    logoBundleIdentifier:(NSString *)logoBundleIdentifier logoResourceName:(NSString *)logoResourceName
    usageDisplayModeDefaultsKey:(NSString *)usageDisplayModeDefaultsKey {
    if ((self = [super init])) {
        _name = [name copy];
        _key = [key copy];
        _usedKey = [usedKey copy];
        _profileProvider = [profileProvider copy];
        _standardColorRGB = [standardColorRGB copy];
        _glassColorRGB = [glassColorRGB copy];
        _logoBundleIdentifier = [logoBundleIdentifier copy];
        _logoResourceName = [logoResourceName copy];
        _usageDisplayModeDefaultsKey = [usageDisplayModeDefaultsKey copy];
    }
    return self;
}
@end

NSArray<CCPetsProviderDescriptor *> *CCPetsProviderDescriptors(void) {
    static NSArray<CCPetsProviderDescriptor *> *providers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        providers = @[
            [[CCPetsProviderDescriptor alloc] initWithName:@"Codex" key:@"codex"
                usedKey:@"used_percent" profileProvider:CCPetsProfileProviderCodex
                standardColorRGB:@[@0.30, @0.82, @0.90] glassColorRGB:@[@0.30, @0.82, @0.90]
                logoBundleIdentifier:@"com.openai.codex" logoResourceName:@"icon-chatgpt.icns"
                usageDisplayModeDefaultsKey:CodexUsageDisplayModeKey],
            // 原生玻璃背后只有一层压暗，原来的紫在上面偏暗，glass 色提亮到和青色相近的明度。
            [[CCPetsProviderDescriptor alloc] initWithName:@"Claude" key:@"claude"
                usedKey:@"used_percentage" profileProvider:CCPetsProfileProviderClaude
                standardColorRGB:@[@0.66, @0.43, @0.94] glassColorRGB:@[@0.80, @0.66, @1.00]
                logoBundleIdentifier:@"com.anthropic.claudefordesktop" logoResourceName:@"electron.icns"
                usageDisplayModeDefaultsKey:ClaudeUsageDisplayModeKey]
        ];
    });
    return providers;
}

CCPetsProviderDescriptor *CCPetsProviderForName(NSString *name) {
    for (CCPetsProviderDescriptor *provider in CCPetsProviderDescriptors()) {
        if ([provider.name isEqualToString:name]) return provider;
    }
    return nil;
}

CCPetsProviderDescriptor *CCPetsProviderForProfileProvider(NSString *profileProvider) {
    for (CCPetsProviderDescriptor *provider in CCPetsProviderDescriptors()) {
        if ([provider.profileProvider isEqualToString:profileProvider]) return provider;
    }
    return nil;
}
