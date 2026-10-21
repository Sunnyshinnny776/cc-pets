#import <Cocoa/Cocoa.h>

// 菜单里用的自绘开关。系统 NSSwitch 在 NSMenuItem 的自定义视图里对比度不足。
@interface MenuToggleSwitch : NSButton
@end

// 菜单里的用量展示模式按钮。外观接近开关，但点击后直接在两种模式间切换。
@interface MenuUsageModeButton : NSButton
@end
