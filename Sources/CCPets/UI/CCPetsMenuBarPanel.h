#import <Cocoa/Cocoa.h>

@class CCPetsStatusItemController;

// 菜单栏图标左键弹出的玻璃面板：宠物与当前状态、在线会话、各账号额度、今日用量。
//
// 刻意只放「扫一眼」的信息：趋势、本机 Token 明细、系统指标留给宠物旁的悬停面板和主窗口。
// 材质、白字投影和额度配色与悬停面板一致，并跟随面板主题（经典 / Liquid Glass）。
// 面板不抢焦点（抢了会把前台终端的焦点夺走），因此不支持方向键；Esc 只在本 App 处于前台时有效，
// 点面板以外任何地方即收起，和 CCPetsGlassMenu 同一套做法。
@interface CCPetsMenuBarPanel : NSObject
- (instancetype)initWithOwner:(CCPetsStatusItemController *)owner;
@property(nonatomic, readonly, getter=isShown) BOOL shown;
- (void)showBelowButton:(NSStatusBarButton *)button;
// 数据变了：面板开着就就地重排，顶边不动。
- (void)reload;
- (void)dismiss;
@end
