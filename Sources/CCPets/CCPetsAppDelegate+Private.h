// AppDelegate 按功能拆成多个 category（CCPetsAppDelegate+<模块>.m），这个头文件是它们之间的私有约定：
// 共享常量、共用的小控件类，以及跨文件调用的方法声明。只给 AppDelegate 自己的实现文件 import。
#import "CCPetsAppDelegate.h"
#import "CCPetsPaths.h"
#import "CCPetsL10n.h"
#import "CCPetsVersion.h"
#import "CCPetsEvents.h"
#import "CCPetsQuotaHistory.h"
#import "CCPetsImageLoader.h"
#import "CCPetsPhrases.h"
#import "CCPetsPhrasesEditor.h"
#import "CCPetsUsage.h"
#import "CCPetsTerminalFocus.h"
#import "MenuChoiceRow.h"
#import "CCPetsGlassMenu.h"
#import "CCPetsBridge.h"
#import "MenuToggleSwitch.h"
#import <UserNotifications/UserNotifications.h>
#import <signal.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <sys/sysctl.h>
#import <stdlib.h>

static const NSTimeInterval PendingApprovalTTL = 24 * 60 * 60;
static const NSUInteger PendingApprovalLimit = 100;
static const NSUInteger AgentSessionRecordLimit = 20;
static const NSUInteger AgentSessionMenuLimit = 8;
static const CGFloat PetApprovalBadgeSize = 17.0;
static const CGFloat PetUpdateBadgeSize = 24.0;
// CC Bridge：轮询间隔、"最近消息"的时间窗、菜单里最多列几条。
static const NSTimeInterval BridgeRefreshInterval = 3.0;
static const NSTimeInterval BridgeRecentWindow = 30 * 60;
static const NSUInteger BridgeMenuDeliveryLimit = 5;
static const unsigned long long UpdateLogSizeLimit = 1024 * 1024;
static NSString *const CCPetsRepositorySlug = @"Sunnyshinnny776/cc-pets";
// 更新弹窗里最多列几条说明、每条最多几个字符；多出来的条目用一行「…」代替。
static const NSUInteger UpdateHighlightLimit = 3;
static const NSUInteger UpdateHighlightMaxLength = 50;
// CLI 每开一个终端都会 open 一次桌宠，这个间隔内不重复联网检查。
static const NSTimeInterval UpdateSilentCheckInterval = 10 * 60;
// 启动时的更新气泡比普通碎碎念停得久，给用户留出点它的时间。
static const NSTimeInterval UpdateBubbleDwell = 30.0;
// 碎碎念开着时，每次够条件说话有一半机会换成更新提醒；提醒气泡停得比闲话久一点，来得及点。
static const uint32_t UpdateReminderSharePercent = 50;
static const NSTimeInterval UpdateReminderDwell = 8.0;
static NSString *const PetInteractionPhrasesV1MigratedKey =
    @"CCPetsInteractionPhrasesV1Migrated";

// 全量聚合是同步的主线程活儿（本机实测数十毫秒，会话目录越大越久），而面板恰好由"鼠标
// 停在口袋上"触发——那正是用户可能马上按下并拖动的时刻。事件被这几十毫秒挡住，mouseDown
// 和 mouseDragged 就会成批迟到，手感上像是"鼠标走远了宠物才跟上"。
// 因此：左键按着的时候不刷（拖动期间没人看数字），刚刷过的也不重刷（进出热区会反复触发）。
static const NSTimeInterval UsageRefreshCoalesceWindow = 2.0;
// 气泡停留时长。
static const NSTimeInterval PetSpeechDwell = 4.5;
// 气泡与状态卡的本体高度。
//
// 不要再加尾巴（三角、锥形、思考圆点都试过）：药丸的圆角等于高度一半，整条边都是弧，
// 尾巴只能从弧上长出来，怎么调都像贴上去的；换成圆角矩形能配尾巴，但那要放弃
// layer.cornerRadius + kCACornerCurveContinuous 改用位图 maskImage 裁形，
// squircle 和 GPU 端矢量裁切的质感一起丢了，得不偿失。
// 结论：保持药丸 + 原生圆角，靠贴近宠物来表达归属。
static const CGFloat PetSpeechBodyHeight = 38.0;
static const CGFloat PetStatusBodyHeight = 58.0;
// 副行没东西可显示时的高度，只放得下标题一行。
static const CGFloat PetStatusSingleLineHeight = 40.0;

