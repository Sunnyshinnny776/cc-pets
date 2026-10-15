#import "CCPetsL10n.h"
#import "CCPetsDoctor.h"
#import "CCPetsBridge.h"
#import "CCPetsBridgeSetup.h"
#import "CCPetsBridgeStore.h"
#import "CCPetsCLISupport.h"
#import "CCPetsCleanup.h"
#import "CCPetsIntegrations.h"
#import "CCPetsPhrases.h"
#import "CCPetsVersion.h"
#import <sys/stat.h>
#import <sys/utsname.h>
#import <math.h>

#define LF(localized, values) CCPetsInterpolate(localized, values)

// npm 包目录：可执行文件在 <包目录>/.build/release/cc-pets。
static NSString *PackageDirectory(void) {
    return CCPetsExecutablePath().stringByDeletingLastPathComponent.stringByDeletingLastPathComponent
        .stringByDeletingLastPathComponent;
}

static NSString *PetBinary(void) {
    return [PackageDirectory() stringByAppendingPathComponent:@".build/release/cc-pets"];
}

// 版本以 package.json 为准（npm 安装的就是它）；读不到时退回编进二进制的版本。
static NSString *PackageVersion(void) {
    NSData *data = [NSData dataWithContentsOfFile:[PackageDirectory() stringByAppendingPathComponent:@"package.json"]];
    NSDictionary *package = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *version = [package isKindOfClass:NSDictionary.class] && [package[@"version"] isKindOfClass:NSString.class]
        ? package[@"version"] : nil;
    return version ?: @CC_PETS_VERSION;
}

static NSString *ShellRC(void) {
    return [(CCPetsEnvironmentValue(@"ZDOTDIR") ?: CCPetsHomeDirectory()) stringByAppendingPathComponent:@".zshrc"];
}

static NSString *InstalledApp(void) {
    return [(CCPetsEnvironmentValue(@"CC_PETS_APPLICATIONS_DIR") ?: [CCPetsHomeDirectory() stringByAppendingPathComponent:@"Applications"])
        stringByAppendingPathComponent:@"CC Pets.app"];
}

static NSDictionary<NSString *, id> *NativePaths(void) {
    NSMutableDictionary *paths = [CCPetsDataPaths() mutableCopy];
    paths[@"phrases"] = PetPhrasesFilePath();
    paths[@"petPhrases"] = PetPhrasesPetDirectory();
    return paths;
}

// 文件 / 目录占用的字节数，不存在时为 nil。软链按软链本身算，不跟进去。
static NSNumber *SizeOf(NSString *target) {
    struct stat info;
    if (lstat(target.fileSystemRepresentation, &info) != 0) return nil;
    if (!S_ISDIR(info.st_mode)) return @(info.st_size);
    unsigned long long total = 0;
    for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:target error:nil]) {
        total += [SizeOf([target stringByAppendingPathComponent:entry]) unsignedLongLongValue];
    }
    return @(total);
}

static NSString *FormatSize(NSNumber *bytes) {
    if (!bytes) return L(@"missing");
    double value = bytes.doubleValue;
    if (value < 1024) return [NSString stringWithFormat:@"%llu B", bytes.unsignedLongLongValue];
    if (value < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB", value / 1024];
    return [NSString stringWithFormat:@"%.1f MB", value / 1024 / 1024];
}

// 终端里中文占两列，按字符数对齐会错位。
static NSUInteger DisplayWidth(NSString *text) {
    NSUInteger width = 0;
    for (NSUInteger index = 0; index < text.length; index++) {
        unichar character = [text characterAtIndex:index];
        BOOL wide = (character >= 0x1100 && character <= 0x115f) || (character >= 0x2e80 && character <= 0xa4cf) ||
            (character >= 0xac00 && character <= 0xd7a3) || (character >= 0xf900 && character <= 0xfaff) ||
            (character >= 0xfe30 && character <= 0xfe4f) || (character >= 0xff00 && character <= 0xff60) ||
            (character >= 0xffe0 && character <= 0xffe6);
        width += wide ? 2 : 1;
    }
    return width;
}

// 读 JSON 配置：@{value} 或 @{error: missing | invalid}。
static NSDictionary *ReadJSONFile(NSString *file) {
    NSData *data = [NSData dataWithContentsOfFile:file];
    if (!data) return @{@"error": [NSFileManager.defaultManager fileExistsAtPath:file] ? @"invalid" : @"missing"};
    id value = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil];
    return value ? @{@"value": value} : @{@"error": @"invalid"};
}

