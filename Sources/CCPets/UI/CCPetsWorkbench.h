#import <Cocoa/Cocoa.h>

// 主窗口「工作台」几页（概览、会话）要的数据，由 AppDelegate 提供。和 CCPetsSettingsActions
// 一样只声明契约：页面不 import AppDelegate 的私有头，AppDelegate 也不在声明上采纳协议
// （方法分散在几个 category 里），签名一致由 tests/test.sh 的检查守着。
//
// 返回的都是快照：普通字典和数组，页面拿去渲染，不回写。
@protocol CCPetsWorkbenchSource <NSObject>

// 在线会话，等审批的排最前，其余按最近活动倒序。每项：
//   id（会话键，交回 focusWorkbenchSessionWithID: 用）、provider（Claude / Codex）、
//   name（CC Bridge 里的会话名，没开 Bridge 时没有）、state（Agent 状态）、status（状态文字）、
//   tool（正在用的工具，可能为空）、terminal（终端名）、updatedAt（最近一条事件的时间戳）、
//   pendingMessages（这个会话信箱里还没投递的消息数）。
- (NSArray<NSDictionary *> *)workbenchSessions;

// CC Bridge 消息，只有元数据，没有正文。键：
//   enabled（Bridge 是否开启）、
//   pending（数组：session、name、count —— 卡在信箱里、要用户去那个终端开口才会送进去的消息）、
//   deliveries（数组：from、to、toSession、at、unseen —— 最近送达的消息，新的在前）。
- (NSDictionary *)workbenchMessages;

// 订阅额度，每个已登记账号一项（未登记的平台保留一张卡片）。键：provider（Claude / Codex）、
//   profileId / profileName（账号身份与名称；未登记时没有）、
//   profile（账号配置）、usage（与悬停面板相同的完整额度和本地 Token）、history（该账号额度历史）、
//   apiMode（是否显示 API 用量）、online / hasData（在线与数据状态）、state / status（状态与显示文案）、
//   fiveRemaining / weekRemaining（剩余百分比）、fiveReset / weekReset（重置时间）、pace / paceLevel（本周节奏）、
//   hasDiagnosticIssues（该账号确实有 warn / fail 诊断结果，缺少额度不算问题）。
- (NSArray<NSDictionary *> *)workbenchQuotas;

// 跳到会话所在的终端。
- (void)focusWorkbenchSessionWithID:(NSString *)sessionID;
// 跳到 CC Bridge 会话所在的终端（收件人、信箱积压的那个会话）。
- (void)focusBridgeSessionWithID:(NSString *)sessionID;
// 用户在主窗口看过消息了：和打开右键会话菜单一样，清掉桌宠上的未读角标。
- (void)markWorkbenchMessagesSeen;

@end

extern NSNotificationName const CCPetsWorkbenchQuotasDidChangeNotification;
