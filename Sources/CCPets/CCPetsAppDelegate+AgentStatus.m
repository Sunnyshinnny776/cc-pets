// Agent 状态卡、会话列表、审批与卡住提醒、终端回跳、系统通知。
#import "CCPetsAppDelegate+Private.h"

@implementation AppDelegate (AgentStatus)
- (void)sendNotificationWithTitle:(NSString *)title body:(NSString *)body {
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = title;
    content.body = body;
    content.sound = UNNotificationSound.defaultSound;
    NSString *identifier = [@"cc-pets-" stringByAppendingString:NSUUID.UUID.UUIDString];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier
        content:content trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request
        withCompletionHandler:nil];
}
- (void)notifyForRecord:(NSDictionary *)record {
    NSString *event = record[@"event"];
    NSString *state = [record[@"state"] isKindOfClass:NSString.class] ? record[@"state"] : @"";
    NSString *provider = SanitizedShortString(record[@"provider"], 32);
    if (provider.length == 0) provider = @"Agent";
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([event isEqualToString:@"PermissionRequest"] &&
        ![state isEqualToString:@"auto_review"] &&
        [defaults boolForKey:NotificationApprovalKey]) {
        [self sendNotificationWithTitle:L(@"Awaiting approval")
            body:[NSString stringWithFormat:L(@"%@ is waiting for you."), provider]];
    } else if ([event isEqualToString:@"StopFailure"] &&
               [defaults boolForKey:NotificationFailureKey]) {
        [self sendNotificationWithTitle:L(@"Task failed")
            body:[NSString stringWithFormat:L(@"%@'s task failed."), provider]];
    } else if (([event isEqualToString:@"Stop"] || [event isEqualToString:@"SessionEnd"]) &&
               [defaults boolForKey:NotificationCompletionKey]) {
        [self sendNotificationWithTitle:L(@"Task done")
            body:[NSString stringWithFormat:L(@"%@ finished the current task."), provider]];
    }
}
- (NSString *)statusTextForState:(NSString *)state tool:(NSString *)tool {
    if ([state isEqualToString:@"starting"]) return L(@"Starting");
    if ([state isEqualToString:@"idle"]) return L(@"Idle");
    if ([state isEqualToString:@"thinking"]) return L(@"Thinking");
    if ([state isEqualToString:@"auto_review"]) return L(@"Auto-reviewing");
    if ([state isEqualToString:@"approval"]) return L(@"Awaiting approval");
    if ([state isEqualToString:@"subagent"]) return L(@"Subagent working");
    if ([state isEqualToString:@"tool_completed"]) return L(@"Step done");
    if ([state isEqualToString:@"tool_failed"]) return L(@"Tool failed");
    if ([state isEqualToString:@"completed"]) return L(@"Task completed");
    if ([state isEqualToString:@"failed"]) return L(@"Task failed");
    if ([state isEqualToString:@"notification"]) return L(@"Needs attention");
    if ([state isEqualToString:@"tool"]) {
        NSString *lower = tool.lowercaseString;
        if ([lower containsString:@"bash"] || [lower containsString:@"exec"] ||
            [lower containsString:@"shell"] || [lower containsString:@"terminal"]) return L(@"Running a command");
        if ([lower containsString:@"patch"] || [lower containsString:@"edit"] ||
            [lower containsString:@"write"]) return L(@"Editing files");
        if ([lower containsString:@"read"] || [lower containsString:@"search"] ||
            [lower containsString:@"find"] || [lower containsString:@"grep"] ||
            [lower containsString:@"glob"] || [lower containsString:@"web"] ||
            [lower hasPrefix:@"mcp__"]) return L(@"Looking things up");
        if ([lower containsString:@"task"] || [lower containsString:@"agent"]) return L(@"Subagent working");
        return L(@"Using a tool");
    }
    return L(@"Working");
}
// 状态卡副行的正文。每个 hook 状态都由宠物来讲，标题仍然给事实。
//
// 这不是"额外说话"，是把原来的样板文案整体换成宠物口吻，所以不受说话预算限制——
// 状态本来就在变，每次变化说一句是应该的。预算只管情绪句那一层。
- (NSString *)petVoiceTagForState:(NSString *)state tool:(NSString *)tool {
    if ([state isEqualToString:@"starting"]) return PetPhraseTagStateStarting;
    if ([state isEqualToString:@"idle"]) return PetPhraseTagStateIdle;
    if ([state isEqualToString:@"thinking"]) return PetPhraseTagStateThinking;
    if ([state isEqualToString:@"auto_review"]) return PetPhraseTagStateAutoReview;
    if ([state isEqualToString:@"approval"]) return PetPhraseTagStateApproval;
    if ([state isEqualToString:@"subagent"]) return PetPhraseTagStateSubagent;
    if ([state isEqualToString:@"tool_completed"]) return PetPhraseTagStateToolDone;
    if ([state isEqualToString:@"tool_failed"]) return PetPhraseTagStateToolFailed;
    if ([state isEqualToString:@"completed"]) return PetPhraseTagStateCompleted;
    if ([state isEqualToString:@"failed"]) return PetPhraseTagStateFailed;
    if ([state isEqualToString:@"notification"]) return PetPhraseTagStateNotification;
    if ([state isEqualToString:@"tool"]) {
        // 工具四分类和标题那边同源。原来副行只有一句"正在调用工具…"覆盖全部四类，
        // 分开之后副行的信息量反而比改造前更大。
        NSString *lower = tool.lowercaseString;
        if ([lower containsString:@"bash"] || [lower containsString:@"exec"] ||
            [lower containsString:@"shell"] || [lower containsString:@"terminal"]) {
            return PetPhraseTagStateToolBash;
        }
        if ([lower containsString:@"patch"] || [lower containsString:@"edit"] ||
            [lower containsString:@"write"]) return PetPhraseTagStateToolEdit;
        if ([lower containsString:@"read"] || [lower containsString:@"search"] ||
            [lower containsString:@"find"] || [lower containsString:@"grep"] ||
            [lower containsString:@"glob"] || [lower containsString:@"web"] ||
            [lower hasPrefix:@"mcp__"]) return PetPhraseTagStateToolRead;
        if ([lower containsString:@"task"] || [lower containsString:@"agent"]) {
            return PetPhraseTagStateSubagent;
        }
        return PetPhraseTagStateTool;
    }
    return PetPhraseTagStateTool;
}
- (NSString *)statusDetailForState:(NSString *)state tool:(NSString *)tool {
    NSString *tag = [self petVoiceTagForState:state tool:tool];
    // 同一个状态连着来一串事件时不重摇，否则副行会不停闪。一次状态转换说一句就够。
    if ([tag isEqualToString:self.lastPetVoiceTag] && self.lastPetVoiceText.length > 0) {
        return self.lastPetVoiceText;
    }
    NSString *text = PetPhraseForTag(tag, [self speechSlots]);
    self.lastPetVoiceTag = tag;
    self.lastPetVoiceText = text;
    return text;
}
- (NSColor *)statusColorForState:(NSString *)state {
    if ([state isEqualToString:@"completed"] || [state isEqualToString:@"tool_completed"]) {
        return [NSColor colorWithRed:0.18 green:0.68 blue:0.35 alpha:1];
    }
    if ([state isEqualToString:@"failed"] || [state isEqualToString:@"tool_failed"]) {
        return [NSColor colorWithRed:0.86 green:0.28 blue:0.28 alpha:1];
    }
    if ([state isEqualToString:@"approval"] || [state isEqualToString:@"notification"]) {
        return [NSColor colorWithRed:0.92 green:0.58 blue:0.12 alpha:1];
    }
    // 待机是"没在干活"，用中性灰和工作中的蓝拉开距离。
    if ([state isEqualToString:@"idle"]) return [NSColor colorWithWhite:0.55 alpha:1];
    return [NSColor colorWithRed:0.33 green:0.53 blue:0.78 alpha:1];
}
- (NSString *)statusSymbolForState:(NSString *)state {
    if ([state isEqualToString:@"completed"] || [state isEqualToString:@"tool_completed"]) return @"checkmark";
    if ([state isEqualToString:@"failed"] || [state isEqualToString:@"tool_failed"]) return @"xmark";
    if ([state isEqualToString:@"approval"] || [state isEqualToString:@"notification"]) return @"exclamationmark";
    if ([state isEqualToString:@"idle"]) return @"zzz";
    return @"ellipsis";
}
// Codex / Claude 退出时不会补发结束事件：包装脚本最后一行是 exec，自身已经被
// 替换掉，装不上 EXIT trap。唯一可靠的退出信号是客户端 pid 文件被回收。
// 没有这一步的话，“正在启动”只能等 60 秒无活动才消失，而另一个 provider 的事件
// 会不断把这 60 秒重置掉——用户关掉所有 Codex 窗口后仍然看到“Codex 正在启动”。
- (void)hideAgentStatusIfClientGone {
    if (!self.hasAgentStatus || self.hasUnlabeledClient) return;
    NSString *provider = self.lastStatusProvider;
    if (provider.length == 0 || [self.liveClientProviders containsObject:provider]) return;
    // 不经包装脚本启动的客户端（直接跑 claude / codex）没有 pid 文件，只能靠
    // “最近还在发事件”证明自己活着，所以这里必须留一段静默宽限再清。
    if ([NSDate.date timeIntervalSince1970] - self.lastStatusTimestamp < AgentStatusOrphanInterval) return;
    [self hideAgentStatus];
}
- (void)hideAgentStatus {
    // 卡在审批的会话不该跟着沉默一起消失。60 秒没有新事件时，气泡不清场，而是回落
    // 到最近那条审批：这样"有人在等你确认"始终有个落点，点卡片就能跳回那个终端，
    // 角标也不会随面板一起被收走。
    //
    // 这不是把旧的"审批全局优先"逻辑搬回来——那一版在事件流里拦截，一个未处理的
    // 审批会把其他 Agent 的所有 Hook 全挡住。这里只在完全没有新事件时才接管，任何
    // 一条新事件都照常刷新正文。
    NSArray<NSDictionary *> *pending = [self pendingApprovalSessionRecords];
    if (self.hasAgentStatus && pending.count > 0) {
        [self performSelector:@selector(hideAgentStatus) withObject:nil
            afterDelay:AgentStatusInactivityInterval];
        [self presentPendingApprovalRecord:pending.firstObject];
        return;
    }
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(enterIdleStatus) object:nil];
    [self.statusPanel orderOut:nil];
    [CCPetsGlassMenu dismiss];
    self.hasAgentStatus = NO;
    [self refreshApprovalBadge];
}
// 只改卡片内容和回跳目标，不走 displayAgentRecord：那条路会连带播动画、说一句话、
// 发一次通知，而这里是"气泡闲下来后回落"，重复表演反而吵。
- (void)presentPendingApprovalRecord:(NSDictionary *)record {
    if (record.count == 0) return;
    NSDictionary *terminal = [record[@"terminal"] isKindOfClass:NSDictionary.class]
        ? record[@"terminal"] : nil;
    if (terminal.count > 0) self.lastTerminalFocusTarget = terminal;
    NSString *provider = SanitizedShortString(record[@"provider"], 32);
    NSString *tool = [record[@"tool"] isKindOfClass:NSString.class] ? record[@"tool"] : @"";
    if ([self.lastStatusState isEqualToString:@"approval"] &&
        [self.lastStatusProvider isEqualToString:provider]) return;
    [self applyStatusPresentationForState:@"approval"
        provider:provider.length > 0 ? provider : @"Agent" tool:tool];
}
// 勾选 = 显示气泡。没有 agent 状态时也允许改，这样用户可以提前设好偏好，
// 而不必等下一次会话开始。
- (void)toggleStatusBubbleFromMenu:(NSButton *)sender {
    self.statusBubbleExpanded = !self.statusBubbleExpanded;
    [NSUserDefaults.standardUserDefaults setBool:self.statusBubbleExpanded
        forKey:StatusBubbleExpandedKey];
    sender.state = self.statusBubbleExpanded ? NSControlStateValueOn : NSControlStateValueOff;
    if (self.statusBubbleExpanded && self.hasAgentStatus) {
        [self positionAgentStatus];
        [self.statusPanel orderFrontRegardless];
    } else {
        [self.statusPanel orderOut:nil];
        [CCPetsGlassMenu dismiss];
    }
}
// Stop 之后还会飘来 SubagentStop / PostToolUse / TaskCompleted 这类"仍在工作"的尾巴事件
// （实测 Stop 后 4 秒），它们和 UserPromptSubmit 一样都归一成 thinking，只看 state 分不出来，
// 所以必须按事件名判断。终态只能被新一轮真实动作解除（用户提问、工具调用、需要关注），
// 否则"任务已完成"会被打回"正在思考"，看起来像任务又活了。
- (BOOL)isTrailingRecord:(NSDictionary *)record afterState:(NSString *)state {
    if (![state isEqualToString:@"completed"] && ![state isEqualToString:@"failed"]) return NO;
    NSString *event = [record[@"event"] isKindOfClass:NSString.class] ? record[@"event"] : @"";
    return [event isEqualToString:@"SubagentStop"] || [event isEqualToString:@"PostToolUse"] ||
        [event isEqualToString:@"TaskCompleted"];
}
- (void)applyStatusPresentationForState:(NSString *)state provider:(NSString *)provider
    tool:(NSString *)tool {
    self.lastStatusState = state;
    self.lastStatusProvider = provider;
    self.statusTitleLabel.stringValue = [NSString stringWithFormat:@"%@ · %@",
        provider, [self statusTextForState:state tool:tool]];
    self.statusDetailLabel.stringValue = [self statusDetailForState:state tool:tool];
    // 上一句碎碎念借走的副行已经被新状态覆盖，取消那次归还，否则它会把旧文案写回来。
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(restoreStatusDetail) object:nil];
    NSColor *stateColor = [self statusColorForState:state];
    self.statusIconButton.layer.backgroundColor = [stateColor colorWithAlphaComponent:0.28].CGColor;
    NSImage *icon = [NSImage imageWithSystemSymbolName:[self statusSymbolForState:state]
        accessibilityDescription:[self statusTextForState:state tool:tool]];
    self.statusIconButton.image = [icon imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightBold]];
    self.statusIconButton.contentTintColor = [stateColor blendedColorWithFraction:0.18
        ofColor:NSColor.blackColor] ?: stateColor;
    [self resizeStatusCardToFitText];
    [self layoutApprovalBadge];
    [self positionAgentStatus];
    if (self.statusBubbleExpanded) {
        [self.statusPanel orderFrontRegardless];
        // 卡片一出现就收掉独立气泡：两者都是宠物在说话，同时挂着就是重影。
        // 更新气泡也一样让开：agent 有新动静时状态卡优先，更新入口还有角标和菜单。
        if (self.speechPanel.isVisible) [self hideSpeechBubble];
    } else {
        [self.statusPanel orderOut:nil];
        [CCPetsGlassMenu dismiss];
    }
}
// "正在启动"只在会话拉起的一瞬间成立。之后如果没有任何后续事件，真实情况是会话已就绪、
// 正在等用户输入——继续显示"正在准备当前会话…"会让启动和待机看起来一模一样。
- (void)enterIdleStatus {
    if (!self.hasAgentStatus) return;
    [self applyStatusPresentationForState:@"idle"
        provider:self.lastStatusProvider ?: @"Agent" tool:@""];
}
- (void)showAgentStatusForRecord:(NSDictionary *)record notify:(BOOL)shouldNotify {
    NSString *provider = SanitizedShortString(record[@"provider"], 32);
    if (provider.length == 0) provider = @"Agent";
    NSString *state = [record[@"state"] isKindOfClass:NSString.class]
        ? record[@"state"] : NormalizedStateForEvent(record[@"event"], [record[@"failed"] boolValue]);
    NSString *tool = [record[@"tool"] isKindOfClass:NSString.class] ? record[@"tool"] : @"";
    // 尾巴事件仍然算"客户端还活着"，只是不该改写气泡上的终态。
    self.lastStatusTimestamp = [NSDate.date timeIntervalSince1970];
    if (!self.providerActivityAt) self.providerActivityAt = [NSMutableDictionary dictionary];
    self.providerActivityAt[provider] = @(self.lastStatusTimestamp);
    [self updateQuotaLiveState];
    if (self.hasAgentStatus && [provider isEqualToString:self.lastStatusProvider] &&
        [self isTrailingRecord:record afterState:self.lastStatusState]) return;

    NSDictionary *terminal = [record[@"terminal"] isKindOfClass:NSDictionary.class]
        ? record[@"terminal"] : nil;
    self.lastTerminalFocusTarget = terminal.count > 0 ? terminal : nil;

    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(hideAgentStatus) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(enterIdleStatus) object:nil];
    self.hasAgentStatus = YES;
    [self applyStatusPresentationForState:state provider:provider tool:tool];
    [self.panel orderFrontRegardless];
    [self performSelector:@selector(hideAgentStatus)
        withObject:nil afterDelay:AgentStatusInactivityInterval];
    if ([state isEqualToString:@"starting"]) {
        [self performSelector:@selector(enterIdleStatus) withObject:nil
            afterDelay:AgentStartingGraceInterval];
    }
    if (shouldNotify) [self notifyForRecord:record];
}
- (void)showAgentStatusForRecord:(NSDictionary *)record {
    [self showAgentStatusForRecord:record notify:YES];
}
- (NSString *)approvalKeyForRecord:(NSDictionary *)record {
    NSString *provider = SanitizedShortString(record[@"provider"], 32);
    if (provider.length == 0) provider = @"Agent";
    NSString *session = SanitizedShortString(record[@"session"], 128);
    return session.length > 0
        ? [NSString stringWithFormat:@"%@:%@", provider, session]
        : provider;
}
- (void)prunePendingApprovalRecords {
    NSTimeInterval cutoff = NSDate.date.timeIntervalSince1970 - PendingApprovalTTL;
    for (NSString *key in self.pendingApprovalRecords.allKeys) {
        NSDictionary *record = self.pendingApprovalRecords[key];
        if ([record[@"timestamp"] doubleValue] < cutoff) {
            [self.pendingApprovalRecords removeObjectForKey:key];
        }
    }
    if (self.pendingApprovalRecords.count <= PendingApprovalLimit) return;
    NSArray<NSDictionary *> *oldestFirst = [self.pendingApprovalRecords.allValues
        sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            NSTimeInterval leftTime = [left[@"timestamp"] doubleValue];
            NSTimeInterval rightTime = [right[@"timestamp"] doubleValue];
            if (leftTime < rightTime) return NSOrderedAscending;
            if (leftTime > rightTime) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    NSUInteger removeCount = oldestFirst.count - PendingApprovalLimit;
    for (NSUInteger index = 0; index < removeCount; index++) {
        NSString *key = [self approvalKeyForRecord:oldestFirst[index]];
        [self.pendingApprovalRecords removeObjectForKey:key];
    }
}
- (void)displayAgentRecord:(NSDictionary *)record notify:(BOOL)shouldNotify {
    NSString *event = [record[@"event"] isKindOfClass:NSString.class] ? record[@"event"] : @"";
    NSString *state = [record[@"state"] isKindOfClass:NSString.class] ? record[@"state"] : @"";
    NSString *tool = [record[@"tool"] isKindOfClass:NSString.class] ? record[@"tool"] : @"";
    NSString *animationEvent = [state isEqualToString:@"auto_review"]
        ? @"AutoReviewRequest" : event;
    [self.petView handleAgentEvent:animationEvent tool:tool
        failed:[record[@"failed"] boolValue]];
    [self showAgentStatusForRecord:record notify:shouldNotify];
    // 说话是事件流的新消费者，不改变事件生产。冷启动重放已被 processAgentEventData
    // 的 recentOnly + 5 秒 cutoff 挡住，再加上预算制和冷却，最坏也只多说一句。
    [self considerSpeechForRecord:record];
}
- (NSString *)agentSessionKeyForRecord:(NSDictionary *)record {
    NSString *provider = SanitizedShortString(record[@"provider"], 32);
    NSDictionary *terminal = [record[@"terminal"] isKindOfClass:NSDictionary.class]
        ? record[@"terminal"] : nil;
    NSString *tty = SanitizedShortString(terminal[@"tty"], 64);
    NSString *bundleID = SanitizedShortString(terminal[@"bundleID"], 128);
    if (tty.length > 0) {
        return [NSString stringWithFormat:@"%@|%@|%@", provider, bundleID, tty];
    }
    NSString *session = SanitizedShortString(record[@"session"], 128);
    if (session.length > 0) return [NSString stringWithFormat:@"%@|%@", provider, session];
    return terminal.count > 0 ? [NSString stringWithFormat:@"%@|%@", provider, bundleID] : nil;
}
- (NSString *)onlineAgentSessionKeyForProvider:(NSString *)provider tty:(NSString *)tty {
    provider = SanitizedShortString(provider, 32);
    tty = SanitizedShortString(tty.lastPathComponent, 64);
    if (provider.length == 0 || tty.length == 0) return nil;
    return [NSString stringWithFormat:@"%@|%@", provider, tty];
}
- (NSString *)onlineAgentSessionKeyForRecord:(NSDictionary *)record {
    NSDictionary *terminal = [record[@"terminal"] isKindOfClass:NSDictionary.class]
        ? record[@"terminal"] : nil;
    return [self onlineAgentSessionKeyForProvider:record[@"provider"] tty:terminal[@"tty"]];
}
// 在线判定优先用包装脚本写出的 pid 文件：它给出精确的退出信号，会话一关列表就更新。
// 但直接跑 claude / codex（或终端窗口早于 shim 安装就已打开）的会话根本没有 pid 文件，
// 只按 pid 文件判定会把它们当场判死，列表里永远看不到——哪怕它们的 Hook 正在正常发事件。
// 这类会话退回活跃度宽限：最近一次事件在静默窗口内就算在线。某个 provider 一旦出现过
// pid 文件，说明包装脚本对它生效，继续按精确信号判定，不被宽限盖住。
- (BOOL)isAgentSessionRecordLive:(NSDictionary *)record {
    NSString *onlineKey = [self onlineAgentSessionKeyForRecord:record];
    if (onlineKey.length > 0 && [self.liveAgentSessionKeys containsObject:onlineKey]) return YES;
    NSString *provider = SanitizedShortString(record[@"provider"], 32);
    if (provider.length > 0 && [self.liveClientProviders containsObject:provider]) return NO;
    return NSDate.date.timeIntervalSince1970 - [record[@"timestamp"] doubleValue]
        < AgentStatusInactivityInterval;
}
- (void)pruneOfflineAgentSessionRecords {
    for (NSString *key in self.agentSessionRecords.allKeys) {
        if (![self isAgentSessionRecordLive:self.agentSessionRecords[key]]) {
            [self.agentSessionRecords removeObjectForKey:key];
        }
    }
}
- (void)trackAgentSessionRecord:(NSDictionary *)record {
    NSString *key = [self agentSessionKeyForRecord:record];
    if (key.length == 0) return;
    if (!self.agentSessionRecords) self.agentSessionRecords = [NSMutableDictionary dictionary];
    self.agentSessionRecords[key] = record;
    if (self.agentSessionRecords.count <= AgentSessionRecordLimit) return;
    NSArray<NSDictionary *> *oldestFirst = [self.agentSessionRecords.allValues
        sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            return [left[@"timestamp"] compare:right[@"timestamp"]];
        }];
    NSUInteger removeCount = oldestFirst.count - AgentSessionRecordLimit;
    for (NSUInteger index = 0; index < removeCount; index++) {
        NSString *oldKey = [self agentSessionKeyForRecord:oldestFirst[index]];
        if (oldKey) [self.agentSessionRecords removeObjectForKey:oldKey];
    }
}
- (BOOL)isApprovalSessionRecord:(NSDictionary *)record {
    NSString *state = [record[@"state"] isKindOfClass:NSString.class] ? record[@"state"] : @"";
    return [state isEqualToString:@"approval"];
}
// 卡在审批的在线会话，最近的排前面。角标计数和会话列表置顶共用这一份，两处数字
// 才不会打架。判据是"该会话的最后一条事件是审批"——审批一旦被处理，后续事件会
// 把这条记录顶掉，会话自然退出这个集合，不需要额外的解除信号。
- (NSArray<NSDictionary *> *)pendingApprovalSessionRecords {
    [self pruneOfflineAgentSessionRecords];
    NSMutableArray<NSDictionary *> *pending = [NSMutableArray array];
    for (NSDictionary *record in self.agentSessionRecords.allValues) {
        if ([self isApprovalSessionRecord:record]) [pending addObject:record];
    }
    [pending sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [right[@"timestamp"] compare:left[@"timestamp"]];
    }];
    return pending;
}
- (NSTimeInterval)stallIntervalForState:(NSString *)state {
    if ([state isEqualToString:@"approval"]) return AgentApprovalStallInterval;
    if ([state isEqualToString:@"thinking"]) return AgentThinkingStallInterval;
    return 0;
}
// 会话停在同一个状态太久就提醒一次。去重键带上该会话当时的时间戳：会话一有新
// 事件，时间戳变了，旧键自然失效，于是下一次卡住还会再提醒。每轮用当前有效键
// 求交集，退出的会话不会在集合里留垃圾。
- (void)checkStalledAgentSessions {
    if (self.agentSessionRecords.count == 0) {
        [self.stallNotifiedSessionKeys removeAllObjects];
        return;
    }
    [self pruneOfflineAgentSessionRecords];
    if (!self.stallNotifiedSessionKeys) self.stallNotifiedSessionKeys = [NSMutableSet set];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    BOOL shouldNotify = [NSUserDefaults.standardUserDefaults boolForKey:NotificationStallKey];
    NSMutableSet<NSString *> *valid = [NSMutableSet set];
    NSDictionary *stalled = nil;
    for (NSString *key in self.agentSessionRecords.allKeys) {
        NSDictionary *record = self.agentSessionRecords[key];
        NSTimeInterval timestamp = [record[@"timestamp"] doubleValue];
        NSString *stamp = [NSString stringWithFormat:@"%@|%.0f", key, timestamp];
        [valid addObject:stamp];
        NSString *state = [record[@"state"] isKindOfClass:NSString.class] ? record[@"state"] : @"";
        NSTimeInterval limit = [self stallIntervalForState:state];
        if (limit <= 0 || now - timestamp < limit) continue;
        if ([self.stallNotifiedSessionKeys containsObject:stamp]) continue;
        [self.stallNotifiedSessionKeys addObject:stamp];
        NSString *provider = SanitizedShortString(record[@"provider"], 32);
        if (provider.length == 0) provider = @"Agent";
        if (shouldNotify) {
            NSInteger minutes = (NSInteger)((now - timestamp) / 60.0);
            [self sendNotificationWithTitle:
                [state isEqualToString:@"approval"] ? L(@"Approval still pending") : L(@"Agent unresponsive")
                body:[NSString stringWithFormat:L(@"%1$@: %2$@ for %3$ld min."),
                    provider, [self statusTextForState:state tool:record[@"tool"]], (long)minutes]];
        }
        // 多个会话同时卡住时只把最旧的那条顶到气泡上：它等得最久。
        if (!stalled || [record[@"timestamp"] doubleValue] < [stalled[@"timestamp"] doubleValue]) {
            stalled = record;
        }
    }
    [self.stallNotifiedSessionKeys intersectSet:valid];
    if (!stalled) return;
    NSString *event = [stalled[@"event"] isKindOfClass:NSString.class] ? stalled[@"event"] : @"";
    NSString *tool = [stalled[@"tool"] isKindOfClass:NSString.class] ? stalled[@"tool"] : @"";
    [self.petView handleAgentEvent:event tool:tool failed:NO];
    [self presentStalledRecord:stalled];
}
// 卡住提醒要把气泡重新推到眼前，所以这里不走 presentPendingApprovalRecord 那条
// 带早退的回落路径——面板此刻很可能已经因为长时间沉默被收走了，必须强制重现。
- (void)presentStalledRecord:(NSDictionary *)record {
    NSDictionary *terminal = [record[@"terminal"] isKindOfClass:NSDictionary.class]
        ? record[@"terminal"] : nil;
    if (terminal.count > 0) self.lastTerminalFocusTarget = terminal;
    NSString *provider = SanitizedShortString(record[@"provider"], 32);
    NSString *state = [record[@"state"] isKindOfClass:NSString.class] ? record[@"state"] : @"";
    self.hasAgentStatus = YES;
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(hideAgentStatus) object:nil];
    [self applyStatusPresentationForState:state
        provider:provider.length > 0 ? provider : @"Agent"
        tool:[record[@"tool"] isKindOfClass:NSString.class] ? record[@"tool"] : @""];
    [self.panel orderFrontRegardless];
    [self performSelector:@selector(hideAgentStatus) withObject:nil
        afterDelay:AgentStatusInactivityInterval];
}
- (void)layoutApprovalBadge {
    if (!self.approvalBadgeView) return;
    // statusIconButton 在玻璃卡片内，角标在卡片外层，差一个 6 点的卡片边距。
    // 再各让出 4 点压到图标身上，看起来才是"贴在图标角上"而不是浮在旁边。
    NSRect icon = self.statusIconButton.frame;
    self.approvalBadgeView.frame = NSMakeRect(
        6 + NSMaxX(icon) - PetApprovalBadgeSize + 4,
        6 + NSMaxY(icon) - PetApprovalBadgeSize + 4,
        PetApprovalBadgeSize, PetApprovalBadgeSize);
    self.bridgeBadgeView.frame = NSMakeRect(
        6 + NSMaxX(icon) - PetApprovalBadgeSize + 4,
        6 + NSMinY(icon) - 4,
        PetApprovalBadgeSize, PetApprovalBadgeSize);
}
- (void)refreshApprovalBadge {
    CCPetsApprovalBadgeView *badge = (CCPetsApprovalBadgeView *)self.approvalBadgeView;
    if (!badge) return;
    badge.count = [self pendingApprovalSessionRecords].count;
    [self layoutApprovalBadge];
}
// 等审批的排最前面。纯按时间倒序会把它们推到最底下——它们的时间戳按定义只会
// 越来越旧，而它们恰恰是唯一需要用户动手的那几条。
- (NSArray<NSDictionary *> *)recentAgentSessionRecords {
    [self pruneOfflineAgentSessionRecords];
    NSArray<NSDictionary *> *records = [self.agentSessionRecords.allValues
        sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            BOOL leftApproval = [self isApprovalSessionRecord:left];
            BOOL rightApproval = [self isApprovalSessionRecord:right];
            if (leftApproval != rightApproval) return leftApproval ? NSOrderedAscending : NSOrderedDescending;
            return [right[@"timestamp"] compare:left[@"timestamp"]];
        }];
    if (records.count <= AgentSessionMenuLimit) return records;
    return [records subarrayWithRange:NSMakeRange(0, AgentSessionMenuLimit)];
}
- (NSString *)terminalNameForTarget:(NSDictionary *)target {
    NSString *program = SanitizedShortString(target[@"program"], 64);
    NSString *lower = program.lowercaseString;
    if ([lower isEqualToString:@"apple_terminal"]) return @"Terminal";
    if ([lower containsString:@"iterm"]) return @"iTerm2";
    if ([lower isEqualToString:@"vscode"]) return @"VS Code";
    if ([lower containsString:@"jetbrains"]) return @"JetBrains";
    if ([lower containsString:@"ghostty"]) return @"Ghostty";
    if ([lower containsString:@"warp"]) return @"Warp";
    if ([lower containsString:@"wezterm"]) return @"WezTerm";
    if (program.length > 0) return program;
    NSString *bundleID = SanitizedShortString(target[@"bundleID"], 128);
    return bundleID.length > 0 ? bundleID : @"Terminal";
}
- (void)focusAgentSessionRecord:(NSMenuItem *)sender {
    NSDictionary *record = [sender.representedObject isKindOfClass:NSDictionary.class]
        ? sender.representedObject : nil;
    NSDictionary *target = [record[@"terminal"] isKindOfClass:NSDictionary.class]
        ? record[@"terminal"] : nil;
    if (target.count > 0) ActivateTerminalFocusTarget(target);
}
- (void)showAgentSessionsMenu:(NSButton *)sender {
    NSArray<NSDictionary *> *records = [self recentAgentSessionRecords];
    [self refreshBridgeState:nil];
    NSArray<NSDictionary *> *deliveries = self.bridgeRecentDeliveries ?: @[];
    NSDictionary<NSString *, NSNumber *> *pending = self.bridgePendingCounts ?: @{};
    if (records.count == 0 && deliveries.count == 0 && pending.count == 0) return;
    NSMenu *menu = [[NSMenu alloc] initWithTitle:L(@"Recent Agent Sessions")];
    if (deliveries.count > 0 || pending.count > 0) {
        [self addBridgeItemsToMenu:menu deliveries:deliveries pending:pending];
        [menu addItem:NSMenuItem.separatorItem];
    }
    // 菜单打开即视为看过：角标清零，下一条新消息再亮。
    self.bridgeSeenAt = NSDate.date.timeIntervalSince1970;
    [self refreshBridgeBadge];
    if (records.count == 0) {
        [self popUpAgentSessionsMenu:menu from:sender];
        return;
    }
    NSMenuItem *heading = [menu addItemWithTitle:L(@"Recent Agent Sessions") action:nil keyEquivalent:@""];
    heading.enabled = NO;
    [menu addItem:NSMenuItem.separatorItem];
    BOOL separatedApprovals = NO;
    for (NSDictionary *record in records) {
        NSString *provider = SanitizedShortString(record[@"provider"], 32);
        NSString *state = [record[@"state"] isKindOfClass:NSString.class] ? record[@"state"] : @"";
        NSString *tool = [record[@"tool"] isKindOfClass:NSString.class] ? record[@"tool"] : @"";
        NSDictionary *target = record[@"terminal"];
        BOOL approval = [self isApprovalSessionRecord:record];
        // 置顶的审批组和其余会话之间划一道线，免得两段看起来像同一个时间序列。
        if (!approval && !separatedApprovals && record != records.firstObject) {
            [menu addItem:NSMenuItem.separatorItem];
            separatedApprovals = YES;
        }
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:[record[@"timestamp"] doubleValue]];
        NSString *time = [NSDateFormatter localizedStringFromDate:date
            dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle];
        // 开启 CC Bridge 时带上会话名：用户和 Agent 之间就是用这个名字互相指代的。
        NSDictionary *bridge = [self bridgeSessionEntryForRecord:record];
        NSString *bridgeName = bridge.count > 0
            ? [NSString stringWithFormat:L(@" (%@)"), bridge[@"name"]] : @"";
        NSUInteger waiting = [pending[[self bridgeSessionIdForRecord:record] ?: @""] unsignedIntegerValue];
        NSString *title = [NSString stringWithFormat:@"%@%@%@ · %@ · %@ · %@%@",
            approval ? @"⚠️ " : @"",
            provider.length > 0 ? provider : @"Agent", bridgeName,
            [self statusTextForState:state tool:tool], [self terminalNameForTarget:target], time,
            waiting > 0 ? [NSString stringWithFormat:@" · 📬 %lu", (unsigned long)waiting] : @""];
        NSMenuItem *item = [menu addItemWithTitle:title
            action:@selector(focusAgentSessionRecord:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = record;
        if ([target isEqual:self.lastTerminalFocusTarget]) item.state = NSControlStateValueOn;
    }
    [self popUpAgentSessionsMenu:menu from:sender];
}
// Liquid Glass 主题下用玻璃面板展示，和旁边的玻璃状态卡保持一致；经典主题仍是系统菜单。
// 玻璃面板不抢焦点，所以不支持方向键选择，Esc 只在本 App 处于前台时有效。
- (void)popUpAgentSessionsMenu:(NSMenu *)menu from:(NSButton *)sender {
    if (self.statusGlass.usesLiquidGlass) {
        [CCPetsGlassMenu showMenu:menu belowView:self.statusGlass alignRightTo:self.statusGlass];
        return;
    }
    [menu popUpMenuPositioningItem:nil
        atLocation:NSMakePoint(0, NSHeight(sender.bounds) + 4) inView:sender];
}
- (BOOL)focusLatestAgentTerminal {
    // 只有 Hook 状态气泡上的透明按钮会调用这里；桌宠本体继续负责原有互动。
    if (!self.hasAgentStatus || self.lastTerminalFocusTarget.count == 0) return NO;
    return ActivateTerminalFocusTarget(self.lastTerminalFocusTarget);
}
- (void)focusLatestAgentTerminal:(id)sender {
    [self focusLatestAgentTerminal];
}
// 状态卡：左内边距 20 + 文字 + 间隙 8 + 图标 34 + 右内边距 14。
- (void)resizeStatusCardToFitText {
    if (!self.statusPanel) return;
    const CGFloat leading = 20, gap = 8, iconWidth = 34, trailing = 14;
    // 副行没内容时收成单行，而不是留一块空白。
    //
    // 台词全在 speech.txt 里，代码里没有兜底文案：用户把某个 state_ 小节清空了，
    // 副行就真的没有东西可显示。编辑器保存时会拦下这种文件，但外部编辑器绕得过去，
    // 所以显示层必须自己站得住。
    BOOL hasDetail = self.statusDetailLabel.stringValue.length > 0;
    CGFloat height = hasDetail ? PetStatusBodyHeight : PetStatusSingleLineHeight;
    CGFloat textWidth = PetMeasuredLabelWidth(self.statusTitleLabel);
    if (hasDetail) {
        textWidth = fmax(textWidth, PetMeasuredLabelWidth(self.statusDetailLabel));
    }
    CGFloat glassWidth = leading + textWidth + gap + iconWidth + trailing;
    glassWidth = fmax(210.0, fmin(glassWidth, 420.0));
    NSSize panelSize = NSMakeSize(glassWidth + 12, height + 12);
    // 文字未变化时也重新应用比例，滑动条缩放不能被原来的尺寸早退跳过。
    PetResizeBubblePanel(self.statusPanel, panelSize);
    self.statusGlass.frame = NSMakeRect(6, 6, glassWidth, height);
    self.statusGlass.cornerRadius = height / 2.0;
    self.statusShadowView.frame = NSMakeRect(6, 6, glassWidth, height);
    self.statusShadowView.layer.cornerRadius = height / 2.0;
    // shadowPath 是按旧尺寸算死的，卡片变宽后不重算，阴影会留在原来的形状上。
    CGPathRef path = CGPathCreateWithRoundedRect(self.statusShadowView.bounds,
        height / 2.0, height / 2.0, NULL);
    self.statusShadowView.layer.shadowPath = path;
    CGPathRelease(path);

    CGFloat labelWidth = glassWidth - leading - gap - iconWidth - trailing;
    self.statusDetailLabel.hidden = !hasDetail;
    if (hasDetail) {
        self.statusTitleLabel.frame = NSMakeRect(leading, 34, labelWidth, 14);
        self.statusDetailLabel.frame = NSMakeRect(leading, 10, labelWidth, 22);
    } else {
        self.statusTitleLabel.frame = NSMakeRect(leading, (height - 14) / 2.0, labelWidth, 14);
    }
    self.statusIconButton.frame = NSMakeRect(glassWidth - trailing - iconWidth,
        (height - iconWidth) / 2.0, iconWidth, iconWidth);
    self.statusClickButton.frame = NSMakeRect(6, 6, glassWidth - 56, height);
    [self layoutApprovalBadge];
}
// 面板底边到"最小那颗圆点底边"的距离。定位要拿它反推面板该放多高，
// 才能让圆点正好落在宠物头顶而不是悬在空中。
- (void)positionAgentStatus {
    NSRect petFrame = self.panel.frame;
    NSRect visible = (self.panel.screen ?: NSScreen.mainScreen).visibleFrame;
    NSSize size = self.statusPanel.frame.size;
    CGFloat x = NSMidX(petFrame) - size.width / 2.0;
    CGFloat gap = 8 * CCPetsBubbleScalePreference();
    CGFloat aboveY = NSMaxY(petFrame) + gap;
    CGFloat belowY = NSMinY(petFrame) - size.height - gap;
    BOOL aboveFits = aboveY + size.height <= NSMaxY(visible) - 10;
    BOOL belowFits = belowY >= NSMinY(visible) + 10;
    self.statusBubbleAbove = aboveFits || !belowFits;
    CGFloat y = self.statusBubbleAbove ? aboveY : belowY;
    x = fmax(NSMinX(visible) + 10, fmin(x, NSMaxX(visible) - size.width - 10));
    y = fmax(NSMinY(visible) + 10, fmin(y, NSMaxY(visible) - size.height - 10));
    [self.statusPanel setFrameOrigin:NSMakePoint(x, y)];
}
@end
