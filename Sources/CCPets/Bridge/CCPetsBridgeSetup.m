#import "CCPetsL10n.h"
#import "CCPetsBridgeSetup.h"
#import "CCPetsBridge.h"
#import "CCPetsBridgeStore.h"
#import "CCPetsCLISupport.h"
#import "CCPetsJSON.h"
#import <sys/stat.h>

#define LF(localized, values) CCPetsInterpolate(localized, values)

NSString *const CCBridgeHookMarker = @"CC_BRIDGE_HOOK=";
NSString *const CCBridgeMCPName = @"cc-bridge";
static NSString *const TomlStart = @"# >>> cc-bridge >>>";
static NSString *const TomlEnd = @"# <<< cc-bridge <<<";

// 正式发布前这个功能叫过 "Agent Bus"（cc-pets bus）。启用过旧版的机器上还留着旧标记的 hooks、
// 旧名字的 MCP 注册和旧审批块，安装 / 卸载时一并识别清理，不留两套。
static NSArray<NSString *> *HookMarkers(void) {
    return @[CCBridgeHookMarker, @"CC_PETS_BUS_HOOK="];
}

static NSArray<NSString *> *MCPNames(void) {
    return @[CCBridgeMCPName, @"cc-pets-bus"];
}

static NSArray<NSArray<NSString *> *> *TomlBlocks(void) {
    return @[@[TomlStart, TomlEnd], @[@"# >>> cc-pets-bus >>>", @"# <<< cc-pets-bus <<<"]];
}

// 文件预留提醒只挂在编辑类工具上，避免每次 shell / 读文件都多跑一次 hook。
static NSString *const ClaudeEditMatcher = @"Edit|Write|MultiEdit|NotebookEdit";
static NSString *const CodexEditMatcher = @"apply_patch|Edit|Write";

BOOL CCBridgeShouldTouchMCP(void) {
    return ![CCPetsEnvironmentValue(@"CC_BRIDGE_SKIP_MCP") isEqualToString:@"1"];
}

// 写进 hooks 的命令直接调原生二进制，不经过 bin/cc-pets：hook 在对方 CLI 的关键路径上，越轻越好。
static NSString *BridgeCommand(NSString *provider, NSString *subcommand, NSDictionary *profile) {
    NSString *identity = @"";
    if ([profile[@"id"] isKindOfClass:NSString.class]) {
        identity = [NSString stringWithFormat:@" CC_PETS_PROFILE_ID=%@ CC_PETS_PROFILE_NAME=%@ CC_PETS_PROFILE_HOME=%@",
            CCPetsShellQuote(profile[@"id"]), CCPetsShellQuote(profile[@"displayName"] ?: profile[@"slug"] ?: provider),
            CCPetsShellQuote(profile[@"home"] ?: @"")];
    }
    return [NSString stringWithFormat:@"%@%@%@ %@ bridge %@", CCBridgeHookMarker, provider, identity,
        CCPetsShellQuote(CCPetsExecutablePath()), subcommand];
}

static BOOL IsBridgeHook(id handler) {
    id command = [handler isKindOfClass:CCPetsJSONObject.class] ? ((CCPetsJSONObject *)handler)[@"command"] : nil;
    if (![command isKindOfClass:NSString.class]) return NO;
    for (NSString *marker in HookMarkers()) {
        if ([command hasPrefix:marker]) return YES;
    }
    return NO;
}

#pragma mark - JSON 配置

static CCPetsJSONObject *ReadJSONConfig(NSString *file) {
    NSString *error = nil;
    id config = CCPetsReadConfig(file, &error);
    if (!config && error) [NSException raise:@"CCBridgeConfig" format:@"%@: %@", file, error];
    if (!config) return [CCPetsJSONObject new];
    if (![config isKindOfClass:CCPetsJSONObject.class]) {
        [NSException raise:@"CCBridgeConfig" format:@"%@", LF(L(@"{file} isn't a JSON object"), @{@"file": file})];
    }
    return config;
}

static void WriteJSONConfig(NSString *file, CCPetsJSONObject *config) {
    struct stat info;
    mode_t mode = stat(file.fileSystemRepresentation, &info) == 0 ? (info.st_mode & 0777) : 0600;
    NSString *error = nil;
    if (!CCPetsWriteFileAtomically(file, [CCPetsJSONStringify(config) stringByAppendingString:@"\n"], mode, &error)) {
        [NSException raise:@"CCBridgeConfig" format:@"%@", error];
    }
}

