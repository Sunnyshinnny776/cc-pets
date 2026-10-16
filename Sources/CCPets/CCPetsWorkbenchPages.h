#import <Cocoa/Cocoa.h>

// 主窗口「工作台」组里的两页。数据都从 AppDelegate 现取快照（CCPetsWorkbench.h），页面只读。

// 概览：宠物和它此刻的状态、今天的用量、诊断提醒、订阅额度。会话和消息不在这里重复列，
// 它们有自己的一页。
@interface CCPetsOverviewPage : NSViewController
@end

// 会话与消息：在线的 Agent 会话（等审批的置顶，一键跳回终端），以及 CC Bridge 的消息往来。
// 页面开着时每几秒重读一次快照（会话状态一变也会立刻刷新）；窗口不可见时停表。
@interface CCPetsSessionsPage : NSViewController
@end
