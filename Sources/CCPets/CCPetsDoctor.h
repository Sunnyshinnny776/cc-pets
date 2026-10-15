#import <Foundation/Foundation.h>

// `cc-pets paths [--json]` 与 `cc-pets doctor`。
//
// 两者都只读：不改任何配置、不拉起桌宠。输出常被贴进 issue，所以 home 一律显示成 `~`，
// 不打印 status line 原命令、会话内容或 token。
//
// arguments 以子命令开头（"paths" / "doctor"）。返回进程退出码：doctor 有错误项时为 1。
int CCPetsDoctorMain(NSArray<NSString *> *arguments);
