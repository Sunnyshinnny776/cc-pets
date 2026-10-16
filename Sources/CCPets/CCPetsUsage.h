#import <Foundation/Foundation.h>

// Codex 与 Claude 的额度读取。
int RecordClaudeUsage(void);
NSDictionary *ClaudeRateLimits(void);
NSDictionary *LatestClaudeUsage(void);
NSDictionary *LatestUsage(void);
// 清掉 resets_at 已经翻篇（或不可能属于当前窗口）的额度窗口，缺 resets_at 的保留。
NSDictionary *UsageByRemovingExpiredQuotaWindows(NSDictionary *usage);

// 增量跟读 ~/.claude/projects 下的会话转录，按官方 5 小时 / 7 天窗口聚合本地 Token。
@interface ClaudeUsageReader : NSObject
@property NSURL *projectsURL;
// 只有常驻的桌宠进程写摘要缓存。--status / --hook 这类一次性命令照样读它（省下冷解析），
// 但绝不能写：它们按各自当时的窗口把缓存剪一遍再存回去，等于把桌宠攒下的月度条目清掉。
@property BOOL persistsCache;
- (NSDictionary *)refresh;
- (NSDictionary *)refreshWithFullAggregation;
@end

// 增量跟读当前 Codex 会话文件：只在会话切换时做一次冷读，之后按偏移追读。
@interface CodexUsageReader : NSObject
@property NSURL *sessionsURL;
// 见 ClaudeUsageReader.persistsCache。
@property BOOL persistsCache;
@property NSURL *sessionURL;
@property NSDictionary *usage;
@property unsigned long long offset;
@property NSMutableData *partialLine;
@property NSTimeInterval lastFullDiscovery;
- (NSDictionary *)refresh;
- (NSDictionary *)refreshWithFullDiscovery;
// 一批 FSEvents 里可能有多个会话文件同时变更（并发会话）。谁的额度采样更晚要读过才知道，
// 不能取遍历到的最后一个，详见实现处注释。
- (NSDictionary *)refreshForSessionURLs:(NSArray<NSURL *> *)urls;
@end

// 按模型的用量，provider 为 "claude" 或 "codex"（别的返回 nil）。统计 [start, end) 之间的自然日
// （start / end 应是日零点），数据来自本机会话日志，不联网。会读整段区间的会话文件，首次可能耗时
// 数百毫秒到数秒，只在后台队列调用。结果：
//   models: @{模型名: counts}   区间合计
//   daily:  @[@{timestamp: 日零点, models: @{模型名: counts}}]   每天一项，没数据的天 models 为空
// counts 的键：input（非缓存输入）/ cacheRead / cacheWrite / output / reasoning（output 的子集）/
// requests。四栏 input + cacheRead + cacheWrite + output 互不重叠，等于总 Token。
// 用自己的缓存和按日归档（Claude Code 默认约 30 天后清理转录，归档里留得更久），
// 不碰桌宠悬停面板用的那套缓存。
// 每次调用都会把缓存清理到只剩 [start, end) 涉及的会话文件，所以调用方应固定用同一个最长区间，
// 短区间在结果里自己截取；区间来回切会让较早会话的缓存被删了又整篇重读。
NSDictionary *CCPetsModelUsage(NSString *provider, NSTimeInterval start, NSTimeInterval end);
