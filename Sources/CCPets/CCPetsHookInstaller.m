#import "CCPetsL10n.h"
#import "CCPetsHookInstaller.h"
#import "CCPetsJSON.h"
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

// 条目标记与 scripts/integration-markers.mjs 一致，卸载和 doctor 仍按那一份认领。
static NSString *const ClaudeHookMarker = @"CC_PETS_CLAUDE_AGENT_HOOK=1";
static NSString *const LegacyClaudeHookMarker = @"CLAUDE_PET_AGENT_HOOK=1";
static NSString *const CodexHookMarker = @"CC_PETS_CODEX_AGENT_HOOK=1";
static NSString *const LegacyCodexHookMarker = @"CODEX_PET_AGENT_HOOK=1";
static NSString *const StatusLineMarker = @"CC_PETS_CLAUDE_STATUS_LINE=1";
static NSString *const LegacyStatusLineMarker = @"CLAUDE_PET_STATUS_LINE=1";
static NSString *const StatusLineStartMarker = @"# >>> cc-pets-statusline >>>";
static NSString *const StatusLineEndMarker = @"# <<< cc-pets-statusline <<<";
static NSString *const CreatedStatusLineMarker = @"# CC Pets created this status line script";

static void PrintLine(FILE *stream, NSString *text) {
    fprintf(stream, "%s\n", text.UTF8String);
}

static NSString *EnvironmentValue(NSString *name) {
    NSString *value = NSProcessInfo.processInfo.environment[name];
    return value.length > 0 ? value : nil;
}

// 用 $HOME 而不是 NSHomeDirectory()：后者只看账户数据库，测试和 Node 版都靠覆盖 HOME 做隔离。
static NSString *HomeDirectory(void) {
    return EnvironmentValue(@"HOME") ?: NSHomeDirectory();
}

// 对应 Node 的 path.resolve：补成绝对路径并折叠 . 和 ..，但不碰文件系统。
// 不用 stringByStandardizingPath：它会展开 ~，还会把 /private/tmp 改写成 /tmp。
static NSString *ResolvePath(NSString *path) {
    if (![path hasPrefix:@"/"]) {
        path = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingFormat:@"/%@", path];
    }
    NSMutableArray<NSString *> *components = [NSMutableArray array];
    for (NSString *component in [path componentsSeparatedByString:@"/"]) {
        if (component.length == 0 || [component isEqualToString:@"."]) continue;
        if ([component isEqualToString:@".."]) {
            if (components.count > 0) [components removeLastObject];
            continue;
        }
        [components addObject:component];
    }
    return [@"/" stringByAppendingString:[components componentsJoinedByString:@"/"]];
}

static NSString *RealPath(NSString *path) {
    char resolved[PATH_MAX];
    if (!realpath(path.fileSystemRepresentation, resolved)) return nil;
    return [NSString stringWithUTF8String:resolved];
}

