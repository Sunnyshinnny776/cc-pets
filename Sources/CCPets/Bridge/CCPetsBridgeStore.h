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
// 仅对标记为自动生成的名字去掉账号段；自定义名字及旧记录保持原名。
NSString *CCBridgeSessionShortName(NSDictionary *session);
// 中文界面下自动名称的动物别名；其他语言、自定义名称和旧记录返回空串。
NSString *CCBridgeSessionAnimalAlias(NSDictionary *session);
// 仅供展示，不可作为消息地址；原 name / ref 始终保持不变。
NSString *CCBridgeSessionDisplayName(NSDictionary *session);
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
// 写入目标信箱。返回 nil 表示成功；Bridge 已关闭或目标已离线时不写入，返回拒绝原因。
NSString *CCBridgeEnqueueInbox(NSDictionary *message);
// 认领并持有信箱锁：恢复上次未确认的 claimed；调用方必须在输出后 FinishInbox。
NSArray<NSDictionary *> *CCBridgeClaimInbox(id sessionId);
// transport 非 nil 表示输出成功；nil 保留消息供重试。两种情况都会释放锁。
void CCBridgeFinishInbox(id sessionId, NSArray<NSDictionary *> *messages, NSString *transport);
NSUInteger CCBridgePendingCount(id sessionId);
// 会话结束：信箱里还没投出去的消息标记为 undeliverable。
void CCBridgeAbandonInbox(id sessionId);
// 同上，但用于没有 SessionEnd 的离线会话（崩溃、被杀）：连同它的空闲订阅一起清掉；锁繁忙或会话又上线时不动。
void CCBridgeAbandonOfflineSession(id sessionId);
// 关闭 Bridge：之后不会再有 hook 来清理，所有未投递的消息现在就标记 undeliverable 并删除。
void CCBridgeAbandonAllInboxes(NSString *reason);
// 扫描状态目录：离线会话按上面处理，在线会话里超过 TTL 的消息标记为 expired。锁繁忙的留给下一次。
void CCBridgeSweepMessages(void);
void CCBridgePruneReceipts(void);

#pragma mark - 空闲订阅（一次性）

void CCBridgeAddIdleSubscription(NSString *targetSession, NSString *subscriberSession);
BOOL CCBridgeHasIdleSubscriptions(NSString *targetSession);
NSArray<NSString *> *CCBridgeTakeIdleSubscriptions(NSString *targetSession);
void CCBridgeClearIdleSubscriptions(id targetSession);

#pragma mark - watcher 接替

// 新 watcher 登记后，旧的在下次轮询时退出，新的拿到锁并重新计时：每轮结束都能续满等待时间。
NSString *CCBridgeClaimWatcher(NSString *sessionId);
BOOL CCBridgeWatcherOwned(NSString *sessionId, NSString *token);
// 会话结束：清掉登记，还在等待的 watcher 随之退出。
void CCBridgeDropWatcher(id sessionId);

#pragma mark - 锁

// 稳定 inode 上的 flock；PID 文件只作诊断。进程退出自动释放，成功返回诊断文件路径。
NSString *CCBridgeAcquireLock(NSString *name);
void CCBridgeReleaseLock(NSString *lockFile);
// 等锁（有上限，超时抛异常）后执行 body。锁不可重入，body 里不能再取同名锁。
id CCBridgeWithLock(NSString *name, id (^body)(void));

#pragma mark - 进程探测

BOOL CCBridgeProcessAlive(pid_t pid);
// 进程的 argv，元素边界与启动时一致；读不到时返回 nil。
NSArray<NSString *> *CCBridgeProcessArguments(pid_t pid);
// CLI 进程的控制终端，如 "ttys003"；没有时返回 nil。
NSString *CCBridgeProcessTty(pid_t pid);
BOOL CCBridgeArgumentsMatchProvider(NSString *provider, NSArray<NSString *> *arguments);
// 离 startPid 最近的 Claude / Codex 祖先进程：@{provider, pid}。CC_BRIDGE_AGENT=Codex:1234 可强制指定。
NSDictionary *CCBridgeFindAgentAncestor(pid_t startPid);
// 有 pid 时以"进程还在且仍是同一种 CLI"为准（防 pid 复用）；没有 pid 的记录退回 6 小时活动窗口。
BOOL CCBridgeSessionLive(NSDictionary *session);
// `codex queue` 能力探测：@{status: supported|unsupported|missing|unknown, executable, version}。
NSDictionary *CCBridgeProbeCodexQueue(NSString *executable);
// environment 为 nil 时继承当前环境。npm 装的 codex 是 `env node` 脚本，主窗口得带上能找到 node 的 PATH。
NSDictionary *CCBridgeProbeCodexQueueWithEnvironment(NSString *executable, NSDictionary<NSString *, NSString *> *environment);