// 返回是否摘掉了东西。事件下一个 group 都不剩就删掉事件，hooks 空了也删掉。
static BOOL StripBridgeHooks(CCPetsJSONObject *config) {
    CCPetsJSONObject *hooks = config[@"hooks"];
    if (![hooks isKindOfClass:CCPetsJSONObject.class]) return NO;
    BOOL changed = NO;
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
                if (!IsBridgeHook(handler)) [remaining addObject:handler];
            }
            if (remaining.count != handlers.count) changed = YES;
            if (remaining.count == 0) continue;
            CCPetsJSONObject *updated = [group copy];
            updated[@"hooks"] = remaining;
            [kept addObject:updated];
        }
        if (kept.count > 0) hooks[event] = kept;
        else [hooks removeObjectForKey:event];
    }
    if (hooks.keys.count == 0) [config removeObjectForKey:@"hooks"];
    return changed;
}

static CCPetsJSONObject *Handler(NSString *command, BOOL asyncRewake, NSInteger timeout) {
    CCPetsJSONObject *handler = [CCPetsJSONObject new];
    handler[@"type"] = @"command";
    handler[@"command"] = command;
    if (asyncRewake) handler[@"asyncRewake"] = @YES;
    handler[@"timeout"] = @(timeout);
    return handler;
}

static void AddHook(CCPetsJSONObject *config, NSString *event, CCPetsJSONObject *handler, NSString *matcher) {
    if (![config[@"hooks"] isKindOfClass:CCPetsJSONObject.class]) config[@"hooks"] = [CCPetsJSONObject new];
    CCPetsJSONObject *hooks = config[@"hooks"];
    NSMutableArray *groups = [hooks[event] isKindOfClass:NSArray.class] ? [hooks[event] mutableCopy] : [NSMutableArray array];
    CCPetsJSONObject *group = [CCPetsJSONObject new];
    if (matcher) group[@"matcher"] = matcher;
    group[@"hooks"] = @[handler];
    [groups addObject:group];
    hooks[event] = groups;
}

// Claude：同步 hook 维护注册表；asyncRewake watcher 负责投递（单例锁保证同时只有一个）。
// watcher 只挂 SessionStart / Stop，不挂 UserPromptSubmit：由 UserPromptSubmit 拉起的 watcher 在回合中途
// exit 2 时，Claude Code 会显示成 "Stop hook blocking error from command UserPromptSubmit"，像报错。
// Stop 拉起的 watcher 会一直活过下一个忙碌回合，中途投递照常；watcher 超时退出后，用户开口时信箱里
// 已有的消息由同步 hook 注入。
//
// 选项决定装哪些：关闭"自动唤醒"时不装 watcher；关闭"编辑前预留拦截"时不装 PreToolUse。
// hook / watcher 自己也会再读一次选项兜底。
static void AddClaudeHooks(CCPetsJSONObject *config, NSDictionary *options, NSDictionary *profile) {
    for (NSString *event in @[@"SessionStart", @"UserPromptSubmit", @"Stop", @"SessionEnd"]) {
        AddHook(config, event, Handler(BridgeCommand(@"Claude", @"hook", profile), NO, 10), nil);
    }
    if ([options[@"editGuard"] boolValue]) {
        AddHook(config, @"PreToolUse", Handler(BridgeCommand(@"Claude", @"hook", profile), NO, 10), ClaudeEditMatcher);
    }
    if ([options[@"wake"] boolValue]) {
        for (NSString *event in @[@"SessionStart", @"Stop"]) {
            AddHook(config, event, Handler(BridgeCommand(@"Claude", @"watch", profile), YES, 3600), nil);
        }
    }
}

static void AddCodexHooks(CCPetsJSONObject *config, NSDictionary *options, NSDictionary *profile) {
    for (NSString *event in @[@"SessionStart", @"UserPromptSubmit", @"Stop", @"SessionEnd"]) {
        AddHook(config, event, Handler(BridgeCommand(@"Codex", @"hook", profile), NO, 10), nil);
    }
    if ([options[@"editGuard"] boolValue]) {
        AddHook(config, @"PreToolUse", Handler(BridgeCommand(@"Codex", @"hook", profile), NO, 10), CodexEditMatcher);
    }
}

