#import "CCPetsBridgeAntigravityApp.h"

#import "CCPetsBridge.h"
#import "CCPetsBridgeStore.h"
#import "CCPetsCLISupport.h"
#import <signal.h>
#import <stdio.h>
#import <unistd.h>

NSString *const CCBridgeAntigravityAppWakePrompt = @"[cc-bridge inbox] A teammate message is waiting in the local CC Bridge inbox. Read the message context supplied by the hook and handle it within this session’s permissions. If there is no supplied message, stop without taking any action.";

static volatile sig_atomic_t SidecarStopping;

static void StopSidecar(int signalNumber) {
    (void)signalNumber;
    SidecarStopping = 1;
}

static BOOL WakeEnabled(void) {
    NSDictionary *options = CCBridgeOptions();
    return [options[@"antigravityApp"] boolValue] && [options[@"wake"] boolValue];
}

static BOOL IsHostedConversation(NSDictionary *session, NSNumber *hostPID) {
    return [session[@"provider"] isEqual:CCBridgeAntigravityAppProvider] &&
        [CCBridgeSessionHostPID(session) isEqual:hostPID] && ![session[@"status"] isEqual:@"gone"];
}

// The oldest pending ID remains unchanged as later messages arrive. After Antigravity
// accepts a nudge, leave that batch to its hook and allow a new nudge only after it advances.
static void WakeIdleConversations(NSString *agentAPI, NSNumber *hostPID,
    NSMutableDictionary<NSString *, NSDictionary *> *attempts) {
    NSMutableSet<NSString *> *active = [NSMutableSet set];
    for (NSDictionary *session in CCBridgeListSessions()) {
        if (SidecarStopping) return;
        if (!IsHostedConversation(session, hostPID)) continue;
        NSString *sessionID = CCBridgeSafeSessionId(session[@"session"]);
        if (!sessionID || ![[NSUUID alloc] initWithUUIDString:sessionID]) continue;

        NSString *firstPending = CCBridgeOldestPendingMessageName(sessionID);
        if (!firstPending) continue;
        [active addObject:sessionID];
        if (![session[@"status"] isEqual:@"idle"]) continue;

        NSDictionary *previous = attempts[sessionID];
        BOOL sameBatch = [firstPending isEqual:previous[@"firstPending"]];
        if (sameBatch && [previous[@"accepted"] boolValue]) continue;
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (sameBatch && now < [previous[@"retryAt"] doubleValue]) continue;

        // A human prompt may have started after listing sessions. Recheck immediately
        // before calling App's transport and leave inbox claims to PreInvocation.
        NSDictionary *target = CCBridgeReadSession(sessionID);
        if (!IsHostedConversation(target, hostPID) || ![target[@"status"] isEqual:@"idle"] ||
            !CCBridgeSessionLive(target) || ![firstPending isEqual:CCBridgeOldestPendingMessageName(sessionID)] ||
            SidecarStopping || !WakeEnabled()) continue;

        int status = CCPetsRun(agentAPI, @[@"send-message", sessionID, CCBridgeAntigravityAppWakePrompt],
            nil, nil, 5, nil, nil);
        if (status == 0) {
            attempts[sessionID] = @{@"firstPending": firstPending, @"accepted": @YES};
        } else {
            NSTimeInterval delay = sameBatch ? MIN(60, 2 * [previous[@"delay"] doubleValue]) : 2;
            // A timeout may have happened after acceptance. Give the hook time to
            // consume the batch before retrying an unconfirmed call.
            if (status == CCPetsRunTimedOut) delay = 60;
            attempts[sessionID] = @{@"firstPending": firstPending, @"delay": @(delay),
                @"retryAt": @(NSProcessInfo.processInfo.systemUptime + delay)};
        }
    }
    for (NSString *sessionID in attempts.allKeys) {
        if (![active containsObject:sessionID]) [attempts removeObjectForKey:sessionID];
    }
}

int CCBridgeRunAntigravityAppSidecar(void) {
    pid_t parent = getppid();
    NSDictionary *ancestor = CCBridgeFindAgentAncestor(parent);
    NSNumber *hostPID = ancestor[@"pid"];
    NSString *dataDirectory = CCPetsEnvironmentValue(@"ANTIGRAVITY_EXECUTABLE_DATA_DIR");
    NSString *agentAPI = CCPetsFindRealExecutable(@"agentapi", nil);
    if (![ancestor[@"provider"] isEqual:CCBridgeAntigravityAppProvider] || hostPID.intValue <= 1 ||
        !dataDirectory.isAbsolutePath || !agentAPI.isAbsolutePath) {
        fputs("cc-pets: agy-app-sidecar requires an Antigravity App-managed Sidecar and agentapi.\n", stderr);
        return 0;
    }

    NSString *lock = nil;
    struct sigaction action = {0};
    struct sigaction previousInterrupt = {0}, previousTerminate = {0}, previousHangup = {0};
    action.sa_handler = StopSidecar;
    sigemptyset(&action.sa_mask);
    SidecarStopping = 0;
    sigaction(SIGINT, &action, &previousInterrupt);
    sigaction(SIGTERM, &action, &previousTerminate);
    sigaction(SIGHUP, &action, &previousHangup);
    @try {
        NSString *lockName = [NSString stringWithFormat:@"agy-app-sidecar-%@", hostPID];
        NSMutableDictionary<NSString *, NSDictionary *> *attempts = [NSMutableDictionary dictionary];
        while (!SidecarStopping && getppid() == parent && CCBridgeProcessAlive(hostPID.intValue)) {
            @autoreleasepool {
                if (WakeEnabled()) {
                    if (!lock) lock = CCBridgeAcquireLock(lockName);
                    if (lock) WakeIdleConversations(agentAPI, hostPID, attempts);
                }
            }
            if (!SidecarStopping) sleep(1);
        }
        return 0;
    } @catch (NSException *exception) {
        fputs("cc-pets: Antigravity App Sidecar could not access the CC Bridge state.\n", stderr);
        return 1;
    } @finally {
        CCBridgeReleaseLock(lock);
        sigaction(SIGINT, &previousInterrupt, NULL);
        sigaction(SIGTERM, &previousTerminate, NULL);
        sigaction(SIGHUP, &previousHangup, NULL);
    }
}
