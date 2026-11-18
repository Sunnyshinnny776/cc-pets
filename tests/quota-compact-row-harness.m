#import "QuotaDashboardView+Private.h"
#import "CCPetsProviderRegistry+Testing.h"

static CCPetsProviderDescriptor *Provider(NSString *name, NSString *billing, NSArray *specs,
    CCPetsUsageNormalizer normalizer) {
    return [[CCPetsProviderDescriptor alloc] initWithName:name key:name.lowercaseString usedKey:@"spent"
        profileProvider:name.lowercaseString standardColorRGB:@[@0.23, @0.81, @0.76]
        glassColorRGB:@[@0.65, @0.90, @0.80] logoBundleIdentifier:nil logoResourceName:nil
        usageDisplayModeDefaultsKey:nil billing:billing windowSpecs:specs normalizer:normalizer];
}

static NSDictionary *Window(NSString *key, NSString *title, NSInteger minutes, BOOL trend) {
    return @{@"key": key, @"titleKey": title, @"minutes": @(minutes), @"showDate": @(trend), @"trend": @(trend)};
}

static void Check(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "%s\n", message.UTF8String);
        exit(EXIT_FAILURE);
    }
}

static void CheckNormalization(CCPetsProviderDescriptor *sub, NSDictionary *raw) {
    NSDictionary *result = CCPetsNormalizedUsage(sub, raw, NO);
    NSArray *windows = result[@"windows"];
    Check([result[@"billing"] isEqual:@"subscription"] && [result[@"hasData"] boolValue] &&
        ![result[@"exhausted"] boolValue] && windows.count == 2, @"subscription model");
    NSDictionary *first = windows[0], *second = windows[1];
    Check([first[@"key"] isEqual:@"hour"] && [first[@"titleKey"] isEqual:@"1h"] &&
        [first[@"used"] isEqual:@75] && [first[@"quota"] isEqual:raw[@"hour"]] &&
        [first[@"tokens"] isEqual:raw[@"tokenUsage"][@"hour"]] && ![first[@"showDate"] boolValue] &&
        [second[@"showDate"] boolValue] && [second[@"trend"] boolValue] &&
        [CCPetsTrendWindow(windows) isEqual:second], @"window metadata and order");
    Check([CCPetsTrendWindow(@[second, first]) isEqual:second] &&
        [CCPetsTrendWindow(@[first]) isEqual:first] && !CCPetsTrendWindow(@[]), @"trend selection");
    for (NSString *key in @[@"month", @"monthComparable", @"previousMonthToDate", @"today", @"recentWeek", @"monthDaily"]) {
        Check([result[@"tokens"][key] isEqual:raw[@"tokenUsage"][key]], key);
    }
    result = CCPetsNormalizedUsage(sub, @{@"hour": @{@"spent": @120}, @"day": @{@"spent": @-5}}, NO);
    Check([result[@"windows"][0][@"used"] isEqual:@100] && [result[@"windows"][1][@"used"] isEqual:@0], @"clamp");
    result = CCPetsNormalizedUsage(sub, @{@"hour": @{@"spent": @"90"}, @"day": NSNull.null}, NO);
    Check(!result[@"windows"][0][@"used"] && ![result[@"hasData"] boolValue], @"invalid / absent window");
    result = CCPetsNormalizedUsage(sub, @{@"tokenUsage": @{@"day": @{}}}, NO);
    Check([result[@"hasData"] boolValue], @"window token bucket without limits");
    result = CCPetsNormalizedUsage(sub, @{@"exhaustedAt": @0}, NO);
    Check([result[@"exhausted"] boolValue] && [result[@"hasData"] boolValue], @"exhausted without window");
    result = CCPetsNormalizedUsage(sub, @{@"exhaustedAt": @0}, YES);
    Check([result[@"billing"] isEqual:@"api"] && ![result[@"hasData"] boolValue], @"API needs a month bucket");
    Check([CCPetsNormalizedUsage(sub, raw, YES)[@"hasData"] boolValue], @"API month bucket");
    CCPetsProviderDescriptor *custom = Provider(@"Custom", @"none", @[], ^NSDictionary *(NSDictionary *usage, BOOL api) {
        return @{@"billing": api ? @"api" : @"credits", @"windows": @[], @"tokens": usage[@"counts"],
            @"exhausted": @NO, @"hasData": @YES};
    });
    result = CCPetsNormalizedUsage(custom, @{@"counts": @{@"today": @42}}, NO);
    Check([result[@"billing"] isEqual:@"credits"] && [result[@"tokens"][@"today"] isEqual:@42], @"custom normalizer");
}

