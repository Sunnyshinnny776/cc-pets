#import "CCPetsBridgeTerminalTitle.h"
#import "CCPetsBridge.h"
#import "CCPetsBridgeStore.h"
#import "CCPetsCLISupport.h"
#import <unistd.h>

static NSString *StringValue(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSString *BindingPath(NSString *launchToken, BOOL createDirectory) {
    NSString *rawToken = StringValue(launchToken);
    NSUUID *token = rawToken.length == 36 ? [[NSUUID alloc] initWithUUIDString:rawToken] : nil;
    if (!token) return nil;
    NSString *directory = createDirectory ? CCBridgeSubdirectory(@[@"terminal-titles"])
        : [CCBridgeStateDirectory() stringByAppendingPathComponent:@"terminal-titles"];
    return [directory stringByAppendingPathComponent:[token.UUIDString.lowercaseString stringByAppendingString:@".json"]];
}

BOOL CCBridgeTerminalTitleEnabled(void) {
    return CCBridgeEnabled() && [CCBridgeOptions()[@"tabTitle"] boolValue];
}

static void BindTerminalTitle(NSString *launchToken, NSString *provider, NSString *sessionID, BOOL replace) {
    if (!provider.length || !CCBridgeSafeSessionId(sessionID)) return;
    NSString *path = BindingPath(launchToken, YES);
    if (!path) return;
    CCBridgeWithLock(@"terminal-title-bindings", ^id {
        NSDictionary *binding = CCBridgeReadJSON(path);
        if (!binding || (replace && ![binding[@"session"] isEqual:sessionID])) {
            CCBridgeWriteJSON(path, @{@"provider": provider, @"session": sessionID});
        }
        return nil;
    });
}

void CCBridgeBindTerminalTitle(NSString *launchToken, NSString *provider, NSString *sessionID) {
    BindTerminalTitle(launchToken, provider, sessionID, YES);
}

void CCBridgeBindTerminalTitleIfUnbound(NSString *launchToken, NSString *provider, NSString *sessionID) {
    BindTerminalTitle(launchToken, provider, sessionID, NO);
}

void CCBridgeClearTerminalTitleBinding(NSString *launchToken) {
    NSString *path = BindingPath(launchToken, NO);
    if (path) unlink(path.fileSystemRepresentation);
}

NSString *CCBridgeTerminalTitleNameForSession(NSString *sessionID, NSString *provider) {
    if (!CCBridgeTerminalTitleEnabled() || !CCBridgeSafeSessionId(sessionID)) return nil;
    NSDictionary *record = CCBridgeReadSession(sessionID);
    if (![record[@"provider"] isEqual:provider] || !CCBridgeSessionLive(record)) return nil;
    NSString *alias = CCBridgeSessionAnimalAlias(record);
    if (alias.length > 0) return alias;
    NSString *name = CCBridgeNormalizeSessionName(record[@"name"]);
    if ([record[@"nameSource"] isEqual:@"generated"]) {
        NSArray<NSString *> *parts = [name componentsSeparatedByString:@"."];
        if (parts.count == 3) return parts.lastObject;
    }
    return name;
}

NSString *CCBridgeTerminalTitleName(NSString *provider, NSString *launchToken, pid_t childPID) {
    if (!CCBridgeProcessAlive(childPID)) return nil;
    NSString *path = BindingPath(launchToken, NO);
    id binding = path ? CCBridgeReadJSON(path) : nil;
    if (![binding isKindOfClass:NSDictionary.class] || ![binding[@"provider"] isEqual:provider]) return nil;
    return CCBridgeTerminalTitleNameForSession(StringValue(binding[@"session"]), provider);
}

static NSString *PlainTitle(NSString *value) {
    if (!value.length) return @"";
    NSString *line = [[value componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
    NSArray<NSString *> *parts = [line componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet];
    return [[parts componentsJoinedByString:@""] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

NSString *CCBridgeComposeTerminalTitle(NSString *base, NSString *nickname) {
    NSString *title = PlainTitle(base);
    NSString *name = PlainTitle(nickname);
    if (!name.length) return title;
    return title.length > 0 ? [NSString stringWithFormat:@"%@ · %@", title, name] : name;
}

int CCBridgePrintAntigravityTitle(NSString *originalTitle) {
    @try {
        NSData *input = [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile];
        id state = input.length > 0 ? [NSJSONSerialization JSONObjectWithData:input options:0 error:nil] : nil;
        if (![state isKindOfClass:NSDictionary.class]) state = @{};
        NSString *sessionID = StringValue(state[@"conversation_id"]) ?: StringValue(state[@"session_id"]);
        NSString *nickname = CCBridgeTerminalTitleNameForSession(sessionID, CCBridgeAntigravityProvider);
        NSString *base = originalTitle;
        if (base == nil) {
            NSString *title = PlainTitle(StringValue(state[@"conversation_title"]));
            NSString *project = StringValue(state[@"cwd"]).lastPathComponent;
            base = title.length > 0 && project.length > 0 ? [NSString stringWithFormat:@"%@ | %@", title, project]
                : (title.length > 0 ? title : project);
        }
        CCPetsPrintLine(stdout, CCBridgeComposeTerminalTitle(base, nickname));
    } @catch (NSException *exception) {
        if (originalTitle) CCPetsPrintLine(stdout, PlainTitle(originalTitle));
    }
    return 0;
}
