#import <Cocoa/Cocoa.h>

// 包装脚本在 Agent 启动时固定下来的终端身份。Hook 子进程继承这些环境变量，
// 因此任务结束时即使用户已经切到别的应用，也不会把目标错记成当前前台窗口。
NSDictionary *TerminalFocusTargetFromEnvironment(void);

// Terminal / iTerm2 按 TTY 精确选中 tab/session；其他终端在无扩展模式下激活应用。
BOOL ActivateTerminalFocusTarget(NSDictionary *target);

// 供包装脚本在 exec Agent 之前捕获承载终端的应用。
NSString *FrontmostApplicationBundleIdentifier(void);
