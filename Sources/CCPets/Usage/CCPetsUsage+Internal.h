// CCPetsUsage 拆成多个文件后，跨文件共用的常量、记录结构和内部函数。只给 CCPetsUsage*.m 用，
// 不对外：对外接口仍在 CCPetsUsage.h。
#import "CCPetsUsage.h"

// Claude 的 rate_limits 不带 window_minutes，窗长按官方订阅固定。既用于 Token 聚合区间，
// 也用于快照的合理性校验，所以定义在这里给两处共用。
static const double FiveHourWindowMinutes = 300;
static const double SevenDayWindowMinutes = 10080;
// 一条限额错误刚发生、手上却一个可用窗口都没有时的保留时长。见 ExhaustionStillHolds。
static const NSTimeInterval RecentExhaustionGraceSeconds = 300.0;
// Token 聚合要遍历近 7 天的会话文件，而 refresh 由 FSEvents 驱动、会话写盘时约 0.5 秒
// 一次。按额度窗口节流，窗口滚动或手动刷新时立刻重算。
static const NSTimeInterval TokenAggregationInterval = 5.0;
// 落盘节流：聚合本身最快 5 秒一次，缓存写盘没必要跟得那么紧。进程被 kill 而没来得及写，
// 代价也只是下次启动多解析一段。
static const NSTimeInterval TokenCacheSaveInterval = 60.0;

// model 是 ClaudeModelNames 里的下标，不直接存名字：记录是定长的二进制块，常驻内存、整块落盘。
typedef struct {
    double timestamp;
    uint64_t identity;
    unsigned long long input;
    unsigned long long output;
    unsigned long long cacheRead;
    unsigned long long cacheWrite;
    uint32_t model;
    uint32_t reserved;
} ClaudeTokenRecord;

// 额度窗口（CCPetsUsage.m）
BOOL ResetLooksCurrentAt(double reset, double windowMinutes, NSTimeInterval sampledAt);
BOOL QuotaWindowLooksCurrentAt(NSDictionary *quota, double windowMinutes,
    NSTimeInterval sampledAt);
BOOL QuotaWindowLooksCurrent(NSDictionary *quota, double windowMinutes, NSTimeInterval now);
NSDictionary *UsageByRemovingInactiveQuotaWindows(NSDictionary *usage);

// Codex 会话行解析与会话文件定位（CCPetsUsage+CodexSessions.m）
const NSArray<NSString *> *TokenKeys(void);
NSDate *ISO8601Timestamp(NSString *value);
NSDictionary *TokenRecordFromLine(NSData *lineData);
NSURL *NewestSessionFileInDirectory(NSURL *directory, NSDate **outDate);
NSURL *NewestCodexSessionURL(NSURL *sessionsURL);
NSNumber *ExhaustionTimestampFromLine(NSData *lineData);
NSDictionary *UsageFromCodexLine(NSData *lineData);
BOOL ExhaustionStillHolds(NSDictionary *usage, NSTimeInterval exhaustedAt);
NSDictionary *UsageByMarkingExhaustion(NSDictionary *usage, NSTimeInterval exhaustedAt);
NSDictionary *NewerUsageSnapshot(NSDictionary *current, NSDictionary *candidate);
NSDictionary *LatestUsageInData(NSData *data, NSNumber **outExhaustedAt);
BOOL ProfileShowsAPIUsage(NSString *provider, NSString *home);
NSTimeInterval RollingTokenWindowFloor(void);
NSDate *CurrentMonthStartDate(void);
NSString *MonthArchiveKey(NSTimeInterval monthStart);
NSArray<NSURL *> *RecentCodexSessionURLs(NSURL *sessionsURL, NSTimeInterval earliest);
NSArray<NSURL *> *TokenAggregationURLs(NSURL *sessionsURL, NSTimeInterval earliest,
    NSArray<NSURL *> *pinnedURLs);
NSData *SessionTailData(NSURL *url);
NSDictionary *LatestQuotaInRecentSessions(NSURL *sessionsURL, NSURL *skipURL);

// Token 窗口聚合、摘要缓存与月度归档（CCPetsUsage+TokenTotals.m）
BOOL IsPseudoModelName(NSString *model);
NSDictionary *TokenSessionSummaryTracking(NSURL *url, NSMutableDictionary *cache,
    BOOL trackModels);
BOOL TokenWindowOrFallback(NSDictionary *quota, double fallbackMinutes,
    NSTimeInterval *outStart, NSTimeInterval *outEnd);
void RollingTokenWindows(NSTimeInterval *todayStart, NSTimeInterval *weekStart,
    NSTimeInterval *end);
NSDictionary *CalendarMonthWindows(NSTimeInterval alignedEnd);
NSString *PartialTokenKey(NSTimeInterval start, NSTimeInterval end);
NSDictionary *TokenTotalsInWindow(NSTimeInterval start, NSTimeInterval end,
    NSArray<NSURL *> *urls, NSMutableDictionary *cache);
NSDictionary *TokenTotalsForQuota(NSDictionary *quota, double fallbackMinutes,
    NSArray<NSURL *> *urls, NSMutableDictionary *cache);
NSArray<NSDictionary *> *CodexDailyTokenSeries(NSTimeInterval start, NSTimeInterval end,
    NSArray<NSURL *> *urls, NSMutableDictionary *cache, BOOL *outHasTokenSchema);
NSDictionary *SummedDailyTokenSeries(NSArray<NSDictionary *> *series);
NSDictionary *SummedDailyTokenSeriesInRange(NSArray<NSDictionary *> *series,
    NSTimeInterval start, NSTimeInterval end);
void PruneTokenCache(NSMutableDictionary *cache, NSArray<NSURL *> *urls,
    NSSet<NSString *> *liveWindowKeys);
NSMutableDictionary *LoadTokenSummaryCache(NSString *path);
NSMutableDictionary *LoadMonthlyUsageArchive(NSString *path);
void MakeCachedRecordsMutable(NSMutableDictionary *cache);
void SaveTokenSummaryCache(NSDictionary *cache, NSString *path);
void PruneMonthlyArchive(NSMutableDictionary *archive);

// Codex 额度与 Token 汇总、CodexUsageReader（CCPetsUsage+CodexReader.m）
NSString *TokenWindowIdentity(NSDictionary *usage);

// Claude Code 转录记录与 ClaudeUsageReader（CCPetsUsage+ClaudeReader.m）
NSArray<NSString *> *ClaudeModelNames(NSDictionary *cache);
void PruneClaudeRecordCache(NSMutableDictionary *cache, NSSet<NSString *> *livePaths);
NSArray<NSURL *> *RecentClaudeTranscriptURLs(NSURL *projectsURL,
    NSTimeInterval earliest);
NSData *ClaudeRecordsForFile(NSURL *url, NSMutableDictionary *cache);
NSData *ClaudeMergedRecords(NSArray<NSData *> *recordSets, NSTimeInterval start,
    NSTimeInterval end);
