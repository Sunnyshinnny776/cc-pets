#import <Foundation/Foundation.h>

// 本地额度历史始终记录并展示。
// RecordQuotaHistory 返回当前文档，调用方直接复用，避免一轮刷新里重复读盘。
NSDictionary *QuotaHistoryDocument(void);
NSDictionary *RecordQuotaHistory(NSDictionary *codexUsage, NSDictionary *claudeUsage);
// 每个点保留 timestamp 与 weekRemaining，绘图层才能按真实时间轴展示缺口和重置。
NSArray<NSDictionary *> *QuotaHistorySeries(NSDictionary *document, NSString *provider);
NSDictionary *RecordProfileQuotaHistory(NSDictionary<NSString *, NSDictionary *> *profileUsages,
    NSArray<NSDictionary *> *profiles);
NSArray<NSDictionary *> *QuotaHistorySeriesForProfile(NSDictionary *document, NSString *profileID);
