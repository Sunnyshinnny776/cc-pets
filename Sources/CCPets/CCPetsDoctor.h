#import <Foundation/Foundation.h>

// `cc-pets paths [--json]` 与 `cc-pets doctor`。
//
// 两者都只读：不改任何配置、不拉起桌宠。输出常被贴进 issue，所以 home 一律显示成 `~`，
// 不打印 status line 原命令、会话内容或 token。
//
// arguments 以子命令开头（"paths" / "doctor"）。返回进程退出码：doctor 有错误项时为 1。
int CCPetsDoctorMain(NSArray<NSString *> *arguments);

// doctor 的检查结果，`cc-pets doctor` 与主窗口诊断页同源：
// @[@{title, results: @[@{level: ok | warn | fail | info, title, fix?}]}]，fix 是建议执行的命令。
// 会读 Claude / Codex 配置、探测 CLI 与 codex queue，可能耗时数百毫秒，不要放在主线程。
NSArray<NSDictionary *> *CCPetsDoctorSections(void);
// 完整报告文本（标题行、各节、汇总），与 `cc-pets doctor` 的标准输出逐字一致，不含末尾换行。
// 诊断页的"复制报告"用它；和 CLI 一样把 home 显示成 `~`，可以直接贴进 issue。
NSString *CCPetsDoctorReport(NSArray<NSDictionary *> *sections);
// 有 fail 级别的项。`cc-pets doctor` 据此以 1 退出。
BOOL CCPetsDoctorHasFailures(NSArray<NSDictionary *> *sections);