// 碎碎念的话痨程度。四道闸（每小时预算 / 两句间隔 / 静默门槛 / 出话概率）本来是
// 四个互相牵制的常数，单独调任何一个都不会真的变频繁——比如把冷却调到 0，
// 每小时 4 句的预算照样卡死。所以对用户只暴露一个档位，四个值一起走。
//
// normal 档就是改造前的原值，默认不变。
typedef struct {
    NSInteger hourlyBudget;
    NSTimeInterval cooldown;
    NSTimeInterval quietSeconds;    // 距上一次 agent 事件多久才算"没人打扰"
    uint32_t idleChancePercent;     // 每次判定（≤30 秒一次）的出话概率
} PetSpeechRate;

static const PetSpeechRate PetSpeechRateLow    = {2,  480.0, 300.0, 15};
static const PetSpeechRate PetSpeechRateNormal = {4,  240.0, 180.0, 25};
static const PetSpeechRate PetSpeechRateHigh   = {8,  120.0,  90.0, 45};
static const PetSpeechRate PetSpeechRateChatty = {20,  45.0,  45.0, 70};

// 档位写进 defaults 的值。字符串而不是整数：以后加档、调顺序都不会让老配置错位。
extern NSString *const PetSpeechFrequencyKey;
static NSString *const PetSpeechFrequencyLow = @"low";
static NSString *const PetSpeechFrequencyNormal = @"normal";
static NSString *const PetSpeechFrequencyHigh = @"high";
static NSString *const PetSpeechFrequencyChatty = @"chatty";

// 卡片和气泡都按文案实际宽度伸缩。固定宽度下"收工！"和"到处翻资料呢。"占一样长的条，
// 前者会拖着一大截空白，看着像没加载完。
// 用控件自己的 fittingSize 量，不要用 sizeWithAttributes:。
// NSTextField 的 cell 有一点内部留白，纯按字符串量出来的宽度会比控件真正需要的小几个点，
// 结果就是明明算着"刚好够"，显示出来最后一两个字变成省略号。
static inline CGFloat PetMeasuredLabelWidth(NSTextField *label) {
    if (label.stringValue.length == 0) return 0;
    return ceil(label.fittingSize.width) + 2;
}

@interface CCPetsStatusClickButton : NSButton
@end

// 待审批角标。等审批的会话按定义是停住不动的，它的时间戳只会越来越旧——状态卡
// 正文永远显示最新事件，会话列表又按时间倒序，两边都会把最该处理的那条推到看
// 不见的地方。角标把这个数字单独拎出来常驻。
@interface CCPetsApprovalBadgeView : NSView
@property(nonatomic) NSUInteger count;
// 默认审批红；CC Bridge 消息角标复用同一个视图，换成蓝色 / 橙色。
@property(nonatomic) NSColor *fillColor;
@end

@interface AppDelegate ()
- (NSString *)applicationSupportDirectory;
- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message;
- (void)installEditMenu;
- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag;
- (void)screensDidSleep:(NSNotification *)notification;
- (void)screensDidWake:(NSNotification *)notification;
- (void)petWindowDidMove:(NSNotification *)notification;
- (void)applicationWillTerminate:(NSNotification *)notification;
@end

