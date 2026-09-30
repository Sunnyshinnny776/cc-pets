#import <Cocoa/Cocoa.h>

// 包装脚本在 Agent 启动时固定下来的终端身份。Hook 子进程继承这些环境变量，
// 因此任务结束时即使用户已经切到别的应用，也不会把目标错记成当前前台窗口。
// 由 Codex 共享服务（app-server --managed-daemon）拉起的 hook 返回空目标，见实现处注释。
NSDictionary *TerminalFocusTargetFromEnvironment(void);
BOOL TerminalFocusRunsUnderSharedAgentHost(void);

// hook 用：普通情况同 TerminalFocusTargetFromEnvironment；Codex 共享服务下按会话 ID 找
// codex-with-pet 登记的终端，找不到返回空目标。
NSDictionary *TerminalFocusTargetForHook(NSDictionary *payload, NSString *provider);
// cc-pets --codex-launch：codex-with-pet 在 exec 真正的 codex 之前登记自己的终端。
int RegisterCodexLaunch(void);
// 以下两个供测试直接驱动。
BOOL RegisterCodexLaunchForProcess(pid_t pid, NSString *cwd, NSDictionary *terminal,
    NSTimeInterval launchedAt);
NSDictionary *CodexLaunchTerminalForThread(NSString *thread, NSDictionary *payload);

// Terminal / iTerm2 按 TTY 精确选中 tab/session；其他终端在无扩展模式下激活应用。
BOOL ActivateTerminalFocusTarget(NSDictionary *target);

// 回跳目标的候选 bundle ID，按优先级排列，已去重去空。
NSArray<NSString *> *TerminalFocusBundleCandidates(NSDictionary *target);

// 供包装脚本在 exec Agent 之前捕获承载终端的应用。
NSString *FrontmostApplicationBundleIdentifier(void);
