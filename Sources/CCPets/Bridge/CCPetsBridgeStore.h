#import <Foundation/Foundation.h>

// CC Bridge 的存储层：会话注册表、信箱、回执、订阅、锁，以及选项解析与进程探测。
//
// 一条记录一个文件，通过原子 rename 发布 JSON；读改写和消息认领使用 flock 串行化。
// claimed 消息在输出成功后确认，进程崩溃由内核释放锁，下次消费者恢复未确认记录。
// 不需要常驻守护进程或数据库。
//
// 目录在 CCBridgeStateDirectory()（默认 $TMPDIR 下），与桌宠事件流同级：会话本身活不过重启，
// 注册表和未投递的消息也没有跨重启保留的意义。启用开关则放在 ~/.cc-pets 里持久保存。
//
// 目录准备失败（不是普通目录、不属于当前用户）时抛 NSException，由命令入口统一捕获。

extern const NSUInteger CCBridgeMessageBodyLimit;
extern const long long CCBridgeMessageTTL;
extern const NSUInteger CCBridgePairLimitCount;

#pragma mark - 开关与选项

// 正式发布前叫过 "Agent Bus"，开关文件是 bus-enabled。迁移成新名字并保留当时的选项。
BOOL CCBridgeMigrateLegacyFlag(void);
void CCBridgeSetEnabled(BOOL enabled, NSDictionary *options);
// 桌宠菜单靠这个文件找到 cc-pets 与终端里的 PATH，每次 refresh / enable / configure 都重写。
void CCBridgeWriteCLILocator(void);

// "view,send_message" → 展开分组、校验工具名。空字符串表示清空。失败返回 nil 并给出原因。
NSArray<NSString *> *CCBridgeParseToolList(NSString *text, NSString *flag, NSString **error);
// on / off（也认 true / false / 1 / 0 / yes / no）。失败返回 nil。
NSNumber *CCBridgeParseSwitch(NSString *text, NSString *flag, NSString **error);
// 在 base 之上叠加命令行里给出的选项（approve / codexApprove / claudeAllow / wake / editGuard），
// 没给的保持原值。失败返回 nil。
NSDictionary *CCBridgeMergeOptionFlags(NSDictionary *base, NSDictionary<NSString *, NSString *> *flags, NSString **error);
NSArray<NSString *> *CCBridgeDescribeOptions(NSDictionary *options);

#pragma mark - 目录与文件

NSString *CCBridgeSubdirectory(NSArray<NSString *> *parts);
// session id 会拼进文件路径，只放行 UUID 一类的安全字符，杜绝 ../ 之类的路径穿越。
NSString *CCBridgeSafeSessionId(id value);
void CCBridgeWriteJSON(NSString *file, id value);
id CCBridgeReadJSON(NSString *file);

// 只用来派生短标识（ref、预留 id），不涉及安全。
NSString *CCBridgeSHA1Hex(NSString *text);

#pragma mark - 会话注册表

NSString *CCBridgeSessionRef(NSString *sessionId);
NSDictionary *CCBridgeReadSession(id sessionId);
NSArray<NSDictionary *> *CCBridgeListSessions(void);
void CCBridgeRemoveSession(id sessionId);
void CCBridgeRemoveSessionIfOffline(id sessionId);
NSString *CCBridgeNormalizeSessionName(id value);
// liveSessions 参数保留兼容；名字分配/改名在注册表锁内重新读取在线会话，避免使用过期快照。
NSDictionary *CCBridgeUpsertSession(NSString *sessionId, NSString *provider, NSNumber *pid, NSString *cwd,
    NSString *tty, NSString *status, NSString *preferredName, NSString *profileID,
    NSString *profileName, NSArray<NSDictionary *> *liveSessions);
// 会话内改名：被其他在线会话占用时报错。返回 @{error} 或 @{session, previous}。
NSDictionary *CCBridgeRenameSession(NSString *sessionId, NSString *requestedName, NSArray<NSDictionary *> *liveSessions);

#pragma mark - 消息

NSString *CCBridgeNewMessageId(void);
NSDictionary *CCBridgeReadReceipt(id messageId);
void CCBridgeWriteReceipt(NSDictionary *message);
NSDictionary *CCBridgeUpdateReceipt(NSString *messageId, NSDictionary *patch);
NSArray<NSDictionary *> *CCBridgeListReceipts(void);
// 发送前的配额检查。nil 表示放行，否则返回拒绝原因。
NSString *CCBridgeCheckSendLimits(NSString *fromSession, NSString *toSession);
void CCBridgeEnqueueInbox(NSDictionary *message);
// 认领并持有信箱锁：恢复上次未确认的 claimed；调用方必须在输出后 FinishInbox。
NSArray<NSDictionary *> *CCBridgeClaimInbox(id sessionId);
// transport 非 nil 表示输出成功；nil 保留消息供重试。两种情况都会释放锁。
void CCBridgeFinishInbox(id sessionId, NSArray<NSDictionary *> *messages, NSString *transport);
NSUInteger CCBridgePendingCount(id sessionId);
// 会话结束：信箱里还没投出去的消息标记为 undeliverable。
void CCBridgeAbandonInbox(id sessionId);
void CCBridgePruneReceipts(void);

#pragma mark - 空闲订阅（一次性）

void CCBridgeAddIdleSubscription(NSString *targetSession, NSString *subscriberSession);
BOOL CCBridgeHasIdleSubscriptions(NSString *targetSession);
NSArray<NSString *> *CCBridgeTakeIdleSubscriptions(NSString *targetSession);

#pragma mark - 锁

// 稳定 inode 上的 flock；PID 文件只作诊断。进程退出自动释放，成功返回诊断文件路径。
NSString *CCBridgeAcquireLock(NSString *name);
void CCBridgeReleaseLock(NSString *lockFile);

#pragma mark - 进程探测

BOOL CCBridgeProcessAlive(pid_t pid);
NSString *CCBridgeProcessCommand(pid_t pid);
// CLI 进程的控制终端，如 "ttys003"；没有时返回 nil。
NSString *CCBridgeProcessTty(pid_t pid);
BOOL CCBridgeCommandMatchesProvider(NSString *provider, NSString *command);
// 离 startPid 最近的 Claude / Codex 祖先进程：@{provider, pid}。CC_BRIDGE_AGENT=Codex:1234 可强制指定。
NSDictionary *CCBridgeFindAgentAncestor(pid_t startPid);
// 有 pid 时以"进程还在且仍是同一种 CLI"为准（防 pid 复用）；没有 pid 的记录退回 6 小时活动窗口。
BOOL CCBridgeSessionLive(NSDictionary *session);
// `codex queue` 能力探测：@{status: supported|unsupported|missing|unknown, executable, version}。
NSDictionary *CCBridgeProbeCodexQueue(NSString *executable);
// environment 为 nil 时继承当前环境。npm 装的 codex 是 `env node` 脚本，主窗口得带上能找到 node 的 PATH。
NSDictionary *CCBridgeProbeCodexQueueWithEnvironment(NSString *executable, NSDictionary<NSString *, NSString *> *environment);
