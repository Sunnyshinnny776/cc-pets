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
        identity = [NSString stringWithFormat:@" CC_PETS_PROFILE_ID=%@ CC_PETS_PROFILE_NAME=%@",
            CCPetsShellQuote(profile[@"id"]), CCPetsShellQuote(profile[@"displayName"] ?: profile[@"slug"] ?: provider)];
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

static NSString *StripTomlBlocks(NSString *text) {
    for (NSArray<NSString *> *block in TomlBlocks()) {
        NSString *pattern = [NSString stringWithFormat:@"\\n?%@[\\s\\S]*?%@\\n?",
            [NSRegularExpression escapedPatternForString:block[0]], [NSRegularExpression escapedPatternForString:block[1]]];
        NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
        text = [expression stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@"\n"];
    }
    NSRegularExpression *blank = [NSRegularExpression regularExpressionWithPattern:@"\\n{3,}" options:0 error:nil];
    return [blank stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@"\n\n"];
}

static void SetCodexApprovalAtHome(NSArray<NSString *> *tools, NSString *codexHome) {
    NSString *file = [codexHome stringByAppendingPathComponent:@"config.toml"];
    struct stat info;
    BOOL exists = stat(file.fileSystemRepresentation, &info) == 0;
    NSString *original = exists ? ([NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil] ?: @"") : @"";
    // 只把末尾的空白收成一个换行：开头的空白属于用户的文件，原样保留。
    NSString *stripped = StripTomlBlocks(original);
    NSUInteger end = stripped.length;
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    while (end > 0 && [whitespace characterIsMember:[stripped characterAtIndex:end - 1]]) end--;
    NSString *updated = [[stripped substringToIndex:end] stringByAppendingString:@"\n"];
    if (tools.count > 0) updated = [updated stringByAppendingFormat:@"\n%@\n", CodexApprovalBlock(tools)];
    if ([updated isEqualToString:original]) return;
    NSString *error = nil;
    if (!CCPetsWriteFileAtomically(file, updated, exists ? (info.st_mode & 0777) : 0600, &error)) {
        [NSException raise:@"CCBridgeConfig" format:@"%@", error];
    }
}

static void SetCodexApproval(NSArray<NSString *> *tools) {
    SetCodexApprovalAtHome(tools, CCPetsCodexHome());
}

#pragma mark - MCP

static BOOL RunQuietly(NSString *executable, NSArray<NSString *> *arguments) {
    return CCPetsRun(executable, arguments, nil, nil, 60, NULL, NULL) == 0;
}

static BOOL RunQuietlyForHome(NSString *executable, NSArray<NSString *> *arguments,
    NSString *provider, NSString *home) {
    NSMutableDictionary<NSString *, NSString *> *environment =
        [NSProcessInfo.processInfo.environment mutableCopy];
    environment[[provider isEqualToString:@"claude"] ? @"CLAUDE_CONFIG_DIR" : @"CODEX_HOME"] = home;
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
    }
    SetCodexApprovalAtHome(options[@"codexApprove"], home);
    return report;
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
            if (!claude) [report addObject:[@"ERROR: " stringByAppendingString:
                L(@"Claude Code executable not found; MCP registration was not removed.")]];
            for (NSString *name in MCPNames()) {
                if (claude && RunQuietlyForHome(claude, @[@"mcp", @"remove", @"--scope", @"user", name], provider, home)) {
                    [report addObject:LF(L(@"Removed Claude Code MCP: {name}."), @{@"name": name})];
                }
            }
        }
    } else if ([provider isEqualToString:@"codex"]) {
        if (RemoveJSONHooks([home stringByAppendingPathComponent:@"hooks.json"], NO)) {
            [report addObject:L(@"Removed the cc-bridge hooks from Codex.")];
        }
        SetCodexApprovalAtHome(@[], home);
        if (unregisterMcp) {
            NSString *codex = CCPetsFindRealExecutable(@"codex", @"CODEX_REAL_BIN");
            if (!codex) [report addObject:[@"ERROR: " stringByAppendingString:
                L(@"Codex executable not found; MCP registration was not removed.")]];
            for (NSString *name in MCPNames()) {
                if (codex && RunQuietlyForHome(codex, @[@"mcp", @"remove", name], provider, home)) {
                    [report addObject:LF(L(@"Removed Codex MCP: {name}."), @{@"name": name})];
                }
            }
        }
    }
    return report;
}

