#import <Cocoa/Cocoa.h>

// 主窗口每一页的骨架：顶部页头（标题、一句副标题、右侧控件），下面是可滚动的竖向内容。
// 内容按「分组标题 + 圆角卡片」排，卡片里的行之间有分隔线。所有页面共用这一份，样式只此一处。
//
// 它只管排版，不碰任何设置或数据；控件怎么绑定由页面自己决定。
@interface CCPetsFormBuilder : NSObject

- (instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle;

// 整页：页头 + 滚动区。页面把它设成自己的 view。
@property(nonatomic, readonly) NSView *view;
@property(nonatomic, readonly) NSScrollView *scrollView;
// 竖向堆叠的内容；页面想放分组以外的东西（指标条、图表卡片）时直接往里加，宽度会被拉满。
@property(nonatomic, readonly) NSStackView *stack;
// 副标题会随数据变（"4 个在线 · 今天 6 条消息"），页面直接改它。
@property(nonatomic, readonly) NSTextField *subtitleLabel;

// 页头右侧的控件（分段控件、按钮），从左到右排。
- (void)setAccessoryViews:(NSArray<NSView *> *)views;

// 一行：左边标题（可带一行灰色说明），右边一组控件。
+ (NSView *)rowWithTitle:(NSString *)title controls:(NSArray<NSView *> *)controls;
+ (NSView *)rowWithTitle:(NSString *)title subtitle:(NSString *)subtitle controls:(NSArray<NSView *> *)controls;
// 卡片里的分隔线，行与行之间自动加；自己拼卡片时也可以用。
+ (NSView *)separator;

// 分组标题；note 是标题右边的灰色小字，可为 nil。
- (void)addGroupTitle:(NSString *)title note:(NSString *)note;
// 同上，info 非空时标题后面带一个 ⓘ 角标，悬停显示 info。
- (void)addGroupTitle:(NSString *)title note:(NSString *)note info:(NSString *)info;
// 一张卡片，rows 之间自动加分隔线。title 非 nil 时先加分组标题；footer 是卡片下方的小字。
// 返回卡片。
- (NSView *)addGroupWithTitle:(NSString *)title rows:(NSArray<NSView *> *)rows footer:(NSString *)footer;
// 拉满宽度加到内容里。
- (void)addView:(NSView *)view;
// 卡片下方那种灰色小字。
- (NSTextField *)addFootnote:(NSString *)text;
// 清空内容（页头不动），用于页面整体重排。
- (void)removeAllContent;

@end
