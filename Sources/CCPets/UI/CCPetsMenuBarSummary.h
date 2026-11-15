#import <Foundation/Foundation.h>

// 菜单栏标题要显示什么。只依赖 workbenchQuotas 的快照（见 CCPetsWorkbench.h），不碰 AppKit，
// 单独成文件是为了让 tests/menu-bar-summary-harness.m 不必链接整套界面代码。

typedef NS_ENUM(NSInteger, CCPetsMenuBarLevel) {
    CCPetsMenuBarLevelNormal = 0,
    CCPetsMenuBarLevelWarning,    // 剩余 ≤ 20%
    CCPetsMenuBarLevelCritical,   // 剩余 ≤ 10%，或已被限流
};

// 与低额度台词同一组阈值（20 / 10），菜单栏变色和宠物开口在同一时刻发生。
extern const NSInteger CCPetsMenuBarWarningPercent;
extern const NSInteger CCPetsMenuBarCriticalPercent;

// 订阅账号里最低的 5 小时剩余百分比（0–100）。API 账号、没有数据的账号不参与；
// 被限流（state == limited）的账号按 0 算。没有任何可比较的账号时返回 -1。
NSInteger CCPetsMenuBarLowestFiveHourRemaining(NSArray<NSDictionary *> *quotas);

CCPetsMenuBarLevel CCPetsMenuBarLevelForRemaining(NSInteger remaining);

// 菜单栏图标旁的文字。键：
//   percent（NSString，如 "62%"；不该显示时没有这个键）、level（NSNumber，CCPetsMenuBarLevel）、
//   approvals（NSString，待审批数；为 0 时没有这个键）。
// 数字只由 showPercent 决定：用户关掉就不显示，哪怕额度已进警告档（低额度在面板里照样着色）。
// 曾经在 ≤20% 时无视开关强制显示，结果关掉开关后数字不消失，看起来像开关坏了。
NSDictionary *CCPetsMenuBarTitleParts(NSArray<NSDictionary *> *quotas, NSUInteger approvals, BOOL showPercent);

// 菜单栏图标的色调。state 是宠物名片快照里的 Agent 状态（和状态卡同一条），归类与状态卡的
// statusColorForState: 一致；待机或没有状态时保持原色，颜色只用来提示「有 Agent 在动」或「刚完成 / 失败」。
// 具体颜色由菜单栏那边取系统色：状态卡的工作蓝是为浅色玻璃调的，放在深色菜单栏上太暗。
typedef NS_ENUM(NSInteger, CCPetsMenuBarIconTone) {
    CCPetsMenuBarIconToneNone = 0,
    CCPetsMenuBarIconToneWorking,
    CCPetsMenuBarIconToneAttention,   // 等待审批、需要关注
    CCPetsMenuBarIconToneCompleted,
    CCPetsMenuBarIconToneFailed,
};
CCPetsMenuBarIconTone CCPetsMenuBarIconToneForState(NSString *state);

// 面板里账号的排列：订阅账号在前，API 账号在后；同一组内保持 workbenchQuotas 原有次序
// （平台次序与悬停面板一致）。订阅额度会耗尽、要盯着看，API 用量只是记账。
NSArray<NSDictionary *> *CCPetsMenuBarOrderedQuotas(NSArray<NSDictionary *> *quotas);

// 所有账号今日 Token 合计（usage.tokenUsage.today.total_tokens）。都没有数据时返回 nil。
NSNumber *CCPetsMenuBarTodayTokens(NSArray<NSDictionary *> *quotas);
