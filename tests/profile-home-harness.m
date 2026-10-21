#import <Foundation/Foundation.h>
#import "CCPetsProfiles.h"

// 添加 / 重新定位账号前的 Home 判定。实际出过的事：在「添加 Codex」里选了 ~/.claude-x，
// 因为 Claude Code 也会建 sessions/，被当成 Codex Home 登记，集成又把 Codex 的
// config.toml / hooks.json 写了进去。

static BOOL Check(BOOL condition, NSString *label) {
    if (!condition) NSLog(@"失败：%@", label);
    return condition;
}

static NSString *MakeHome(NSString *root, NSString *name, NSArray<NSString *> *files, NSArray<NSString *> *directories) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *home = [root stringByAppendingPathComponent:name];
    [manager createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *file in files) {
        [manager createFileAtPath:[home stringByAppendingPathComponent:file] contents:[NSData data] attributes:nil];
    }
    for (NSString *directory in directories) {
        [manager createDirectoryAtPath:[home stringByAppendingPathComponent:directory]
            withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return home;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) return 2;
        NSString *root = @(argv[1]);
        NSString *claude = CCPetsProfileProviderClaude, *codex = CCPetsProfileProviderCodex;
        BOOL ok = YES;

        NSString *claudeHome = MakeHome(root, @"claude", @[@"settings.json"], @[@"projects", @"sessions"]);
        ok &= Check(CCPetsProfileHomeMatchesProvider(claude, claudeHome), @"Claude Home 可以加为 Claude");
        ok &= Check(!CCPetsProfileHomeMatchesProvider(codex, claudeHome), @"带 sessions/ 的 Claude Home 不能加为 Codex");

        // 已经被装错过一次的 Claude Home：仍要能作为 Claude 加回来，也仍然不能当 Codex。
        NSString *polluted = MakeHome(root, @"claude-polluted", @[@"settings.json", @"config.toml", @"hooks.json"],
            @[@"projects", @"sessions"]);
        ok &= Check(CCPetsProfileHomeMatchesProvider(claude, polluted), @"被写过 config.toml 的 Claude Home 仍可加为 Claude");
        ok &= Check(!CCPetsProfileHomeMatchesProvider(codex, polluted), @"被写过 config.toml 的 Claude Home 不能加为 Codex");

        NSString *codexHome = MakeHome(root, @"codex", @[@"config.toml", @"version.json"], @[@"sessions"]);
        ok &= Check(CCPetsProfileHomeMatchesProvider(codex, codexHome), @"Codex Home 可以加为 Codex");
        ok &= Check(!CCPetsProfileHomeMatchesProvider(claude, codexHome), @"Codex Home 不能加为 Claude");

        NSString *sessionsOnly = MakeHome(root, @"sessions-only", @[], @[@"sessions"]);
        ok &= Check(!CCPetsProfileHomeMatchesProvider(codex, sessionsOnly), @"只有 sessions/ 不算 Codex Home");

        NSString *empty = MakeHome(root, @"empty", @[], @[]);
        ok &= Check(!CCPetsProfileHomeMatchesProvider(claude, empty), @"空目录不算 Claude Home");
        ok &= Check(!CCPetsProfileHomeMatchesProvider(codex, empty), @"空目录不算 Codex Home");
        ok &= Check(!CCPetsProfileHomeMatchesProvider(@"gemini", claudeHome), @"未知 provider 一律拒绝");

        if (!ok) return 1;
        NSLog(@"Agent Home 判定测试通过");
    }
    return 0;
}