// Claude 的工具放行写在 settings.json 的 permissions.allow 里，条目形如 mcp__cc-bridge__send_message。
// 只增删这个前缀下的条目（含旧名 cc-pets-bus），不碰用户其他的放行规则。返回是否有变化。
static BOOL ApplyClaudeAllow(CCPetsJSONObject *config, NSArray<NSString *> *tools) {
    CCPetsJSONObject *permissions = [config[@"permissions"] isKindOfClass:CCPetsJSONObject.class] ? config[@"permissions"] : nil;
    NSArray *current = [permissions[@"allow"] isKindOfClass:NSArray.class] ? permissions[@"allow"] : @[];
    NSRegularExpression *managed = [NSRegularExpression regularExpressionWithPattern:@"\\Amcp__(?:cc-bridge|cc-pets-bus)__[a-z_]+\\z" options:0 error:nil];
    NSMutableArray *next = [NSMutableArray array];
    for (id entry in current) {
        BOOL ours = [entry isKindOfClass:NSString.class] &&
            [managed firstMatchInString:entry options:0 range:NSMakeRange(0, [entry length])];
        if (!ours) [next addObject:entry];
    }
    for (NSString *tool in tools) [next addObject:[NSString stringWithFormat:@"mcp__%@__%@", CCBridgeMCPName, tool]];
    if ([next isEqualToArray:current] && (next.count > 0 || !permissions[@"allow"])) return NO;
    if (next.count > 0) {
        CCPetsJSONObject *updated = permissions ? [permissions copy] : [CCPetsJSONObject new];
        updated[@"allow"] = next;
        config[@"permissions"] = updated;
    } else if (permissions) {
        [permissions removeObjectForKey:@"allow"];
        if (permissions.keys.count == 0) [config removeObjectForKey:@"permissions"];
    }
    return YES;
}

#pragma mark - Codex 工具审批
// Codex 默认每次 MCP 调用都要审批，approval_policy=never 时直接报错（实测）。用户选择放开时，
// 只在 config.toml 末尾追加一段带标记的块，移除时整段删掉。

static NSString *CodexApprovalBlock(NSArray<NSString *> *tools) {
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObjects:TomlStart,
        L(@"# Written by cc-pets bridge enable / configure; cc-pets bridge disable removes it."), nil];
    for (NSString *tool in tools) {
        [lines addObject:[NSString stringWithFormat:@"[mcp_servers.%@.tools.%@]", CCBridgeMCPName, tool]];
        [lines addObject:@"approval_mode = \"approve\""];
        [lines addObject:@""];
    }
    [lines addObject:TomlEnd];
    return [lines componentsJoinedByString:@"\n"];
}

typedef NS_ENUM(NSInteger, TomlLexState) {
    TomlLexNormal,
    TomlLexMultilineBasic,
    TomlLexMultilineLiteral
};

// 扫过一行，返回行尾的词法状态。只关心多行字符串：字符串里的内容长得再像管理块也是用户的数据。
static TomlLexState AdvanceTomlState(NSString *line, TomlLexState state) {
    NSUInteger length = line.length;
    BOOL (^startsWith)(NSUInteger, NSString *) = ^BOOL(NSUInteger index, NSString *text) {
        return index + text.length <= length &&
            [[line substringWithRange:NSMakeRange(index, text.length)] isEqualToString:text];
    };
    for (NSUInteger index = 0; index < length; index++) {
        unichar character = [line characterAtIndex:index];
        if (state == TomlLexMultilineBasic) {
            if (character == '\\') index++;
            else if (startsWith(index, @"\"\"\"")) { state = TomlLexNormal; index += 2; }
        } else if (state == TomlLexMultilineLiteral) {
            if (startsWith(index, @"'''")) { state = TomlLexNormal; index += 2; }
        } else if (character == '#') {
            return state;
        } else if (startsWith(index, @"\"\"\"")) {
            state = TomlLexMultilineBasic;
            index += 2;
        } else if (startsWith(index, @"'''")) {
            state = TomlLexMultilineLiteral;
            index += 2;
        } else if (character == '"' || character == '\'') {
            for (index++; index < length && [line characterAtIndex:index] != character; index++) {
                if (character == '"' && [line characterAtIndex:index] == '\\') index++;
            }
        }
    }
    return state;
}

