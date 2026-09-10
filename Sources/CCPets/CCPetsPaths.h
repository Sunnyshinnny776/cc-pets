#import <Foundation/Foundation.h>

// 状态文件与配置目录。所有路径都可以通过环境变量覆盖，测试依赖这一点做隔离。
NSString *PetStateDirectory(void);
NSString *AgentEventPath(void);
// 记录端用：解析当前会话的 CLAUDE_CONFIG_DIR。
NSString *ClaudeUsagePath(void);
// 额度文件的写锁。挂在单独的文件上：数据文件本身由 rename 整体替换，
// 锁在它上面的话两个写者会锁到不同的 inode，等于没锁。
NSString *ClaudeUsageLockPath(void);
// 桌宠端用：只看主账号，不受继承来的 CLAUDE_CONFIG_DIR 影响。
NSString *DefaultClaudeConfigDirectory(void);
NSString *CurrentClaudeConfigDirectory(void);
// 桌宠端用：只看主账号的 Codex 目录，不受继承来的 CODEX_HOME 影响。
NSString *DefaultCodexHomeDirectory(void);
NSString *ClaudeUsagePathForConfigDirectory(NSString *configDirectory);
// Token 会话摘要缓存的落盘位置，按 provider 与数据源目录分文件。
NSString *TokenSummaryCachePath(NSString *provider, NSString *sourceDirectory);
// 已结束自然月的用量归档，同样按 provider 与数据源目录分文件。
NSString *MonthlyUsageArchivePath(NSString *provider, NSString *sourceDirectory);
NSString *ApplicationSupportDirectory(void);
NSString *QuotaHistoryPath(void);
// 桌宠只认这一个素材目录。~/.petdex/pets 和 ~/.codex/pets 由别的工具写入，
// 永远不直接扫描，只在开关打开时由 ImportCodexPets 复制进来。
NSString *OwnPetsDirectory(void);
NSString *CodexPetsDirectory(void);

// 这台机器上有没有这家 CLI。面板据此决定渲染几张额度卡：判据是"装没装"，不是"此刻在不在线"。
// 在线信号（liveProviders）会随 CLI 退出而消失，拿它控制卡片显隐会让面板在用户眼前抖动，
// 而 CLI 刚退出恰恰是用户最想看剩余额度的时候。安装器已经不再凭空创建这两个配置目录，
// 所以"目录存在"是干净信号。参见 scripts/detect-cli.mjs 里同一套判据的 Node 实现。
BOOL CodexCLIDetected(void);
BOOL ClaudeCLIDetected(void);
// 把 ~/.codex/pets 里的素材复制进 OwnPetsDirectory()，返回新导入的数量。
// 已存在的同名目录一律跳过，不覆盖。
NSUInteger ImportCodexPets(void);

extern NSString *const HistoryEnabledKey;
extern NSString *const NotificationCompletionKey;
extern NSString *const NotificationFailureKey;
extern NSString *const NotificationApprovalKey;
// Agent 卡在审批或思考态超过阈值时的提醒开关。
extern NSString *const NotificationStallKey;
extern NSString *const StatusBubbleExpandedKey;
extern NSString *const StatusBubblePreferenceV2Key;
extern NSString *const ImportCodexPetsKey;
extern NSString *const SystemCPUEnabledKey;
extern NSString *const SystemTemperatureEnabledKey;
extern NSString *const SystemMemoryEnabledKey;
// 每个 Provider 独立保存额度卡展示模式，值为 "subscription" 或 "api"。
extern NSString *const CodexUsageDisplayModeKey;
extern NSString *const ClaudeUsageDisplayModeKey;
// 曾经检测到过的 provider 集合。只增不减：探测有可能瞬时失败（配置目录被临时改名、
// 外置盘没挂上），而卡片突然消失比多显示一张空卡更像 bug。
extern NSString *const DetectedProvidersKey;

extern const NSTimeInterval AgentStatusInactivityInterval;
extern const NSTimeInterval AgentStatusOrphanInterval;
extern const NSTimeInterval AgentStartingGraceInterval;
extern const NSTimeInterval AgentApprovalStallInterval;
extern const NSTimeInterval AgentThinkingStallInterval;
extern const NSTimeInterval UpdateRetryDelay;
extern const NSTimeInterval UsageRefreshIntervalVisible;
extern const NSTimeInterval UsageRefreshIntervalHidden;
extern const NSTimeInterval ClientLifecycleInterval;
extern const NSTimeInterval QuotaClockInterval;
extern const NSTimeInterval AgentEventReaderCheckInterval;
extern const NSTimeInterval PetFrameInterval;
