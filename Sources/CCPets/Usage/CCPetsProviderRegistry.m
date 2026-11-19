#import "CCPetsProviderRegistry.h"
#import "CCPetsProfiles.h"
#import "CCPetsPaths.h"

@interface CCPetsProviderDescriptor ()
- (instancetype)initWithName:(NSString *)name key:(NSString *)key
    usedKey:(NSString *)usedKey profileProvider:(NSString *)profileProvider
    standardColorRGB:(NSArray<NSNumber *> *)standardColorRGB glassColorRGB:(NSArray<NSNumber *> *)glassColorRGB
    logoBundleIdentifier:(NSString *)logoBundleIdentifier logoResourceName:(NSString *)logoResourceName
    usageDisplayModeDefaultsKey:(NSString *)usageDisplayModeDefaultsKey billing:(NSString *)billing
    windowSpecs:(NSArray<NSDictionary *> *)windowSpecs normalizer:(CCPetsUsageNormalizer)normalizer;
@end

@implementation CCPetsProviderDescriptor
- (instancetype)initWithName:(NSString *)name key:(NSString *)key
    usedKey:(NSString *)usedKey profileProvider:(NSString *)profileProvider
    standardColorRGB:(NSArray<NSNumber *> *)standardColorRGB glassColorRGB:(NSArray<NSNumber *> *)glassColorRGB
    logoBundleIdentifier:(NSString *)logoBundleIdentifier logoResourceName:(NSString *)logoResourceName
    usageDisplayModeDefaultsKey:(NSString *)usageDisplayModeDefaultsKey billing:(NSString *)billing
    windowSpecs:(NSArray<NSDictionary *> *)windowSpecs normalizer:(CCPetsUsageNormalizer)normalizer {
    if ((self = [super init])) {
        _billing = [billing copy];
        _windowSpecs = [windowSpecs copy];
        _normalizer = [normalizer copy];
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

static NSArray<CCPetsProviderDescriptor *> *overrideProviders;

void CCPetsProviderRegistrySetOverride(NSArray<CCPetsProviderDescriptor *> *providers) {
    overrideProviders = [providers copy];
}

NSArray<CCPetsProviderDescriptor *> *CCPetsProviderDescriptors(void) {
    if (overrideProviders) return overrideProviders;
    static NSArray<CCPetsProviderDescriptor *> *providers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 这里的 L 只为多语言检查器标记英文源 key，绘制时才按当前语言翻译。
#define L(source) source
        NSArray *windows = @[
            @{@"key": @"fiveHour", @"titleKey": L(@"5h window"), @"minutes": @300, @"showDate": @NO},
            @{@"key": @"week", @"titleKey": L(@"7d window"), @"minutes": @10080, @"showDate": @YES, @"trend": @YES}
        ];
#undef L
        providers = @[
            [[CCPetsProviderDescriptor alloc] initWithName:@"Codex" key:@"codex"
                usedKey:@"used_percent" profileProvider:CCPetsProfileProviderCodex
                standardColorRGB:@[@0.30, @0.82, @0.90] glassColorRGB:@[@0.30, @0.82, @0.90]
                logoBundleIdentifier:@"com.openai.codex" logoResourceName:@"icon-chatgpt.icns"
                usageDisplayModeDefaultsKey:CodexUsageDisplayModeKey billing:@"subscription"
                windowSpecs:windows normalizer:nil],
            // 原生玻璃背后只有一层压暗，原来的紫在上面偏暗，glass 色提亮到和青色相近的明度。
            [[CCPetsProviderDescriptor alloc] initWithName:@"Claude" key:@"claude"
                usedKey:@"used_percentage" profileProvider:CCPetsProfileProviderClaude
                standardColorRGB:@[@0.66, @0.43, @0.94] glassColorRGB:@[@0.80, @0.66, @1.00]
                logoBundleIdentifier:@"com.anthropic.claudefordesktop" logoResourceName:@"electron.icns"
                usageDisplayModeDefaultsKey:ClaudeUsageDisplayModeKey billing:@"subscription"
                windowSpecs:windows normalizer:nil],
            [[CCPetsProviderDescriptor alloc] initWithName:@"Antigravity" key:@"antigravity"
                usedKey:@"used_percent" profileProvider:CCPetsProfileProviderAntigravity
                standardColorRGB:@[@0.28, @0.63, @0.98] glassColorRGB:@[@0.40, @0.71, @1.00]
                logoBundleIdentifier:@"com.google.antigravity" logoResourceName:@"icon.icns"
                usageDisplayModeDefaultsKey:AntigravityUsageDisplayModeKey billing:@"subscription"
                windowSpecs:windows normalizer:nil]
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