#pragma mark - cc-pets paths

static NSArray<NSDictionary *> *PathGroups(NSDictionary *native) {
    return @[
        @{@"title": L(@"Settings (removed by --purge)"), @"items": @[@[L(@"Preferences"), native[@"preferences"]]]},
        @{@"title": L(@"Your content (kept by both clean and --purge)"), @"items": @[
            @[L(@"Pet sprites"), native[@"pets"]],
            @[L(@"Shared lines"), native[@"phrases"]],
            @[L(@"Per-pet lines"), native[@"petPhrases"]],
            @[L(@"CC Bridge switch"), [CCBridgeHomeDirectory() stringByAppendingPathComponent:@"bridge-enabled"]],
            @[@"codex / claude shim", CCPetsShimDirectory()]
        ]},
        @{@"title": L(@"App data (removed by --purge; clean only clears the token cache and update log)"), @"items": @[
            @[L(@"App data directory"), native[@"applicationSupport"]],
            @[L(@"Quota history"), native[@"quotaHistory"]],
            @[L(@"Auto-update config"), [native[@"applicationSupport"] stringByAppendingPathComponent:@"updater.json"]]
        ]},
        @{@"title": L(@"Caches and runtime state (cleared by clean; safe to lose)"), @"items": @[
            @[L(@"Pet store manifest cache"), native[@"petStoreCache"]],
            @[L(@"Agent event stream"), native[@"agentEvents"]],
            @[L(@"Claude quota snapshot"), native[@"claudeUsage"]],
            @[L(@"Codex live quota"), native[@"codexLiveUsage"]],
            @[L(@"Codex launch records"), native[@"codexLaunches"]],
            @[L(@"Online client records"), native[@"clients"]],
            @[L(@"CC Bridge state directory"), CCBridgeStateDirectory()]
        ]},
        @{@"title": L(@"Program and integrations"), @"items": @[
            @[L(@"npm package"), PackageDirectory()],
            @[L(@"Installed app"), InstalledApp()],
            @[L(@"Claude Code settings"), [CCPetsClaudeHome() stringByAppendingPathComponent:@"settings.json"]],
            @[@"Codex Hooks", [CCPetsCodexHome() stringByAppendingPathComponent:@"hooks.json"]],
            @[L(@"Shell config"), ShellRC()]
        ]}
    ];
}

static int PrintPaths(BOOL asJSON) {
    NSDictionary *native = NativePaths();
    NSArray<NSDictionary *> *groups = PathGroups(native);
    if (asJSON) {
        NSMutableArray *documentGroups = [NSMutableArray array];
        for (NSDictionary *group in groups) {
            NSMutableArray *items = [NSMutableArray array];
            for (NSArray *item in group[@"items"]) {
                [items addObject:@{@"label": item[0], @"path": CCPetsTildePath(item[1]), @"bytes": SizeOf(item[1]) ?: NSNull.null}];
            }
            [documentGroups addObject:@{@"title": group[@"title"], @"items": items}];
        }
        NSDictionary *document = @{@"version": PackageVersion(), @"running": native[@"running"] ?: NSNull.null, @"groups": documentGroups};
        NSData *json = [NSJSONSerialization dataWithJSONObject:document
            options:NSJSONWritingPrettyPrinted | NSJSONWritingWithoutEscapingSlashes error:nil];
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
        return 0;
    }
    NSUInteger width = 0;
    for (NSDictionary *group in groups) {
        for (NSArray *item in group[@"items"]) width = MAX(width, DisplayWidth(item[0]));
    }
    [groups enumerateObjectsUsingBlock:^(NSDictionary *group, NSUInteger index, BOOL *stop) {
        if (index > 0) CCPetsPrintLine(stdout, @"");
        CCPetsPrintLine(stdout, group[@"title"]);
        for (NSArray *item in group[@"items"]) {
            NSString *padding = [@"" stringByPaddingToLength:width - DisplayWidth(item[0]) + 2 withString:@" " startingAtIndex:0];
            CCPetsPrintLine(stdout, [NSString stringWithFormat:@"  %@%@%@  (%@)", item[0], padding, CCPetsTildePath(item[1]),
                FormatSize(SizeOf(item[1]))]);
        }
    }];
    return 0;
}