// 右键菜单里的各项设置开关
@interface AppDelegate (Settings)
- (void)toggleSystemMetric:(NSButton *)sender;
- (void)setUsageDisplayModeFromControl:(NSButton *)sender;
- (NSString *)systemMetricKeyForTag:(NSInteger)tag;
- (void)applySystemMetricPreferences;
- (void)applyUsageDisplayModePreferences;
- (void)toggleImportCodexPets:(NSButton *)sender;
- (void)showImportedCodexPetsAlert:(NSUInteger)imported;
- (NSString *)notificationKeyForTag:(NSInteger)tag;
- (void)setPanelTheme:(MenuChoiceRowView *)sender;
- (void)applyBubbleTextStyle;
- (void)setGlassDimLevel:(MenuChoiceRowView *)sender;
- (void)toggleSpeech:(NSButton *)sender;
- (void)togglePetInteraction:(NSButton *)sender;
- (void)setPetInteractionHeartThreshold:(MenuChoiceRowView *)sender;
- (void)setPetInteractionAnnoyedThreshold:(MenuChoiceRowView *)sender;
- (void)setPetInteractionInterval:(MenuChoiceRowView *)sender;
- (void)setSpeechFrequency:(MenuChoiceRowView *)sender;
- (void)setPhrasesSource:(MenuChoiceRowView *)sender;
- (void)editPhrasesFile:(id)sender;
- (void)setLanguagePreferenceFromMenu:(NSMenuItem *)sender;
- (void)languageDidChange:(NSNotification *)notification;
- (void)toggleNotification:(NSButton *)sender;
@end

// Agent 状态卡、会话列表、审批与卡住提醒、终端回跳、系统通知
@interface AppDelegate (AgentStatus)
- (void)positionAgentStatus;
- (void)showAgentStatusForRecord:(NSDictionary *)record;
- (void)prunePendingApprovalRecords;
- (void)toggleStatusBubbleFromMenu:(NSButton *)sender;
- (void)sendNotificationWithTitle:(NSString *)title body:(NSString *)body;
- (void)notifyForRecord:(NSDictionary *)record;
- (NSString *)statusTextForState:(NSString *)state tool:(NSString *)tool;
- (NSString *)petVoiceTagForState:(NSString *)state tool:(NSString *)tool;
- (NSString *)statusDetailForState:(NSString *)state tool:(NSString *)tool;
- (NSColor *)statusColorForState:(NSString *)state;
- (NSString *)statusSymbolForState:(NSString *)state;
- (void)hideAgentStatusIfClientGone;
- (void)hideAgentStatus;
- (void)presentPendingApprovalRecord:(NSDictionary *)record;
- (BOOL)isTrailingRecord:(NSDictionary *)record afterState:(NSString *)state;
- (void)applyStatusPresentationForState:(NSString *)state provider:(NSString *)provider
    tool:(NSString *)tool;
- (void)enterIdleStatus;
- (void)showAgentStatusForRecord:(NSDictionary *)record notify:(BOOL)shouldNotify;
- (NSString *)approvalKeyForRecord:(NSDictionary *)record;
- (void)displayAgentRecord:(NSDictionary *)record notify:(BOOL)shouldNotify;
- (NSString *)agentSessionKeyForRecord:(NSDictionary *)record;
- (NSString *)onlineAgentSessionKeyForProvider:(NSString *)provider tty:(NSString *)tty;
- (NSString *)onlineAgentSessionKeyForRecord:(NSDictionary *)record;
- (BOOL)isAgentSessionRecordLive:(NSDictionary *)record;
- (void)pruneOfflineAgentSessionRecords;
- (void)trackAgentSessionRecord:(NSDictionary *)record;
- (BOOL)isApprovalSessionRecord:(NSDictionary *)record;
- (NSArray<NSDictionary *> *)pendingApprovalSessionRecords;
- (NSTimeInterval)stallIntervalForState:(NSString *)state;
- (void)checkStalledAgentSessions;
- (void)presentStalledRecord:(NSDictionary *)record;
- (void)layoutApprovalBadge;
- (void)refreshApprovalBadge;
- (NSArray<NSDictionary *> *)recentAgentSessionRecords;
- (NSString *)terminalNameForTarget:(NSDictionary *)target;
- (void)focusAgentSessionRecord:(NSMenuItem *)sender;
- (void)showAgentSessionsMenu:(NSButton *)sender;
- (void)popUpAgentSessionsMenu:(NSMenu *)menu from:(NSButton *)sender;
- (BOOL)focusLatestAgentTerminal;
- (void)focusLatestAgentTerminal:(id)sender;
- (void)resizeStatusCardToFitText;
@end

