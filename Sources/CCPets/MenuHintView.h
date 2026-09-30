#import <Cocoa/Cocoa.h>

// 菜单里的悬停说明。系统 toolTip 只在 App 处于激活状态时显示，而桌宠窗口是
// NonactivatingPanel，右键弹菜单时前台通常还是终端，于是说明时有时无。这里自己画一个
// 浮窗，不依赖激活状态。
@interface MenuHint : NSObject
// 悬停一段时间后在 rect（屏幕坐标）下方显示 text；刚显示过别的说明时立即显示。
+ (void)scheduleText:(NSString *)text belowScreenRect:(NSRect)rect;
+ (void)cancel;
@end

// 菜单自绘行。设置 hint 后，鼠标停在行内任意位置（包括其中的开关）都会显示说明。
@interface MenuHintRowView : NSView
@property(nonatomic, copy) NSString *hint;
@end
