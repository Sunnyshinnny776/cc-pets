#import <Cocoa/Cocoa.h>

// 主窗口共用的视觉部件。桌宠浮窗不用这些。

// 系统设置式的彩色图标块：圆角方块底色 + 白色 SF Symbol。size 是方块边长（pt）。
// 系统没有这个符号时只画底色，不至于留个空洞。
NSImage *CCPetsSymbolTile(NSString *symbol, NSColor *color, CGFloat size);

// 只会按"行 + 帧"循环播放精灵图的轻量视图，给主窗口里的宠物名片用。
//
// 不复用 PetView：它带着拖动挪窗口、右键菜单、全局鼠标跟随这些桌宠专属行为，放进普通窗口
// 只会互相打架。这里只有播放：窗口关闭或最小化时停表，系统开了"减弱动态效果"时停在第一帧。
@interface CCPetsSpriteView : NSView
// 精灵图与行数，布局同 PetView：每行 8 格，第 0 行是待机。
- (void)setSheet:(NSImage *)sheet rowCount:(NSInteger)rowCount;
// Agent 状态（idle / thinking / approval / tool / subagent / completed / failed …），
// 映射到和桌宠一致的动画行。行数不够的素材一律回落到待机行。
@property(nonatomic, copy) NSString *state;
@end