static NSString *ShellQuote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static BOOL DirectoryExists(NSString *path) {
    BOOL isDirectory = NO;
    return [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory;
}

#pragma mark - CLI 探测

// 和 scripts/detect-cli.mjs 同一套判据（那份仍供 doctor 和 CC Bridge 使用）：
// 配置目录已存在，或 PATH 里有真二进制。桌宠端的 CodexCLIDetected() 刻意忽略会话级环境变量，
// 安装器则相反，CODEX_HOME / CLAUDE_CONFIG_DIR 指向哪里就装到哪里。
//
// 不能直接 which：安装完成后 shim 目录排在 PATH 最前面，命中的是我们自己的包装器。
static BOOL HasRealExecutable(NSString *name) {
    NSString *shim = ResolvePath(EnvironmentValue(@"CC_PETS_SHIM_DIR") ?:
        [HomeDirectory() stringByAppendingPathComponent:@".cc-pets/shims"]);
    NSSet<NSString *> *wrapperNames = [NSSet setWithObjects:
        [name stringByAppendingString:@"-with-pet"], @"codex-with-pet", @"claude-with-pet", nil];
    for (NSString *entry in [NSProcessInfo.processInfo.environment[@"PATH"] ?: @"" componentsSeparatedByString:@":"]) {
        if (entry.length == 0) continue;
        NSString *resolvedEntry = RealPath(entry) ?: ResolvePath(entry);
        if ([resolvedEntry isEqualToString:shim]) continue;
        NSString *candidate = [entry stringByAppendingPathComponent:name];
        struct stat info;
        if (stat(candidate.fileSystemRepresentation, &info) != 0) continue;
        if (!S_ISREG(info.st_mode) || (info.st_mode & 0111) == 0) continue;
        NSString *real = RealPath(candidate);
        if (!real) continue;
        if ([real.stringByDeletingLastPathComponent isEqualToString:shim]) continue;
        if ([wrapperNames containsObject:real.lastPathComponent]) continue;
        return YES;
    }
    return NO;
}

// 逃生舱：探测漏判时（容器、裁剪过的 PATH、CI）可以强制安装。
static BOOL CLIForced(NSString *realBinVariable) {
    return [EnvironmentValue(@"CC_PETS_ASSUME_CLI") isEqualToString:@"1"] ||
        EnvironmentValue(realBinVariable) != nil;
}

static NSString *ClaudeHome(void) {
    return EnvironmentValue(@"CLAUDE_CONFIG_DIR") ?: [HomeDirectory() stringByAppendingPathComponent:@".claude"];
}

static NSString *CodexHome(void) {
    return EnvironmentValue(@"CODEX_HOME") ?: [HomeDirectory() stringByAppendingPathComponent:@".codex"];
}

static BOOL ClaudeCLIInstalled(void) {
    return CLIForced(@"CLAUDE_REAL_BIN") || DirectoryExists(ClaudeHome()) || HasRealExecutable(@"claude");
}

static BOOL CodexCLIInstalled(void) {
    return CLIForced(@"CODEX_REAL_BIN") || DirectoryExists(CodexHome()) || HasRealExecutable(@"codex");
}

#pragma mark - 配置读写

// 先写同目录临时文件再 rename，中途失败不会留下半份配置。临时文件一创建就是目标权限，
// 不会有一段时间以默认权限（通常 0644）暴露 settings.json 里的 token。
static BOOL WriteFileAtomically(NSString *path, NSString *text, mode_t mode, NSString **errorMessage) {
    NSString *temporaryPath = [path stringByAppendingString:@".cc-pets.tmp"];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    int descriptor = open(temporaryPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode);
    BOOL written = descriptor >= 0;
    const uint8_t *bytes = data.bytes;
    NSUInteger offset = 0;
    while (written && offset < data.length) {
        ssize_t count = write(descriptor, bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) written = NO;
        else offset += (NSUInteger)count;
    }
    int failure = written ? 0 : errno;
    if (descriptor >= 0) close(descriptor);
    if (written && rename(temporaryPath.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
        failure = errno;
        written = NO;
    }
    if (!written) {
        unlink(temporaryPath.fileSystemRepresentation);
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"%@: %s", path, strerror(failure)];
        return NO;
    }
    chmod(path.fileSystemRepresentation, mode);
    return YES;
}

// 读不到文件算空配置，读到了却解析失败要报错退出：直接覆盖会把用户的配置整个冲掉。
static CCPetsJSONObject *LoadConfig(NSString *path, NSString **errorMessage) {
    CCPetsJSONObject *config = nil;
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
        NSError *readError = nil;
        NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&readError];
        if (!data) {
            if (errorMessage) *errorMessage = readError.localizedDescription;
            return nil;
        }
        id parsed = CCPetsJSONParse(data, errorMessage);
        if (!parsed) return nil;
        if ([parsed isKindOfClass:CCPetsJSONObject.class]) config = parsed;
    }
    if (!config) config = [CCPetsJSONObject new];
    if (![config[@"hooks"] isKindOfClass:CCPetsJSONObject.class]) config[@"hooks"] = [CCPetsJSONObject new];
    return config;
}

