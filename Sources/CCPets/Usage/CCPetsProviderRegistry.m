#import "CCPetsProviderRegistry.h"
#import "CCPetsProfiles.h"

@interface CCPetsProviderDescriptor ()
- (instancetype)initWithName:(NSString *)name key:(NSString *)key
    usedKey:(NSString *)usedKey profileProvider:(NSString *)profileProvider;
@end

@implementation CCPetsProviderDescriptor
- (instancetype)initWithName:(NSString *)name key:(NSString *)key
    usedKey:(NSString *)usedKey profileProvider:(NSString *)profileProvider {
    if ((self = [super init])) {
        _name = [name copy];
        _key = [key copy];
        _usedKey = [usedKey copy];
        _profileProvider = [profileProvider copy];
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
                usedKey:@"used_percent" profileProvider:CCPetsProfileProviderCodex],
            [[CCPetsProviderDescriptor alloc] initWithName:@"Claude" key:@"claude"
                usedKey:@"used_percentage" profileProvider:CCPetsProfileProviderClaude]
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
