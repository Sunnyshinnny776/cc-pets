// 用量页内部共用：计数读取、数字格式和指标枚举，图表、部件和页面各自 import。
// 都是 static inline，每个编译单元各自一份，不导出符号。
#import <Foundation/Foundation.h>
#import "CCPetsL10n.h"
#import "CCPetsUsage.h"
#import "CCPetsUsagePage.h"

static inline unsigned long long Count(NSDictionary *counts, NSString *key) {
    return [counts[key] unsignedLongLongValue];
}

static inline NSString *FormatCount(unsigned long long value) {
    static NSNumberFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSNumberFormatter new];
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
    });
    return [formatter stringFromNumber:@(value)];
}

// 和指标条的五格一一对应，分段控件的次序也是这个。
typedef NS_ENUM(NSInteger, UsageMetric) {
    UsageMetricTotal,
    UsageMetricInput,
    UsageMetricOutput,
    UsageMetricCachedInput,
    UsageMetricRequests,
};

static inline unsigned long long MetricValue(UsageMetric metric, NSDictionary *counts) {
    switch (metric) {
        case UsageMetricInput: return Count(counts, @"input");
        case UsageMetricOutput: return Count(counts, @"output");
        case UsageMetricCachedInput: return Count(counts, @"cacheRead");
        case UsageMetricRequests: return Count(counts, @"requests");
        default: return CCPetsTotalTokens(counts);
    }
}

static inline NSString *MetricTitle(UsageMetric metric) {
    switch (metric) {
        case UsageMetricInput: return L(@"Input");
        case UsageMetricOutput: return L(@"Output");
        case UsageMetricCachedInput: return L(@"Cached Input");
        case UsageMetricRequests: return L(@"Requests");
        default: return L(@"Total Usage");
    }
}

static inline NSString *MetricText(UsageMetric metric, unsigned long long value) {
    return metric == UsageMetricRequests ? FormatCount(value) : CCPetsFormatTokens(value);
}
