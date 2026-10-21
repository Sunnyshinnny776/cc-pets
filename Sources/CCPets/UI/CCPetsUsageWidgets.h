#import <Cocoa/Cocoa.h>

// 用量页的小部件：折行容器、图例项、模型表行、占比条。

// 自动换行的横排容器：图例项多了就折到下一行，不撑宽页面。
@interface CCPetsFlowView : NSView
@property(nonatomic) CGFloat spacing;
@property(nonatomic) CGFloat lineSpacing;
@end

// 图例项：色点 + 模型名。可点的图例就是筛选器，点了只看这个模型。
@interface CCPetsLegendItem : NSView
@property(nonatomic) BOOL dimmed;
@property(nonatomic) BOOL selected;
@property(nonatomic, copy) void (^onClick)(void);
- (instancetype)initWithTitle:(NSString *)title color:(NSColor *)color;
@end

// 模型表的一行：色块 + 模型名 + 来源，占比条，四列数字。整行可点，和图例同一个筛选。
@interface CCPetsUsageModelRow : NSView
@property(nonatomic) BOOL selected;
@property(nonatomic) BOOL dimmed;
@property(nonatomic, copy) void (^onClick)(void);
@end

// 占比条：底轨 + 模型色。
@interface CCPetsShareBar : NSView
@property(nonatomic) double fraction;
@property(nonatomic) NSColor *color;
@end
