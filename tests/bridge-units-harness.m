#import <Foundation/Foundation.h>
#import "CCPetsBridgeCore.h"
#import "CCPetsBridgeSetup.h"
#import "CCPetsBridgeStore.h"

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
        Check(!CCBridgePatternsOverlap(@"src/api/**", @"src/web/**"), @"不相交的目录不应重叠");
        Check(CCBridgePatternsOverlap(@"src/**/*.ts", @"src/api/*"), @"glob 对 glob 按前缀保守判断");
        Check(!CCBridgePatternsOverlap(@"src/a.md", @"src/**/*.ts"), @"具体路径应精确匹配");
        Check(CCBridgePatternsOverlap(@"src/api/user.ts", @"src/api/**"), @"具体路径落在 glob 里应重叠");

        // 路径规范化：相对路径按当前目录解析；越出仓库根拒绝；末尾斜杠去掉；仓库根本身即 **。
        Check([CCBridgeNormalizePattern(@"/repo", @"/repo/sub", @"../x.ts") isEqualToString:@"x.ts"], @"../x.ts 应解析到仓库根下");
        Check(CCBridgeNormalizePattern(@"/repo", @"/repo", @"../outside.ts") == nil, @"越出仓库根应拒绝");
        Check(CCBridgeNormalizePattern(@"/repo", @"/repo", @"/etc/passwd") == nil, @"仓库外的绝对路径应拒绝");
        Check([CCBridgeNormalizePattern(@"/repo", @"/repo", @"/repo/src/") isEqualToString:@"src"], @"末尾斜杠应去掉");
        Check([CCBridgeNormalizePattern(@"/repo", @"/repo/a", @"..") isEqualToString:@"**"], @"仓库根本身应规范为 **");
        Check([CCBridgeNormalizePattern(@"/repo", @"/repo", @"src/**") isEqualToString:@"src/**"], @"glob 应原样保留");
        Check(CCBridgeNormalizePattern(@"/repo", @"/repo", @"   ") == nil, @"空路径应拒绝");

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
        Check(CCBridgeSafeSessionId(@"../../evil") == nil && CCBridgeSafeSessionId(@"..") == nil, @"路径穿越的 session id 应拒绝");
        Check([CCBridgeSafeSessionId(@"11111111-aaaa-4bbb-8ccc-000000000001") length] > 0, @"UUID 应放行");
    }
    if (failures > 0) return EXIT_FAILURE;
    puts("bridge-units: all passed");
    return EXIT_SUCCESS;
}
