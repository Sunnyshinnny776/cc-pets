// 主窗口工作台几页的数据快照（见 CCPetsWorkbench.h）。只读：整理现有的会话、Bridge、额度状态，
// 不新增任何采集。
#import "CCPetsAppDelegate+Private.h"
#import "CCPetsBridge.h"
#import "CCPetsBridgeStore.h"
#import "CCPetsBridgeRemote.h"
#import "CCPetsDiagnosticsPage.h"
#import "CCPetsUsageMode.h"
#import "CCPetsProviderRegistry.h"

NSNotificationName const CCPetsWorkbenchQuotasDidChangeNotification = @"CCPetsWorkbenchQuotasDidChange";

@implementation AppDelegate (Workbench)

- (NSArray<NSDictionary *> *)workbenchSessions {
    [self pruneOfflineAgentSessionRecords];
    NSDictionary<NSString *, NSNumber *> *pending = self.bridgePendingCounts ?: @{};
    NSMutableArray<NSDictionary *> *sessions = [NSMutableArray array];
    for (NSString *key in self.agentSessionRecords) {
        NSDictionary *record = self.agentSessionRecords[key];
        NSString *provider = SanitizedShortString(record[@"provider"], 32);
        NSString *providerKey = provider.lowercaseString;
        // 和状态气泡一致：启动后一直没有后续事件，说明会话已就绪、在等输入。
        NSString *state = SessionDisplayState([record[@"state"] isKindOfClass:NSString.class]
            ? record[@"state"] : @"", [record[@"timestamp"] doubleValue], NSDate.date.timeIntervalSince1970);
        NSString *tool = [record[@"tool"] isKindOfClass:NSString.class] ? record[@"tool"] : @"";
        NSDictionary *terminal = [record[@"terminal"] isKindOfClass:NSDictionary.class] ? record[@"terminal"] : nil;
        NSMutableDictionary *session = [NSMutableDictionary dictionary];
        session[@"id"] = key;
        session[@"provider"] = [providerKey isEqualToString:@"claude"] ? @"Claude"
            : ([providerKey isEqualToString:@"codex"] ? @"Codex" : (provider.length > 0 ? provider : @"Agent"));
        if ([record[@"profileId"] isKindOfClass:NSString.class]) session[@"profileId"] = record[@"profileId"];
        if ([record[@"profileName"] isKindOfClass:NSString.class]) session[@"profileName"] = record[@"profileName"];
        session[@"state"] = state;
        session[@"status"] = [self statusTextForState:state tool:tool];
        session[@"tool"] = SanitizedShortString(tool, 64) ?: @"";
        session[@"terminal"] = terminal.count > 0 ? [self terminalNameForTarget:terminal] : @"";
        session[@"updatedAt"] = record[@"timestamp"] ?: @0;
        NSDictionary *bridge = [self bridgeSessionEntryForRecord:record];
        NSString *cwd = SanitizedWorkingDirectory(record[@"cwd"]);
        if (cwd.length == 0) cwd = SanitizedWorkingDirectory(bridge[@"cwd"]);
        if (cwd.length > 0) session[@"projectName"] = cwd.lastPathComponent;
        if ([bridge[@"name"] isKindOfClass:NSString.class]) session[@"name"] = bridge[@"name"];
        session[@"displayName"] = CCBridgeSessionDisplayName(bridge);
        NSString *bridgeID = [self bridgeSessionIdForRecord:record];
        session[@"pendingMessages"] = bridgeID ? (pending[bridgeID] ?: @0) : @0;
        [sessions addObject:session];
    }
    if (CCBridgeEnabled()) {
        for (NSDictionary *peer in CCBridgeMessageRecipients(self.bridgeSessions.allValues)) {
            if (![peer[@"provider"] isEqual:CCBridgeSlackProvider]) continue;
            NSString *state = peer[@"gateway"] ? peer[@"status"] : @"idle";
            NSString *status = [state isEqual:@"busy"] ? L(@"Busy") : L(@"Idle");
            [sessions addObject:@{@"id": peer[@"session"], @"remote": @YES,
                @"displayName": peer[@"name"], @"provider": peer[@"remoteProvider"] ?: CCBridgeSlackProvider,
                @"state": state, @"status": peer[@"gateway"] ? status : L(@"Configured"), @"updatedAt": @0}];
        }
    }
    // 和右键会话菜单同一个次序：等审批的置顶，其余新的在前。
    [sessions sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        BOOL leftApproval = [left[@"state"] isEqualToString:@"approval"];
        BOOL rightApproval = [right[@"state"] isEqualToString:@"approval"];
        if (leftApproval != rightApproval) return leftApproval ? NSOrderedAscending : NSOrderedDescending;
        if ([left[@"remote"] boolValue] && [right[@"remote"] boolValue]) {
            return [left[@"displayName"] localizedStandardCompare:right[@"displayName"]];
        }
        return [right[@"updatedAt"] compare:left[@"updatedAt"]];
    }];
    return sessions;
}