static BOOL IsManagedHookCommand(id value, NSString *marker, NSString *executable) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *suffix = [NSString stringWithFormat:@"/.build/release/%@' --hook", executable];
    return [value hasPrefix:[marker stringByAppendingString:@" "]] && [value hasSuffix:suffix];
}

// 先摘掉旧的自家条目（含改名前 codex-pet 的），再给每个事件追加一条，重复安装保持幂等。
// 别的工具的 handler 原样保留；一个 group 里只剩我们的条目时整个 group 删掉。
static void ReplaceManagedHooks(CCPetsJSONObject *config, NSArray<NSArray<NSString *> *> *signatures,
                                NSString *command, NSArray<NSString *> *events) {
    CCPetsJSONObject *hooks = config[@"hooks"];
    for (NSString *event in hooks.keys) {
        NSArray *groups = hooks[event];
        if (![groups isKindOfClass:NSArray.class]) continue;
        NSMutableArray *kept = [NSMutableArray array];
        for (id group in groups) {
            NSArray *handlers = [group isKindOfClass:CCPetsJSONObject.class] ? ((CCPetsJSONObject *)group)[@"hooks"] : nil;
            if (![handlers isKindOfClass:NSArray.class]) {
                [kept addObject:group];
                continue;
            }
            NSMutableArray *remaining = [NSMutableArray array];
            for (id handler in handlers) {
                id handlerCommand = [handler isKindOfClass:CCPetsJSONObject.class] ? ((CCPetsJSONObject *)handler)[@"command"] : nil;
                BOOL managed = NO;
                for (NSArray<NSString *> *signature in signatures) {
                    if (IsManagedHookCommand(handlerCommand, signature[0], signature[1])) managed = YES;
                }
                if (!managed) [remaining addObject:handler];
            }
            if (remaining.count == 0) continue;
            CCPetsJSONObject *updated = [group copy];
            updated[@"hooks"] = remaining;
            [kept addObject:updated];
        }
        hooks[event] = kept;
    }
    for (NSString *event in events) {
        NSMutableArray *groups = [hooks[event] isKindOfClass:NSArray.class] ? [hooks[event] mutableCopy] : [NSMutableArray array];
        CCPetsJSONObject *handler = [CCPetsJSONObject new];
        handler[@"type"] = @"command";
        handler[@"command"] = command;
        handler[@"timeout"] = @3;
        CCPetsJSONObject *group = [CCPetsJSONObject new];
        group[@"hooks"] = @[handler];
        [groups addObject:group];
        hooks[event] = groups;
    }
}

#pragma mark - Claude status line

static NSString *FirstCapture(NSString *pattern, NSRegularExpressionOptions options, NSString *text,
                              NSInteger group, NSTextCheckingResult **matchOut) {
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern options:options error:nil];
    NSTextCheckingResult *match = [expression firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (matchOut) *matchOut = match;
    if (!match) return nil;
    NSRange range = [match rangeAtIndex:group];
    return range.location == NSNotFound ? @"" : [text substringWithRange:range];
}

static NSString *Unquote(NSString *value) {
    NSString *inner = FirstCapture(@"\\A(['\"])(.*)\\1\\z", NSRegularExpressionDotMatchesLineSeparators, value, 2, NULL);
    return inner ?: value;
}

