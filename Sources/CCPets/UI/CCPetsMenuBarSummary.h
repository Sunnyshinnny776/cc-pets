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
// showPercent 关闭时，只要额度进了警告档仍然显示数字：低额度是这个模式下唯一的主动提醒。
NSDictionary *CCPetsMenuBarTitleParts(NSArray<NSDictionary *> *quotas, NSUInteger approvals, BOOL showPercent);

// 所有账号今日 Token 合计（usage.tokenUsage.today.total_tokens）。都没有数据时返回 nil。
NSNumber *CCPetsMenuBarTodayTokens(NSArray<NSDictionary *> *quotas);
