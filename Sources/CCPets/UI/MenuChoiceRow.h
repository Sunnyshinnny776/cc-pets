#import <Cocoa/Cocoa.h>

// 菜单里的单选行。普通 NSMenuItem 点完菜单就收起，想连着对比几个档位就得反复右键；
// 自绘行视图收到点击时菜单不会关闭。同一 group 的行互斥勾选，点击后同一菜单里所有行
// 重新计算 enabledHandler，让「切到经典主题后压暗档位置灰」这类联动当场生效。
@interface MenuChoiceRowView : NSView
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *group;
@property(nonatomic) BOOL checked;
@property(nonatomic) BOOL enabled;
@property(nonatomic) CGFloat indentation;
@property(nonatomic, strong) id representedObject;
@property(nonatomic, weak) id target;
@property(nonatomic) SEL action;
@property(nonatomic, copy) BOOL (^enabledHandler)(void);
+ (NSMenuItem *)addToMenu:(NSMenu *)menu title:(NSString *)title group:(NSString *)group
    representedObject:(id)representedObject checked:(BOOL)checked
    target:(id)target action:(SEL)action width:(CGFloat)width;
@end
