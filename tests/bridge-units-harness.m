#import <Foundation/Foundation.h>
#import "CCPetsBridgeCore.h"
#import "CCPetsBridgeSetup.h"
#import "CCPetsBridgeStore.h"
#import "CCPetsCLISupport.h"
#import <signal.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

// CC Bridge 里不经过进程边界的纯逻辑：文件预留的模式匹配、编辑文件提取、选项解析、codex queue 探测。
// 端到端行为（hook、watcher、MCP、安装）见 bridge-harness.mjs。
// 参数：<临时目录>，用来放假的 codex 可执行文件。

static int failures = 0;

static void Check(BOOL condition, NSString *message) {
    if (condition) return;
    fprintf(stderr, "bridge-units: %s\n", message.UTF8String);
    failures++;
}

static NSString *WriteScript(NSString *directory, NSString *name, NSString *body) {
    NSString *path = [directory stringByAppendingPathComponent:name];
    [body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:path error:nil];
    return path;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *temporary = argc > 1 ? @(argv[1]) : NSTemporaryDirectory();

        // 模式匹配：** 可匹配零层目录；不带通配符的模式覆盖整个目录；方括号按字面匹配。
        Check(CCBridgePatternMatches(@"src/**/*.ts", @"src/a.ts"), @"src/**/*.ts 应匹配 src/a.ts");
        Check(CCBridgePatternMatches(@"src/**/*.ts", @"src/x/y.ts"), @"src/**/*.ts 应匹配 src/x/y.ts");
        Check(!CCBridgePatternMatches(@"src/**/*.ts", @"srcx/a.ts"), @"src/**/*.ts 不应匹配 srcx/a.ts");
        Check(CCBridgePatternMatches(@"src/api", @"src/api/user.ts"), @"不带通配符的目录应覆盖其下所有文件");
        Check(CCBridgePatternMatches(@"src/api", @"src/api"), @"不带通配符的模式应匹配自身");
        Check(!CCBridgePatternMatches(@"src/api", @"src/apix"), @"src/api 不应匹配 src/apix");
        Check(CCBridgePatternMatches(@"a[1].ts", @"a[1].ts"), @"方括号按字面匹配");
        Check(CCBridgePatternMatches(@"src/?.ts", @"src/a.ts") && !CCBridgePatternMatches(@"src/?.ts", @"src/a/b.ts"), @"? 只匹配一个非 / 字符");
        Check(!CCBridgePatternsOverlap(nil, @"src/api/**", @"src/web/**"), @"不相交的目录不应重叠");
        Check(CCBridgePatternsOverlap(nil, @"src/**/*.ts", @"src/api/*"), @"两个 glob 能匹配同一路径时应重叠");
        Check(CCBridgePatternsOverlap(nil, @"src/api/user.ts", @"src/api/**"), @"具体路径落在 glob 里应重叠");
        Check(CCBridgePatternsOverlap(nil, @"src/api", @"src/**/*.ts"), @"目录与其下文件的 glob 应重叠");
        Check(CCBridgePatternsOverlap(nil, @"src/**/*.ts", @"src/api"), @"重叠判断应与参数顺序无关");
        Check(CCBridgePatternsOverlap(nil, @"src", @"src/api/x.ts"), @"目录应覆盖其下的具体文件");
        Check(CCBridgePatternsOverlap(nil, @"**", @"anything/at/all"), @"** 应覆盖一切");
        Check(!CCBridgePatternsOverlap(nil, @"src/api", @"src/apix/**"), @"相同前缀的不同目录不应重叠");
        Check(!CCBridgePatternsOverlap(nil, @"src/*.ts", @"src/api"), @"单层 * 进不了子目录");
        Check(!CCBridgePatternsOverlap(nil, @"src/*.ts", @"src/*.js"), @"后缀不同的 glob 不应重叠");
        Check(!CCBridgePatternsOverlap(nil, @"src/?.ts", @"src/ab.ts"), @"? 只匹配一个字符");
        NSString *overlapRoot = [temporary stringByAppendingPathComponent:@"overlap"];
        [NSFileManager.defaultManager createDirectoryAtPath:[overlapRoot stringByAppendingPathComponent:@"src"]
            withIntermediateDirectories:YES attributes:nil error:nil];
        [@"x" writeToFile:[overlapRoot stringByAppendingPathComponent:@"src/a.md"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Check(!CCBridgePatternsOverlap(overlapRoot, @"src/a.md", @"src/**/*.ts"), @"确认是普通文件时不算它下面的路径");
        Check(CCBridgePatternsOverlap(nil, @"src/a.md", @"src/**/*.ts"), @"不知道是文件还是目录时宁可多报");

        // 进程识别：argv 保留边界，路径里的空格不影响判断；其余参数里出现 claude 不算。
        Check(CCBridgeArgumentsMatchProvider(@"Claude", @[@"/Users/x/Library/Application Support/Claude/claude-code/1.0/claude", @"--resume"]),
            @"路径含空格的 claude 应被识别");
        Check(CCBridgeArgumentsMatchProvider(@"Claude", @[@"node", @"/opt/my tools/node_modules/@anthropic-ai/claude-code/cli.js"]),
            @"脚本路径含空格的 npm 版 claude 应被识别");
        Check(!CCBridgeArgumentsMatchProvider(@"Claude", @[@"/usr/bin/tmux", @"new-session", @"claude"]), @"参数里的 claude 不算");
        NSString *spacedDirectory = [temporary stringByAppendingPathComponent:@"Application Support"];
        [NSFileManager.defaultManager createDirectoryAtPath:spacedDirectory withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *spacedClaude = [spacedDirectory stringByAppendingPathComponent:@"claude"];
        [NSFileManager.defaultManager removeItemAtPath:spacedClaude error:nil];
        [NSFileManager.defaultManager createSymbolicLinkAtPath:spacedClaude withDestinationPath:@"/bin/sleep" error:nil];
        // 用 posix_spawn 而不是 NSTask：要让 argv[0] 就是这个带空格的路径，和 CLI 被直接启动时一样。
        char *spacedArguments[] = {(char *)spacedClaude.fileSystemRepresentation, "30", NULL};
        pid_t spacedHost = 0;
        if (posix_spawn(&spacedHost, spacedClaude.fileSystemRepresentation, NULL, NULL, spacedArguments, environ) == 0) {
            NSArray<NSString *> *arguments = nil;
            for (int attempt = 0; attempt < 100; attempt++) {
                arguments = CCBridgeProcessArguments(spacedHost);
                if ([arguments.firstObject hasSuffix:@"claude"]) break;
                usleep(10000);
            }
            Check([arguments.firstObject isEqualToString:spacedClaude], @"argv[0] 应保留路径里的空格");
            Check(CCBridgeSessionLive(@{@"provider": @"Claude", @"pid": @(spacedHost)}), @"路径含空格的宿主应算在线");
            kill(spacedHost, SIGKILL);
            waitpid(spacedHost, NULL, 0);
        } else {
            Check(NO, @"无法启动路径含空格的假宿主");
        }

        // 路径规范化：相对路径按当前目录解析；越出仓库根拒绝；末尾斜杠去掉；仓库根本身即 **。
        Check([CCBridgeNormalizePattern(@"/repo", @"/repo/sub", @"../x.ts") isEqualToString:@"x.ts"], @"../x.ts 应解析到仓库根下");
        Check(CCBridgeNormalizePattern(@"/repo", @"/repo", @"../outside.ts") == nil, @"越出仓库根应拒绝");
        Check(CCBridgeNormalizePattern(@"/repo", @"/repo", @"/etc/passwd") == nil, @"仓库外的绝对路径应拒绝");
        Check([CCBridgeNormalizePattern(@"/repo", @"/repo", @"/repo/src/") isEqualToString:@"src"], @"末尾斜杠应去掉");
        Check([CCBridgeNormalizePattern(@"/repo", @"/repo/a", @"..") isEqualToString:@"**"], @"仓库根本身应规范为 **");
        Check([CCBridgeNormalizePattern(@"/repo", @"/repo", @"src/**") isEqualToString:@"src/**"], @"glob 应原样保留");
        Check(CCBridgeNormalizePattern(@"/repo", @"/repo", @"   ") == nil, @"空路径应拒绝");

        // 软链：会话路径经过软链时也要和 git 给的物理路径对上；新文件和 glob 的尾部不存在，原样保留。
        NSFileManager *files = NSFileManager.defaultManager;
        NSString *physical = [CCPetsRealPath(temporary) stringByAppendingPathComponent:@"links/real"];
        NSString *linked = [CCPetsRealPath(temporary) stringByAppendingPathComponent:@"links/alias"];
        [files removeItemAtPath:[physical stringByDeletingLastPathComponent] error:nil];
        [files createDirectoryAtPath:[physical stringByAppendingPathComponent:@"src"] withIntermediateDirectories:YES attributes:nil error:nil];
        [files createSymbolicLinkAtPath:linked withDestinationPath:physical error:nil];
        [files createSymbolicLinkAtPath:[physical stringByAppendingPathComponent:@"inner"] withDestinationPath:@"src" error:nil];
        [files createSymbolicLinkAtPath:[physical stringByAppendingPathComponent:@"escape"] withDestinationPath:@"/etc" error:nil];
        Check([CCBridgeNormalizePattern(physical, linked, @"src/new.ts") isEqualToString:@"src/new.ts"], @"相对路径经过软链时应落回仓库内");
        Check([CCBridgeNormalizePattern(physical, physical, [linked stringByAppendingPathComponent:@"src/new.ts"]) isEqualToString:@"src/new.ts"],
            @"绝对路径经过软链时应落回仓库内");
        Check([CCBridgeNormalizePattern(physical, linked, [linked stringByAppendingPathComponent:@"src/**"]) isEqualToString:@"src/**"],
            @"经过软链的 glob 应保留通配符");
        Check([CCBridgeNormalizePattern(linked, linked, @"inner/new.ts") isEqualToString:@"src/new.ts"], @"仓库内的软链目录应解析到实际位置");
        Check(CCBridgeNormalizePattern(physical, physical, @"escape/passwd") == nil, @"软链指向仓库外应算越界");
        [files createDirectoryAtPath:[physical stringByAppendingPathComponent:@"src/sub"] withIntermediateDirectories:YES attributes:nil error:nil];
        [files createSymbolicLinkAtPath:[physical stringByAppendingPathComponent:@"deep"] withDestinationPath:@"src/sub" error:nil];
        Check([CCBridgeNormalizePattern(physical, physical, @"deep/../a.ts") isEqualToString:@"src/a.ts"], @".. 应在解析软链之后处理");
        Check([CCBridgeNormalizePattern(physical, physical, @"new/../src/a.ts") isEqualToString:@"src/a.ts"], @"不存在的目录按字面处理 ..");
        Check([CCBridgeRepoRoot(linked) isEqualToString:physical], @"非 git 目录的仓库根也应是物理路径");

        // 编辑文件提取：Claude 的 file_path；Codex 补丁正文（字段名不固定，整段做文本匹配）。
        Check([CCBridgeEditedFiles(@{@"file_path": @"/repo/a.ts", @"old_string": @"x"}) isEqualToArray:@[@"/repo/a.ts"]],
            @"应取出 file_path");
        NSArray *patched = [CCBridgeEditedFiles(@{@"input": @"*** Begin Patch\n*** Update File: src/a.ts\n@@\n*** Add File: src/b.ts\n*** End Patch"})
            sortedArrayUsingSelector:@selector(compare:)];
        Check([patched isEqualToArray:@[@"src/a.ts", @"src/b.ts"]], @"应从补丁里取出新增与修改的文件");
        Check([CCBridgeEditedFiles(@"*** Delete File: /repo/c.ts\n*** Move to: /repo/d.ts") isEqualToArray:@[@"/repo/c.ts", @"/repo/d.ts"]],
            @"字符串形式的补丁也要能取出删除与移动的文件");
        Check([CCBridgeEditedFiles(@{@"command": @"*** Add File: /a/b/c.ts\n+x"}) isEqualToArray:@[@"/a/b/c.ts"]],
            @"路径里的 / 不能被转义成 \\/");

        Check([CCBridgeEditedFiles(@{@"file_path": @"/repo/guide.md", @"content": @"示例：\n*** Update File: src/other.ts\n"})
            isEqualToArray:@[@"/repo/guide.md"]], @"写入内容里的补丁文本不算编辑对象");

        // 选项：分组展开、按定义顺序去重、未知工具报错、开关只认 on / off 系列、合并时未给的保持原值。
        NSString *error = nil;
        Check([CCBridgeParseToolList(@"send_message,view", @"--x", &error)
            isEqualToArray:(@[@"list_agents", @"list_reservations", @"check_inbox", @"send_message"])], @"分组应展开并按定义顺序排列");
        Check([CCBridgeParseToolList(@"", @"--x", &error) isEqualToArray:@[]], @"空字符串表示清空");
        error = nil;
        Check(CCBridgeParseToolList(@"rm_rf", @"--x", &error) == nil && [error containsString:@"只接受分组"], @"未知工具应报错");
        error = nil;
        Check(CCBridgeParseSwitch(@"maybe", @"--wake", &error) == nil && [error containsString:@"on / off"], @"非法开关值应报错");
        Check([CCBridgeParseSwitch(@" OFF ", @"--wake", &error) isEqual:@NO], @"开关值不区分大小写");
        NSDictionary *merged = CCBridgeMergeOptionFlags(@{@"codexApprove": @[@"set_name"], @"wake": @YES, @"editGuard": @YES},
            @{@"wake": @"off"}, &error);
        Check([merged[@"codexApprove"] isEqualToArray:@[@"set_name"]], @"未给出的选项保持原值");
        Check([merged[@"wake"] isEqual:@NO], @"给出的选项应生效");
        Check([CCBridgeMergeOptionFlags(@{}, @{@"approve": @"send"}, &error)[@"claudeAllow"] isEqualToArray:@[@"send_message"]],
            @"--approve 应同时作用于两边");

        // codex queue 探测：新版支持、旧版把 queue 当成交互参数打出总帮助、找不到可执行文件。
        NSString *supported = WriteScript(temporary, @"codex-new",
            @"#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo \"codex-cli 9.9.9\"; exit 0; fi\n"
             "if [ \"$1\" = \"queue\" ]; then echo \"Usage: codex queue [OPTIONS] --thread <THREAD> --message <TEXT>\"; exit 0; fi\nexit 1\n");
        NSDictionary *probe = CCBridgeProbeCodexQueue(supported);
        Check([probe[@"status"] isEqual:@"supported"] && [probe[@"version"] isEqual:@"codex-cli 9.9.9"], @"新版 codex 应判为支持");
        Check(CCBridgeDescribeCodexQueue(probe) == nil, @"支持时不应给出提示");
        NSString *old = WriteScript(temporary, @"codex-old",
            @"#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo \"codex-cli 0.100.0\"; exit 0; fi\n"
             "echo \"Codex CLI\"\necho \"If no subcommand is specified, options will be forwarded to the interactive CLI.\"\nexit 0\n");
        probe = CCBridgeProbeCodexQueue(old);
        Check([probe[@"status"] isEqual:@"unsupported"], @"旧版 codex 应判为不支持");
        NSString *notice = CCBridgeDescribeCodexQueue(probe);
        Check([notice containsString:@"codex-cli 0.100.0"] && [notice containsString:@"不支持 codex queue"], @"不支持时应说明版本与原因");
        probe = CCBridgeProbeCodexQueue([temporary stringByAppendingPathComponent:@"no-such-codex"]);
        Check([probe[@"status"] isEqual:@"missing"] && [CCBridgeDescribeCodexQueue(probe) containsString:@"CODEX_REAL_BIN"],
            @"找不到 codex 时应提示设置 CODEX_REAL_BIN");

        // 会话名：统一小写；非法字符拒绝；最长 40。
        Check([CCBridgeNormalizeSessionName(@" Frontend ") isEqualToString:@"frontend"], @"名字应去空白并转小写");
        Check(CCBridgeNormalizeSessionName(@"bad name [x]") == nil, @"带空格和方括号的名字应拒绝");
        Check(CCBridgeNormalizeSessionName([@"" stringByPaddingToLength:41 withString:@"a" startingAtIndex:0]) == nil, @"超过 40 个字符应拒绝");
        // 状态卡短名：只去掉默认名字开头的账号段，自定义名字原样保留。
        Check([CCBridgeSessionShortName(@{@"name": @"claude.cc-pets.crab", @"provider": @"Claude", @"nameSource": @"generated"}) isEqualToString:@"cc-pets.crab"],
            @"默认名字应去掉 provider 账号段");
        Check([CCBridgeSessionShortName(@{@"name": @"work-acct.cc-pets.crab", @"provider": @"Claude", @"profileName": @"Work Acct", @"nameSource": @"generated"})
            isEqualToString:@"cc-pets.crab"], @"多账号时应去掉账号名段");
        Check([CCBridgeSessionShortName(@{@"name": @"frontend", @"provider": @"Codex"}) isEqualToString:@"frontend"],
            @"自定义名字应原样保留");
        Check([CCBridgeSessionShortName(@{@"name": @"claude.", @"provider": @"Claude"}) isEqualToString:@"claude."] &&
            [CCBridgeSessionShortName(@{@"provider": @"Claude"}) isEqualToString:@""], @"去掉账号段后不能变空；没有名字返回空串");
        Check(CCBridgeSafeSessionId(@"../../evil") == nil && CCBridgeSafeSessionId(@"..") == nil, @"路径穿越的 session id 应拒绝");
        Check([CCBridgeSafeSessionId(@"11111111-aaaa-4bbb-8ccc-000000000001") length] > 0, @"UUID 应放行");
    }
    if (failures > 0) return EXIT_FAILURE;
    puts("bridge-units: all passed");
    return EXIT_SUCCESS;
}
