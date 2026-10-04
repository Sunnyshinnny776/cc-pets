// CC Bridge 开关、消息角标与菜单。
#import "CCPetsAppDelegate+Private.h"

@implementation AppDelegate (Bridge)
// 菜单开关 → cc-pets bridge enable / disable / configure。逻辑全在 CLI 里，桌宠只负责调用，
// 命令行与菜单两条路的行为才一致。enable 要跑 claude / codex mcp add，要几秒，所以异步执行；
// 执行期间忽略新的切换，结束后按实际状态刷新（菜单下次打开时现读）。
- (void)runBridgeCommand:(NSArray<NSString *> *)arguments sender:(NSButton *)sender
    successMessage:(NSString *)successMessage {
    NSDictionary<NSString *, NSString *> *locator = CCBridgeCLILocator();
    if (!locator) {
        [self showAlertWithTitle:@"无法修改 CC Bridge 设置"
            message:@"没有找到 cc-pets 的命令行程序。请在终端执行一次 cc-pets install 后重试。"];
        [self syncBridgeSwitch:sender];
        return;
    }
    if (self.bridgeCommandRunning) {
        [self syncBridgeSwitch:sender];
        return;
    }
    self.bridgeCommandRunning = YES;
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:locator[@"node"]];
    task.arguments = [@[locator[@"cli"]] arrayByAddingObjectsFromArray:arguments];
    NSMutableDictionary<NSString *, NSString *> *environment =
        [NSProcessInfo.processInfo.environment mutableCopy];
    NSString *existingPath = environment[@"PATH"].length > 0 ? environment[@"PATH"] : @"/usr/bin:/bin:/usr/sbin:/sbin";
    // claude / codex 常装在 node 同目录（nvm），桌宠的 PATH 里未必有。
    environment[@"PATH"] = [NSString stringWithFormat:@"%@:%@",
        [locator[@"node"] stringByDeletingLastPathComponent], existingPath];
    task.environment = environment;
    NSPipe *output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = output;
    __weak typeof(self) weakSelf = self;
    task.terminationHandler = ^(NSTask *finished) {
        NSData *data = [output.fileHandleForReading readDataToEndOfFile];
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.bridgeCommandRunning = NO;
            [strongSelf refreshBridgeState:nil];
            if (finished.terminationStatus == EXIT_SUCCESS) {
                if (successMessage.length > 0) {
                    [strongSelf sendNotificationWithTitle:@"CC Bridge" body:successMessage];
                }
                return;
            }
            [strongSelf syncBridgeSwitch:sender];
            NSString *detail = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            [strongSelf showAlertWithTitle:@"CC Bridge 设置失败"
                message:detail.length > 0 ? detail : @"命令执行失败。"];
        });
    };
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        self.bridgeCommandRunning = NO;
        [self syncBridgeSwitch:sender];
        [self showAlertWithTitle:@"CC Bridge 设置失败" message:error.localizedDescription];
    }
}
// 与其他菜单开关一致：目标状态按"实际存储的状态取反"算，不信任开关视图自己翻转后的 state——
// 菜单停留期间状态可能已被命令行改过。命令没执行成功时再把开关翻回实际状态。
- (BOOL)currentBridgeStateForSwitch:(NSButton *)sender {
    NSDictionary *options = CCBridgeOptions();
    if (sender.action == @selector(toggleBridgeEnabled:)) return CCBridgeEnabled();
    if (sender.action == @selector(toggleBridgeWake:)) return [options[@"wake"] boolValue];
    if (sender.action == @selector(toggleBridgeEditGuard:)) return [options[@"editGuard"] boolValue];
    if (sender.action == @selector(toggleBridgeApproval:)) {
        NSSet *tools = [NSSet setWithArray:CCBridgeToolGroup([self bridgeApprovalGroupForTag:sender.tag])];
        return tools.count > 0 && [tools isSubsetOfSet:[NSSet setWithArray:options[@"codexApprove"]]] &&
            [tools isSubsetOfSet:[NSSet setWithArray:options[@"claudeAllow"]]];
    }
    return NO;
}
- (void)syncBridgeSwitch:(NSButton *)sender {
    if (!sender) return;
    sender.state = [self currentBridgeStateForSwitch:sender] ? NSControlStateValueOn : NSControlStateValueOff;
}
// 返回目标状态，并先把开关视图摆到目标状态上（命令失败时 syncBridgeSwitch 再翻回来）。
- (BOOL)targetBridgeStateForSwitch:(NSButton *)sender {
    BOOL target = ![self currentBridgeStateForSwitch:sender];
    sender.state = target ? NSControlStateValueOn : NSControlStateValueOff;
    return target;
}
- (NSString *)bridgeApprovalGroupForTag:(NSInteger)tag {
    NSArray<NSString *> *groups = CCBridgeToolGroupNames();
    return tag >= 1 && tag <= (NSInteger)groups.count ? groups[tag - 1] : @"";
}
- (void)toggleBridgeEnabled:(NSButton *)sender {
    BOOL enable = [self targetBridgeStateForSwitch:sender];
    [self runBridgeCommand:@[enable ? @"enable" : @"disable"] sender:sender
        successMessage:enable
            ? @"已开启。已在运行的 Codex 会话需重启并在 /hooks 中信任；Claude 会话重启后才有 cc-bridge 工具。"
            : @"已关闭，相关 hooks 与 MCP 注册已移除。"];
}
// 一个分组同时作用于 Codex 免审批与 Claude 免确认：菜单上只有一组开关，两边保持一致。
- (void)toggleBridgeApproval:(NSButton *)sender {
    NSArray<NSString *> *tools = CCBridgeToolGroup([self bridgeApprovalGroupForTag:sender.tag]);
    if (tools.count == 0) return;
    BOOL allow = [self targetBridgeStateForSwitch:sender];
    NSDictionary *options = CCBridgeOptions();
    NSString *(^apply)(NSArray<NSString *> *) = ^NSString *(NSArray<NSString *> *current) {
        NSMutableOrderedSet<NSString *> *next = [NSMutableOrderedSet orderedSetWithArray:current];
        if (allow) [next addObjectsFromArray:tools]; else [next removeObjectsInArray:tools];
        return [next.array componentsJoinedByString:@","];
    };
    [self runBridgeCommand:@[@"configure",
        [@"--codex-approve=" stringByAppendingString:apply(options[@"codexApprove"])],
        [@"--claude-allow=" stringByAppendingString:apply(options[@"claudeAllow"])]]
        sender:sender successMessage:nil];
}
- (void)toggleBridgeWake:(NSButton *)sender {
    [self runBridgeCommand:@[@"configure",
        [self targetBridgeStateForSwitch:sender] ? @"--wake=on" : @"--wake=off"] sender:sender successMessage:nil];
}
- (void)toggleBridgeEditGuard:(NSButton *)sender {
    [self runBridgeCommand:@[@"configure",
        [self targetBridgeStateForSwitch:sender] ? @"--edit-guard=on" : @"--edit-guard=off"]
        sender:sender successMessage:nil];
}
- (void)toggleBridgeBadge:(NSButton *)sender {
    BOOL enabled = ![NSUserDefaults.standardUserDefaults boolForKey:BridgeBadgeEnabledKey];
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:BridgeBadgeEnabledKey];
    sender.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self refreshBridgeBadge];
}
// 与"系统通知"那组开关同一套授权流程：第一次打开时向系统申请通知权限。
- (void)toggleBridgeNotification:(NSButton *)sender {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:BridgeNotificationKey]) {
        [defaults setBool:NO forKey:BridgeNotificationKey];
        sender.state = NSControlStateValueOff;
        return;
    }
    [UNUserNotificationCenter.currentNotificationCenter
        requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
        completionHandler:^(BOOL granted, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [defaults setBool:granted forKey:BridgeNotificationKey];
            sender.state = granted ? NSControlStateValueOn : NSControlStateValueOff;
            if (!granted) {
                [self showAlertWithTitle:@"无法启用系统通知" message:error.localizedDescription ?:
                    @"请在“系统设置 → 通知 → CC Pets”中允许通知后重试。"];
            }
        });
    }];
}
// 读 bridge 状态（会话名、最近送达、信箱积压），刷新角标。bridge 未开启时清空并隐藏。
// 回执目录没变就不重读文件，只按时间窗重新过滤缓存——回执状态一变，写入端的
// "临时文件 + rename" 必然改动目录的修改时间。
- (void)refreshBridgeState:(NSTimer *)timer {
    if (!CCBridgeEnabled()) {
        self.bridgeSessions = nil;
        self.bridgeRecentDeliveries = nil;
        self.bridgePendingCounts = nil;
        self.bridgeSentStamp = nil;
        [self refreshBridgeBadge];
        return;
    }
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSString *directory = CCBridgeStateDirectory();
    self.bridgeSessions = CCBridgeSessions();
    NSDate *stamp = [NSFileManager.defaultManager attributesOfItemAtPath:
        [directory stringByAppendingPathComponent:@"sent"] error:nil].fileModificationDate;
    if (!stamp || ![stamp isEqualToDate:self.bridgeSentStamp] || !self.bridgeDeliveryCache) {
        self.bridgeDeliveryCache = CCBridgeRecentDeliveries(now - BridgeRecentWindow, 50);
        self.bridgeSentStamp = stamp;
    }
    NSMutableArray<NSDictionary *> *recent = [NSMutableArray array];
    for (NSDictionary *delivery in self.bridgeDeliveryCache) {
        if ([delivery[@"at"] doubleValue] >= now - BridgeRecentWindow) [recent addObject:delivery];
    }
    self.bridgeRecentDeliveries = recent;
    // 只算仍在线的会话：已退出会话的积压已经投不出去，提醒也无从处理。
    NSMutableDictionary<NSString *, NSNumber *> *pending = [NSMutableDictionary dictionary];
    [CCBridgePendingCounts() enumerateKeysAndObjectsUsingBlock:^(NSString *session, NSNumber *count, BOOL *stop) {
        if (self.bridgeSessions[session]) pending[session] = count;
    }];
    self.bridgePendingCounts = pending;
    [self notifyNewBridgeDeliveries];
    [self refreshBridgeBadge];
}
// 新送达的跨会话消息发系统通知：只含谁发给谁，不含正文。一次刷新里来了多条时合并成一条。
- (void)notifyNewBridgeDeliveries {
    NSMutableArray<NSDictionary *> *fresh = [NSMutableArray array];
    for (NSDictionary *delivery in self.bridgeRecentDeliveries) {
        if ([delivery[@"at"] doubleValue] > self.bridgeNotifiedAt) [fresh addObject:delivery];
    }
    if (fresh.count == 0) return;
    for (NSDictionary *delivery in fresh) {
        self.bridgeNotifiedAt = MAX(self.bridgeNotifiedAt, [delivery[@"at"] doubleValue]);
    }
    if (![NSUserDefaults.standardUserDefaults boolForKey:BridgeNotificationKey]) return;
    NSDictionary *latest = fresh.firstObject;
    NSString *body = fresh.count == 1
        ? [NSString stringWithFormat:@"%@ → %@", latest[@"from"], latest[@"to"]]
        : [NSString stringWithFormat:@"%@ → %@ 等 %lu 条", latest[@"from"], latest[@"to"],
            (unsigned long)fresh.count];
    [self sendNotificationWithTitle:@"CC Bridge 新消息" body:body];
}
// 蓝色 = 有新的跨会话消息送达；橙色 = 有消息卡在某个会话的信箱里（那个 Claude 会话长时间空闲、
// 唤醒 watcher 已退出，要等用户在那个终端开口才会送进去），需要用户过去看一眼。
- (void)refreshBridgeBadge {
    CCPetsApprovalBadgeView *badge = (CCPetsApprovalBadgeView *)self.bridgeBadgeView;
    if (!badge) return;
    if (![NSUserDefaults.standardUserDefaults boolForKey:BridgeBadgeEnabledKey]) {
        badge.count = 0;
        return;
    }
    NSUInteger unseen = 0;
    for (NSDictionary *delivery in self.bridgeRecentDeliveries) {
        if ([delivery[@"at"] doubleValue] > self.bridgeSeenAt) unseen++;
    }
    NSUInteger waiting = 0;
    for (NSNumber *count in self.bridgePendingCounts.allValues) waiting += count.unsignedIntegerValue;
    badge.fillColor = waiting > 0
        ? [NSColor colorWithRed:0.92 green:0.58 blue:0.12 alpha:1]
        : [NSColor colorWithRed:0.20 green:0.47 blue:0.90 alpha:1];
    badge.count = unseen + waiting;
    [self layoutApprovalBadge];
}
- (NSString *)bridgeSessionIdForRecord:(NSDictionary *)record {
    NSString *session = SanitizedShortString(record[@"session"], 128);
    if (session.length > 0 && self.bridgeSessions[session]) return session;
    // 事件里没有 session id 的记录，退回按 provider + tty 对上 bridge 注册表。
    NSDictionary *terminal = [record[@"terminal"] isKindOfClass:NSDictionary.class] ? record[@"terminal"] : nil;
    NSString *tty = SanitizedShortString([terminal[@"tty"] lastPathComponent], 64);
    NSString *provider = SanitizedShortString(record[@"provider"], 32);
    if (tty.length == 0) return nil;
    __block NSString *match = nil;
    [self.bridgeSessions enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *entry, BOOL *stop) {
        if ([entry[@"tty"] isEqualToString:tty] && [entry[@"provider"] isEqualToString:provider]) {
            match = key;
            *stop = YES;
        }
    }];
    return match;
}
- (NSDictionary *)bridgeSessionEntryForRecord:(NSDictionary *)record {
    NSString *session = [self bridgeSessionIdForRecord:record];
    return session ? self.bridgeSessions[session] : nil;
}
// 收件会话的终端：优先用桌宠自己记录的该会话终端信息（带宿主应用），其次按 tty 对上任一
// 已知终端，最后借用最近一次的宿主应用配上 bridge 记录的 tty。
- (NSDictionary *)terminalTargetForBridgeSession:(NSString *)sessionId {
    NSString *tty = self.bridgeSessions[sessionId][@"tty"];
    NSDictionary *byTty = nil;
    for (NSDictionary *record in self.agentSessionRecords.allValues) {
        NSDictionary *terminal = [record[@"terminal"] isKindOfClass:NSDictionary.class] ? record[@"terminal"] : nil;
        if (terminal.count == 0) continue;
        if ([SanitizedShortString(record[@"session"], 128) isEqualToString:sessionId]) return terminal;
        if (tty.length > 0 && [[terminal[@"tty"] lastPathComponent] isEqualToString:tty]) byTty = terminal;
    }
    if (byTty) return byTty;
    if (tty.length > 0 && self.lastTerminalFocusTarget.count > 0) {
        NSMutableDictionary *target = [self.lastTerminalFocusTarget mutableCopy];
        target[@"tty"] = tty;
        [target removeObjectForKey:@"session"];
        return target;
    }
    return nil;
}
- (void)focusBridgeSession:(NSMenuItem *)sender {
    NSString *sessionId = [sender.representedObject isKindOfClass:NSString.class] ? sender.representedObject : nil;
    NSDictionary *target = sessionId ? [self terminalTargetForBridgeSession:sessionId] : nil;
    if (target.count > 0) ActivateTerminalFocusTarget(target);
}
- (void)addBridgeItemsToMenu:(NSMenu *)menu deliveries:(NSArray<NSDictionary *> *)deliveries
    pending:(NSDictionary<NSString *, NSNumber *> *)pending {
    NSMenuItem *heading = [menu addItemWithTitle:@"CC Bridge 消息" action:nil keyEquivalent:@""];
    heading.enabled = NO;
    [pending enumerateKeysAndObjectsUsingBlock:^(NSString *session, NSNumber *count, BOOL *stop) {
        NSString *name = self.bridgeSessions[session][@"name"] ?: session;
        NSString *title = [NSString stringWithFormat:@"📬 %@ 有 %lu 条消息待投递（去那个终端说句话即可送达）",
            name, count.unsignedLongValue];
        NSMenuItem *item = [menu addItemWithTitle:title action:@selector(focusBridgeSession:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = session;
    }];
    NSUInteger shown = 0;
    for (NSDictionary *delivery in deliveries) {
        if (shown++ >= BridgeMenuDeliveryLimit) break;
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:[delivery[@"at"] doubleValue]];
        NSString *time = [NSDateFormatter localizedStringFromDate:date
            dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle];
        BOOL unseen = [delivery[@"at"] doubleValue] > self.bridgeSeenAt;
        NSString *title = [NSString stringWithFormat:@"%@%@ → %@ · %@",
            unseen ? @"✉️ " : @"", delivery[@"from"], delivery[@"to"], time];
        NSMenuItem *item = [menu addItemWithTitle:title action:@selector(focusBridgeSession:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = delivery[@"toSession"];
        item.toolTip = [NSString stringWithFormat:@"跳到 %@ 所在的终端", delivery[@"to"]];
    }
}
@end
