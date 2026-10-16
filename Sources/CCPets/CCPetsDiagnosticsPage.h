#import <Cocoa/Cocoa.h>

// 主窗口的「诊断」页：渲染 `cc-pets doctor` 的同一份检查结果（CCPetsDoctorSections）。
//
// 检查要读配置、探测 CLI，放在后台队列做，页面只在显示时创建并检查一次；之后只有点"重新检查"才再跑，
// 不开定时器。v1 只读：修复建议给出命令让用户自己复制执行，不在这里改 shell / 配置。
@interface CCPetsDiagnosticsPage : NSViewController
@end
