#import <Cocoa/Cocoa.h>
#import "CCPetsMainWindow.h"
#import "CCPetsWorkbench.h"

// 菜单栏图标：左键弹出玻璃面板（宠物状态、会话、各账号额度、今日用量，见 CCPetsMenuBarPanel），
// 右键是和桌宠同一份右键菜单。
//
// 数据全部来自现有快照（workbenchSessions / workbenchQuotas / petCardSnapshot），这里不采集、
// 不起定时器：标题和开着的面板只在宠物名片、额度或设置变了的时候重算。
// 和主窗口各页一样只认协议，不 import AppDelegate 的私有头。
@interface CCPetsStatusItemController : NSObject
- (instancetype)initWithSource:(id<CCPetsWorkbenchSource, CCPetsPetCardSource>)source;
@property(nonatomic, weak, readonly) id<CCPetsWorkbenchSource, CCPetsPetCardSource> source;
// 会话状态对应的颜色，和状态卡图标同一套（AppDelegate 的 statusColorForState:）。
@property(nonatomic, copy) NSColor *(^stateColorProvider)(NSString *state);
// 右键菜单。由桌宠那边现建；菜单收起后调 contextMenuFinished 收拾预览浮窗和说明。
@property(nonatomic, copy) NSMenu *(^contextMenuProvider)(void);
@property(nonatomic, copy) void (^contextMenuFinished)(void);
// 「显示桌宠」勾选项：读当前状态、切换。
@property(nonatomic, copy) BOOL (^petVisibleProvider)(void);
@property(nonatomic, copy) void (^togglePetVisible)(void);
// 有可安装的新版本时返回版本号；「仅菜单栏」下没有更新气泡和角标，入口只剩面板底部。
@property(nonatomic, copy) NSString *(^pendingUpdateVersionProvider)(void);
@property(nonatomic, copy) void (^showPendingUpdate)(void);
- (void)refresh;
// 从菜单栏移除并停止监听。之后这个对象不再可用。
- (void)invalidate;
@end
