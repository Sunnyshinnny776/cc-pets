#import <Foundation/Foundation.h>

// CC Bridge（scripts/bridge/）状态的只读视图，供桌宠显示角标、在会话列表里标出
// 会话名、以及点击跳回收件会话的终端。
//
// 只读元数据：会话名 / tty、谁发给谁、何时送达、信箱积压条数。回执文件里虽然带着
// 消息正文，这里解析后立即丢弃，不返回、不缓存——桌宠界面不显示正文。

// 桌宠侧的偏好：消息角标（默认开）、新消息系统通知（默认关）。
extern NSString *const BridgeBadgeEnabledKey;
extern NSString *const BridgeNotificationKey;

// <PetStateDirectory>/cc-bridge-<uid>：会话注册表、信箱、回执、预留。写入端见 CCPetsBridgeStore.h。
NSString *CCBridgeStateDirectory(void);
// ~/.cc-pets（可用 CC_PETS_HOME 覆盖）：开关文件与 CLI 定位文件所在目录。
NSString *CCBridgeHomeDirectory(void);

// ~/.cc-pets/bridge-enabled（可用 CC_PETS_HOME 覆盖）存在即视为开启。
BOOL CCBridgeEnabled(void);

// 选项（保存在开关文件里）：
// @{ @"codexApprove": NSArray, @"claudeAllow": NSArray, @"wake": @YES, @"editGuard": @YES }
//   codexApprove  Codex 中免审批的工具（写入 config.toml 的带标记块）
//   claudeAllow   Claude Code 中免确认的工具（写入 settings.json 的 permissions.allow）
//   wake          自动唤醒空闲会话；关闭后消息只进信箱，等对方下次收到用户输入时带入（省 token）
//   editGuard     编辑他人预留的文件时暂停一次（首次拦截、重试放行）
// 工具名只保留认识的，按分组定义的顺序排列；wake / editGuard 只有明确写 false 才算关。
NSDictionary *CCBridgeNormalizeOptions(NSDictionary *raw);
// 开关文件的原始内容，读不到时为空字典。
NSDictionary *CCBridgeReadSavedOptions(void);
// 已开启时取保存的选项，否则取默认值。
NSDictionary *CCBridgeOptions(void);

// 免审批分组：view / send / reserve / name → 工具名。桌宠菜单按分组显示，不暴露 7 个工具名。
NSArray<NSString *> *CCBridgeToolGroupNames(void);
NSArray<NSString *> *CCBridgeToolGroup(NSString *group);

// CLI 定位（~/.cc-pets/bridge-cli.json，由 cc-pets bridge refresh / enable / configure 写入）：
// @{ @"binary": cc-pets 可执行文件, @"path": 写入时终端里的 PATH }。桌宠是从 Finder / open 拉起的，
// PATH 里通常没有 nvm 之类的目录，调用 claude / codex mcp add 时要用这份 PATH。
// binary 必须是存在的可执行绝对路径，否则返回 nil。
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