static NSString *Trim(NSString *value) {
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// 能就地插 prelude 的 status line 命令：一个脚本的绝对路径（可带 `~/`），或者
// `bash ~/.claude/statusline-command.sh` 这类带解释器前缀的写法。带 -c 的不算：
// `-c` 后面是命令串而不是脚本路径。scripts/integration-markers.mjs 里有同一套规则。
//
// 返回 nil 表示无法注入；否则 script 是展开后用于读写的绝对路径，target 保留用户原来的写法
// （含 `~/`，官方默认就是 `~/.claude/statusline.sh`，不能展开后写回配置），
// interpreter / flags 表示原命令是否带解释器前缀、前缀上是否带选项。
static NSDictionary<NSString *, id> *ParseStatusLineCommand(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *candidate = Unquote(Trim(value));
    BOOL hasInterpreter = NO;
    NSString *flags = @"";
    NSTextCheckingResult *match = nil;
    FirstCapture(@"\\A(?:/usr/bin/env\\s+)?(?:[^\\s'\"]*/)?(?:ba|z|k|da)?sh((?:\\s+-[A-Za-z]+)*)\\s+(.+)\\z",
        NSRegularExpressionDotMatchesLineSeparators, candidate, 0, &match);
    if (match) {
        NSString *matchedFlags = [candidate substringWithRange:[match rangeAtIndex:1]];
        BOOL runsCommandString = FirstCapture(@"-[A-Za-z]*c(?=\\s|\\z)", 0, matchedFlags, 0, NULL) != nil;
        if (!runsCommandString) {
            hasInterpreter = YES;
            flags = Trim(matchedFlags);
            candidate = Unquote(Trim([candidate substringWithRange:[match rangeAtIndex:2]]));
        }
    }
    NSString *resolved = candidate;
    if ([resolved hasPrefix:@"~/"]) {
        resolved = [HomeDirectory() stringByAppendingPathComponent:[resolved substringFromIndex:2]];
    }
    if (![resolved hasPrefix:@"/"]) return nil;
    if (FirstCapture(@"[\\s;&|<>`$()]", 0, resolved, 0, NULL)) return nil;
    return @{@"script": ResolvePath(resolved), @"target": candidate,
             @"interpreter": @(hasInterpreter), @"flags": @(flags.length > 0)};
}

static NSString *ReplacePattern(NSString *text, NSString *pattern, NSString *replacement) {
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    return [expression stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length)
        withTemplate:[NSRegularExpression escapedTemplateForString:replacement]];
}

static NSString *RemoveStatusLineBlock(NSString *text) {
    NSString *block = [NSString stringWithFormat:@"(?:\\A|\\n)%@\\n[\\s\\S]*?\\n%@(?=\\n|\\z)",
        [NSRegularExpression escapedPatternForString:StatusLineStartMarker],
        [NSRegularExpression escapedPatternForString:StatusLineEndMarker]];
    text = ReplacePattern(text, block, @"");
    text = ReplacePattern(text, @"\\A\\n+", @"");
    return ReplacePattern(text, @"\\n{3,}", @"\n\n");
}

// prelude 把 Claude 喂给 status line 的 JSON 先存一份，交给 cc-pets --claude-usage 记录额度，
// 再把 stdin 换回这份内容，原脚本照常读到完整输入。
static NSString *StatusLinePrelude(NSString *binary) {
    NSString *quoted = ShellQuote(binary);
    return [@[
        StatusLineStartMarker,
        @"CC_PETS_STATUSLINE_INPUT=\"$(/usr/bin/mktemp \"${TMPDIR:-/tmp}/cc-pets-statusline.XXXXXX\")\" || exit 1",
        @"/bin/cat > \"${CC_PETS_STATUSLINE_INPUT}\"",
        [NSString stringWithFormat:@"if [ -x %@ ]; then", quoted],
        [NSString stringWithFormat:@"  %@ --claude-usage < \"${CC_PETS_STATUSLINE_INPUT}\" >/dev/null 2>&1 || true", quoted],
        @"fi",
        @"exec 0< \"${CC_PETS_STATUSLINE_INPUT}\"",
        @"/bin/rm -f \"${CC_PETS_STATUSLINE_INPUT}\"",
        @"unset CC_PETS_STATUSLINE_INPUT",
        StatusLineEndMarker
    ] componentsJoinedByString:@"\n"];
}

