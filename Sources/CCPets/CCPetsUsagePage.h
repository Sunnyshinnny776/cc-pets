#import <Cocoa/Cocoa.h>

// 主窗口的「用量」页：本机 Claude Code / Codex 的 Token 用量，按模型分色堆叠的每日柱状图 + 模型表。
//
// 数据来自 CCPetsModelUsage（本机会话日志，不联网），由 CCPetsUsageStore 在后台按最长的 90 天算一次，
// 切换来源、区间、指标、模型都只在本地截取，不重算、不开定时器。图表自绘，不用 Swift Charts。
@interface CCPetsUsagePage : NSViewController
@end

// 90 天的模型用量，用量页和概览页共用一份。数据层按请求的起点清理缓存，所以统一按最长窗口取，
// 两页各取各的窗口会让较早的会话缓存被删了又重读。
//
// results：provider（claude / codex）-> CCPetsModelUsage 的返回值；还没算完时为 nil。
extern NSNotificationName const CCPetsUsageStoreDidChangeNotification;
@interface CCPetsUsageStore : NSObject
@property(class, nonatomic, readonly) NSDictionary<NSString *, NSDictionary *> *results;
@property(class, nonatomic, readonly) BOOL loading;
// 没算过或者结果超过两分钟就重算；正在算时不重复发起。算完发 CCPetsUsageStoreDidChangeNotification。
+ (void)loadIfStale;
@end

// 1234 -> 1.23K，1234567 -> 1.23M。
NSString *CCPetsFormatTokens(unsigned long long value);
// 新处理 = 非缓存输入 + 缓存写 + 输出：这次真正"新"进出模型的量。缓存读单列，不混进来，
// 否则它会以百倍的量级把其余几项淹没。
unsigned long long CCPetsNewTokens(NSDictionary *counts);
// 一组按天的 { timestamp, models: { model: counts } } 里，所有模型某天的合计。
NSDictionary *CCPetsUsageDayTotals(NSDictionary *day);
