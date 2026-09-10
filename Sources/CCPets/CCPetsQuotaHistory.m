#import "CCPetsQuotaHistory.h"
#import "CCPetsPaths.h"
#import <sys/stat.h>

static NSNumber *RemainingValue(NSDictionary *usage, NSString *quotaKey, NSString *usedKey) {
    NSDictionary *quota = [usage[quotaKey] isKindOfClass:NSDictionary.class] ? usage[quotaKey] : nil;
    NSNumber *used = [quota[usedKey] isKindOfClass:NSNumber.class] ? quota[usedKey] : nil;
    if (!used) return nil;
    return @(fmax(0, fmin(100, 100.0 - used.doubleValue)));
}

NSDictionary *QuotaHistoryDocument(void) {
    NSData *data = [NSData dataWithContentsOfFile:QuotaHistoryPath()];
    NSDictionary *document = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![document isKindOfClass:NSDictionary.class] ||
        [document[@"schemaVersion"] integerValue] != 1 ||
        ![document[@"samples"] isKindOfClass:NSArray.class]) {
        return @{@"schemaVersion": @1, @"samples": @[]};
    }
    return document;
}

static NSDictionary *HistoryProviderSample(NSDictionary *usage, NSString *usedKey) {
    NSNumber *fiveHour = RemainingValue(usage, @"fiveHour", usedKey);
    NSNumber *week = RemainingValue(usage, @"week", usedKey);
    // usage_limit_exceeded 没有窗口归属，既不能证明两个窗口都归零，也不能证明上次快照
    // 仍代表当前额度。但"受限"和"没有可信百分比"是两件事：受限期间官方 rate_limits
    // 照样会返回窗口百分比（见 CCPetsCodexRateLimits.m 的 LiveUsageFromRateLimitBucket，
    // 受限分支之前就已经填好 fiveHour / week），那是服务端给的真实数值。一律丢掉的话，
    // 长期受限的 provider 在 7 天里攒不下一个历史点，趋势曲线就只剩"当前"这一个点，
    // 画不出线。所以只在快照比受限时刻更旧时才丢——判据与 CCPetsUsage.m 的
    // ExhaustionStillHolds 一致：exhaustedAt < sampledAt 说明快照更新、仍然可信。
    NSNumber *exhaustedAt = [usage[@"exhaustedAt"] isKindOfClass:NSNumber.class]
        ? usage[@"exhaustedAt"] : nil;
    if (exhaustedAt && exhaustedAt.doubleValue >= [usage[@"sampledAt"] doubleValue]) {
        fiveHour = nil;
        week = nil;
    }
    NSMutableDictionary *sample = [NSMutableDictionary dictionary];
    if (fiveHour) sample[@"fiveHourRemaining"] = fiveHour;
    if (week) sample[@"weekRemaining"] = week;
    return sample;
}

// 返回当前的历史文档，供调用方直接取用：原先每次刷新要读盘+解析三次
// （这里一次、两条曲线各一次），现在整轮只读一次。
NSDictionary *RecordQuotaHistory(NSDictionary *codexUsage, NSDictionary *claudeUsage) {
    NSDictionary *document = QuotaHistoryDocument();
    NSDictionary *codex = HistoryProviderSample(codexUsage, @"used_percent");
    NSDictionary *claude = HistoryProviderSample(claudeUsage, @"used_percentage");
    if (codex.count == 0 && claude.count == 0) return document;

    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSTimeInterval cutoff = now - 7 * 24 * 60 * 60;
    NSArray *existing = document[@"samples"];
    NSMutableArray *samples = [NSMutableArray arrayWithCapacity:existing.count + 1];
    for (NSDictionary *sample in existing) {
        if (![sample isKindOfClass:NSDictionary.class] || [sample[@"timestamp"] doubleValue] < cutoff) continue;
        [samples addObject:sample];
    }
    NSDictionary *last = samples.lastObject;
    if (last && now - [last[@"timestamp"] doubleValue] < 15 * 60) return document;

    NSMutableDictionary *sample = [@{@"timestamp": @(now)} mutableCopy];
    if (codex.count > 0) sample[@"codex"] = codex;
    if (claude.count > 0) sample[@"claude"] = claude;
    [samples addObject:sample];
    if (samples.count > 672) {
        [samples removeObjectsInRange:NSMakeRange(0, samples.count - 672)];
    }

    NSString *directory = QuotaHistoryPath().stringByDeletingLastPathComponent;
    [NSFileManager.defaultManager createDirectoryAtPath:directory
        withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *updated = @{@"schemaVersion": @1, @"samples": samples};
    NSData *json = [NSJSONSerialization dataWithJSONObject:updated
        options:NSJSONWritingPrettyPrinted error:nil];
    if ([json writeToFile:QuotaHistoryPath() options:NSDataWritingAtomic error:nil]) {
        chmod(QuotaHistoryPath().fileSystemRepresentation, S_IRUSR | S_IWUSR);
    }
    return updated;
}

NSArray<NSDictionary *> *QuotaHistorySeries(NSDictionary *document, NSString *provider) {
    NSMutableArray<NSDictionary *> *series = [NSMutableArray array];
    for (NSDictionary *sample in document[@"samples"]) {
        if (![sample isKindOfClass:NSDictionary.class]) continue;
        NSNumber *timestamp = [sample[@"timestamp"] isKindOfClass:NSNumber.class]
            ? sample[@"timestamp"] : nil;
        NSDictionary *providerSample = [sample[provider] isKindOfClass:NSDictionary.class]
            ? sample[provider] : nil;
        NSNumber *remaining = [providerSample[@"weekRemaining"] isKindOfClass:NSNumber.class]
            ? providerSample[@"weekRemaining"] : nil;
        if (timestamp && remaining) {
            [series addObject:@{@"timestamp": timestamp, @"remaining": remaining}];
        }
    }
    return series;
}