// 返回是否插入成功；hadShebang 记录原脚本有没有 shebang，决定能不能去掉 command 里的解释器前缀。
static BOOL InstallStatusLinePrelude(NSString *scriptPath, NSString *binary, BOOL createIfMissing, BOOL *hadShebang) {
    *hadShebang = NO;
    NSString *original = nil;
    mode_t mode = 0700;
    struct stat info;
    if (stat(scriptPath.fileSystemRepresentation, &info) == 0) {
        if (!S_ISREG(info.st_mode)) return NO;
        NSData *data = [NSData dataWithContentsOfFile:scriptPath];
        original = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (!original) return NO;
        mode = info.st_mode & 07777;
    } else if (createIfMissing) {
        [NSFileManager.defaultManager createDirectoryAtPath:scriptPath.stringByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:nil error:nil];
        original = [NSString stringWithFormat:@"#!/bin/zsh\n%@\n", CreatedStatusLineMarker];
    } else {
        return NO;
    }

    NSString *cleaned = RemoveStatusLineBlock(original);
    BOOL hasShebang = [cleaned hasPrefix:@"#!"];
    NSRange newline = [cleaned rangeOfString:@"\n"];
    NSString *shebang = @"#!/bin/zsh";
    NSString *body = cleaned;
    if (hasShebang) {
        shebang = newline.location == NSNotFound ? cleaned : [cleaned substringToIndex:newline.location];
        body = newline.location == NSNotFound ? @"" : [cleaned substringFromIndex:newline.location + 1];
    }
    NSString *updated = [NSString stringWithFormat:@"%@\n%@\n%@", shebang, StatusLinePrelude(binary), body];
    // 结尾的换行收成恰好一个。不能用 \n*\z 全局替换：它在末尾还会再匹配一次空串，多出一行。
    while ([updated hasSuffix:@"\n"]) updated = [updated substringToIndex:updated.length - 1];
    updated = [updated stringByAppendingString:@"\n"];
    if (!WriteFileAtomically(scriptPath, updated, mode | 0100, NULL)) return NO;
    *hadShebang = hasShebang;
    return YES;
}