// lines[start] 是管理块的起始标记时返回结束标记所在行，否则 NSNotFound。没有结束标记的不算管理块。
static NSUInteger TomlBlockEnd(NSArray<NSString *> *lines, NSUInteger start) {
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSString *first = [lines[start] stringByTrimmingCharactersInSet:whitespace];
    for (NSArray<NSString *> *block in TomlBlocks()) {
        if (![first isEqualToString:block[0]]) continue;
        for (NSUInteger index = start + 1; index < lines.count; index++) {
            if ([[lines[index] stringByTrimmingCharactersInSet:whitespace] isEqualToString:block[1]]) return index;
        }
    }
    return NSNotFound;
}

// 只移除自己的管理块和安装时加在它前面的那一个空行，其余内容逐字保留：
// config.toml 是用户的文件，多行字符串里的空行也是值的一部分。
static NSString *StripTomlBlocks(NSString *text) {
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    TomlLexState state = TomlLexNormal;
    for (NSUInteger index = 0; index < lines.count; index++) {
        NSUInteger end = state == TomlLexNormal ? TomlBlockEnd(lines, index) : NSNotFound;
        if (end != NSNotFound) {
            if ([kept.lastObject isEqualToString:@""]) [kept removeLastObject];
            index = end;
            continue;
        }
        [kept addObject:lines[index]];
        state = AdvanceTomlState(lines[index], state);
    }
    return [kept componentsJoinedByString:@"\n"];
}

static void SetCodexApprovalAtHome(NSArray<NSString *> *tools, NSString *codexHome) {
    NSString *file = [codexHome stringByAppendingPathComponent:@"config.toml"];
    struct stat info;
    BOOL exists = stat(file.fileSystemRepresentation, &info) == 0;
    NSString *original = exists ? [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil] : @"";
    if (!original) [NSException raise:@"CCBridgeConfig" format:@"Cannot read %@", file];
    NSString *updated = StripTomlBlocks(original);
    if (tools.count > 0) {
        if (updated.length > 0 && ![updated hasSuffix:@"\n"]) updated = [updated stringByAppendingString:@"\n"];
        updated = [updated stringByAppendingFormat:updated.length > 0 ? @"\n%@\n" : @"%@\n", CodexApprovalBlock(tools)];
    }
    if ([updated isEqualToString:original]) return;
    NSString *error = nil;
    if (!CCPetsWriteFileAtomically(file, updated, exists ? (info.st_mode & 0777) : 0600, &error)) {
        [NSException raise:@"CCBridgeConfig" format:@"%@", error];
    }
}

#pragma mark - MCP

static BOOL RunQuietlyForHome(NSString *executable, NSArray<NSString *> *arguments,
    NSString *provider, NSString *home) {
    NSMutableDictionary<NSString *, NSString *> *environment =
        [NSProcessInfo.processInfo.environment mutableCopy];
    BOOL claude = [provider isEqualToString:@"claude"];
    // 官方 ~/.claude 不能显式设 CLAUDE_CONFIG_DIR：一旦设了，user 级 MCP 会写进
    // ~/.claude/.claude.json，而正常启动的 claude 读的是 ~/.claude.json。
    NSString *officialClaude = CCPetsRealPath([CCPetsHomeDirectory() stringByAppendingPathComponent:@".claude"]);
    if (claude && officialClaude.length > 0 && [CCPetsRealPath(home) isEqualToString:officialClaude]) {
        [environment removeObjectForKey:@"CLAUDE_CONFIG_DIR"];
    } else {
        environment[claude ? @"CLAUDE_CONFIG_DIR" : @"CODEX_HOME"] = home;
    }
    return CCPetsRun(executable, arguments, nil, environment, 60, NULL, NULL) == 0;
}

// MCP 进程的环境会被 CLI 裁剪，PATH 里不一定找得到 codex；投递到 Codex 需要它，
// 注册时把安装时解析到的绝对路径固定下来。
static NSArray<NSString *> *MCPEnvironment(void) {
    NSString *codex = CCPetsFindRealExecutable(@"codex", @"CODEX_REAL_BIN");
    return codex ? @[[@"CODEX_REAL_BIN=" stringByAppendingString:codex]] : @[];
}

static NSArray<NSString *> *MCPCommand(void) {
    return @[@"--", CCPetsExecutablePath(), @"bridge", @"mcp"];
}

