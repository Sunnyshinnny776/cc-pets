#import <Foundation/Foundation.h>

// CC Bridge（scripts/bridge/）状态的只读视图，供桌宠显示角标、在会话列表里标出
// 会话名、以及点击跳回收件会话的终端。
//
// 只读元数据：会话名 / tty、谁发给谁、何时送达、信箱积压条数。回执文件里虽然带着
// 消息正文，这里解析后立即丢弃，不返回、不缓存——桌宠界面不显示正文。

// 桌宠侧的偏好：消息角标（默认开）、新消息系统通知（默认关）。
extern NSString *const BridgeBadgeEnabledKey;
extern NSString *const BridgeNotificationKey;

// <PetStateDirectory>/cc-bridge-<uid>，与 scripts/bridge/store.mjs 的 bridgeDirectory 一致。
NSString *CCBridgeStateDirectory(void);

// ~/.cc-pets/bridge-enabled（可用 CC_PETS_HOME 覆盖）存在即视为开启。
BOOL CCBridgeEnabled(void);

// 开关文件里保存的选项（与 scripts/bridge/options.mjs 一致），未开启或缺项时取默认值：
// @{ @"codexApprove": NSArray, @"claudeAllow": NSArray, @"wake": @YES, @"editGuard": @YES }
NSDictionary *CCBridgeOptions(void);

// 免审批分组：view / send / reserve / name → 工具名。必须与 options.mjs 的 TOOL_GROUPS 一致。
NSArray<NSString *> *CCBridgeToolGroupNames(void);
NSArray<NSString *> *CCBridgeToolGroup(NSString *group);

// CLI 定位（~/.cc-pets/bridge-cli.json，由 cc-pets bridge refresh / enable / configure 写入）：
// @{ @"node", @"cli" }，两者都必须是存在的绝对路径，否则返回 nil。
NSDictionary<NSString *, NSString *> *CCBridgeCLILocator(void);

// 仍有效（未过期、持有者在给定会话集合内）的文件预留条数。
NSUInteger CCBridgeActiveReservationCount(NSSet<NSString *> *sessionIds);

// 在线会话：session id → @{ @"name", @"ref", @"provider", @"tty" }（tty 可能缺省）。
// 记录了 pid 而进程已不在的会话不返回。
NSDictionary<NSString *, NSDictionary *> *CCBridgeSessions(void);

// 最近送达的跨会话消息，不含 cc-bridge 自己发的系统通知（空闲通知等），按送达时间倒序。
// 每项：@{ @"id", @"from", @"to", @"toSession", @"at" }，at 为秒级时间戳。
NSArray<NSDictionary *> *CCBridgeRecentDeliveries(NSTimeInterval since, NSUInteger limit);

// session id → 信箱里仍未投递的条数（只含 > 0 的会话）。
NSDictionary<NSString *, NSNumber *> *CCBridgePendingCounts(void);
