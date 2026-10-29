#import "CCPetsUsagePage.h"
#import "CCPetsProfiles.h"
#import "CCPetsUsageShared.h"

#pragma mark - 数据

// 统计这么多天，切换 7 / 30 / 90 天只在本地截取。
static const NSInteger UsageMaximumRangeDays = 90;
// 结果在这段时间内算新鲜：来回切页面不重算，隔一阵再打开能看到新用量。
static const NSTimeInterval UsageStoreFreshness = 120;

NSNotificationName const CCPetsUsageStoreDidChangeNotification = @"CCPetsUsageStoreDidChange";
static NSDictionary<NSString *, NSDictionary *> *UsageStoreResults;
static NSDictionary<NSString *, NSDictionary *> *UsageStoreProfileResults;
static NSTimeInterval UsageStoreLoadedAt;
// 结果所对应的"今天"零点。跨过午夜后区间要整体后移一天，哪怕结果才算出来一分钟也得重算。
static NSTimeInterval UsageStoreLoadedDayStart;
static NSString *UsageStoreProfileFingerprint;
static BOOL UsageStoreLoading;

@implementation CCPetsUsageStore

+ (NSDictionary<NSString *, NSDictionary *> *)results {
    return UsageStoreResults;
}

+ (NSDictionary<NSString *, NSDictionary *> *)profileResults {
    return UsageStoreProfileResults;
}

static NSDictionary *MergeModelUsageResults(NSArray<NSDictionary *> *values) {
    if (values.count == 0) return @{ @"models": @{}, @"daily": @[] };
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *days = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *totals = [NSMutableDictionary dictionary];
    for (NSDictionary *usage in values) {
        for (NSDictionary *day in usage[@"daily"] ?: @[]) {
            NSNumber *stamp = day[@"timestamp"];
            if (!stamp) continue;
            NSMutableDictionary *models = days[stamp];
            if (!models) { models = [NSMutableDictionary dictionary]; days[stamp] = models; }
            for (NSString *model in day[@"models"] ?: @{}) {
                NSMutableDictionary *counts = models[model];
                if (!counts) { counts = [NSMutableDictionary dictionary]; models[model] = counts; }
                NSDictionary *incoming = day[@"models"][model];
                for (NSString *key in @[@"input", @"cacheRead", @"cacheWrite", @"output", @"reasoning", @"requests", @"background"]) {
                    counts[key] = @(Count(counts, key) + Count(incoming, key));
                }
            }
        }
    }
    NSMutableArray *daily = [NSMutableArray array];
    for (NSNumber *stamp in [days.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *models = days[stamp];
        [daily addObject:@{ @"timestamp": stamp, @"models": models }];
        for (NSString *model in models) {
            NSMutableDictionary *sum = totals[model];
            if (!sum) { sum = [NSMutableDictionary dictionary]; totals[model] = sum; }
            for (NSString *key in @[@"input", @"cacheRead", @"cacheWrite", @"output", @"reasoning", @"requests", @"background"]) {
                sum[key] = @(Count(sum, key) + Count(models[model], key));
            }
        }
    }
    return @{ @"models": totals, @"daily": daily };
}

+ (BOOL)loading {
    return UsageStoreLoading;
}

// 区间是 [今天往前数 89 天的零点, 明天零点)，含今天。
+ (void)loadIfStale {
    if (UsageStoreLoading) return;
    NSMutableArray<NSString *> *identity = [NSMutableArray array];
    for (NSDictionary *profile in CCPetsProfiles()) {
        [identity addObject:[NSString stringWithFormat:@"%@|%@", profile[@"id"], profile[@"home"]]];
    }
    NSString *fingerprint = [identity componentsJoinedByString:@"\n"];
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *today = [calendar startOfDayForDate:NSDate.date];
    if (UsageStoreResults && [UsageStoreProfileFingerprint isEqualToString:fingerprint] &&
        NSDate.date.timeIntervalSince1970 - UsageStoreLoadedAt < UsageStoreFreshness &&
        UsageStoreLoadedDayStart == today.timeIntervalSince1970) return;
    UsageStoreLoading = YES;
    NSDate *end = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:today options:0];
    NSDate *start = [calendar dateByAddingUnit:NSCalendarUnitDay value:-UsageMaximumRangeDays toDate:end options:0];
    // 串行队列：上一轮还没算完时不会两份同时写同一批缓存文件。
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.ccpets.model-usage", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(queue, ^{
        NSMutableDictionary *results = [NSMutableDictionary dictionary];
        NSMutableDictionary *profileResults = [NSMutableDictionary dictionary];
        for (NSString *provider in @[@"claude", @"codex"]) {
            NSArray<NSDictionary *> *profiles = CCPetsProfilesForProvider(provider);
            if (profiles.count == 0) continue;
            NSMutableArray<NSDictionary *> *providerValues = [NSMutableArray array];
            for (NSDictionary *profile in profiles) {
                NSDictionary *usage = CCPetsModelUsageAtHome(provider, profile[@"home"],
                    start.timeIntervalSince1970, end.timeIntervalSince1970);
                if (!usage) continue;
                profileResults[profile[@"id"]] = usage;
                [providerValues addObject:usage];
            }
            results[provider] = MergeModelUsageResults(providerValues);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            UsageStoreResults = results;
            UsageStoreProfileResults = profileResults;
            UsageStoreLoadedAt = NSDate.date.timeIntervalSince1970;
            UsageStoreLoadedDayStart = today.timeIntervalSince1970;
            UsageStoreProfileFingerprint = fingerprint;
            UsageStoreLoading = NO;
            [NSNotificationCenter.defaultCenter postNotificationName:CCPetsUsageStoreDidChangeNotification object:nil];
        });
    });
}

@end
