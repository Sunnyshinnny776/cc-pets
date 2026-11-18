#import "CCPetsNormalizedUsage.h"

static NSDictionary *Dictionary(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

NSDictionary *CCPetsTrendWindow(NSArray<NSDictionary *> *windows) {
    for (NSDictionary *window in windows) {
        if ([window[@"trend"] boolValue]) return window;
    }
    return windows.lastObject;
}

NSDictionary *CCPetsNormalizedUsage(CCPetsProviderDescriptor *provider, NSDictionary *rawUsage, BOOL showsAPIUsage) {
    if (provider.normalizer) return provider.normalizer(rawUsage ?: @{}, showsAPIUsage);
    NSString *billing = showsAPIUsage ? @"api" : (provider.billing ?: @"none");
    NSDictionary *tokens = Dictionary(rawUsage[@"tokenUsage"]);
    BOOL exhausted = [rawUsage[@"exhaustedAt"] isKindOfClass:NSNumber.class];
    BOOL hasWindowData = exhausted;
    NSMutableArray *windows = [NSMutableArray array];
    for (NSDictionary *spec in provider.windowSpecs) {
        NSString *key = spec[@"key"];
        NSDictionary *quota = Dictionary(rawUsage[key]);
        NSDictionary *totals = Dictionary(tokens[key]);
        id used = quota[provider.usedKey];
        NSMutableDictionary *window = [spec mutableCopy];
        window[@"quota"] = quota ?: @{};
        window[@"tokens"] = totals ?: @{};
        window[@"trend"] = @([spec[@"trend"] boolValue]);
        if ([used isKindOfClass:NSNumber.class]) {
            window[@"used"] = @(fmax(0, fmin(100, [used doubleValue])));
        }
        if (window[@"used"] || totals) hasWindowData = YES;
        [windows addObject:[window copy]];
    }
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"month", @"monthComparable", @"previousMonthToDate", @"today", @"recentWeek", @"monthDaily"]) {
        summary[key] = tokens[key];
    }
    BOOL hasData = [billing isEqualToString:@"subscription"] ? hasWindowData : Dictionary(tokens[@"month"]) != nil;
    return @{@"billing": billing, @"windows": [windows copy], @"tokens": [summary copy],
        @"exhausted": @(exhausted), @"hasData": @(hasData)};
}