// CC Bridge 开关、消息角标与菜单
@interface AppDelegate (Bridge)
- (void)runBridgeCommand:(NSArray<NSString *> *)arguments sender:(NSButton *)sender
    successMessage:(NSString *)successMessage;
- (BOOL)currentBridgeStateForSwitch:(NSButton *)sender;
- (void)syncBridgeSwitch:(NSButton *)sender;
- (BOOL)targetBridgeStateForSwitch:(NSButton *)sender;
- (NSString *)bridgeApprovalGroupForTag:(NSInteger)tag;
- (void)toggleBridgeEnabled:(NSButton *)sender;
- (void)toggleBridgeApproval:(NSButton *)sender;
- (void)toggleBridgeWake:(NSButton *)sender;
- (void)toggleBridgeEditGuard:(NSButton *)sender;
- (void)toggleBridgeBadge:(NSButton *)sender;
- (void)toggleBridgeNotification:(NSButton *)sender;
- (void)refreshBridgeState:(NSTimer *)timer;
- (void)notifyNewBridgeDeliveries;
- (void)refreshBridgeBadge;
- (NSString *)bridgeSessionIdForRecord:(NSDictionary *)record;
- (NSDictionary *)bridgeSessionEntryForRecord:(NSDictionary *)record;
- (NSDictionary *)terminalTargetForBridgeSession:(NSString *)sessionId;
- (void)focusBridgeSession:(NSMenuItem *)sender;
- (void)addBridgeItemsToMenu:(NSMenu *)menu deliveries:(NSArray<NSDictionary *> *)deliveries
    pending:(NSDictionary<NSString *, NSNumber *> *)pending;
@end

// 宠物素材发现、切换与删除
@interface AppDelegate (Pets)
- (void)switchPetToID:(NSString *)petID;
- (BOOL)deletePetWithID:(NSString *)petID;
- (NSDictionary *)petManifestInDirectory:(NSString *)directory;
- (NSInteger)spriteVersionInDirectory:(NSString *)directory fallbackDirectory:(NSString *)fallbackDirectory;
- (NSInteger)spriteRowCountForVersion:(NSInteger)version;
- (NSString *)spritePathInDirectory:(NSString *)directory;
- (NSArray<NSString *> *)petDirectoryNamesAtPath:(NSString *)root;
- (NSArray<NSDictionary *> *)discoverPetOptions;
- (NSDate *)petOptionsStamp;
- (void)invalidatePetOptionsCache;
- (NSArray<NSDictionary *> *)petOptions;
- (NSDictionary *)petOptionWithID:(NSString *)petID inOptions:(NSArray<NSDictionary *> *)options;
- (NSArray<NSDictionary *> *)waitForPetOptions;
@end

// 额度面板、用量刷新与系统指标
@interface AppDelegate (Quota)
- (void)showQuotaDashboard;
- (void)positionQuotaDashboard;
- (void)scheduleQuotaDashboardHide;
- (void)hideQuotaDashboardIfNeeded;
- (void)refreshUsage:(id)sender;
- (void)applyCodexUsage:(NSDictionary *)codexUsage claudeUsage:(NSDictionary *)claudeUsage;
- (void)rescheduleUsageTimer;
- (BOOL)shouldRefreshUsageForDashboard;
- (BOOL)hasEnabledSystemMetric;
- (void)refreshSystemMetrics:(id)sender;
- (void)updateSystemMetricsTimer;
- (void)startQuotaClock;
- (void)tickQuotaClock:(id)sender;
- (void)updateQuotaLiveState;
- (void)resizeQuotaDashboard;
- (void)refreshDetectedProviders;
@end

