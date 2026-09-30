#import <Cocoa/Cocoa.h>

// 用原生玻璃面板展示一个已经构建好的 NSMenu。系统菜单的材质不能换，Liquid Glass 主题下
// 消息列表会和旁边的玻璃状态卡风格割裂；这里只读菜单项的标题、启用、勾选、分隔线和
// target/action，调用方的菜单构建代码不用改。只支持平铺菜单（没有子菜单、自定义视图）。
@interface CCPetsGlassMenu : NSObject
// anchor 是玻璃状态卡；面板贴在它下方、右边与 alignView 右边对齐，屏幕下方放不下时放到上方。
+ (void)showMenu:(NSMenu *)menu belowView:(NSView *)anchor alignRightTo:(NSView *)alignView;
+ (void)dismiss;
@end