// 包装器形态的 command 末尾是 base64 编码的原命令；Buffer.from 容忍缺失的填充，这里补齐后再解。
static NSString *DecodeWrappedStatusLine(NSString *command) {
    NSString *encoded = FirstCapture(@"'([A-Za-z0-9+/=]*)'\\s*\\z", 0, command, 1, NULL);
    if (!encoded) return @"";
    encoded = [encoded stringByReplacingOccurrencesOfString:@"=" withString:@""];
    while (encoded.length % 4 != 0) encoded = [encoded stringByAppendingString:@"="];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
    if (!data) return @"";
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?:
        [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
}

static BOOL IsManagedStatusLine(NSString *command, NSString *marker) {
    return [command hasPrefix:[marker stringByAppendingString:@" "]] &&
        FirstCapture(@"/bin/claude-statusline-with-pet' '[A-Za-z0-9+/=]*'\\z", 0, command, 0, NULL) != nil;
}

#pragma mark - 安装入口

int InstallClaudeHooks(NSString *binary) {
    if (binary.length == 0) {
        PrintLine(stderr, L(@"Usage: cc-pets --install-claude-hooks /absolute/path/to/cc-pets"));
        return 2;
    }
    // 没装 Claude Code 就什么都不写：下面会创建 statusline-command.sh 并把 statusLine 指过去，
    // 对还没装 Claude 的用户等于提前替他决定了状态栏。
    if (!ClaudeCLIInstalled()) {
        PrintLine(stdout, L(@"Claude Code CLI not detected; skipping Claude hooks and status line setup."));
        PrintLine(stdout, L(@"If you install Claude Code later, run cc-pets install to set it up."));
        return 0;
    }

    binary = ResolvePath(binary);
    NSString *claudeHome = ClaudeHome();
    NSString *settingsPath = [claudeHome stringByAppendingPathComponent:@"settings.json"];
    [NSFileManager.defaultManager createDirectoryAtPath:claudeHome withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *errorMessage = nil;
    CCPetsJSONObject *config = LoadConfig(settingsPath, &errorMessage);
    if (!config) {
        PrintLine(stderr, [NSString stringWithFormat:L(@"Can't parse %1$@: %2$@"), settingsPath, errorMessage]);
        return 1;
    }

    NSString *command = [NSString stringWithFormat:@"%@ %@ --hook", ClaudeHookMarker, ShellQuote(binary)];
    ReplaceManagedHooks(config, @[@[ClaudeHookMarker, @"cc-pets"], @[LegacyClaudeHookMarker, @"codex-pet"]], command, @[
        @"SessionStart", @"UserPromptSubmit", @"PreToolUse", @"PermissionRequest", @"PostToolUse",
        @"PostToolUseFailure", @"Notification", @"SubagentStart", @"SubagentStop", @"TaskCreated",
        @"TaskCompleted", @"Stop", @"StopFailure", @"SessionEnd"
    ]);

    // 找出用户原本的 status line 命令。已经被我们包装过的，从 base64 里还原出原命令。
    NSString *originalCommand = @"";
    CCPetsJSONObject *statusLine = config[@"statusLine"];
    if ([statusLine isKindOfClass:CCPetsJSONObject.class]) {
        NSString *current = [statusLine[@"command"] isKindOfClass:NSString.class] ? statusLine[@"command"] : @"";
        if (IsManagedStatusLine(current, StatusLineMarker) || IsManagedStatusLine(current, LegacyStatusLineMarker)) {
            originalCommand = DecodeWrappedStatusLine(current);
        } else {
            originalCommand = current;
        }
    } else {
        statusLine = [CCPetsJSONObject new];
        statusLine[@"type"] = @"command";
    }
    BOOL createdStatusLine = NO;
    if (originalCommand.length == 0) {
        originalCommand = [claudeHome stringByAppendingPathComponent:@"statusline-command.sh"];
        createdStatusLine = YES;
    }
    statusLine = [statusLine copy];
    statusLine[@"type"] = @"command";
    statusLine[@"command"] = originalCommand;
    config[@"statusLine"] = statusLine;

    NSDictionary<NSString *, id> *parsed = ParseStatusLineCommand(originalCommand);
    BOOL hadShebang = NO;
    BOOL statusLineInstalled = parsed &&
        InstallStatusLinePrelude(parsed[@"script"], binary, createdStatusLine, &hadShebang);

    // 只在原命令带解释器前缀（`bash ~/x.sh`）时才改写 command，去掉那层前缀让 agent 能直接读懂。
    // 纯路径形态——包括官方默认的 `~/.claude/statusline.sh`——一个字都不动。另外两道闸门都是为了
    // 不改变脚本的执行语义：带 flag（`sh -e ~/x.sh`）不动，否则 -e 会被悄悄丢掉；原脚本没有
    // shebang 的不动，否则 prelude 补上的 #!/bin/zsh 会把本来用 bash 跑的脚本换成 zsh。
    if (statusLineInstalled && [parsed[@"interpreter"] boolValue] && ![parsed[@"flags"] boolValue] && hadShebang) {
        statusLine[@"command"] = parsed[@"target"];
    }

    // 解析不出脚本路径的命令（`bun x ccstatusline`、`npx …`、带管道或 `sh -c` 的命令行）没法就地插
    // prelude，而 status line 是 Claude 额度的唯一来源。回退到包装器：command 换成
    // claude-statusline-with-pet + base64 编码的原命令，它先把 stdin 喂给 cc-pets --claude-usage，
    // 再原样转发给原命令执行。卸载侧认这个形态，能原样还原。
    NSString *packageDirectory = binary.stringByDeletingLastPathComponent
        .stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    NSString *wrapper = [packageDirectory stringByAppendingPathComponent:@"bin/claude-statusline-with-pet"];
    BOOL statusLineWrapped = NO;
    struct stat wrapperInfo;
    if (!statusLineInstalled && stat(wrapper.fileSystemRepresentation, &wrapperInfo) == 0) {
        // 包内文件不可写（只读安装）时权限位通常本来就是对的，失败不影响。
        chmod(wrapper.fileSystemRepresentation, (wrapperInfo.st_mode & 07777) | 0100);
        NSString *encoded = [[originalCommand dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
        statusLine[@"type"] = @"command";
        statusLine[@"command"] = [NSString stringWithFormat:@"%@ %@ '%@'", StatusLineMarker, ShellQuote(wrapper), encoded];
        statusLineWrapped = YES;
    }

    if (!statusLineInstalled && !statusLineWrapped) {
        PrintLine(stderr, [NSString stringWithFormat:L(@"Claude status line not hooked up: %@"), originalCommand]);
        PrintLine(stderr, L(@"Claude hooks still work, but the pet can't show Claude quota % (token usage is unaffected)."));
    }

    NSString *text = [CCPetsJSONStringify(config) stringByAppendingString:@"\n"];
    if (!WriteFileAtomically(settingsPath, text, 0600, &errorMessage)) {
        PrintLine(stderr, errorMessage);
        return 1;
    }
    PrintLine(stdout, [NSString stringWithFormat:L(@"Claude Code hooks installed in %@"), settingsPath]);
    if (statusLineInstalled) {
        PrintLine(stdout, L(@"Claude quota tracking added to your existing status line. The pet shows quota after the first API response."));
    } else if (statusLineWrapped) {
        PrintLine(stdout, L(@"Claude quota tracking added to the status line through a wrapper; your original command still runs. The pet shows quota after the first API response."));
    }
    return 0;
}

int InstallCodexHooks(NSString *binary) {
    if (binary.length == 0) {
        PrintLine(stderr, L(@"Usage: cc-pets --install-codex-hooks /absolute/path/to/cc-pets"));
        return 2;
    }
    if (!CodexCLIInstalled()) {
        PrintLine(stdout, L(@"Codex CLI not detected; skipping Codex hooks."));
        PrintLine(stdout, L(@"If you install Codex later, run cc-pets install to set it up."));
        return 0;
    }

    binary = ResolvePath(binary);
    NSString *codexHome = CodexHome();
    NSString *hooksPath = [codexHome stringByAppendingPathComponent:@"hooks.json"];
    [NSFileManager.defaultManager createDirectoryAtPath:codexHome withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *errorMessage = nil;
    CCPetsJSONObject *config = LoadConfig(hooksPath, &errorMessage);
    if (!config) {
        PrintLine(stderr, [NSString stringWithFormat:L(@"Can't parse %1$@: %2$@"), hooksPath, errorMessage]);
        return 1;
    }

    NSString *command = [NSString stringWithFormat:@"%@ %@ --hook", CodexHookMarker, ShellQuote(binary)];
    ReplaceManagedHooks(config, @[@[CodexHookMarker, @"cc-pets"], @[LegacyCodexHookMarker, @"codex-pet"]], command, @[
        @"SessionStart", @"UserPromptSubmit", @"PreToolUse", @"PermissionRequest", @"PostToolUse",
        @"SubagentStart", @"SubagentStop", @"Stop"
    ]);

    NSString *text = [CCPetsJSONStringify(config) stringByAppendingString:@"\n"];
    if (!WriteFileAtomically(hooksPath, text, 0600, &errorMessage)) {
        PrintLine(stderr, errorMessage);
        return 1;
    }
    PrintLine(stdout, [NSString stringWithFormat:L(@"Codex agent hooks installed in %@"), hooksPath]);
    PrintLine(stdout, L(@"Next time you start Codex, run /hooks and trust the CC Pets hooks."));
    return 0;
}
