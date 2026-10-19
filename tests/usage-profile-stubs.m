#import "CCPetsProfiles.h"
#import "CCPetsPaths.h"

// 用量相关独立编译目标共用只读注册表，避免引入完整的 Profile/Bridge 安装栈。
// 正式监控器只会读取已登记的账号，因此测试桩必须保留两个官方默认 Home。
NSString *const CCPetsProfileProviderClaude = @"claude";
NSString *const CCPetsProfileProviderCodex = @"codex";
NSArray<NSDictionary *> *CCPetsProfiles(void) {
    return @[
        @{ @"id": @"claude:default", @"provider": CCPetsProfileProviderClaude,
           @"home": DefaultClaudeConfigDirectory() },
        @{ @"id": @"codex:default", @"provider": CCPetsProfileProviderCodex,
           @"home": DefaultCodexHomeDirectory() },
    ];
}
NSArray<NSDictionary *> *CCPetsProfilesForProvider(NSString *provider) {
    if (provider.length == 0) return @[];
    NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
    for (NSDictionary *profile in CCPetsProfiles()) {
        if ([profile[@"provider"] isEqualToString:provider]) [matches addObject:profile];
    }
    return matches.copy;
}

NSDictionary *CCPetsProfileForHome(NSString *provider, NSString *home) {
    NSString *target = home.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    for (NSDictionary *profile in CCPetsProfilesForProvider(provider)) {
        NSString *candidate = [profile[@"home"] stringByStandardizingPath].stringByResolvingSymlinksInPath;
        if ([candidate isEqualToString:target]) return profile;
    }
    return nil;
}
