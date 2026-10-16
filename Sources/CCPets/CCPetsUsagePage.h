#import <Cocoa/Cocoa.h>

// 主窗口的「用量」页：按模型看本机 Claude Code / Codex 的 Token 用量，点一个模型看它每天的堆叠柱状图。
//
// 数据来自 CCPetsModelUsage（本机会话日志，不联网），在后台队列算；页面只在显示时创建，打开时算一次，
// 之后只有切换时间区间才重算，不开定时器。图表自绘，不用 Swift Charts。
@interface CCPetsUsagePage : NSViewController
@end