static NSArray<NSString *> *ClaudeMCPAddArguments(void) {
    NSMutableArray<NSString *> *arguments = [@[@"mcp", @"add", @"--scope", @"user", CCBridgeMCPName] mutableCopy];
    for (NSString *pair in MCPEnvironment()) [arguments addObjectsFromArray:@[@"-e", pair]];
    [arguments addObjectsFromArray:MCPCommand()];
    return arguments;
}

static NSArray<NSString *> *CodexMCPAddArguments(void) {
    NSMutableArray<NSString *> *arguments = [@[@"mcp", @"add", CCBridgeMCPName] mutableCopy];
    for (NSString *pair in MCPEnvironment()) [arguments addObjectsFromArray:@[@"--env", pair]];
    [arguments addObjectsFromArray:MCPCommand()];
    return arguments;
}

static NSString *QuotedArguments(NSArray<NSString *> *arguments) {
    NSMutableArray<NSString *> *quoted = [NSMutableArray array];
    for (NSString *argument in arguments) [quoted addObject:CCPetsShellQuote(argument)];
    return [quoted componentsJoinedByString:@" "];
}

NSString *CCBridgeDescribeCodexQueue(NSDictionary *probe) {
    NSString *version = [probe[@"version"] isKindOfClass:NSString.class]
        ? LF(L(@" ({version})"), @{@"version": probe[@"version"]}) : @"";
    NSString *status = probe[@"status"];
    if ([status isEqualToString:@"supported"]) return nil;
    if ([status isEqualToString:@"unsupported"]) {
        return [LF(L(@"This Codex{version} doesn't support codex queue, so messages to Codex can't wake it; they go to its inbox "),
            @{@"version": version}) stringByAppendingString:
            L(@"and are picked up via check_inbox or with the next input. Upgrading Codex enables wake-up without re-enabling CC Bridge.")];
    }
    if ([status isEqualToString:@"missing"]) {
        return L(@"codex executable not found, so messages to Codex can only go to its inbox; set CODEX_REAL_BIN and run cc-pets bridge enable.");
    }
    return L(@"Couldn't tell whether Codex supports codex queue; failed deliveries fall back to the inbox.");
}

#pragma mark - 安装 / 卸载

static BOOL RemoveJSONHooks(NSString *file, BOOL claudeAllow);

NSArray<NSString *> *CCBridgeInstallForProfile(NSDictionary *profile, NSDictionary *rawOptions, BOOL registerMcp) {
    NSString *provider = [profile[@"provider"] isKindOfClass:NSString.class] ? profile[@"provider"] : @"";
    NSString *home = [profile[@"home"] isKindOfClass:NSString.class] ? profile[@"home"] : @"";
    if (home.length == 0 || (![provider isEqualToString:@"claude"] && ![provider isEqualToString:@"codex"])) {
        [NSException raise:@"CCBridgeConfig" format:@"Invalid Agent profile."];
    }
    NSDictionary *options = CCBridgeNormalizeOptions(rawOptions);
    NSMutableArray<NSString *> *report = [NSMutableArray array];
    [NSFileManager.defaultManager createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:nil];
    if ([provider isEqualToString:@"claude"]) {
        NSString *settingsPath = [home stringByAppendingPathComponent:@"settings.json"];
        CCPetsJSONObject *config = ReadJSONConfig(settingsPath);
        StripBridgeHooks(config);
        AddClaudeHooks(config, options, profile);
        ApplyClaudeAllow(config, options[@"claudeAllow"]);
        WriteJSONConfig(settingsPath, config);
        [report addObject:LF(L(@"Claude Code hooks written to {path}"), @{@"path": settingsPath})];
        if (registerMcp) {
            NSString *claude = CCPetsFindRealExecutable(@"claude", @"CLAUDE_REAL_BIN");
            for (NSString *name in MCPNames()) {
                if (claude) RunQuietlyForHome(claude, @[@"mcp", @"remove", @"--scope", @"user", name], provider, home);
            }
            BOOL ok = claude && RunQuietlyForHome(claude, ClaudeMCPAddArguments(), provider, home);
            [report addObject:ok
                ? LF(L(@"Claude Code MCP registered: {MCP_NAME} (on first use, Claude asks according to your permission settings)"), @{@"MCP_NAME": CCBridgeMCPName})
                : [@"ERROR: " stringByAppendingString:LF(L(@"Claude Code MCP registration failed. Run manually: claude {shellQuote}"), @{@"shellQuote": QuotedArguments(ClaudeMCPAddArguments())})]];
        }
        return report;
    }

    NSString *hooksPath = [home stringByAppendingPathComponent:@"hooks.json"];
    CCPetsJSONObject *config = ReadJSONConfig(hooksPath);
    StripBridgeHooks(config);
    AddCodexHooks(config, options, profile);
    WriteJSONConfig(hooksPath, config);
    [report addObject:LF(L(@"Codex hooks written to {path}. Next time you start Codex, run /hooks and trust the cc-pets bridge hooks."), @{@"path": hooksPath})];
    if (registerMcp) {
        NSString *codex = CCPetsFindRealExecutable(@"codex", @"CODEX_REAL_BIN");
        for (NSString *name in MCPNames()) {
            if (codex) RunQuietlyForHome(codex, @[@"mcp", @"remove", name], provider, home);
        }
        BOOL ok = codex && RunQuietlyForHome(codex, CodexMCPAddArguments(), provider, home);
        [report addObject:ok
            ? LF(L(@"Codex MCP registered: {MCP_NAME}"), @{@"MCP_NAME": CCBridgeMCPName})
            : [@"ERROR: " stringByAppendingString:LF(L(@"Codex MCP registration failed. Run manually: codex {shellQuote}"), @{@"shellQuote": QuotedArguments(CodexMCPAddArguments())})]];
        // 只在 enable / refresh 时探测：configure 由桌宠菜单开关触发，不值得每次多拉起两次 codex。
        if ([options[@"wake"] boolValue]) {
            NSString *notice = CCBridgeDescribeCodexQueue(CCBridgeProbeCodexQueue(codex));
            if (notice) [report addObject:notice];
        }
    }
    SetCodexApprovalAtHome(options[@"codexApprove"], home);
    return report;
}