// agent 事件流读取与客户端存活检测
@interface AppDelegate (AgentEvents)
- (void)prepareAgentEventReader;
- (void)consumeAgentEventData:(NSData *)data;
- (void)processAgentEventData:(NSData *)data ignoreFirstPartial:(BOOL)ignoreFirstPartial recentOnly:(BOOL)recentOnly;
- (void)readNewAgentEvents;
- (void)startAgentEventReader;
- (void)ensureAgentEventReader:(id)sender;
- (void)refreshClientLifecycle:(id)sender;
@end

// 说话气泡与碎碎念
@interface AppDelegate (Speech)
- (BOOL)speechEnabled;
- (PetSpeechRate)speechRate;
- (NSTimeInterval)speechCooldownSeconds;
- (NSInteger)speechHourlyBudget;
- (BOOL)agentBusyForSpeech;
- (BOOL)canSpeakNow;
- (NSDictionary<NSString *, NSString *> *)speechSlots;
- (NSDictionary<NSString *, NSString *> *)speechSlotsWithTool:(NSString *)tool;
- (NSInteger)remainingFiveHourQuotaPercent;
- (NSString *)fiveHourResetTimeText;
- (void)considerQuotaSpeech;
- (void)buildSpeechPanelIfNeeded;
- (void)positionSpeechPanel;
- (void)speakWithTag:(NSString *)tag;
- (void)presentSpeechText:(NSString *)text;
- (void)restoreStatusDetail;
- (void)showSpeechBubbleWithText:(NSString *)text;
- (void)showSpeechBubbleWithText:(NSString *)text dwell:(NSTimeInterval)dwell;
- (void)consumeSpeechDebugTrigger;
- (void)hideSpeechBubble;
- (void)considerIdleSpeech;
- (void)considerSpeechForRecord:(NSDictionary *)record;
- (void)resizeSpeechBubbleToFitText;
@end

// 检查更新、自动更新、更新气泡 / 角标 / 弹窗，以及「关于」
@interface AppDelegate (Update)
- (NSDictionary *)updaterConfiguration;
- (BOOL)restartAfterUpdateToVersion:(NSString *)version configuration:(NSDictionary *)configuration;
- (void)startUpdateToVersion:(NSString *)version;
- (void)retryUpdate:(NSArray *)context;
- (void)startUpdateToVersion:(NSString *)version attempt:(NSInteger)attempt;
- (void)showAboutPanel:(id)sender;
- (void)fetchLatestReleaseWithCompletion:(void (^)(NSString *version, NSString *notes,
    NSString *errorMessage))completion;
- (void)fetchReleaseNotesForVersion:(NSString *)version sourceIndex:(NSUInteger)index
    completion:(void (^)(NSString *body))completion;
- (void)checkForUpdates:(id)sender;
- (void)showPendingUpdate:(id)sender;
- (void)silentCheckForUpdate;
- (void)rememberPendingUpdate:(NSString *)version notes:(NSString *)notes;
- (void)refreshUpdateBadge;
- (void)clearPendingUpdate;
- (NSView *)updateHighlightsAccessoryView:(NSArray<NSString *> *)highlights truncated:(BOOL)truncated;
- (void)showUpdateDialog;
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem;
- (void)applyUpdateBadgeStyle;
- (void)showUpdateBubble;
- (NSString *)updateReminderText;
- (void)showUpdateBubbleWithText:(NSString *)text dwell:(NSTimeInterval)dwell;
- (void)updateBubbleClicked:(id)sender;
@end
