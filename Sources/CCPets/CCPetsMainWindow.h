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

@interface CCPetsMainWindowController : NSWindowController

// 打开（已开着就前置）并切到指定页面；page 为 nil 或不认识时打开上次看的页面。
+ (void)presentPage:(NSString *)page;

@end