static NSUInteger TomlSkipSpaces(NSString *text, NSUInteger index) {
    while (index < text.length && ([text characterAtIndex:index] == ' ' || [text characterAtIndex:index] == '\t')) index++;
    return index;
}

// index 指向开引号，返回闭引号的位置；没有闭引号时返回 text.length。
static NSUInteger TomlStringEnd(NSString *text, NSUInteger index) {
    unichar quote = [text characterAtIndex:index];
    for (index++; index < text.length && [text characterAtIndex:index] != quote; index++) {
        if (quote == '"' && [text characterAtIndex:index] == '\\') index++;
    }
    return MIN(index, text.length);
}

// 双引号键的转义要先解码才能比较：`"cc-bridge"` 就是 cc-bridge。不合法的转义按原样保留。
static NSString *TomlDecodeBasicString(NSString *text) {
    if (![text containsString:@"\\"]) return text;
    NSDictionary<NSString *, NSString *> *simple = @{@"b": @"\b", @"t": @"\t", @"n": @"\n", @"f": @"\f", @"r": @"\r",
        @"e": @"\033", @"\"": @"\"", @"\\": @"\\"};
    NSDictionary<NSString *, NSNumber *> *numeric = @{@"x": @2, @"u": @4, @"U": @8};
    NSCharacterSet *notHex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"].invertedSet;
    NSMutableString *decoded = [NSMutableString string];
    for (NSUInteger index = 0; index < text.length; index++) {
        unichar character = [text characterAtIndex:index];
        if (character != '\\' || index + 1 >= text.length) {
            [decoded appendFormat:@"%C", character];
            continue;
        }
        NSString *escape = [text substringWithRange:NSMakeRange(++index, 1)];
        if (simple[escape]) {
            [decoded appendString:simple[escape]];
            continue;
        }
        NSUInteger digits = numeric[escape].unsignedIntegerValue;
        NSString *hex = digits > 0 && index + digits < text.length
            ? [text substringWithRange:NSMakeRange(index + 1, digits)] : nil;
        uint32_t scalar = hex ? (uint32_t)strtoul(hex.UTF8String, NULL, 16) : 0;
        BOOL valid = hex && [hex rangeOfCharacterFromSet:notHex].location == NSNotFound &&
            scalar <= 0x10FFFF && (scalar < 0xD800 || scalar > 0xDFFF);
        if (!valid) {
            [decoded appendFormat:@"\\%@", escape];
            continue;
        }
        [decoded appendString:[[NSString alloc] initWithBytes:&scalar length:sizeof scalar encoding:NSUTF32LittleEndianStringEncoding]];
        index += digits;
    }
    return decoded;
}