NSArray<NSString *> *CCBridgeInstall(NSDictionary *rawOptions, BOOL registerMcp) {
    NSDictionary *options = CCBridgeNormalizeOptions(rawOptions);
    NSArray<NSString *> *claudeAllow = options[@"claudeAllow"];
    NSArray<NSString *> *codexApprove = options[@"codexApprove"];
    NSMutableArray<NSString *> *report = [NSMutableArray array];
    if (CCPetsClaudeCLIInstalled()) {
        [NSFileManager.defaultManager createDirectoryAtPath:CCPetsClaudeHome() withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *settingsPath = [CCPetsClaudeHome() stringByAppendingPathComponent:@"settings.json"];
        CCPetsJSONObject *config = ReadJSONConfig(settingsPath);
        StripBridgeHooks(config);
        AddClaudeHooks(config, options, nil);
        ApplyClaudeAllow(config, claudeAllow);
        WriteJSONConfig(settingsPath, config);
        [report addObject:LF(L(@"Claude Code hooks written to {path}"), @{@"path": settingsPath})];
        [report addObject:claudeAllow.count > 0
            ? LF(L(@"Claude Code allows these tools without asking: {claudeAllow}"), @{@"claudeAllow": [claudeAllow componentsJoinedByString:@", "]})
            : L(@"In Claude Code, cc-bridge tools follow your permission settings.")];
        if (registerMcp) {
            NSString *claude = CCPetsFindRealExecutable(@"claude", @"CLAUDE_REAL_BIN");
            for (NSString *name in MCPNames()) RunQuietly(claude ?: @"claude", @[@"mcp", @"remove", @"--scope", @"user", name]);
            BOOL ok = claude && RunQuietly(claude, ClaudeMCPAddArguments());
            [report addObject:ok
                ? LF(L(@"Claude Code MCP registered: {MCP_NAME} (on first use, Claude asks according to your permission settings)"), @{@"MCP_NAME": CCBridgeMCPName})
                : LF(L(@"Claude Code MCP registration failed. Run manually: claude {shellQuote}"), @{@"shellQuote": QuotedArguments(ClaudeMCPAddArguments())})];
        }
    } else {
        [report addObject:L(@"Claude Code CLI not detected, skipped.")];
    }

    if (CCPetsCodexCLIInstalled()) {
        [NSFileManager.defaultManager createDirectoryAtPath:CCPetsCodexHome() withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *hooksPath = [CCPetsCodexHome() stringByAppendingPathComponent:@"hooks.json"];
        CCPetsJSONObject *config = ReadJSONConfig(hooksPath);
        StripBridgeHooks(config);
        AddCodexHooks(config, options, nil);
        WriteJSONConfig(hooksPath, config);
        [report addObject:LF(L(@"Codex hooks written to {path}. Next time you start Codex, run /hooks and trust the cc-pets bridge hooks."), @{@"path": hooksPath})];
        if (registerMcp) {
            NSString *codex = CCPetsFindRealExecutable(@"codex", @"CODEX_REAL_BIN");
            for (NSString *name in MCPNames()) RunQuietly(codex ?: @"codex", @[@"mcp", @"remove", name]);
            BOOL ok = codex && RunQuietly(codex, CodexMCPAddArguments());
            [report addObject:ok
                ? LF(L(@"Codex MCP registered: {MCP_NAME}"), @{@"MCP_NAME": CCBridgeMCPName})
                : LF(L(@"Codex MCP registration failed. Run manually: codex {shellQuote}"), @{@"shellQuote": QuotedArguments(CodexMCPAddArguments())})];
            // 只在 enable / refresh 时探测：configure 由桌宠菜单开关触发，不值得每次多拉起两次 codex。
            if ([options[@"wake"] boolValue]) {
                NSString *notice = CCBridgeDescribeCodexQueue(CCBridgeProbeCodexQueue(codex));
                if (notice) [report addObject:notice];
            }
        }
        SetCodexApproval(codexApprove);
        [report addObject:codexApprove.count > 0
            ? LF(L(@"Codex auto-approves these tools: {codexApprove} (restart Codex sessions to apply)"), @{@"codexApprove": [codexApprove componentsJoinedByString:@", "]})
            : L(@"cc-bridge tools keep Codex's default approvals (calls fail under approval_policy=never; allow them with --codex-approve).")];
    } else {
        [report addObject:L(@"Codex CLI not detected, skipped.")];
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

NSArray<NSString *> *CCBridgeUninstall(BOOL unregisterMcp) {
    NSMutableArray<NSString *> *report = [NSMutableArray array];
    if (RemoveJSONHooks([CCPetsClaudeHome() stringByAppendingPathComponent:@"settings.json"], YES)) {
        [report addObject:L(@"Removed the cc-bridge hooks and tool permissions from Claude Code.")];
    }
    if (RemoveJSONHooks([CCPetsCodexHome() stringByAppendingPathComponent:@"hooks.json"], NO)) {
        [report addObject:L(@"Removed the cc-bridge hooks from Codex.")];
    }
    if ([NSFileManager.defaultManager fileExistsAtPath:[CCPetsCodexHome() stringByAppendingPathComponent:@"config.toml"]]) {
        SetCodexApproval(@[]);
    }
    if (unregisterMcp) {
        NSString *claude = CCPetsFindRealExecutable(@"claude", @"CLAUDE_REAL_BIN");
        for (NSString *name in MCPNames()) {
            if (claude && RunQuietly(claude, @[@"mcp", @"remove", @"--scope", @"user", name])) {
                [report addObject:LF(L(@"Removed Claude Code MCP: {name}."), @{@"name": name})];
            }
        }
        NSString *codex = CCPetsFindRealExecutable(@"codex", @"CODEX_REAL_BIN");
        for (NSString *name in MCPNames()) {
            if (codex && RunQuietly(codex, @[@"mcp", @"remove", name])) {
                [report addObject:LF(L(@"Removed Codex MCP: {name}."), @{@"name": name})];
            }
        }
    }
    return report;
}
