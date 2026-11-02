#import <Cocoa/Cocoa.h>

// AppleScript 精确跳转的终端（终端 / iTerm2 / Ghostty）在设置页的检测结果。
// 每行：name、bundleID、version、group（@"apple" 或 @"ghostty"）、state：
//   granted        已允许 CC Pets 自动化控制
//   notDetermined  尚未询问；首次跳转时系统会弹窗
//   denied         已拒绝；跳转只能激活应用
//   notRunning     应用未运行，无法查询授权
//   unsupported    版本过低，不支持按 TTY 定位（Ghostty < 1.4）
// 未安装的终端不出现；系统自带的终端始终在。查询不会弹授权窗口，但可能短暂阻塞，在后台线程调用。
NSArray<NSDictionary *> *CCPetsTerminalIntegrationSnapshot(void);

// 主动请求自动化授权（应用需在运行，会弹系统窗口）。在后台执行，完成后在主线程回调。
void CCPetsRequestTerminalAutomation(NSString *bundleID, void (^completion)(void));

// 打开 系统设置 → 隐私与安全性 → 自动化。
void CCPetsOpenAutomationSettings(void);