#pragma mark - cc-pets doctor

static NSDictionary *Result(NSString *level, NSString *title, NSString *fix) {
    return fix ? @{@"level": level, @"title": title, @"fix": fix} : @{@"level": level, @"title": title};
}

static NSString *VersionOfApp(NSString *appPath) {
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Contents/Info.plist"]];
    NSString *version = [plist[@"CFBundleShortVersionString"] isKindOfClass:NSString.class] ? plist[@"CFBundleShortVersionString"] : nil;
    return version.length > 0 ? version : nil;
}

// 认出配置里属于 CC Pets 的 hook，并区分"指向当前安装"和"指向别处"（包被挪走、换了 node 版本重装后常见，
// hook 每次触发都会失败）。
static NSDictionary *InspectHooks(NSString *configFile, NSString *marker, NSString *legacyMarker) {
    NSDictionary *read = ReadJSONFile(configFile);
    if ([read[@"error"] isEqual:@"invalid"]) return @{@"error": @"invalid"};
    NSDictionary *value = [read[@"value"] isKindOfClass:NSDictionary.class] ? read[@"value"] : nil;
    NSDictionary *hooks = [value[@"hooks"] isKindOfClass:NSDictionary.class] ? value[@"hooks"] : nil;
    NSMutableArray *commands = [NSMutableArray array];
    for (id groups in hooks.allValues) {
        if (![groups isKindOfClass:NSArray.class]) continue;
        for (id group in groups) {
            NSArray *handlers = [group isKindOfClass:NSDictionary.class] ? group[@"hooks"] : nil;
            if (![handlers isKindOfClass:NSArray.class]) continue;
            for (id handler in handlers) {
                id command = [handler isKindOfClass:NSDictionary.class] ? handler[@"command"] : nil;
                [commands addObject:command ?: NSNull.null];
            }
        }
    }
    NSString *current = [NSString stringWithFormat:@"'%@'", PetBinary()];
    NSUInteger total = 0, stale = 0, legacy = 0, bridge = 0;
    for (id command in commands) {
        if (CCPetsIsManagedHookCommand(command, marker, @"cc-pets")) {
            total++;
            if (![command containsString:current]) stale++;
        }
        if (CCPetsIsManagedHookCommand(command, legacyMarker, @"codex-pet")) legacy++;
        if ([command isKindOfClass:NSString.class] && [command hasPrefix:CCBridgeHookMarker]) bridge++;
    }
    return @{@"total": @(total), @"stale": @(stale), @"legacy": @(legacy), @"bridge": @(bridge)};
}

static NSArray<NSDictionary *> *HookChecks(NSString *name, NSString *configFile, NSString *marker, NSString *legacyMarker,
    NSUInteger *bridgeHooks) {
    NSDictionary *hooks = InspectHooks(configFile, marker, legacyMarker);
    *bridgeHooks = [hooks[@"bridge"] unsignedIntegerValue];
    if (hooks[@"error"]) {
        return @[Result(@"fail", LF(L(@"Can't parse {name} config: {configFile}"), (@{@"name": name, @"configFile": CCPetsTildePath(configFile)})),
            L(@"Fix that JSON file, then run cc-pets install"))];
    }
    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    NSUInteger total = [hooks[@"total"] unsignedIntegerValue], stale = [hooks[@"stale"] unsignedIntegerValue];
    NSUInteger legacy = [hooks[@"legacy"] unsignedIntegerValue];
    if (total == 0) {
        [results addObject:Result(@"fail", LF(L(@"{name} hooks not installed"), @{@"name": name}), @"cc-pets install")];
    } else if (stale > 0) {
        NSDictionary *values = @{@"name": name, @"stale": @(stale)};
        [results addObject:Result(@"warn", stale != 1
            ? LF(L(@"{stale} {name} hooks point to cc-pets elsewhere (the package was moved or reinstalled)"), values)
            : LF(L(@"{stale} {name} hook points to cc-pets elsewhere (the package was moved or reinstalled)"), values), @"cc-pets install")];
    } else {
        [results addObject:Result(@"ok", LF(L(@"{name} hooks installed ({total} events)"), (@{@"name": name, @"total": @(total)})), nil)];
    }
    if (legacy > 0) {
        NSDictionary *values = @{@"name": name, @"legacy": @(legacy)};
        [results addObject:Result(@"warn", legacy != 1
            ? LF(L(@"{name} config still has {legacy} old codex-pet hooks"), values)
            : LF(L(@"{name} config still has {legacy} old codex-pet hook"), values), @"cc-pets install")];
    }
    return results;
}

