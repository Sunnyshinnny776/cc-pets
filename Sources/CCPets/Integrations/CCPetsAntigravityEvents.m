#import "CCPetsAntigravityEvents.h"
#import "CCPetsBridgeCLI.h"
#import "CCPetsBridgeStore.h"
#import "CCPetsCLISupport.h"
#import "CCPetsEvents.h"
#import "CCPetsPaths.h"
#import "CCPetsProfiles.h"
#import "CCPetsTerminalFocus.h"
#import <sys/stat.h>
#import <unistd.h>

static NSString *StringValue(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSString *ToolCategory(id value) {
    NSString *tool = SanitizedShortString(value, 64);
    if ([tool hasPrefix:@"browser_"] || [tool isEqual:@"search_web"] || [tool isEqual:@"read_url_content"]) return @"web";
    if ([tool hasPrefix:@"mcp_"] || [tool isEqual:@"call_mcp_tool"]) return @"mcp";
    return @{
        @"run_command": @"shell", @"send_command_input": @"shell",
        @"write_to_file": @"write", @"replace_file_content": @"edit", @"multi_replace_file_content": @"edit", @"sed_file": @"edit",
        @"view_file": @"read", @"list_dir": @"read", @"view_file_outline": @"read",
        @"find_by_name": @"search", @"grep_search": @"search",
        @"invoke_subagent": @"agent", @"manage_subagents": @"agent"
    }[tool] ?: tool;
}

NSString *CCPetsRegisterAntigravityTerminalClient(pid_t pid) {
    NSString *tty = StringValue(TerminalFocusTargetFromEnvironment()[@"tty"]);
    if (tty.length == 0) return nil;
    NSString *directory = [PetStateDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"cc-pets-%u-clients", getuid()]];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:nil];
    struct stat info;
    if (lstat(directory.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode) || info.st_uid != getuid()) return nil;
    NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%d", pid]];
    NSDictionary *profile = CCPetsProfileForHome(CCPetsProfileProviderAntigravity, DefaultAntigravityConfigDirectory());
    NSString *contents = [NSString stringWithFormat:@"%@\n%@\n%@\n", CCBridgeAntigravityProvider, tty,
        NormalizedAgentProfileID(profile[@"id"])];
    return CCPetsWriteFileAtomically(path, contents, 0600, NULL) ? path : nil;
}

// App 与 CLI 共用 Gemini 根目录里的 Hooks，靠祖先进程区分来源。App 会话没有终端，
// 回跳目标是 App 本身；标题用 Provider 名，避免和同一账号的 CLI 会话混在一起。
static BOOL AppendAntigravityEvent(NSString *session, NSString *cwd, NSString *event, NSString *tool, BOOL failed,
    NSString *state, BOOL app) {
    NSString *identifier = CCBridgeSafeSessionId(session);
    if (!identifier) return NO;
    NSMutableDictionary *record = [@{
        @"event": event,
        @"tool": ToolCategory(tool),
        @"failed": @(failed),
        @"provider": app ? CCBridgeAntigravityAppProvider : CCBridgeAntigravityProvider,
        @"state": state ?: NormalizedStateForEvent(event, failed),
        @"timestamp": @(NSDate.date.timeIntervalSince1970),
        @"session": identifier
    } mutableCopy];
    NSString *directory = SanitizedWorkingDirectory(cwd);
    if (directory.length > 0) record[@"cwd"] = directory;
    if (app) {
        NSDictionary *profile = CCPetsProfileForHome(CCPetsProfileProviderAntigravity, DefaultAntigravityAppConfigDirectory());
        NSString *profileID = NormalizedAgentProfileID(profile[@"id"]);
        if (profileID.length > 0) record[@"profileId"] = profileID;
        record[@"terminal"] = @{@"bundleID": CCPetsAntigravityAppBundleIdentifier};
        return AppendAgentEventRecord(record);
    }
    NSString *profileID = NormalizedAgentProfileID(CCPetsEnvironmentValue(@"CC_PETS_PROFILE_ID"));
    NSString *profileName = SanitizedShortString(CCPetsEnvironmentValue(@"CC_PETS_PROFILE_NAME"), 64);
    if (![profileID hasPrefix:@"antigravity:"]) {
        NSDictionary *profile = CCPetsProfileForHome(CCPetsProfileProviderAntigravity, DefaultAntigravityConfigDirectory());
        profileID = NormalizedAgentProfileID(profile[@"id"]);
        profileName = SanitizedShortString(profile[@"displayName"], 64);
    }
    if (profileID.length > 0) record[@"profileId"] = profileID;
    if (profileName.length > 0) record[@"profileName"] = profileName;
    NSDictionary *terminal = TerminalFocusTargetFromEnvironment();
    if (terminal.count > 0) record[@"terminal"] = terminal;
    return AppendAgentEventRecord(record);
}

