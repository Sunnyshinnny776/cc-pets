#import <Foundation/Foundation.h>
#import "CCPetsQuotaHistory.h"

// 受限（usage_limit_exceeded / rateLimitReachedType）曾经无条件清掉两个窗口的百分比，
// 于是长期受限的 provider 在 7 天里攒不下一个历史点，趋势曲线只剩"当前"一个点、画不出线。
// 但受限期间官方 rate_limits 照样返回窗口百分比，那是真实数值。这里锁住区分：
// 快照比受限时刻更新（exhaustedAt < sampledAt）就继续记录，更旧才丢。
static NSDictionary *CodexUsage(NSTimeInterval sampledAt, NSTimeInterval exhaustedAt) {
    return @{@"sampledAt": @(sampledAt),
             @"exhaustedAt": @(exhaustedAt),
             @"fiveHour": @{@"used_percent": @100},
             @"week": @{@"used_percent": @55}};
}

static NSDictionary *LastSample(NSDictionary *document) {
    NSArray *samples = document[@"samples"];
    return [samples.lastObject isKindOfClass:NSDictionary.class] ? samples.lastObject : nil;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *mode = argc > 1 ? @(argv[1]) : @"";
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        BOOL fresh = [mode isEqualToString:@"fresh-snapshot"];
        // fresh：受限标记比快照更旧，百分比可信，必须落盘。
        // stale：受限标记不比快照旧，百分比可能是受限前的残留，不落盘。
        NSDictionary *usage = fresh ? CodexUsage(now, now - 120) : CodexUsage(now - 120, now);
        NSDictionary *codex = LastSample(RecordQuotaHistory(usage, nil))[@"codex"];
        NSNumber *week = [codex[@"weekRemaining"] isKindOfClass:NSNumber.class]
            ? codex[@"weekRemaining"] : nil;
        if (fresh) {
            if (llabs((long long)(week.doubleValue * 100) - 4500) > 1) {
                NSLog(@"受限但快照更新时应记录 7 天余量 45，实际 %@", week ?: @"(缺失)");
                return EXIT_FAILURE;
            }
            puts("受限期间仍记录可信官方百分比测试通过");
        } else {
            if (week) {
                NSLog(@"受限且快照更旧时不应记录余量，实际 %@", week);
                return EXIT_FAILURE;
            }
            puts("受限且快照过期时不写历史点测试通过");
        }
    }
    return EXIT_SUCCESS;
}