static NSDictionary *StatusLineCheck(void) {
    NSDictionary *value = ReadJSONFile([CCPetsClaudeHome() stringByAppendingPathComponent:@"settings.json"])[@"value"];
    NSDictionary *statusLine = [value isKindOfClass:NSDictionary.class] && [value[@"statusLine"] isKindOfClass:NSDictionary.class]
        ? value[@"statusLine"] : nil;
    NSString *command = [statusLine[@"command"] isKindOfClass:NSString.class] ? statusLine[@"command"] : @"";
    if (CCPetsIsManagedStatusLine(command, CCPetsStatusLineMarker)) {
        return Result(@"ok", L(@"Claude status line feeds quota data through the wrapper"), nil);
    }
    NSString *script = CCPetsParseStatusLineCommand(command)[@"script"];
    NSString *content = script ? ([NSString stringWithContentsOfFile:script encoding:NSUTF8StringEncoding error:nil] ?: @"") : @"";
    if ([content containsString:CCPetsStatusLineStartMarker]) {
        return [content containsString:[NSString stringWithFormat:@"'%@'", PetBinary()]]
            ? Result(@"ok", LF(L(@"Claude status line feeds quota data ({script})"), @{@"script": CCPetsTildePath(script)}), nil)
            : Result(@"warn", L(@"The quota hook in the Claude status line points to cc-pets elsewhere"), @"cc-pets install");
    }
    return Result(@"warn", command.length > 0
        ? L(@"Claude status line doesn't feed quota data, so the pet can't show Claude quota %")
        : L(@"No Claude status line configured, so the pet can't show Claude quota %"), @"cc-pets install");
}