static void AppendHookEvent(NSString *hookEvent, NSDictionary *payload, BOOL app) {
    NSString *event = @{
        @"SessionStart": @"SessionStart", @"PreInvocation": @"UserPromptSubmit", @"PreToolUse": @"PreToolUse",
        @"PostToolUse": @"PostToolUse", @"Stop": @"Stop"
    }[hookEvent];
    if (!event) return;
    BOOL failed = StringValue(payload[@"error"]).length > 0;
    if ([hookEvent isEqual:@"Stop"]) {
        if ([payload[@"fullyIdle"] isEqual:@NO]) return;
        NSString *reason = StringValue(payload[@"terminationReason"]);
        failed = failed || [reason isEqual:@"error"] || [reason isEqual:@"max_steps_exceeded"];
        if (failed) event = @"StopFailure";
    }
    if ([hookEvent isEqual:@"PostToolUse"] && failed) event = @"PostToolUseFailure";
    NSArray *workspaces = [payload[@"workspacePaths"] isKindOfClass:NSArray.class] ? payload[@"workspacePaths"] : nil;
    NSString *cwd = StringValue(payload[@"cwd"]) ?: StringValue(workspaces.firstObject);
    NSDictionary *tool = [payload[@"toolCall"] isKindOfClass:NSDictionary.class] ? payload[@"toolCall"] : nil;
    AppendAntigravityEvent(StringValue(payload[@"conversationId"]), cwd, event, StringValue(tool[@"name"]), failed, nil, app);
}

static NSDictionary *ReadPayload(void) {
    NSData *input = [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile];
    id payload = input.length > 0 ? [NSJSONSerialization JSONObjectWithData:input options:0 error:nil] : nil;
    return [payload isKindOfClass:NSDictionary.class] ? payload : nil;
}

int CCPetsRecordAntigravityHook(NSString *hookEvent) {
    NSDictionary *payload = ReadPayload();
    NSDictionary *response = [hookEvent isEqual:@"PreToolUse"] ? @{@"decision": @"allow"}
        : ([hookEvent isEqual:@"Stop"] ? @{@"decision": @"stop"} : @{});
    BOOL written = NO;
    // CLI 与 App 共用这一个 Hook：两边都上报会话状态，Provider 按祖先进程区分。
    @try {
        @try {
            NSDictionary *ancestor = CCBridgeFindAgentAncestor(getppid());
            BOOL cli = [ancestor[@"provider"] isEqual:CCBridgeAntigravityProvider];
            BOOL app = [ancestor[@"provider"] isEqual:CCBridgeAntigravityAppProvider];
            if (payload && (cli || app)) {
                AppendHookEvent(hookEvent, payload, app);
                response = CCBridgeHandleAntigravityHook(hookEvent, payload) ?: response;
            }
        } @catch (NSException *exception) {
            // A monitoring failure must not block the user's Antigravity turn.
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
        if (json) {
            written = fwrite(json.bytes, 1, json.length, stdout) == json.length && fputc('\n', stdout) != EOF;
            written = fflush(stdout) == 0 && written && !ferror(stdout);
        }
    } @finally {
        CCBridgeFinishAntigravityHook(written);
    }
    return 0;
}

int CCPetsRecordAntigravityStatusLine(void) {
    @try {
        NSDictionary *payload = ReadPayload();
        NSString *session = CCBridgeSafeSessionId(payload[@"conversation_id"]) ?: CCBridgeSafeSessionId(payload[@"session_id"]);
        NSString *state = StringValue(payload[@"agent_state"]);
        id confirmation = payload[@"tool_confirmation_pending"];
        if (!session || (!state.length && ![confirmation isKindOfClass:NSNumber.class])) return 0;
        BOOL pending = [confirmation isEqual:@YES] || [state isEqual:@"reviewing"];
        NSString *file = [CCBridgeSubdirectory(@[]) stringByAppendingPathComponent:@"agy-approvals.json"];
        if (!pending && ![NSFileManager.defaultManager fileExistsAtPath:file]) return 0;

        NSDictionary *ancestor = CCBridgeFindAgentAncestor(getppid());
        if (![ancestor[@"provider"] isEqual:CCBridgeAntigravityProvider]) return 0;
        NSNumber *owner = ancestor[@"pid"];
        NSString *lock = CCBridgeAcquireLock(@"agy-approvals");
        if (!lock) return 0;
        @try {
            id snapshot = CCBridgeReadJSON(file);
            NSMutableDictionary *approvals = [snapshot isKindOfClass:NSDictionary.class] ? [snapshot mutableCopy]
                : [NSMutableDictionary dictionary];
            for (NSString *identifier in approvals.allKeys) {
                id pid = approvals[identifier];
                if (![pid isKindOfClass:NSNumber.class] || !CCBridgeProcessAlive([pid intValue])) {
                    [approvals removeObjectForKey:identifier];
                }
            }
            BOOL wasPending = [approvals[session] isEqual:owner];
            if (pending != wasPending) {
                NSString *event = pending ? @"PermissionRequest" : @"ApprovalResolved";
                NSString *eventState = pending ? @"approval" : ([state isEqual:@"idle"] ? @"idle" : @"thinking");
                if (AppendAntigravityEvent(session, StringValue(payload[@"cwd"]), event, nil, NO, eventState, NO)) {
                    if (pending) approvals[session] = owner;
                    else [approvals removeObjectForKey:session];
                }
            }
            if (approvals.count == 0) unlink(file.fileSystemRepresentation);
            else if (![approvals isEqual:snapshot]) CCBridgeWriteJSON(file, approvals);
        } @finally {
            CCBridgeReleaseLock(lock);
        }
    } @catch (NSException *exception) {}
    return 0;
}