- (NSDictionary *)workbenchMessages {
    if (!CCBridgeEnabled()) return @{@"enabled": @NO, @"pending": @[], @"deliveries": @[]};
    [self refreshBridgeState:nil];
    NSMutableArray<NSDictionary *> *pending = [NSMutableArray array];
    [self.bridgePendingCounts enumerateKeysAndObjectsUsingBlock:^(NSString *session, NSNumber *count, BOOL *stop) {
        NSString *name = self.bridgeSessions[session][@"name"];
        NSString *displayName = CCBridgeSessionDisplayName(self.bridgeSessions[session]);
        [pending addObject:@{@"session": session, @"name": [name isKindOfClass:NSString.class] ? name : session,
                             @"displayName": displayName.length > 0 ? displayName : session,
                             @"count": count}];
    }];
    [pending sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"name"] localizedStandardCompare:right[@"name"]];
    }];
    NSMutableArray<NSDictionary *> *deliveries = [NSMutableArray array];
    for (NSDictionary *delivery in self.bridgeRecentDeliveries) {
        NSMutableDictionary *entry = [delivery mutableCopy];
        entry[@"unseen"] = @([delivery[@"at"] doubleValue] > self.bridgeSeenAt);
        [deliveries addObject:entry];
    }
    return @{@"enabled": @YES, @"pending": pending, @"deliveries": deliveries};
}

- (NSArray<NSDictionary *> *)workbenchQuotas {
    NSMutableArray<NSDictionary *> *quotas = [NSMutableArray array];
    // 工作台展示已检测的平台和全部账号，也包含不进入悬停面板的平台。
    for (CCPetsProviderDescriptor *descriptor in CCPetsProviderDescriptors()) {
        NSString *provider = descriptor.name;
        if (self.quotaView.detectedProviders && ![self.quotaView.detectedProviders containsObject:provider]) continue;
        NSMutableArray<NSDictionary *> *profiles = [NSMutableArray array];
        for (NSDictionary *profile in self.quotaView.profiles ?: CCPetsProfiles()) {
            if ([profile[@"provider"] isEqualToString:descriptor.profileProvider]) [profiles addObject:profile];
        }
        // 未登记账号时保留旧版的平台卡片。
        if (profiles.count == 0) [profiles addObject:@{}];
        for (NSDictionary *profile in profiles) {
            NSString *profileID = profile[@"id"];
            NSMutableDictionary *quota = [[self.quotaView accountSnapshotForProvider:provider
                profile:profile.count > 0 ? profile : nil] mutableCopy];
            NSArray *windows = quota[@"normalized"][@"windows"];
            for (NSDictionary *window in windows) {
                NSString *key = window[@"key"];
                NSString *prefix = [key isEqualToString:@"fiveHour"] ? @"five" : key;
                NSNumber *used = window[@"used"];
                if (used) quota[[prefix stringByAppendingString:@"Remaining"]] = @(100 - used.doubleValue);
                NSNumber *reset = window[@"quota"][@"resets_at"];
                if ([reset isKindOfClass:NSNumber.class]) quota[[prefix stringByAppendingString:@"Reset"]] = reset;
            }
            if (![quota[@"apiMode"] boolValue]) {
                NSDictionary *pace = [self.quotaView paceStatusForWindow:CCPetsTrendWindow(windows)
                    color:NSColor.systemTealColor];
                if (pace[@"level"]) {
                    quota[@"pace"] = pace[@"label"];
                    quota[@"paceLevel"] = pace[@"level"];
                }
            }
            for (NSDictionary *section in CCPetsDiagnosticsStore.sections) {
                if (!profileID) continue;
                for (NSDictionary *result in section[@"results"]) {
                    if (![section[@"profileID"] isEqualToString:profileID] &&
                        ![result[@"profileID"] isEqualToString:profileID]) continue;
                    if ([@[@"warn", @"fail"] containsObject:result[@"level"]]) quota[@"hasDiagnosticIssues"] = @YES;
                }
            }
            [quotas addObject:quota];
        }
    }
    return quotas;
}

- (void)focusWorkbenchSessionWithID:(NSString *)sessionID {
    NSDictionary *record = sessionID ? self.agentSessionRecords[sessionID] : nil;
    NSDictionary *target = [record[@"terminal"] isKindOfClass:NSDictionary.class] ? record[@"terminal"] : nil;
    if (target.count > 0) ActivateTerminalFocusTarget(target);
}

- (void)focusBridgeSessionWithID:(NSString *)sessionID {
    NSDictionary *target = sessionID ? [self terminalTargetForBridgeSession:sessionID] : nil;
    if (target.count > 0) ActivateTerminalFocusTarget(target);
}

- (void)markWorkbenchMessagesSeen {
    self.bridgeSeenAt = NSDate.date.timeIntervalSince1970;
    [self refreshBridgeState:nil];
}

@end