static NSArray<NSDictionary *> *ShimChecks(void) {
    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    NSString *shellRC = ShellRC();
    NSString *rc = [NSString stringWithContentsOfFile:shellRC encoding:NSUTF8StringEncoding error:nil] ?: @"";
    [results addObject:[rc containsString:CCPetsShimStartMarker]
        ? Result(@"ok", LF(L(@"{shellRC} adds the shim directory"), @{@"shellRC": CCPetsTildePath(shellRC)}), nil)
        : Result(@"fail", LF(L(@"{shellRC} has no CC Pets shim setup"), @{@"shellRC": CCPetsTildePath(shellRC)}), @"cc-pets install")];

    NSString *shimDirectory = CCPetsShimDirectory();
    NSMutableArray<NSString *> *broken = [NSMutableArray array];
    for (NSString *name in @[@"codex", @"claude"]) {
        NSString *link = [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:[shimDirectory stringByAppendingPathComponent:name] error:nil];
        if (!link) {
            [broken addObject:LF(L(@"{name} (missing)"), @{@"name": name})];
            continue;
        }
        NSString *target = [link hasPrefix:@"/"] ? link : [shimDirectory stringByAppendingPathComponent:link];
        if (![NSFileManager.defaultManager fileExistsAtPath:CCPetsResolvePath(target)]) {
            [broken addObject:LF(L(@"{name} (target doesn't exist)"), @{@"name": name})];
        }
    }
    [results addObject:broken.count == 0
        ? Result(@"ok", LF(L(@"Shims complete: {shimDirectory}"), @{@"shimDirectory": CCPetsTildePath(shimDirectory)}), nil)
        : Result(@"warn", LF(L(@"Shim problems: {broken}"), @{@"broken": [broken componentsJoinedByString:L(@", ")]}), @"cc-pets install")];

    NSMutableArray<NSString *> *entries = [NSMutableArray array];
    for (NSString *entry in [CCPetsEnvironmentValue(@"PATH") ?: @"" componentsSeparatedByString:@":"]) {
        if (entry.length > 0) [entries addObject:CCPetsResolvePath(entry)];
    }
    NSUInteger index = [entries indexOfObject:shimDirectory];
    NSString *sourceHint = LF(L(@"source {shellRC}, or open a new terminal"), @{@"shellRC": CCPetsTildePath(shellRC)});
    if (index == NSNotFound) {
        [results addObject:Result(@"warn", L(@"This terminal's PATH lacks the shim directory, so typing codex / claude won't start the pet"), sourceHint)];
    } else if (index > 0) {
        NSString *shadowing = nil;
        for (NSString *entry in [entries subarrayWithRange:NSMakeRange(0, index)]) {
            for (NSString *name in @[@"codex", @"claude"]) {
                if (!shadowing && [NSFileManager.defaultManager fileExistsAtPath:[entry stringByAppendingPathComponent:name]]) shadowing = entry;
            }
        }
        [results addObject:shadowing
            ? Result(@"warn", LF(L(@"{shadowing} comes before the shim directory in PATH and bypasses the pet"), @{@"shadowing": CCPetsTildePath(shadowing)}), sourceHint)
            : Result(@"ok", L(@"The shim directory comes before the real codex / claude in PATH"), nil)];
    } else {
        [results addObject:Result(@"ok", L(@"The shim directory is first in PATH"), nil)];
    }
    return results;
}

static NSDictionary *RealBinaryCheck(NSString *name, NSString *variable) {
    NSString *real = CCPetsFindRealExecutable(name, variable);
    return real && [NSFileManager.defaultManager fileExistsAtPath:real]
        ? Result(@"ok", LF(L(@"Found the real {name}: {real}"), (@{@"name": name, @"real": CCPetsTildePath(real)})), nil)
        : Result(@"warn", LF(L(@"The real {name} isn't in PATH, so the shim can't forward to it"), @{@"name": name}),
            [NSString stringWithFormat:@"export %@=/absolute/path/to/%@", variable, name]);
}

static NSDictionary *UpdaterCheck(NSDictionary *native) {
    NSString *file = [native[@"applicationSupport"] stringByAppendingPathComponent:@"updater.json"];
    NSDictionary *read = ReadJSONFile(file);
    NSString *fix = @"npm install -g cc-pets@latest --allow-scripts=cc-pets";
    if (read[@"error"]) return Result(@"warn", L(@"Auto-update isn't configured, so in-app updates won't work"), fix);
    NSDictionary *value = [read[@"value"] isKindOfClass:NSDictionary.class] ? read[@"value"] : @{};
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSString *key in @[@"nodePath", @"npmCliPath"]) {
        NSString *path = [value[key] isKindOfClass:NSString.class] ? value[key] : nil;
        if (path.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:path]) [missing addObject:key];
    }
    return missing.count == 0
        ? Result(@"ok", L(@"Auto-update config is valid"), nil)
        : Result(@"warn", LF(L(@"The {missing} recorded for auto-update no longer exist (changed Node versions?)"),
            @{@"missing": [missing componentsJoinedByString:L(@", ")]}), fix);
}

static NSString *FormatAge(NSTimeInterval seconds) {
    long long minutes = llround(seconds / 60);
    if (minutes < 60) return LF(L(@"{minutes} min ago"), @{@"minutes": @(minutes)});
    long long hours = llround(minutes / 60.0);
    return hours < 48 ? LF(L(@"{hours} h ago"), @{@"hours": @(hours)}) : LF(L(@"{days} days ago"), @{@"days": @(llround(hours / 24.0))});
}

