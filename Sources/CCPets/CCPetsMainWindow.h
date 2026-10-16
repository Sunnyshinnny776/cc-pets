#import <Cocoa/Cocoa.h>

// 主窗口：侧边栏 + 内容区的普通 App 窗口，放右键菜单装不下的设置和数据。
//
// 桌宠平时是 Accessory（没有 Dock 图标、不出现在 ⌘Tab），主窗口打开期间临时切成 Regular，
// 像普通 App 一样能切换、有菜单栏；最后一个普通窗口（主窗口、台词编辑器）关掉后切回去。
// 桌宠自己的浮窗都是 NSPanel，不计入"普通窗口"。
//
// 窗口懒创建，关闭即释放，不常驻内存；页面也只在显示时创建。

// 页面标识，也是 `cc-pets open <page>` 的参数。
extern NSString *const CCPetsMainWindowPageSettings;

// 侧边栏顶部的宠物名片要的数据。由 AppDelegate 提供，窗口只读不写。
// 键：sheet（NSImage 精灵图）、rowCount、name、state（Agent 状态，无会话时 idle）、
// status（状态文字）、statusColor（NSColor）、sessions（在线会话数）、approvals（待审批数）。
@protocol CCPetsPetCardSource <NSObject>
- (NSDictionary *)petCardSnapshot;
@end

// 名片上的任何一项变了（换宠物、Agent 状态、会话数、审批数）就发，窗口收到后重读快照。
// 没有窗口时没人听，发一次只是一次空的广播。
extern NSNotificationName const CCPetsPetCardDidChangeNotification;

@interface CCPetsMainWindowController : NSWindowController

// 打开（已开着就前置）并切到指定页面；page 为 nil 或不认识时打开上次看的页面。
+ (void)presentPage:(NSString *)page;

@end
