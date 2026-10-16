#import <Cocoa/Cocoa.h>

// 主窗口页面共用的"分组卡片表单"：可滚动的竖向列表，每组是一个彩色图标 + 标题，下面一张圆角卡片，
// 卡片里的行之间有分隔线（和系统设置一个样子）。设置页、诊断页都用它，卡片样式只此一份。
//
// 它只管排版和按分组滚动，不碰任何设置或数据；控件怎么绑定由页面自己决定。
@interface CCPetsFormBuilder : NSObject

// 放进页面里的滚动视图。
@property(nonatomic, readonly) NSScrollView *scrollView;
// 竖向堆叠容器；页面想在分组之外加东西（页头、提示）时直接往里加。
@property(nonatomic, readonly) NSStackView *stack;
// 已添加的分组：id、title、symbol、color，用于 CCPetsMainPageSections。
@property(nonatomic, readonly) NSArray<NSDictionary *> *sectionEntries;

// 一行：左边标题，右边一组控件。
+ (NSView *)rowWithTitle:(NSString *)title controls:(NSArray<NSView *> *)controls;

// 添加一个分组。sectionID 用于滚动定位；rows 之间自动加分隔线；footer 是卡片下方的小字说明。
// 返回分组标题行。
- (NSView *)addSectionWithID:(NSString *)sectionID title:(NSString *)title symbol:(NSString *)symbol
    color:(NSColor *)color rows:(NSArray<NSView *> *)rows footer:(NSString *)footer;

// 清空所有分组，用于页面重新加载内容。
- (void)removeAllSections;

// sectionID 为 nil 回到顶部。
- (void)scrollToSectionWithID:(NSString *)sectionID;

@end