// 从 cursor 读一个键路径（每一级可以是裸键或带引号），停在路径后第一个非空白字符上。不是键时返回 nil。
static NSArray<NSString *> *TomlParseKey(NSString *text, NSUInteger *cursor) {
    NSMutableCharacterSet *bare = [NSMutableCharacterSet alphanumericCharacterSet];
    [bare addCharactersInString:@"_-"];
    NSMutableArray<NSString *> *path = [NSMutableArray array];
    NSUInteger index = *cursor;
    while (YES) {
        index = TomlSkipSpaces(text, index);
        if (index >= text.length) return nil;
        unichar character = [text characterAtIndex:index];
        if (character == '"' || character == '\'') {
            NSUInteger end = TomlStringEnd(text, index);
            if (end >= text.length) return nil;
            NSString *key = [text substringWithRange:NSMakeRange(index + 1, end - index - 1)];
            [path addObject:character == '"' ? TomlDecodeBasicString(key) : key];
            index = end + 1;
        } else {
            NSUInteger start = index;
            while (index < text.length && [bare characterIsMember:[text characterAtIndex:index]]) index++;
            if (index == start) return nil;
            [path addObject:[text substringWithRange:NSMakeRange(start, index - start)]];
        }
        index = TomlSkipSpaces(text, index);
        if (index >= text.length || [text characterAtIndex:index] != '.') break;
        index++;
    }
    *cursor = index;
    return path;
}

// index 指向 { 之后：这张 inline table 的第一层是否有名为 name 的键。
static BOOL TomlInlineTableHasKey(NSString *text, NSUInteger index, NSString *name) {
    while (YES) {
        NSArray<NSString *> *key = TomlParseKey(text, &index);
        if (!key || index >= text.length || [text characterAtIndex:index] != '=') return NO;
        if ([key.firstObject isEqualToString:name]) return YES;
        NSInteger depth = 0;
        for (index++; index < text.length; index++) {
            unichar character = [text characterAtIndex:index];
            if (character == '"' || character == '\'') {
                index = TomlStringEnd(text, index);
            } else if (character == '{' || character == '[') {
                depth++;
            } else if (character == '}' || character == ']') {
                if (depth == 0) return NO;
                depth--;
            } else if (character == ',' && depth == 0) {
                break;
            }
        }
        if (index >= text.length) return NO;
        index++;
    }
}

// 只认 mcp_servers 下这个服务器的声明：表头、点号键、[mcp_servers] 表里的键，以及 inline table，
// 每一级都可以带引号。项目路径、其他服务器的参数里出现同样的文字都不算，否则卸载会误报"移除失败"；
// 真正的声明也不能漏，否则会跳过 mcp remove，注册还在却报告成功。
static BOOL TomlDeclaresMCPServer(NSString *text, NSString *name) {
    BOOL (^isServer)(NSArray<NSString *> *) = ^BOOL(NSArray<NSString *> *path) {
        return path.count >= 2 && [path[0] isEqualToString:@"mcp_servers"] && [path[1] isEqualToString:name];
    };
    TomlLexState state = TomlLexNormal;
    NSArray<NSString *> *table = @[];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (state == TomlLexNormal) {
            NSUInteger index = TomlSkipSpaces(line, 0);
            if (index < line.length && [line characterAtIndex:index] == '[') {
                index += index + 1 < line.length && [line characterAtIndex:index + 1] == '[' ? 2 : 1;
                NSArray<NSString *> *header = TomlParseKey(line, &index);
                if (header && index < line.length && [line characterAtIndex:index] == ']') {
                    if (isServer(header)) return YES;
                    table = header;
                }
            } else {
                NSArray<NSString *> *key = TomlParseKey(line, &index);
                if (key && index < line.length && [line characterAtIndex:index] == '=') {
                    NSArray<NSString *> *path = [table arrayByAddingObjectsFromArray:key];
                    if (isServer(path)) return YES;
                    NSUInteger value = TomlSkipSpaces(line, index + 1);
                    if ([path isEqualToArray:@[@"mcp_servers"]] && value < line.length && [line characterAtIndex:value] == '{' &&
                        TomlInlineTableHasKey(line, value + 1, name)) return YES;
                }
            }
        }
        state = AdvanceTomlState(line, state);
    }
    return NO;
}

