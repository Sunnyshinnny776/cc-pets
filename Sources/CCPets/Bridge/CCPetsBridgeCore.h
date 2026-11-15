#import <Foundation/Foundation.h>

// CC Bridge 的业务逻辑：身份识别、目标解析、消息封装、按目标 CLI 选择投递方式，以及文件预留。
//
// 投递路径（均为官方公开机制）：
//   - 目标是 Codex：`codex queue --thread <id> --message <text>`。空闲时立即唤醒，忙碌时排到当前回合之后。
//     发给已关闭会话的消息会被 Codex 持久化并在 resume 时自动执行，所以投递前必须确认目标在线。
//   - 目标是 Claude：写入信箱，由 asyncRewake watcher 认领后以 exit 2 唤醒或注入；watcher 不在时，
//     由 UserPromptSubmit hook 在用户下次输入时注入。

// 在线会话（不在线的顺手清出注册表），按启动时间排序。
NSArray<NSDictionary *> *CCBridgeLiveSessions(void);
NSString *CCBridgeDescribeSession(NSDictionary *session);
// 带 ref 和可选动物别名的展示文本；地址仍使用 CCBridgeDescribeSession。
NSString *CCBridgeDescribeSessionForDisplay(NSDictionary *session);

// 优先验证显式会话 ID；缺失时仅允许 provider + PID 唯一匹配。
// 显式 ID 失效、与宿主不符或 PID 匹配多个会话时返回 nil，禁止按活动时间猜测。
NSDictionary *CCBridgeIdentifySelf(void);
// MCP 的逐次调用身份；nil 沿用自动识别，非 nil 必须是有效 ID 且属于当前宿主。
// 不缓存结果，不接受名字/ref；无效显式参数不能回退到环境变量或 PID，验证不了宿主归属时同样拒绝。
// 拒绝显式 ID 时 failure 带上面向调用者的原因。
NSDictionary *CCBridgeIdentifySelfForSession(id sessionId, NSString **failure);

// 名字即地址；重名时追加 " [ref]"。也接受裸 ref 和完整 session id。返回 @{session} 或 @{error}。
NSDictionary *CCBridgeResolveTarget(id address, NSArray<NSDictionary *> *sessions);
NSString *CCBridgeFormatEnvelope(NSDictionary *message);

// 返回 @{receipt} 或 @{error}。
NSDictionary *CCBridgeSendMessage(NSDictionary *from, NSDictionary *to, id body, BOOL notifyWhenIdle, BOOL system);
// 目标会话进入空闲时，给订阅者各发一条一次性通知。
void CCBridgeSendIdleNotices(NSDictionary *target, NSArray<NSString *> *subscribers);
NSString *CCBridgeReceiptSummary(NSDictionary *receipt, NSDictionary *target);

#pragma mark - 文件预留
// 多个 Agent 在同一个仓库里工作时，先声明"我要改哪些文件"，避免互相覆盖。预留是建议性的，不锁文件：
// 其他会话第一次编辑被预留的文件时，PreToolUse hook 把这次编辑拦下一次并说明原因，重试即放行
// （"首次拦截、重试放行"）。作用域是仓库根目录，不同 worktree 各自独立。

extern const NSInteger CCBridgeDefaultTTLMinutes;
extern const NSInteger CCBridgeMaximumTTLMinutes;

NSString *CCBridgeRepoRoot(NSString *directory);
// 调用方给的路径（绝对、相对、glob 均可）→ "相对仓库根、以 / 分隔"的模式；越出仓库根返回 nil。
// 比较前解析软链：经软链指向仓库外的路径同样算越界。
NSString *CCBridgeNormalizePattern(NSString *root, NSString *baseDirectory, id raw);
// 支持 **、*、?；不带通配符的模式视为"这个文件，或这个目录下的一切"。
BOOL CCBridgePatternMatches(NSString *pattern, NSString *path);
// 是否存在同时匹配两个模式的路径。不带通配符的模式可能是目录，所以连同其下的一切一起算，
// 除非 root 下能确认它是普通文件；root 为 nil 时不访问文件系统。
BOOL CCBridgePatternsOverlap(NSString *root, NSString *left, NSString *right);
// 过期的、持有者已不在线的预留顺手清掉，返回仍然有效的（带 holder 字段）。root 为 nil 表示所有仓库；
// sessions 为 nil 时现查在线会话。
NSArray<NSDictionary *> *CCBridgeActiveReservations(NSString *root, NSArray<NSDictionary *> *sessions);
void CCBridgeReleaseSessionReservations(NSString *sessionId);
NSString *CCBridgeDescribeReservation(NSDictionary *reservation);
// 返回 @{error} 或 @{root, patterns, ttl, conflicts: [@{pattern, other}]}。
NSDictionary *CCBridgeReserveFiles(NSDictionary *session, id paths, id reason, id ttlMinutes);
void CCBridgeAcknowledgeReservation(NSString *reservationId, NSString *sessionId);
BOOL CCBridgeReservationAcknowledged(NSDictionary *reservation, NSString *sessionId);
// 返回 @{error}（paths 不是字符串数组，且未做任何改动）或 @{root, released}。
// 不传 paths 表示全部释放；空数组什么都不释放。
NSDictionary *CCBridgeReleaseFiles(NSDictionary *session, id paths);
// 这些具体文件是否被其他在线会话预留：[@{file, reservation}]。
NSArray<NSDictionary *> *CCBridgeFindForeignReservations(NSString *sessionId, NSString *cwd, NSArray<NSString *> *filePaths);
// 从编辑类工具的输入里找出要改的文件：Claude 的 file_path / notebook_path，
// Codex apply_patch 正文里的 "*** Update/Add/Delete File:" 与 "*** Move to:"。
NSArray<NSString *> *CCBridgeEditedFiles(id toolInput);