// 每张图同一组账号并排验收两种模板。PNG 路径仅用于手动审查，测试始终绘制位图。
static void DrawTemplates(NSArray<CCPetsProviderDescriptor *> *providers, NSDictionary *raw, BOOL glass,
    NSUInteger variant, NSString *directory) {
    CGFloat width = 740, height = providers.count * 218 + 10;
    NSRect bounds = NSMakeRect(0, 0, width, height);
    QuotaDashboardView *view = [[QuotaDashboardView alloc] initWithFrame:bounds];
    view.usesLiquidGlass = glass;
    view.cardScrimAlpha = 0.18;
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width
        pixelsHigh:height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    Check(context != nil, @"bitmap graphics context");
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = context;
    [[NSColor colorWithWhite:0.11 alpha:1] setFill];
    NSRectFill(bounds);
    NSImage *logo = [NSImage imageWithSystemSymbolName:@"leaf.fill" accessibilityDescription:nil];
    Check(logo != nil, @"fixture logo");
    for (NSUInteger i = 0; i < providers.count; i++) {
        CCPetsProviderDescriptor *provider = providers[i];
        NSString *name = provider.name;
        BOOL online = (i + variant) % 2 == 0;
        view.liveProviders = online ? [NSSet setWithObject:name] : [NSSet set];
        view.logoByProvider = (i + glass + variant) % 2 ? @{name: logo} : @{};
        NSDictionary *normalized = CCPetsNormalizedUsage(provider, raw, NO);
        Check([normalized[@"billing"] isEqual:provider.billing] &&
            [normalized[@"windows"] count] == provider.windowSpecs.count, name);
        CGFloat y = height - 218 * (i + 1);
        [view drawProvider:name displayName:name usage:raw color:[view colorForProvider:name]
            cardRect:NSMakeRect(10, y + 50, 720, 152) profileCount:0 selectedIndex:0];
        [view drawCompactRowForProvider:name usage:normalized rect:NSMakeRect(10, y, 720, 44)];
    }
    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    Check(png.length > 0, @"rendered templates");
    if (directory) {
        NSString *file = [NSString stringWithFormat:@"%@-%lu-windows.png", glass ? @"glass" : @"standard", (unsigned long)variant];
        Check([png writeToFile:[directory stringByAppendingPathComponent:file] atomically:YES], file);
    }
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSDictionary *hour = Window(@"hour", @"1h", 60, NO), *day = Window(@"day", @"24h", 1440, YES);
        NSDictionary *totals = @{@"total_tokens": @1234567, @"output_tokens": @42500, @"request_count": @130};
        NSDictionary *raw = @{@"hour": @{@"spent": @75}, @"day": @{@"spent": @31},
            @"tokenUsage": @{@"today": totals, @"hour": totals, @"day": totals, @"month": totals,
                @"recentWeek": totals, @"monthComparable": totals, @"previousMonthToDate": totals,
                @"monthDaily": @[]}};
        CheckNormalization(Provider(@"Meter", @"subscription", @[hour, day], nil), raw);
        NSArray *original = CCPetsProviderDescriptors();
        for (NSUInteger count = 0; count <= 2; count++) {
            NSArray *specs = [@[hour, day] subarrayWithRange:NSMakeRange(0, count)];
            NSArray *providers = @[Provider(@"Meter", @"subscription", specs, nil), Provider(@"Calls", @"api", @[], nil),
                Provider(@"Points", @"credits", @[], nil), Provider(@"Local", @"none", @[], nil)];
            CCPetsProviderRegistrySetOverride(providers);
            Check(CCPetsProviderForName(@"Meter") == providers[0] && CCPetsProviderForName(@"Codex") == nil, @"override");
            for (NSUInteger glass = 0; glass <= 1; glass++) {
                DrawTemplates(providers, raw, glass, count, argc > 1 ? @(argv[1]) : nil);
            }
        }
        CCPetsProviderRegistrySetOverride(nil);
        Check([CCPetsProviderDescriptors() isEqual:original], @"restore registry");
        puts("归一化用量、完整卡及紧凑行离屏绘制测试通过");
    }
    return 0;
}