// remove 对“本来就不存在”的注册也可能返回非零；只有确认不存在才按成功处理。
static BOOL HasMCPRegistration(NSString *provider, NSString *home, NSString *name) {
    if ([provider isEqualToString:@"claude"]) {
        NSString *official = CCPetsRealPath([CCPetsHomeDirectory() stringByAppendingPathComponent:@".claude"]);
        NSString *file = official && [CCPetsRealPath(home) isEqualToString:official]
            ? [CCPetsHomeDirectory() stringByAppendingPathComponent:@".claude.json"]
            : [home stringByAppendingPathComponent:@".claude.json"];
        CCPetsJSONObject *config = ReadJSONConfig(file);
        CCPetsJSONObject *servers = config[@"mcpServers"];
        return [servers isKindOfClass:CCPetsJSONObject.class] && servers[name] != nil;
    }
    NSString *file = [home stringByAppendingPathComponent:@"config.toml"];
    if (![NSFileManager.defaultManager fileExistsAtPath:file]) return NO;
    NSString *text = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
    if (!text) [NSException raise:@"CCBridgeConfig" format:@"Cannot read %@", file];
    return TomlDeclaresMCPServer(text, name);
}

static void RemoveMCPRegistration(NSString *executable, NSString *provider, NSString *home,
    NSString *name, NSMutableArray<NSString *> *report) {
    if (!HasMCPRegistration(provider, home, name)) return;
    NSArray *arguments = [provider isEqualToString:@"claude"]
        ? @[@"mcp", @"remove", @"--scope", @"user", name] : @[@"mcp", @"remove", name];
    BOOL removed = executable && RunQuietlyForHome(executable, arguments, provider, home);
    if (!removed || HasMCPRegistration(provider, home, name)) {
        [report addObject:[@"ERROR: " stringByAppendingString:LF(L(@"Could not remove MCP {name} from {home}."),
            (@{@"name": name, @"home": home}))]];
    } else {
        [report addObject:LF(L(@"Removed MCP {name} from {home}."), (@{@"name": name, @"home": home}))];
    }
}

NSArray<NSString *> *CCBridgeUninstallForProfile(NSDictionary *profile, BOOL unregisterMcp) {
    NSString *provider = [profile[@"provider"] isKindOfClass:NSString.class] ? profile[@"provider"] : @"";
    NSString *home = [profile[@"home"] isKindOfClass:NSString.class] ? profile[@"home"] : @"";
    NSMutableArray<NSString *> *report = [NSMutableArray array];
    if ([provider isEqualToString:@"claude"]) {
        if (RemoveJSONHooks([home stringByAppendingPathComponent:@"settings.json"], YES)) {
            [report addObject:L(@"Removed the cc-bridge hooks and tool permissions from Claude Code.")];
        }
        if (unregisterMcp) {
            NSString *claude = CCPetsFindRealExecutable(@"claude", @"CLAUDE_REAL_BIN");
            for (NSString *name in MCPNames()) RemoveMCPRegistration(claude, provider, home, name, report);
        }
    } else if ([provider isEqualToString:@"codex"]) {
        if (RemoveJSONHooks([home stringByAppendingPathComponent:@"hooks.json"], NO)) {
            [report addObject:L(@"Removed the cc-bridge hooks from Codex.")];
        }
        if ([NSFileManager.defaultManager fileExistsAtPath:[home stringByAppendingPathComponent:@"config.toml"]])
            SetCodexApprovalAtHome(@[], home);
        if (unregisterMcp) {
            NSString *codex = CCPetsFindRealExecutable(@"codex", @"CODEX_REAL_BIN");
            for (NSString *name in MCPNames()) RemoveMCPRegistration(codex, provider, home, name, report);
        }
    }
    return report;
}

// 文件不存在、或里面本来就没有我们的东西时不改写——用户的文件不该因为一次卸载被重排格式。
static BOOL RemoveJSONHooks(NSString *file, BOOL claudeAllow) {
    if (![NSFileManager.defaultManager fileExistsAtPath:file]) return NO;
    CCPetsJSONObject *config = ReadJSONConfig(file);
    BOOL changed = StripBridgeHooks(config);
    if (claudeAllow && ApplyClaudeAllow(config, @[])) changed = YES;
    if (!changed) return NO;
    WriteJSONConfig(file, config);
    return YES;
}
