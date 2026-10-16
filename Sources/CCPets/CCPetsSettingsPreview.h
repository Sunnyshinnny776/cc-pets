#import <Cocoa/Cocoa.h>

@class QuotaDashboardView;

// 设置页顶部的预览台：用当前桌面壁纸当底，摆一只按「宠物大小」缩放的宠物、一个说话气泡和
// 一张缩小的额度面板。主题、玻璃压暗、宠物大小、台词来源改了就当场重画，不用回桌面找效果。
//
// 玻璃要有东西透才看得出差别，所以底图用真实壁纸而不是纯色；读不到时退回渐变。
// 预览里的宠物、气泡、额度面板都是独立的视图，和桌面上那一套互不影响。
@interface CCPetsSettingsPreview : NSView
// 宠物精灵图（同 PetView 布局）与 Agent 状态。
- (void)setSheet:(NSImage *)sheet rowCount:(NSInteger)rowCount state:(NSString *)state;
// 气泡里的那句话。
@property(nonatomic, copy) NSString *bubbleText;
// 额度面板的数据由外部填（AppDelegate 照桌面那张抄一份），这里只负责摆放和主题。
@property(nonatomic, readonly) QuotaDashboardView *quotaView;
// 按当前偏好重排：宠物大小、主题、压暗。
- (void)reloadAppearance;
@end
