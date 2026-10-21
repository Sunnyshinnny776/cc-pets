#import <Foundation/Foundation.h>

// `cc-pets paths [--json]` 与 `cc-pets doctor`。
//
// 默认只读：不改任何配置、不拉起桌宠。显式 doctor --repair-profile <id> 会备份后修复该账号的集成。
// 输出常被贴进 issue，所以 home 一律显示成 `~`，
// 不打印 status line 原命令、会话内容或 token。
//
// arguments 以子命令开头（"paths" / "doctor"）。返回进程退出码：doctor 有错误项时为 1。
int CCPetsDoctorMain(NSArray<NSString *> *arguments);

// doctor 的检查结果，`cc-pets doctor` 与主窗口诊断页同源：
// @[@{title, results: @[@{level: ok | warn | fail | info, title, fix?, repairProfileID?}]}]。
// fix 是建议执行的命令，repairProfileID 是允许自动修复的账号；不能自动处理的问题没有这个键。
// 会读 Claude / Codex 配置、探测 CLI 与 codex queue，可能耗时数百毫秒，不要放在主线程。
NSArray<NSDictionary *> *CCPetsDoctorSections(void);
// 主窗口诊断页用的版本。检查跑在桌宠进程里，读到的 PATH 是桌宠启动那一刻继承来的（比如被 npm
// 拉起时 node 目录会插在最前），不是用户终端的 PATH；所以"shim 是否排在 PATH 最前"这一项不判对错，
// 改成一条提示，让用户在终端里跑 cc-pets doctor 确认。其余各项与 CCPetsDoctorSections() 相同。
NSArray<NSDictionary *> *CCPetsDoctorSectionsForApp(void);
// 完整报告文本（标题行、各节、汇总），与 `cc-pets doctor` 的标准输出逐字一致，不含末尾换行。
// 诊断页的"复制报告"用它；和 CLI 一样把 home 显示成 `~`，可以直接贴进 issue。
NSString *CCPetsDoctorReport(NSArray<NSDictionary *> *sections);
// 有 fail 级别的项。`cc-pets doctor` 据此以 1 退出。
BOOL CCPetsDoctorHasFailures(NSArray<NSDictionary *> *sections);
