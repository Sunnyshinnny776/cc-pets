#import <Cocoa/Cocoa.h>

// 额度面板按逻辑尺寸绘制后整体缩放，保证离屏渲染和实时显示是同一套代码。
extern const CGFloat QuotaLogicalWidth;
// 两家 CLI 都装时的高度，也是预览图的尺寸。实际高度按检测到的 provider 数量算。
extern const CGFloat QuotaLogicalHeight;
extern const CGFloat QuotaScale;
CGFloat QuotaLogicalHeightForProviderCount(NSUInteger count);

NSImage *OfficialAppIcon(NSString *bundleIdentifier, NSString *resourceName);

@interface QuotaDashboardView : NSView
@property BOOL usesLiquidGlass;
// 原生玻璃下卡片和汇总区衬底的不透明度，由 App 按压暗档位设置。
@property CGFloat cardScrimAlpha;
@property NSDictionary *codexUsage;
@property NSDictionary *claudeUsage;
@property NSArray<NSDictionary *> *profiles;
@property NSDictionary<NSString *, NSDictionary *> *profileUsages;
@property NSDictionary<NSString *, NSArray<NSDictionary *> *> *profileHistories;
@property NSArray<NSDictionary *> *codexHistory;
@property NSArray<NSDictionary *> *claudeHistory;
@property NSInteger activeAgentCount;
// 仍在运行的客户端所属的 provider（"Codex" / "Claude"）。卡片的在线徽章据此判定，
// 而不是看有没有额度数据——额度会一直缓存着，拿它当在线信号会恒亮。
@property NSSet<NSString *> *liveProviders;
// Hook 能提供 profileId 时优先按账号显示在线状态；老会话没有 profileId 时仍退回 provider。
@property NSSet<NSString *> *liveProfileIDs;
// 仍在线但旧事件没有 profileId 的 provider；无法精确归属时避免把账号卡误判为离线。
@property NSSet<NSString *> *liveUnscopedProviders;
@property NSSet<NSString *> *pendingApprovalProfileIDs;
@property NSSet<NSString *> *bridgeActivityProfileIDs;
// 老版本包装脚本写出的 pid 文件没有 provider 名。有这种客户端时无法断言某一家离线。
@property BOOL hasUnlabeledClient;
// 这台机器上检测到的 provider（"Codex" / "Claude"）。决定渲染几张额度卡、面板多高。
// 与 liveProviders 是两件事：那个是"此刻在不在线"，只驱动徽章。nil 表示没探测过，
// 按两家都有渲染。
@property NSSet<NSString *> *detectedProviders;
- (NSArray<NSString *> *)visibleProviders;
- (CGFloat)logicalHeight;
@property NSTimeInterval lastUpdatedAt;
@property BOOL systemCPUEnabled;
@property BOOL systemTemperatureEnabled;
@property BOOL systemMemoryEnabled;
@property NSNumber *systemCPUPercent;
@property NSNumber *systemTemperatureCelsius;
@property NSNumber *systemMemoryPercent;
@property BOOL codexShowsAPIUsage;
@property BOOL claudeShowsAPIUsage;
- (BOOL)isProviderOnline:(NSString *)name;
- (NSDictionary *)selectedProfileForProvider:(NSString *)name;
- (NSDictionary *)usageForProvider:(NSString *)name;
// 指定账号的独立快照，不改变悬停面板的轮播选择；概览复用同一份账号数据。
- (NSDictionary *)accountSnapshotForProvider:(NSString *)name profile:(NSDictionary *)profile;
// 本周额度的节奏判断，主窗口概览页的额度卡和面板用同一份。返回 label、tip、color，
// 有数据时还有 level（0 充足 / 1 平稳 / 2 需关注 / 3 高风险）。
- (NSDictionary *)paceStatusForQuota:(NSDictionary *)quota currentUsed:(NSNumber *)currentUsed
    color:(NSColor *)providerColor;
@property NSImage *codexLogo;
@property NSImage *claudeLogo;
@property(copy) void (^hoverChanged)(BOOL hovering);
@end