static int RunDoctor(void) {
    NSDictionary *native = NativePaths();
    NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];
    BOOL claudeDetected = CCPetsClaudeCLIInstalled();
    BOOL codexDetected = CCPetsCodexCLIInstalled();
    NSString *packageVersion = PackageVersion();

    NSMutableArray<NSDictionary *> *program = [NSMutableArray arrayWithObject:
        Result(@"info", LF(L(@"npm package {packageVersion}: {projectDir}"),
            (@{@"packageVersion": packageVersion, @"projectDir": CCPetsTildePath(PackageDirectory())})), nil)];
    NSString *binaryVersion = @CC_PETS_VERSION;
    if (![binaryVersion isEqualToString:packageVersion]) {
        [program addObject:Result(@"warn", LF(L(@"Native binary {binaryVersion} doesn't match npm package {packageVersion}"),
            (@{@"binaryVersion": binaryVersion, @"packageVersion": packageVersion})), @"cc-pets install")];
    } else {
        [program addObject:Result(@"ok", LF(L(@"Native binary {binaryVersion}"), @{@"binaryVersion": binaryVersion}), nil)];
    }
    NSString *appVersion = VersionOfApp(InstalledApp());
    if (!appVersion) {
        [program addObject:Result(@"warn", LF(L(@"Installed app not found: {installedApp}"), @{@"installedApp": CCPetsTildePath(InstalledApp())}), @"cc-pets install")];
    } else if (![appVersion isEqualToString:packageVersion]) {
        [program addObject:Result(@"warn", LF(L(@"Installed app {appVersion} doesn't match npm package {packageVersion}"),
            (@{@"appVersion": appVersion, @"packageVersion": packageVersion})), @"cc-pets install")];
    } else {
        [program addObject:Result(@"ok", LF(L(@"Installed app {appVersion}"), @{@"appVersion": appVersion}), nil)];
    }
    [program addObject:Result(@"info", [native[@"running"] boolValue] ? L(@"The pet is running") : L(@"The pet isn't running"), nil)];
    [program addObject:UpdaterCheck(native)];
    [sections addObject:@{@"title": L(@"Program"), @"results": program}];

    NSUInteger claudeBridgeHooks = 0;
    if (claudeDetected) {
        NSMutableArray *claude = [HookChecks(@"Claude Code", [CCPetsClaudeHome() stringByAppendingPathComponent:@"settings.json"],
            CCPetsClaudeHookMarker, CCPetsLegacyClaudeHookMarker, &claudeBridgeHooks) mutableCopy];
        [claude addObject:StatusLineCheck()];
        NSDate *modified = [NSFileManager.defaultManager attributesOfItemAtPath:native[@"claudeUsage"] error:nil].fileModificationDate;
        [claude addObject:modified
            ? Result(@"info", LF(L(@"Claude quota snapshot updated {age}"), @{@"age": FormatAge(-modified.timeIntervalSinceNow)}), nil)
            : Result(@"info", L(@"No Claude quota snapshot yet (created after Claude Code's first API response)"), nil)];
        [sections addObject:@{@"title": @"Claude Code", @"results": claude}];
    } else {
        [sections addObject:@{@"title": @"Claude Code", @"results": @[Result(@"info", L(@"Claude Code CLI not detected, skipped"), nil)]}];
    }

    NSUInteger codexBridgeHooks = 0;
    if (codexDetected) {
        NSMutableArray *codex = [HookChecks(@"Codex", [CCPetsCodexHome() stringByAppendingPathComponent:@"hooks.json"],
            CCPetsCodexHookMarker, CCPetsLegacyCodexHookMarker, &codexBridgeHooks) mutableCopy];
        [codex addObject:Result(@"info", L(@"Codex only runs CC Pets hooks after you trust them in /hooks (can't be checked automatically)"), nil)];
        [sections addObject:@{@"title": @"Codex", @"results": codex}];
    } else {
        [sections addObject:@{@"title": @"Codex", @"results": @[Result(@"info", L(@"Codex CLI not detected, skipped"), nil)]}];
    }

    NSMutableArray *shell = [ShimChecks() mutableCopy];
    if (codexDetected) [shell addObject:RealBinaryCheck(@"codex", @"CODEX_REAL_BIN")];
    if (claudeDetected) [shell addObject:RealBinaryCheck(@"claude", @"CLAUDE_REAL_BIN")];
    [sections addObject:@{@"title": L(@"Shell integration"), @"results": shell}];

    if (!CCBridgeEnabled()) {
        [sections addObject:@{@"title": @"CC Bridge", @"results": @[Result(@"info", L(@"Off (optional; turn on with cc-pets bridge enable)"), nil)]}];
    } else {
        NSMutableArray *bridge = [NSMutableArray arrayWithObject:Result(@"ok", L(@"Enabled"), nil)];
        if (claudeDetected) {
            [bridge addObject:claudeBridgeHooks > 0 ? Result(@"ok", L(@"CC Bridge hooks installed in Claude Code"), nil)
                : Result(@"warn", L(@"CC Bridge hooks missing in Claude Code"), @"cc-pets bridge enable")];
        }
        if (codexDetected) {
            [bridge addObject:codexBridgeHooks > 0 ? Result(@"ok", L(@"CC Bridge hooks installed in Codex"), nil)
                : Result(@"warn", L(@"CC Bridge hooks missing in Codex"), @"cc-pets bridge enable")];
            if ([CCBridgeOptions()[@"wake"] boolValue]) {
                NSString *notice = CCBridgeDescribeCodexQueue(CCBridgeProbeCodexQueue(CCPetsFindRealExecutable(@"codex", @"CODEX_REAL_BIN")));
                [bridge addObject:notice ? Result(@"warn", notice, nil)
                    : Result(@"ok", L(@"Codex supports codex queue, so it can be woken automatically"), nil)];
            }
        }
        [sections addObject:@{@"title": @"CC Bridge", @"results": bridge}];
    }

    struct utsname system;
    uname(&system);
    CCPetsPrintLine(stdout, LF(L(@"CC Pets diagnostics (npm package {packageVersion}, {platform} {release})"),
        (@{@"packageVersion": packageVersion, @"platform": @"darwin", @"release": @(system.release)})));
    NSDictionary<NSString *, NSString *> *icons = @{@"ok": @"✅", @"warn": @"⚠️ ", @"fail": @"❌", @"info": @"ℹ️ "};
    NSCountedSet<NSString *> *counts = [NSCountedSet set];
    for (NSDictionary *section in sections) {
        CCPetsPrintLine(stdout, [@"\n" stringByAppendingString:section[@"title"]]);
        for (NSDictionary *result in section[@"results"]) {
            [counts addObject:result[@"level"]];
            CCPetsPrintLine(stdout, [NSString stringWithFormat:@"  %@ %@", icons[result[@"level"]], result[@"title"]]);
            if (result[@"fix"]) CCPetsPrintLine(stdout, [NSString stringWithFormat:@"     → %@", result[@"fix"]]);
        }
    }
    NSUInteger warn = [counts countForObject:@"warn"], fail = [counts countForObject:@"fail"];
    NSString *warnings = warn != 1 ? LF(L(@"{count} warnings"), @{@"count": @(warn)}) : LF(L(@"{count} warning"), @{@"count": @(warn)});
    NSString *errors = fail != 1 ? LF(L(@"{count} errors"), @{@"count": @(fail)}) : LF(L(@"{count} error"), @{@"count": @(fail)});
    CCPetsPrintLine(stdout, LF(L(@"\nResult: {ok} OK, {warnings}, {errors}."),
        (@{@"ok": @([counts countForObject:@"ok"]), @"warnings": warnings, @"errors": errors})));
    if (fail + warn > 0) CCPetsPrintLine(stdout, L(@"Most problems are fixed by cc-pets install; see cc-pets paths for data locations."));
    return fail > 0 ? 1 : 0;
}

int CCPetsDoctorMain(NSArray<NSString *> *arguments) {
    NSString *command = arguments.firstObject;
    if ([command isEqualToString:@"paths"]) return PrintPaths([arguments containsObject:@"--json"]);
    if ([command isEqualToString:@"doctor"]) return RunDoctor();
    CCPetsPrintLine(stderr, L(@"Usage: cc-pets paths [--json] | cc-pets doctor"));
    return 2;
}
