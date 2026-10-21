// QuotaDashboardView 各个 category 共用的布局常量、私有属性和跨文件调用的方法。
#import "QuotaDashboardView.h"
#import "CCPetsL10n.h"
#import "CCPetsUsageMode.h"

// 面板高度按"检测到几家 CLI"变化，所以纵向布局不再是一堆绝对坐标，而是自上而下的分段：
// 标题区 → 汇总条 → N × 额度卡，块之间统一留 QuotaBlockGap。
// QuotaLogicalHeight 保留为两家都装时的高度（590），既是历史默认值，也是预览图尺寸。
static const CGFloat QuotaHeaderHeight = 106;
static const CGFloat QuotaSummaryHeight = 112;
static const CGFloat QuotaBaseCardHeight = 152;
static const CGFloat QuotaBlockGap = 12;
// 原脚注区占用 44px；保留 12px 外边距，其余空间平均分给可见卡片。
static const CGFloat QuotaReclaimedFooterHeight = 32;
static const CGFloat QuotaBottomPadding = 12;
static const CGFloat QuotaCarouselDotGap = 18;
static const CGFloat QuotaCarouselDotDiameter = 8;
// 两家都没装时的精简态：只留标题区、三行说明和脚注，汇总条和额度卡整块去掉——
// 没有 provider 的"今日用量/近 7 天"是两行 0，比不显示更让人以为是坏了。
static const CGFloat QuotaEmptyNoticeHeight = 76;

static inline CGFloat QuotaCardHeightForProviderCount(NSUInteger count) {
    return count > 0 ? QuotaBaseCardHeight + QuotaReclaimedFooterHeight / count
        : QuotaBaseCardHeight;
}

@interface QuotaDashboardView ()
@property NSMutableDictionary<NSString *, NSString *> *selectedProfileIDs;
@property(copy) NSString *activeCarouselProvider;
@property NSTimeInterval lastCarouselSwitchAt;
@property(copy) NSString *animatingCarouselProvider;
@property NSTimeInterval carouselAnimationStartedAt;
@property NSInteger carouselAnimationDirection;
@property(copy) NSString *dragCarouselProvider;
@property NSPoint dragCarouselStartPoint;
@property BOOL dragCarouselDidSwitch;
@property(copy) NSString *scrollCarouselProvider;
@property CGFloat scrollCarouselAccumulator;
@property BOOL scrollCarouselDidSwitch;

// 主文件里实现、绘图 category 也要用的方法。
- (NSArray<NSDictionary *> *)profilesForProvider:(NSString *)name;
- (NSDictionary *)summaryUsageForProvider:(NSString *)name;
- (NSString *)displayNameForProvider:(NSString *)name;
- (NSUInteger)selectedIndexForProvider:(NSString *)name;
- (NSRect)logicalSummaryRect;
- (NSRect)logicalSummaryCellRectAtIndex:(NSUInteger)index;
- (NSDictionary *)quota:(NSDictionary *)usage key:(NSString *)key;
- (NSDictionary *)tokenTotals:(NSDictionary *)usage key:(NSString *)key;
- (NSString *)formattedTokenValue:(double)value;
- (NSString *)formattedTokenCount:(NSDictionary *)totals;
- (NSString *)formattedRequestCount:(NSDictionary *)totals;
- (NSDictionary *)comparisonForCurrent:(double)current previous:(double)previous
    color:(NSColor *)color;
- (NSString *)formattedTokenSplit:(NSDictionary *)totals wantsOutput:(BOOL)wantsOutput;
- (NSString *)resetText:(NSDictionary *)quota showDate:(BOOL)showDate;
- (NSString *)recentWeekUsageLabel;
- (NSDictionary *)accountStateForProvider:(NSString *)name profile:(NSDictionary *)profile usage:(NSDictionary *)usage;
@end

// 绘图基础：配色、文字排版、系统指标、圆角块和用量曲线。
@interface QuotaDashboardView (Primitives)
- (NSColor *)primaryColor;
- (NSColor *)secondaryColor;
- (NSColor *)claudeColor;
- (NSColor *)accentColor;
- (NSColor *)agentStatusColor;
- (void)drawSystemMetricsEndingAtX:(CGFloat)rightEdge y:(CGFloat)y;
- (NSString *)formattedTokenSplitForUsage:(NSDictionary *)usage key:(NSString *)key
    wantsOutput:(BOOL)wantsOutput;
- (NSNumber *)usedForQuota:(NSDictionary *)quota usedKey:(NSString *)usedKey;
- (NSString *)refreshAgeText;
- (NSFont *)fontWithSize:(CGFloat)size weight:(NSFontWeight)weight;
- (void)drawText:(NSString *)text inRect:(NSRect)rect size:(CGFloat)size
    weight:(NSFontWeight)weight color:(NSColor *)color dotColor:(NSColor *)dotColor;
- (NSDictionary *)attributes:(NSDictionary *)attributes fittingText:(NSString *)text
    inWidth:(CGFloat)width;
- (void)drawTip:(NSString *)text inRect:(NSRect)rect color:(NSColor *)color;
- (void)fillLiquidScrim:(NSBezierPath *)path;
- (NSColor *)textColor:(NSColor *)color;
- (NSDictionary *)textAttributesWithSize:(CGFloat)size color:(NSColor *)color weight:(NSFontWeight)weight;
- (NSDictionary *)rightAlignedTextAttributesWithSize:(CGFloat)size color:(NSColor *)color
    weight:(NSFontWeight)weight;
- (NSDictionary *)centeredTextAttributesWithSize:(CGFloat)size color:(NSColor *)color weight:(NSFontWeight)weight;
- (void)fillRoundedRect:(NSRect)rect radius:(CGFloat)radius color:(NSColor *)color;
- (NSArray<NSDictionary *> *)curvePointsFromHistory:(NSArray<NSDictionary *> *)history
    currentUsed:(NSNumber *)currentUsed;
- (void)appendCurveFromPoint:(NSPoint)from toPoint:(NSPoint)to path:(NSBezierPath *)path;
- (void)drawCurveSegment:(NSArray<NSValue *> *)segment inRect:(NSRect)rect color:(NSColor *)color;
- (void)drawUsageCurve:(NSArray<NSDictionary *> *)points inRect:(NSRect)rect
    color:(NSColor *)color;
- (void)drawMonthlyTokenCurve:(NSArray<NSDictionary *> *)series inRect:(NSRect)rect
    color:(NSColor *)color;
@end

// 卡片、汇总条和整块面板的绘制。
@interface QuotaDashboardView (Rendering)
- (void)drawProvider:(NSString *)name displayName:(NSString *)displayName
    usage:(NSDictionary *)usage usedKey:(NSString *)usedKey color:(NSColor *)color
    cardRect:(NSRect)card profileCount:(NSUInteger)profileCount selectedIndex:(NSUInteger)selectedIndex;
- (void)drawSummaryForProviders:(NSArray<NSString *> *)providers primary:(NSColor *)primary
    secondary:(NSColor *)secondary accent:(NSColor *)cyan;
@end
