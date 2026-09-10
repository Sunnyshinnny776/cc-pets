#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import "PetView.h"
#import "QuotaDashboardView.h"
#import "CCPetsUsageMonitor.h"
#import "CCPetsSystemMonitor.h"

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property NSPanel *panel;
@property NSPanel *quotaPanel;
// 说话气泡。懒创建：用户不开启说话功能就永远不存在这个窗口。
@property NSPanel *speechPanel;
@property NSTextField *speechLabel;
@property NSVisualEffectView *speechGlass;
// 预算制：这一小时说过几句、以及冷却到什么时候。
@property NSMutableArray<NSNumber *> *speechTimestamps;
@property NSTimeInterval speechCooldownUntil;
@property NSTimeInterval lastIdleSpeechCheck;
@property NSTimeInterval lastAgentEventAt;
// 上一次选中的状态标签与文案。同状态的连串事件里保持不变，避免副行闪烁。
@property(copy) NSString *lastPetVoiceTag;
@property(copy) NSString *lastPetVoiceText;
@property NSTimeInterval sessionStartedAt;
@property NSInteger consecutiveFailures;
// 最近一次 agent 事件的工具名，供 {toolName} 槽位使用。
@property(copy) NSString *lastSpeechTool;
// 上次播报额度时剩余百分比落在哪一档。只在向下穿档时说，不是"低于阈值就一直说"。
@property NSInteger lastQuotaTier;
@property BOOL lastQuotaTierInitialized;
@property NSPanel *statusPanel;
@property NSVisualEffectView *statusGlass;
// 卡片要随文案长度伸缩，阴影层得跟着一起改，所以不能再是个局部变量。
@property NSView *statusShadowView;
@property NSTextField *statusTitleLabel;
@property NSTextField *statusDetailLabel;
@property NSButton *statusIconButton;
@property NSButton *statusClickButton;
// 圆形状态图标右上角的待审批角标。状态卡正文永远跟着最新事件走，角标负责让
// "还有几个会话在等你确认"始终留在视线里。
@property NSView *approvalBadgeView;
@property BOOL statusBubbleExpanded;
@property BOOL statusBubbleAbove;
@property BOOL hasAgentStatus;
@property NSInteger liveClientCount;
@property NSString *lastStatusState;
@property NSString *lastStatusProvider;
@property NSDictionary *lastTerminalFocusTarget;
@property NSTimeInterval lastStatusTimestamp;
@property NSSet<NSString *> *liveClientProviders;
// 包装脚本仍存活的精确 Agent 会话，键为 provider + TTY。
@property NSSet<NSString *> *liveAgentSessionKeys;
// 每个 provider 最近一次事件的时间。不经包装脚本启动的客户端没有 pid 文件，
// 只能靠"最近还在发事件"证明自己活着。
@property NSMutableDictionary<NSString *, NSNumber *> *providerActivityAt;
@property BOOL hasUnlabeledClient;
@property NSMutableDictionary<NSString *, NSDictionary *> *pendingApprovalRecords;
// 按终端会话保存最后一条 Hook 状态，供状态图标展开最近多会话列表。
@property NSMutableDictionary<NSString *, NSDictionary *> *agentSessionRecords;
// 已经就"卡住"提醒过的会话，元素是会话键 + 该会话当时的时间戳。会话一有新事件
// 时间戳就变，旧元素随之失效，于是下一次卡住还会再提醒一次。
@property NSMutableSet<NSString *> *stallNotifiedSessionKeys;
@property QuotaDashboardView *quotaView;
@property BOOL managedByCLI;
@property BOOL pocketHovering;
@property BOOL dashboardHovering;
@property BOOL petDragging;
@property NSString *binaryDirectory;
// 素材列表只在启动时扫一次，之后靠素材目录的 mtime 判断要不要重扫——add/remove 必然改动
// 目录本身，所以打开菜单只需要一次 stat，既不用常驻监听也不用和 CLI 做进程间通信。
@property NSArray<NSDictionary *> *cachedPetOptions;
@property NSDate *cachedPetOptionsStamp;
@property PetView *petView;
@property CCPetsUsageMonitor *usageMonitor;
@property unsigned long long agentEventOffset;
@property NSMutableData *agentEventPartialLine;
@property dispatch_source_t agentEventSource;
@property BOOL agentEventReaderInitialized;
@property BOOL checkingForUpdate;
@property BOOL updating;
@property NSTask *updateTask;
@property NSTimer *usageTimer;
// 上一次全量聚合的时刻：面板由悬停触发，短时间内反复进出热区不必每次重算。
@property NSTimeInterval lastUsageRefreshAt;
@property NSTimer *quotaClockTimer;
@property NSTimer *systemMetricsTimer;
@property CCPetsSystemMonitor *systemMonitor;
- (void)showQuotaDashboard;
- (void)positionQuotaDashboard;
- (void)scheduleQuotaDashboardHide;
- (void)hideQuotaDashboardIfNeeded;
- (void)positionAgentStatus;
- (void)showAgentStatusForRecord:(NSDictionary *)record;
- (void)prunePendingApprovalRecords;
- (void)toggleStatusBubbleFromMenu:(NSButton *)sender;
- (void)refreshUsage:(id)sender;
- (void)toggleSystemMetric:(NSButton *)sender;
- (void)setUsageDisplayModeFromControl:(NSButton *)sender;
- (void)applyCodexUsage:(NSDictionary *)codexUsage claudeUsage:(NSDictionary *)claudeUsage;
- (void)switchPetToID:(NSString *)petID;
- (BOOL)deletePetWithID:(NSString *)petID;
@end
