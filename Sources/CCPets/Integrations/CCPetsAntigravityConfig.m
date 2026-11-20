#import "CCPetsAntigravityConfig.h"
#import "CCPetsBridge.h"
#import "CCPetsBridgeSetup.h"
#import "CCPetsBridgeStore.h"
#import "CCPetsCLISupport.h"
#import "CCPetsJSON.h"
#import "CCPetsL10n.h"
#import "CCPetsProfiles.h"
#import <errno.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const HookName = @"cc-pets-cli";
static NSString *const HookMarker = @"CC_PETS_AGY_HOOK=1 ";
static NSString *const MCPMarker = @"CC_PETS_AGY_MCP";
static NSString *const StatusLineMarker = @"CC_PETS_AGY_STATUS_LINE='";
static NSString *const BridgeTitleMarker = @"CC_PETS_AGY_BRIDGE_TITLE='";
static NSString *const AppSidecarName = @"cc-pets-bridge";
static NSString *const AppSidecarDescription = @"CC Pets Bridge delivery for Antigravity App";

static NSString *ProfileFile(NSDictionary *profile, NSString *relative) {
    NSString *home = profile[@"home"];
    if (![home isKindOfClass:NSString.class] || !home.isAbsolutePath) {
        [NSException raise:@"CCPetsAntigravityConfig" format:@"Invalid Antigravity profile home"];
    }
    return [home stringByAppendingPathComponent:relative];
}

static CCPetsJSONObject *Object(id value) {
    return [value isKindOfClass:CCPetsJSONObject.class] ? value : nil;
}

CCPetsJSONObject *CCPetsReadAntigravityConfig(NSString *path, NSString **errorMessage) {
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&readError];
    if (!data) {
        if (errorMessage && !([readError.domain isEqual:NSCocoaErrorDomain] &&
            (readError.code == NSFileReadNoSuchFileError || readError.code == NSFileNoSuchFileError))) {
            *errorMessage = readError.localizedDescription;
        }
        return nil;
    }
    const unsigned char *bytes = data.bytes;
    NSUInteger index = 0;
    while (index < data.length && (bytes[index] == ' ' || bytes[index] == '\t' ||
        bytes[index] == '\r' || bytes[index] == '\n')) index++;
    if (index == data.length) return nil;
    id document = CCPetsJSONParse(data, errorMessage);
    if (document && !Object(document)) {
        if (errorMessage) *errorMessage = L(@"Expected a JSON object.");
        return nil;
    }
    return document;
}

static CCPetsJSONObject *ReadConfig(NSString *path) {
    NSString *error = nil;
    CCPetsJSONObject *document = CCPetsReadAntigravityConfig(path, &error);
    if (error) [NSException raise:@"CCPetsAntigravityConfig" format:@"%@: %@", path, error];
    return document;
}

static BOOL UpdateConfig(NSString *path, BOOL (^update)(CCPetsJSONObject *)) {
    NSString *lock = [@"agy-config-" stringByAppendingString:CCBridgeSHA1Hex(path)];
    return [CCBridgeWithLock(lock, ^id {
        CCPetsJSONObject *document = ReadConfig(path) ?: [CCPetsJSONObject new];
        if (!update(document)) return @NO;
        NSError *directoryError = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:&directoryError]) {
            [NSException raise:@"CCPetsAntigravityConfig" format:@"%@", directoryError.localizedDescription];
        }
        struct stat info;
        mode_t mode = stat(path.fileSystemRepresentation, &info) == 0 ? info.st_mode & 0777 : 0600;
        NSString *error = nil;
        if (!CCPetsWriteFileAtomically(path, [CCPetsJSONStringify(document) stringByAppendingString:@"\n"], mode, &error)) {
            [NSException raise:@"CCPetsAntigravityConfig" format:@"%@", error];
        }
        return @YES;
    }) boolValue];
}

static NSArray<NSString *> *Events(void) {
    return @[@"SessionStart", @"PreInvocation", @"PreToolUse", @"PostToolUse", @"Stop"];
}

