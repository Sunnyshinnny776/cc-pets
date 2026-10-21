#import <Cocoa/Cocoa.h>
#import "CCPetsUsageShared.h"

// 每日柱状图：横轴是天，纵轴是当前指标。"全部模型"时每根柱子按模型分色堆叠（用量大的在下），
// 只看一个模型时就是这个模型自己的颜色。鼠标移上去在柱子旁浮出当天的明细。
@interface CCPetsUsageChartView : NSView
// 每天零点的时间戳。
@property(nonatomic, copy) NSArray<NSNumber *> *days;
// 自下而上的堆叠层。每项：title、color、values（每天的指标值）、counts（每天的四栏，单模型明细用）。
@property(nonatomic, copy) NSArray<NSDictionary *> *series;
@property(nonatomic) UsageMetric metric;
// 只看一个模型：悬停明细列这个模型的各栏，而不是各模型。
@property(nonatomic) BOOL singleModel;
- (void)reloadData;
@end
