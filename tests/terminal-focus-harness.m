#import <Foundation/Foundation.h>
#import "CCPetsTerminalFocus.h"

// 回跳目标的身份来自两处：TERM_PROGRAM 的映射值，和包装脚本捕获的 bundleID。
// 谁优先不是风格问题——选错了点状态卡片就完全没有反应：
//
// 1. TERM_PROGRAM=vscode 是 VS Code 家族（官方 / Cursor / Windsurf / Antigravity）
//    共用的标记，映射到 com.microsoft.VSCode 对分支编辑器一律是个没在运行的
//    bundle ID，必须让捕获值排在前面。
// 2. 其余终端反过来：映射值比"启动瞬间的前台应用"可靠，捕获值只当兜底。

static BOOL CheckCandidates(NSString *name, NSDictionary *target, NSArray<NSString *> *expected) {
    NSArray<NSString *> *actual = TerminalFocusBundleCandidates(target);
    if ([actual isEqualToArray:expected]) return YES;
    NSLog(@"%@ 的候选应为 %@，实际 %@", name, expected, actual);
    return NO;
}

int main(void) {
    @autoreleasepool {
        BOOL ok = YES;
        ok &= CheckCandidates(@"Antigravity", @{
            @"tty": @"ttys003", @"program": @"vscode",
            @"bundleID": @"com.google.antigravity-ide"
        }, @[@"com.google.antigravity-ide", @"com.microsoft.VSCode"]);
        ok &= CheckCandidates(@"官方 VS Code", @{
            @"tty": @"ttys003", @"program": @"vscode",
            @"bundleID": @"com.microsoft.VSCode"
        }, @[@"com.microsoft.VSCode"]);
        // 没走包装脚本时捕获值可能是空的，映射值得继续兜住。
        ok &= CheckCandidates(@"VS Code 家族缺少捕获值", @{
            @"tty": @"ttys003", @"program": @"vscode"
        }, @[@"com.microsoft.VSCode"]);
        ok &= CheckCandidates(@"Apple Terminal", @{
            @"tty": @"ttys001", @"program": @"Apple_Terminal",
            @"bundleID": @"com.apple.Terminal"
        }, @[@"com.apple.Terminal"]);
        // JetBrains 没有统一的 TERM_PROGRAM，只剩捕获值。
        ok &= CheckCandidates(@"WebStorm", @{
            @"tty": @"ttys001", @"bundleID": @"com.jetbrains.WebStorm"
        }, @[@"com.jetbrains.WebStorm"]);
        // 映射值没在运行时要能退到捕获值，所以两个都得留在候选里。
        ok &= CheckCandidates(@"映射值与捕获值不一致", @{
            @"tty": @"ttys001", @"program": @"WarpTerminal",
            @"bundleID": @"dev.warp.Warp-Preview"
        }, @[@"dev.warp.Warp-Stable", @"dev.warp.Warp-Preview"]);
        ok &= CheckCandidates(@"空目标", @{}, @[]);
        if (!ok) return EXIT_FAILURE;
        puts("终端回跳候选优先级测试通过");
    }
    return EXIT_SUCCESS;
}
