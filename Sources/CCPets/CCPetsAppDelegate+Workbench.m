// 主窗口工作台几页的数据快照（见 CCPetsWorkbench.h）。只读：整理现有的会话、Bridge、额度状态，
// 不新增任何采集。
#import "CCPetsAppDelegate+Private.h"
#import "CCPetsBridge.h"

@implementation AppDelegate (Workbench)

- (NSArray<NSDictionary *> *)workbenchSessions {
    [self pruneOfflineAgentSessionRecords];
    NSDictionary<NSString *, NSNumber *> *pending = self.bridgePendingCounts ?: @{};
    NSMutableArray<NSDictionary *> *sessions = [NSMutableArray array];
    for (NSString *key in self.agentSessionRecords) {
        NSDictionary *record = self.agentSessionRecords[key];
        NSString *provider = SanitizedShortString(record[@"provider"], 32).lowercaseString;
        // 和状态气泡一致：启动后一直没有后续事件，说明会话已就绪、在等输入。
        NSString *state = SessionDisplayState([record[@"state"] isKindOfClass:NSString.class]
            ? record[@"state"] : @"", [record[@"timestamp"] doubleValue], NSDate.date.timeIntervalSince1970);
        NSString *tool = [record[@"tool"] isKindOfClass:NSString.class] ? record[@"tool"] : @"";
        NSDictionary *terminal = [record[@"terminal"] isKindOfClass:NSDictionary.class] ? record[@"terminal"] : nil;
        NSMutableDictionary *session = [NSMutableDictionary dictionary];
        session[@"id"] = key;
        session[@"provider"] = [provider isEqualToString:@"claude"] ? @"Claude"
            : ([provider isEqualToString:@"codex"] ? @"Codex" : (provider.length > 0 ? provider : @"Agent"));
        if ([record[@"profileId"] isKindOfClass:NSString.class]) session[@"profileId"] = record[@"profileId"];
        if ([record[@"profileName"] isKindOfClass:NSString.class]) session[@"profileName"] = record[@"profileName"];
        session[@"state"] = state;
        session[@"status"] = [self statusTextForState:state tool:tool];
        session[@"tool"] = SanitizedShortString(tool, 64) ?: @"";
        session[@"terminal"] = terminal.count > 0 ? [self terminalNameForTarget:terminal] : @"";
        session[@"updatedAt"] = record[@"timestamp"] ?: @0;
        NSDictionary *bridge = [self bridgeSessionEntryForRecord:record];
        if ([bridge[@"name"] isKindOfClass:NSString.class]) session[@"name"] = bridge[@"name"];
        NSString *bridgeID = [self bridgeSessionIdForRecord:record];
        session[@"pendingMessages"] = bridgeID ? (pending[bridgeID] ?: @0) : @0;
        [sessions addObject:session];
    }
    // 和右键会话菜单同一个次序：等审批的置顶，其余新的在前。
    [sessions sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        BOOL leftApproval = [left[@"state"] isEqualToString:@"approval"];
        BOOL rightApproval = [right[@"state"] isEqualToString:@"approval"];
        if (leftApproval != rightApproval) return leftApproval ? NSOrderedAscending : NSOrderedDescending;
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
        [pending addObject:@{@"session": session, @"name": [name isKindOfClass:NSString.class] ? name : session,
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
    // 和悬停面板同一个次序与同一份"检测到哪几家"的判断。
    for (NSString *provider in [self.quotaView visibleProviders]) {
        NSDictionary *usage = [self.quotaView usageForProvider:provider] ?: @{};
        NSString *usedKey = [provider isEqualToString:@"Claude"] ? @"used_percentage" : @"used_percent";
        NSDictionary *profile = [self.quotaView selectedProfileForProvider:provider];
        NSMutableDictionary *quota = [NSMutableDictionary dictionaryWithObject:provider forKey:@"provider"];
        if ([profile[@"id"] isKindOfClass:NSString.class]) quota[@"profileId"] = profile[@"id"];
        if ([profile[@"displayName"] isKindOfClass:NSString.class]) quota[@"profileName"] = profile[@"displayName"];
        NSNumber *weekUsed = nil;
        for (NSArray<NSString *> *window in @[@[@"fiveHour", @"five"], @[@"week", @"week"]]) {
            NSDictionary *limit = [usage[window[0]] isKindOfClass:NSDictionary.class]
                ? usage[window[0]] : nil;
            NSNumber *used = [limit[usedKey] isKindOfClass:NSNumber.class] ? limit[usedKey] : nil;
            if (used) {
                double clamped = fmax(0, fmin(100, used.doubleValue));
                quota[[window[1] stringByAppendingString:@"Remaining"]] = @(100 - clamped);
                if ([window[1] isEqualToString:@"week"]) weekUsed = @(clamped);
            }
            NSNumber *reset = [limit[@"resets_at"] isKindOfClass:NSNumber.class] ? limit[@"resets_at"] : nil;
            if (reset) quota[[window[1] stringByAppendingString:@"Reset"]] = reset;
        }
        NSDictionary *weekLimit = [usage[@"week"] isKindOfClass:NSDictionary.class]
            ? usage[@"week"] : nil;
        NSDictionary *pace = [self.quotaView paceStatusForQuota:weekLimit currentUsed:weekUsed
            color:NSColor.systemTealColor];
        if ([pace[@"label"] isKindOfClass:NSString.class]) quota[@"pace"] = pace[@"label"];
        if (pace[@"level"]) quota[@"paceLevel"] = pace[@"level"];
        [quotas addObject:quota];
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