static NSString *ProfileEnvironment(NSDictionary *profile) {
    return [NSString stringWithFormat:@"CC_PETS_PROFILE_ID=%@ CC_PETS_PROFILE_NAME=%@ CC_PETS_PROFILE_HOME=%@",
        CCPetsShellQuote(profile[@"id"] ?: @""), CCPetsShellQuote(profile[@"displayName"] ?: @"Antigravity"),
        CCPetsShellQuote(profile[@"home"])];
}

// The managed command carries its previous settings so repair/uninstall does not require a second file.
static CCPetsJSONObject *WrappedCommandBackup(id command, NSString *marker) {
    if (![command isKindOfClass:NSString.class] || ![command hasPrefix:marker]) return nil;
    NSString *suffix = [command substringFromIndex:marker.length];
    NSRange end = [suffix rangeOfString:@"';"];
    if (end.location == NSNotFound) return nil;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:[suffix substringToIndex:end.location] options:0];
    return data ? Object(CCPetsJSONParse(data, NULL)) : nil;
}

static void ChangeStatusLine(NSDictionary *profile, BOOL install) {
    UpdateConfig(ProfileFile(profile, @"antigravity-cli/settings.json"), ^BOOL(CCPetsJSONObject *document) {
        CCPetsJSONObject *line = Object(document[@"statusLine"]);
        // Let the CLI keep its existing behavior for an older or unrecognized form.
        if (document[@"statusLine"] && !line) return NO;
        id command = line[@"command"];
        if (command && ![command isKindOfClass:NSString.class]) return NO;
        CCPetsJSONObject *previous = WrappedCommandBackup(command, StatusLineMarker);
        if (!install) {
            if (!previous) return NO;
            NSString *previousCommand = previous[@"command"];
            if (previousCommand) line[@"command"] = previousCommand;
            else [line removeObjectForKey:@"command"];
            if (previousCommand.length == 0 && [line[@"stack_with_default"] isEqual:@YES]) {
                if (previous[@"stack_with_default"]) line[@"stack_with_default"] = previous[@"stack_with_default"];
                else [line removeObjectForKey:@"stack_with_default"];
            }
            if (line.keys.count == 0) [document removeObjectForKey:@"statusLine"];
            return YES;
        }
        if ([command hasPrefix:StatusLineMarker] && !previous) return NO;
        previous = previous ?: line ?: [CCPetsJSONObject new];
        if (!line) line = [CCPetsJSONObject new];
        NSString *oldCommand = previous[@"command"];
        NSString *snapshot = [[CCPetsJSONStringify(previous) dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
        NSString *collect = [NSString stringWithFormat:@"%@%@'; agy_status_input=$(/bin/cat); /usr/bin/printf '%%s' \"$agy_status_input\" | %@ %@ --agy-status-line >/dev/null 2>&1 || :",
            StatusLineMarker, snapshot, ProfileEnvironment(profile), CCPetsShellQuote(CCPetsExecutablePath())];
        if (oldCommand.length > 0) {
            collect = [collect stringByAppendingFormat:@"; /usr/bin/printf '%%s' \"$agy_status_input\" | /bin/sh -c %@", CCPetsShellQuote(oldCommand)];
        } else {
            line[@"stack_with_default"] = @YES;
        }
        if ([line[@"command"] isEqual:collect]) return NO;
        line[@"command"] = collect;
        document[@"statusLine"] = line;
        return YES;
    });
}

static BOOL IsJSONBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

void CCPetsConfigureAntigravityBridgeTitle(NSDictionary *profile, BOOL enabled) {
    UpdateConfig(ProfileFile(profile, @"antigravity-cli/settings.json"), ^BOOL(CCPetsJSONObject *document) {
        id configured = document[@"title"];
        CCPetsJSONObject *title = Object(configured);
        if (configured && !title && !IsJSONBoolean(configured)) return NO;
        id currentCommand = title[@"command"];
        if (currentCommand && ![currentCommand isKindOfClass:NSString.class]) return NO;
        CCPetsJSONObject *backup = WrappedCommandBackup(currentCommand, BridgeTitleMarker);
        if (!enabled) {
            if (!backup) return NO;
            id original = backup[@"title"];
            NSString *originalCommand = Object(original)[@"command"];
            if (originalCommand) title[@"command"] = originalCommand;
            else [title removeObjectForKey:@"command"];

            if (IsJSONBoolean(original) && (title.keys.count == 0 ||
                (title.keys.count == 1 && IsJSONBoolean(title[@"enabled"])))) {
                // Keep a user's later /title toggle as well as the legacy boolean shape.
                document[@"title"] = title[@"enabled"] ?: @YES;
            } else if (!original && title.keys.count == 0) {
                [document removeObjectForKey:@"title"];
            }
            return YES;
        }

        if ([currentCommand hasPrefix:BridgeTitleMarker] && !backup) return NO;
        if (!backup) {
            backup = [CCPetsJSONObject new];
            if (configured) backup[@"title"] = configured;
        }
        if (!title) {
            title = [CCPetsJSONObject new];
            if (IsJSONBoolean(configured)) title[@"enabled"] = configured;
        }
        NSString *originalCommand = Object(backup[@"title"])[@"command"];
        NSString *snapshot = [[CCPetsJSONStringify(backup) dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
        // A sentinel keeps trailing newlines in the JSON while command substitution stores it.
        NSMutableString *managed = [NSMutableString stringWithFormat:
            @"%@%@'; agy_title_input=$(/bin/cat && /usr/bin/printf x) || exit $?; agy_title_input=${agy_title_input%%x}; ",
            BridgeTitleMarker, snapshot];
        NSString *render = [NSString stringWithFormat:
            @"/usr/bin/printf '%%s' \"$agy_title_input\" | %@ %@ --agy-bridge-title",
            ProfileEnvironment(profile), CCPetsShellQuote(CCPetsExecutablePath())];
        if (originalCommand.length > 0) {
            [managed appendFormat:@"agy_title_original=$(/usr/bin/printf '%%s' \"$agy_title_input\" | /bin/sh -c %@) || exit $?; ",
                CCPetsShellQuote(originalCommand)];
            [managed appendFormat:@"%@ \"$agy_title_original\" || /usr/bin/printf '%%s\\n' \"$agy_title_original\"", render];
        } else {
            [managed appendString:render];
        }
        if ([currentCommand isEqual:managed]) return NO;
        title[@"command"] = managed;
        document[@"title"] = title;
        return YES;
    });
}

static BOOL IsToolEvent(NSString *event) {
    return [event isEqual:@"PreToolUse"] || [event isEqual:@"PostToolUse"];
}

static BOOL HasHook(id candidate, NSString *event) {
    id entries = Object(candidate)[event];
    if (![entries isKindOfClass:NSArray.class]) return NO;
    for (id entry in entries) {
        NSArray *handlers = IsToolEvent(event) ? Object(entry)[@"hooks"] : @[entry];
        if (![handlers isKindOfClass:NSArray.class]) continue;
        for (id handler in handlers) {
            id command = Object(handler)[@"command"];
            if ([command isKindOfClass:NSString.class] && [command hasPrefix:HookMarker]) return YES;
        }
    }
    return NO;
}

static BOOL OwnsHook(id candidate) {
    for (NSString *event in Events()) if (HasHook(candidate, event)) return YES;
    return NO;
}

BOOL CCPetsAntigravityPetHooksInstalled(NSDictionary *profile) {
    @try {
        CCPetsJSONObject *hook = Object(ReadConfig(ProfileFile(profile, @"config/hooks.json"))[HookName]);
        if ([hook[@"enabled"] isEqual:@NO]) return NO;
        for (NSString *event in Events()) if (!HasHook(hook, event)) return NO;
        return YES;
    } @catch (NSException *exception) { return NO; }
}

NSArray<NSString *> *CCPetsInstallAntigravityPetHooks(NSDictionary *profile) {
    NSString *path = ProfileFile(profile, @"config/hooks.json");
    UpdateConfig(path, ^BOOL(CCPetsJSONObject *document) {
        if (document[HookName] && !OwnsHook(document[HookName])) {
            [NSException raise:@"CCPetsAntigravityConfig" format:@"%@: %@", path, L(@"The Antigravity hook name is already in use.")];
        }
        NSMutableDictionary *hook = [NSMutableDictionary dictionary];
        for (NSString *event in Events()) {
            NSString *command = [NSString stringWithFormat:@"%@%@ %@ --agy-hook %@",
                HookMarker, ProfileEnvironment(profile), CCPetsShellQuote(CCPetsExecutablePath()), event];
            NSArray *handlers = @[@{@"type": @"command", @"command": command, @"timeout": @10}];
            hook[event] = IsToolEvent(event) ? @[@{@"matcher": @"*", @"hooks": handlers}] : handlers;
        }
        document[HookName] = hook;
        return YES;
    });
    ChangeStatusLine(profile, YES);
    return @[CCPetsInterpolate(L(@"Antigravity CLI hooks configured in {path}."), @{@"path": path})];
}

BOOL CCPetsRemoveAntigravityPetHooks(NSDictionary *profile) {
    UpdateConfig(ProfileFile(profile, @"config/hooks.json"), ^BOOL(CCPetsJSONObject *document) {
        if (!OwnsHook(document[HookName])) return NO;
        [document removeObjectForKey:HookName];
        return YES;
    });
    ChangeStatusLine(profile, NO);
    return YES;
}

static BOOL OwnsMCP(id candidate) {
    CCPetsJSONObject *server = Object(candidate);
    return [Object(server[@"env"])[MCPMarker] isEqual:@"1"] && [server[@"args"] isEqual:@[@"bridge", @"mcp"]];
}

BOOL CCPetsAntigravityBridgeInstalled(NSDictionary *profile) {
    @try {
        CCPetsJSONObject *mcp = ReadConfig(ProfileFile(profile, @"config/mcp_config.json"));
        CCPetsJSONObject *server = Object(Object(mcp[@"mcpServers"])[CCBridgeMCPName]);
        NSString *command = server[@"command"];
        return CCPetsAntigravityPetHooksInstalled(profile) && OwnsMCP(server) &&
            [command isKindOfClass:NSString.class] && command.isAbsolutePath &&
            [NSFileManager.defaultManager isExecutableFileAtPath:command];
    } @catch (NSException *exception) { return NO; }
}

static BOOL ChangeMCP(NSDictionary *profile, BOOL enabled) {
    NSString *path = ProfileFile(profile, @"config/mcp_config.json");
    return UpdateConfig(path, ^BOOL(CCPetsJSONObject *document) {
        CCPetsJSONObject *servers = Object(document[@"mcpServers"]);
        id current = servers[CCBridgeMCPName];
        if (!enabled) {
            if (!OwnsMCP(current)) return NO;
            [servers removeObjectForKey:CCBridgeMCPName];
            if (servers.keys.count == 0) [document removeObjectForKey:@"mcpServers"];
            return YES;
        }
        if ((document[@"mcpServers"] && !servers) || (current && !OwnsMCP(current))) {
            [NSException raise:@"CCPetsAntigravityConfig" format:@"%@: %@", path, L(@"The Antigravity MCP server name is already in use.")];
        }
        if (!servers) servers = [CCPetsJSONObject new];
        CCPetsJSONObject *server = Object(current) ?: [CCPetsJSONObject new];
        CCPetsJSONObject *environment = Object(server[@"env"]) ?: [CCPetsJSONObject new];
        NSString *command = CCPetsExecutablePath();
        BOOL changed = ![server[@"command"] isEqual:command] || !OwnsMCP(server);
        for (NSString *key in @[@"CC_PETS_HOME", @"CC_PETS_STATE_DIR"]) {
            NSString *value = CCPetsEnvironmentValue(key);
            id old = environment[key];
            if (!(old == value || [old isEqual:value])) changed = YES;
            if (value) environment[key] = value;
            else [environment removeObjectForKey:key];
        }
        if (!changed) return NO;
        environment[MCPMarker] = @"1";
        server[@"command"] = command;
        server[@"args"] = @[@"bridge", @"mcp"];
        server[@"env"] = environment;
        servers[CCBridgeMCPName] = server;
        document[@"mcpServers"] = servers;
        return YES;
    });
}

static NSString *AllowRule(NSString *tool) {
    return [NSString stringWithFormat:@"mcp(%@/%@)", CCBridgeMCPName, tool];
}

static void SetAllows(NSDictionary *profile, NSArray<NSString *> *allowed) {
    UpdateConfig(ProfileFile(profile, @"antigravity-cli/settings.json"), ^BOOL(CCPetsJSONObject *document) {
        CCPetsJSONObject *permissions = Object(document[@"permissions"]);
        NSArray *current = permissions[@"allow"];
        if ((document[@"permissions"] && !permissions) || (current && ![current isKindOfClass:NSArray.class])) {
            [NSException raise:@"CCPetsAntigravityConfig" format:@"%@", L(@"Expected an Antigravity permissions object with an allow array.")];
        }
        NSMutableSet *managed = [NSMutableSet set];
        for (NSString *group in CCBridgeToolGroupNames()) {
            for (NSString *tool in CCBridgeToolGroup(group)) [managed addObject:AllowRule(tool)];
        }
        NSMutableArray *updated = [NSMutableArray array];
        for (id rule in current) if (![managed containsObject:rule]) [updated addObject:rule];
        for (NSString *tool in allowed) [updated addObject:AllowRule(tool)];
        if ([updated isEqualToArray:current ?: @[]]) return NO;
        if (!permissions) permissions = [CCPetsJSONObject new];
        if (updated.count > 0) permissions[@"allow"] = updated;
        else [permissions removeObjectForKey:@"allow"];
        if (permissions.keys.count > 0) document[@"permissions"] = permissions;
        else [document removeObjectForKey:@"permissions"];
        return YES;
    });
}

NSArray<NSString *> *CCPetsInstallAntigravityBridge(NSDictionary *profile, NSArray<NSString *> *allowed, BOOL registerMcp) {
    NSMutableArray *report = [CCPetsInstallAntigravityPetHooks(profile) mutableCopy];
    if (registerMcp && ChangeMCP(profile, YES)) [report addObject:L(@"Registered CC Bridge MCP for Antigravity CLI.")];
    SetAllows(profile, allowed);
    return report;
}

NSArray<NSString *> *CCPetsRemoveAntigravityBridge(NSDictionary *profile, BOOL unregisterMcp) {
    SetAllows(profile, @[]);
    return unregisterMcp && ChangeMCP(profile, NO) ? @[L(@"Removed CC Bridge MCP from Antigravity CLI.")] : @[];
}

static BOOL IsAntigravityAppProfile(NSDictionary *profile) {
    return [profile[@"provider"] isEqual:CCPetsProfileProviderAntigravity] && CCPetsProfileIsOfficialDefault(profile);
}

static NSString *AppSidecarManifestPath(NSDictionary *profile) {
    return ProfileFile(profile, [NSString stringWithFormat:@"config/sidecars/%@/sidecar.json", AppSidecarName]);
}

static NSArray<NSString *> *AppSidecarArguments(void) {
    return @[@"bridge", @"agy-app-sidecar"];
}

static BOOL OwnsAppSidecar(CCPetsJSONObject *manifest) {
    return [manifest[@"description"] isEqual:AppSidecarDescription] &&
        [manifest[@"args"] isEqual:AppSidecarArguments()];
}

BOOL CCPetsAntigravityAppSidecarInstalled(NSDictionary *profile) {
    if (!IsAntigravityAppProfile(profile)) return NO;
    @try {
        CCPetsJSONObject *manifest = ReadConfig(AppSidecarManifestPath(profile));
        NSString *command = manifest[@"command"];
        CCPetsJSONObject *mcp = ReadConfig(ProfileFile(profile, @"config/mcp_config.json"));
        CCPetsJSONObject *server = Object(Object(mcp[@"mcpServers"])[CCBridgeMCPName]);
        CCPetsJSONObject *config = ReadConfig(ProfileFile(profile, @"config/config.json"));
        CCPetsJSONObject *state = Object(Object(config[@"sidecars"])[AppSidecarName]);
        return OwnsAppSidecar(manifest) && [command isKindOfClass:NSString.class] && command.isAbsolutePath &&
            [NSFileManager.defaultManager isExecutableFileAtPath:command] &&
            OwnsMCP(server) && [server[@"command"] isEqual:command] &&
            [manifest[@"restart_policy"] isEqual:@"on-failure"] && [state[@"enabled"] isEqual:@YES];
    } @catch (NSException *exception) { return NO; }
}

static void FailSidecarCollision(NSString *path) {
    [NSException raise:@"CCPetsAntigravityConfig" format:@"%@: %@", path, L(@"The Antigravity sidecar name is already in use.")];
}

NSArray<NSString *> *CCPetsConfigureAntigravityAppSidecar(NSDictionary *profile, BOOL enabled) {
    if (!IsAntigravityAppProfile(profile)) return @[];
    NSString *manifestPath = AppSidecarManifestPath(profile);
    NSString *configPath = ProfileFile(profile, @"config/config.json");
    NSString *lock = [@"agy-app-sidecar-" stringByAppendingString:CCBridgeSHA1Hex(manifestPath)];
    return CCBridgeWithLock(lock, ^id {
        NSString *error = nil;
        CCPetsJSONObject *manifest = CCPetsReadAntigravityConfig(manifestPath, &error);
        BOOL owned = OwnsAppSidecar(manifest);
        if (!enabled && !owned) return @[];
        if (error) [NSException raise:@"CCPetsAntigravityConfig" format:@"%@: %@", manifestPath, error];

        CCPetsJSONObject *config = ReadConfig(configPath);
        CCPetsJSONObject *sidecars = Object(config[@"sidecars"]);
        id state = sidecars[AppSidecarName];
        if (enabled) {
            struct stat info;
            if (!owned && lstat(manifestPath.fileSystemRepresentation, &info) == 0) FailSidecarCollision(manifestPath);
            if ((state && (!owned || !Object(state))) || (config[@"sidecars"] && !sidecars)) FailSidecarCollision(configPath);

            UpdateConfig(manifestPath, ^BOOL(CCPetsJSONObject *document) {
                if (document.keys.count > 0 && !OwnsAppSidecar(document)) FailSidecarCollision(manifestPath);
                NSMutableDictionary *environment = [NSMutableDictionary dictionary];
                for (NSString *key in @[@"CC_PETS_HOME", @"CC_PETS_STATE_DIR"]) {
                    NSString *value = CCPetsEnvironmentValue(key);
                    if (value) environment[key] = value;
                }
                document[@"display_name"] = @"CC Pets Bridge";
                document[@"description"] = AppSidecarDescription;
                document[@"command"] = CCPetsExecutablePath();
                document[@"args"] = AppSidecarArguments();
                document[@"restart_policy"] = @"on-failure";
                if (environment.count > 0) document[@"env"] = environment;
                else [document removeObjectForKey:@"env"];
                return YES;
            });
        }

        UpdateConfig(configPath, ^BOOL(CCPetsJSONObject *document) {
            CCPetsJSONObject *entries = Object(document[@"sidecars"]);
            if (!enabled) {
                if (!entries[AppSidecarName]) return NO;
                [entries removeObjectForKey:AppSidecarName];
                if (entries.keys.count == 0) [document removeObjectForKey:@"sidecars"];
                return YES;
            }
            id existing = entries[AppSidecarName];
            CCPetsJSONObject *entry = Object(existing);
            if ((document[@"sidecars"] && !entries) || (existing && !entry)) FailSidecarCollision(configPath);
            if ([entry[@"enabled"] isEqual:@YES]) return NO;
            entries = entries ?: [CCPetsJSONObject new];
            entry = entry ?: [CCPetsJSONObject new];
            entry[@"enabled"] = @YES;
            entries[AppSidecarName] = entry;
            document[@"sidecars"] = entries;
            return YES;
        });

        if (!enabled) {
            if (unlink(manifestPath.fileSystemRepresentation) != 0 && errno != ENOENT) {
                NSError *removeError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
                [NSException raise:@"CCPetsAntigravityConfig" format:@"%@: %@", manifestPath, removeError.localizedDescription];
            }
            rmdir(manifestPath.stringByDeletingLastPathComponent.fileSystemRepresentation);
        }
        return @[enabled ? L(@"Antigravity App Sidecar enabled.") : L(@"Antigravity App Sidecar disabled.")];
    });
}
