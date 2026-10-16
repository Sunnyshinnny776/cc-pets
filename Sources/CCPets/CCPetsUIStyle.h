#import <Cocoa/Cocoa.h>

// 主窗口共用的视觉部件。桌宠浮窗不用这些。
//
// 颜色一律是动态 NSColor：在绘制或 updateLayer 时按当前外观解析，深浅色切换不用重建视图。
// 取值和设计稿（docs 里的「栖息地」方案）同一套：Mochi 青做强调色，中性色略偏冷，
// 状态色只用来表达状态，不做装饰。

// 强调色：选中、主按钮、开关。浅色 #0b8ea3，深色 #4fd3e6。
NSColor *CCPetsAccentColor(void);
// 强调色上的文字。
NSColor *CCPetsAccentInkColor(void);
// 内容区底色、卡片底色、卡片描边与分隔线。
NSColor *CCPetsBackgroundColor(void);
NSColor *CCPetsCardColor(void);
NSColor *CCPetsLineColor(void);
// 三级文字：正文、次要、提示。
NSColor *CCPetsInkColor(void);
NSColor *CCPetsSecondaryInkColor(void);
NSColor *CCPetsTertiaryInkColor(void);
// 侧边栏与列表的悬停、选中底色。
NSColor *CCPetsHoverColor(void);
NSColor *CCPetsSelectionColor(void);
// 环形进度的底轨。
NSColor *CCPetsRingTrackColor(void);
// Claude 陶土色、Codex 石墨色。只在额度卡里区分两家时用。
NSColor *CCPetsProviderColor(NSString *provider);

// 状态：work（运行中）、warn（等你处理）、ok（完成）、err（失败）、idle（空闲 / 其他）。
typedef NS_ENUM(NSInteger, CCPetsStatusKind) {
    CCPetsStatusIdle,
    CCPetsStatusWork,
    CCPetsStatusWarn,
    CCPetsStatusOK,
    CCPetsStatusError,
};
NSColor *CCPetsStatusColor(CCPetsStatusKind kind);
NSColor *CCPetsStatusBackgroundColor(CCPetsStatusKind kind);
// Agent 状态（thinking / approval / failed …）归到哪一类。
CCPetsStatusKind CCPetsStatusKindForAgentState(NSString *state);

// 图表的模型色板，8 种按固定顺序分配；slot 超出范围时是「其他」的灰。
// 顺序就是色盲安全的保证（相邻两色在三类色盲下都分得开），不要重排。
NSColor *CCPetsChartColor(NSInteger slot);
extern const NSInteger CCPetsChartColorCount;

// 常用标签。size 为 0 时用系统默认字号。
NSTextField *CCPetsLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color);
// 等宽数字：表格列、指标、刻度，数字变化时不跳动。
NSTextField *CCPetsNumberLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color);

// 会换行的标签。自动布局在宽度定下来之前只会按一行算换行标签的高度，这个标签在每次布局时
// 把实际宽度写回 preferredMaxLayoutWidth，高度才对。
NSTextField *CCPetsWrappingLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color);

// 圆角卡片：卡片底色 + 1pt 描边。内容直接 addSubview，自己排约束。
@interface CCPetsCardView : NSView
// 默认 10。
@property(nonatomic) CGFloat cornerRadius;
// 非 nil 时用它代替卡片底色（概览的宠物卡用浅青渐变的底）。
@property(nonatomic) NSColor *fillColor;
// 左侧 3pt 竖条的颜色；nil 不画。提醒行、问题列表用它表示级别。
@property(nonatomic) NSColor *stripeColor;
// 选中时描边换成强调色（宠物、主题这类卡片式单选）。
@property(nonatomic) BOOL selected;
@end

// 可点的卡片：整张卡片是一个按钮。onClick 为 nil 时不响应。
@interface CCPetsTileView : CCPetsCardView
@property(nonatomic, copy) void (^onClick)(void);
@end

// 填色胶囊按钮：悬停面板「订阅 / 用量」那种一点就切换的开关，和右键菜单里的样子一致。
@interface CCPetsPillButton : NSButton
@property(nonatomic) NSColor *fillColor;
@end

// 圆点 / 色块：图例、模型表、状态点。颜色可以是动态色，深浅色切换时自动重新解析。
@interface CCPetsColorDot : NSView
- (instancetype)initWithColor:(NSColor *)color diameter:(CGFloat)diameter;
@property(nonatomic) NSColor *color;
@end

// 1pt 的分隔线，颜色随深浅色变。高度由使用方约束。
@interface CCPetsLineView : NSView
@end

// 状态胶囊：小圆点 + 文字，底色是状态色的淡色。
@interface CCPetsChipView : NSView
- (instancetype)initWithText:(NSString *)text kind:(CCPetsStatusKind)kind;
@property(nonatomic, copy) NSString *text;
@property(nonatomic) CCPetsStatusKind kind;
// 不要圆点（比如「本周偏快」这类说明性胶囊）。
@property(nonatomic) BOOL hidesDot;
@end

// 侧边栏里的数字角标；warn 为 YES 时用提醒色。
@interface CCPetsCountBadge : NSView
@property(nonatomic) NSInteger count;
@property(nonatomic) BOOL warn;
@end

// 一排等宽的指标格：每项 @[标题, 数字, 说明]，可选第四项是提示文字——标题后面跟一个小 ⓘ，
// 鼠标悬停显示。五格同一个字号、同样的行距，说明为空也占位，三行在各格之间横向对齐；
// 第二格起左边一条贯穿整格的竖线。概览和用量页共用，两处长得一样。
NSView *CCPetsMetricRow(NSArray<NSArray<NSString *> *> *items);

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
// NO 时停在第一帧。宠物选择页里只让选中的那只动，其余静止，免得一屏几十个定时器。
@property(nonatomic) BOOL playing;
@end
