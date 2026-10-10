// 说话气泡与碎碎念。
#import "CCPetsAppDelegate+Private.h"

// 档位写进 defaults 的键；PetView 的右键菜单也要读它。
NSString *const PetSpeechFrequencyKey = @"CCPetsSpeechFrequency";

@implementation AppDelegate (Speech)
- (BOOL)speechEnabled {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    // 缺省开启；用户可在右键菜单里关掉。
    id value = [defaults objectForKey:@"CCPetsSpeechEnabled"];
    return value == nil ? YES : [value boolValue];
}
// 当前档位。现读，右键菜单里改完立刻生效不用重启。
- (PetSpeechRate)speechRate {
    NSString *value = [NSUserDefaults.standardUserDefaults stringForKey:PetSpeechFrequencyKey];
    if ([value isEqualToString:PetSpeechFrequencyLow]) return PetSpeechRateLow;
    if ([value isEqualToString:PetSpeechFrequencyHigh]) return PetSpeechRateHigh;
    if ([value isEqualToString:PetSpeechFrequencyChatty]) return PetSpeechRateChatty;
    return PetSpeechRateNormal;
}
// 预算与冷却。两道闸门都过了才允许说。
// 默认跟随上面的档位；下面这两个键是更细的手动覆盖，写了就压过档位，
// 现读，改完立刻生效不用重启：
//   defaults write com.universewang.cc-pets CCPetsSpeechCooldown -float 0
//   defaults write com.universewang.cc-pets CCPetsSpeechHourlyBudget -int 100
//   defaults delete com.universewang.cc-pets CCPetsSpeechCooldown          # 交回档位
// 域名是 bundle identifier，不是 "cc-pets"——写错域的话键会落在另一个 plist 里，
// 桌宠永远看不到，表现为"设了没反应"。
- (NSTimeInterval)speechCooldownSeconds {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:@"CCPetsSpeechCooldown"];
    if (![value isKindOfClass:NSNumber.class]) return [self speechRate].cooldown;
    return MAX(0.0, [value doubleValue]);
}
- (NSInteger)speechHourlyBudget {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:@"CCPetsSpeechHourlyBudget"];
    if (![value isKindOfClass:NSNumber.class]) return [self speechRate].hourlyBudget;
    return MAX((NSInteger)1, [value integerValue]);
}
// agent 是不是正在干活。只有"待机中"和状态卡压根没显示这两种情况算闲——
// thinking / tool / subagent / approval / notification / completed / failed
// 副行上都带着用户还需要看的信息，闲话一律让路。
// 用 hasAgentStatus 而不是 statusPanel.isVisible：用户把状态卡折叠起来时卡片是隐藏的，
// 但 agent 照样在干活，这时候冒气泡等于绕过折叠又把话糊到脸上。
- (BOOL)agentBusyForSpeech {
    if (!self.hasAgentStatus) return NO;
    return ![self.lastStatusState isEqualToString:@"idle"];
}
- (BOOL)canSpeakNow {
    if (![self speechEnabled]) return NO;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now < self.speechCooldownUntil) return NO;
    if (!self.speechTimestamps) self.speechTimestamps = [NSMutableArray array];
    while (self.speechTimestamps.count > 0 &&
           now - self.speechTimestamps.firstObject.doubleValue > 3600.0) {
        [self.speechTimestamps removeObjectAtIndex:0];
    }
    return (NSInteger)self.speechTimestamps.count < [self speechHourlyBudget];
}
// 当前可用的槽位值。取不到的键就不放进去，模板层会因此跳过需要它的那些条目。
- (NSDictionary<NSString *, NSString *> *)speechSlots {
    return [self speechSlotsWithTool:self.lastSpeechTool];
}
- (NSDictionary<NSString *, NSString *> *)speechSlotsWithTool:(NSString *)tool {
    NSMutableDictionary<NSString *, NSString *> *slots = [NSMutableDictionary dictionary];
    NSCalendar *calendar = NSCalendar.currentCalendar;
    slots[@"hour"] = [@([calendar component:NSCalendarUnitHour fromDate:NSDate.date]) stringValue];
    if (self.consecutiveFailures > 0) {
        slots[@"failCount"] = [@(self.consecutiveFailures) stringValue];
    }
    if (self.sessionStartedAt > 0) {
        NSInteger minutes = (NSInteger)((NSDate.date.timeIntervalSince1970 -
            self.sessionStartedAt) / 60.0);
        if (minutes > 0) slots[@"sessionMin"] = [@(minutes) stringValue];
    }
    NSInteger remaining = [self remainingFiveHourQuotaPercent];
    if (remaining >= 0) {
        slots[@"quota5h"] = [NSString stringWithFormat:@"%ld%%", (long)remaining];
    }
    NSString *reset = [self fiveHourResetTimeText];
    if (reset.length > 0) slots[@"resetTime"] = reset;
    // 工具名此前从来没被填过，导致 "{toolName} 这货不靠谱。" 这类台词永远被跳过。
    NSString *trimmed = [tool stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceCharacterSet];
    if (trimmed.length > 0 && trimmed.length <= 24) slots[@"toolName"] = trimmed;
    return slots;
}
// 5 小时窗口的剩余百分比，取不到返回 -1。Claude 和 Codex 的字段名不一样，都认。
- (NSInteger)remainingFiveHourQuotaPercent {
    NSDictionary *usage = LatestClaudeUsage() ?: LatestUsage();
    NSDictionary *fiveHour = [usage[@"fiveHour"] isKindOfClass:NSDictionary.class]
        ? usage[@"fiveHour"] : nil;
    id used = fiveHour[@"used_percentage"] ?: fiveHour[@"used_percent"];
    if (![used isKindOfClass:NSNumber.class]) return -1;
    NSInteger remaining = 100 - [used integerValue];
    return MAX((NSInteger)0, MIN((NSInteger)100, remaining));
}
// 回血时间，按本机时区格式化。没有这个槽位的话，带 {resetTime} 的词条会被整条跳过。
- (NSString *)fiveHourResetTimeText {
    NSDictionary *usage = LatestClaudeUsage() ?: LatestUsage();
    NSDictionary *fiveHour = [usage[@"fiveHour"] isKindOfClass:NSDictionary.class]
        ? usage[@"fiveHour"] : nil;
    id resets = fiveHour[@"resets_at"];
    if (![resets isKindOfClass:NSNumber.class]) return nil;
    NSTimeInterval at = [resets doubleValue];
    if (at <= NSDate.date.timeIntervalSince1970) return nil;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm";
    formatter.timeZone = NSTimeZone.systemTimeZone;
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:at]];
}
// 额度是"跨阈值"事件，不是状态事件，所以单独判档。
//
// 只在向下穿档时说一次：低于 20%% 就一直念叨会变成唠叨，而额度刷新是每分钟级别的，
// 不设档位的话一小时预算瞬间就被烧光。回血（档位回升）时把标记还回去，
// 下个周期才能再触发。
- (void)considerQuotaSpeech {
    NSInteger remaining = [self remainingFiveHourQuotaPercent];
    if (remaining < 0) return;
    NSInteger tier;
    if (remaining <= 5) tier = 0;
    else if (remaining <= 10) tier = 1;
    else if (remaining <= 20) tier = 2;
    else tier = 3;

    NSInteger previous = self.lastQuotaTier;
    self.lastQuotaTier = tier;
    // 首次拿到数据只记档不出声，免得每次启动都通报一遍额度。
    // （lastQuotaTier 的初值 0 恰好是最低档，不加这道判断的话冷启动必然误判成"刚跌到 5%"。）
    if (!self.lastQuotaTierInitialized) {
        self.lastQuotaTierInitialized = YES;
        return;
    }
    if (tier >= previous) return;  // 回血或没跨档
    [self speakWithTag:PetPhraseTagQuotaLow];
}
- (void)buildSpeechPanelIfNeeded {
    if (self.speechPanel) return;
    NSSize glassSize = NSMakeSize(210, PetSpeechBodyHeight);
    NSSize size = NSMakeSize(glassSize.width + 12, glassSize.height + 12);
    self.speechPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    self.speechPanel.opaque = NO;
    self.speechPanel.backgroundColor = NSColor.clearColor;
    self.speechPanel.hasShadow = NO;
    self.speechPanel.level = NSFloatingWindowLevel;
    self.speechPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary;
    // 气泡不抢焦点、不接受点击：它是纯播报，挡住宠物就本末倒置了。
    self.speechPanel.ignoresMouseEvents = YES;

    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    self.speechGlass = [[CCPetsGlassView alloc]
        initWithFrame:NSMakeRect(6, 6, glassSize.width, glassSize.height)
        material:NSVisualEffectMaterialPopover appearance:NSAppearanceNameAqua
        cornerRadius:glassSize.height / 2.0];
    self.speechGlass.edgeShadeHeight = 9;
    self.speechGlass.edgeShadeAlpha = 0.6;
    self.speechGlass.usesWidgetGlass = YES;

    self.speechLabel = [NSTextField labelWithString:@""];
    self.speechLabel.frame = NSMakeRect(14, 10, glassSize.width - 28, 18);
    // 独立气泡里这句话是唯一元素，不与标题争，比并入状态卡时大半档。
    self.speechLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    self.speechLabel.textColor = [NSColor colorWithWhite:0.10 alpha:0.96];
    self.speechLabel.alignment = NSTextAlignmentCenter;
    self.speechLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.speechGlass.contentView addSubview:self.speechLabel];
    [root addSubview:self.speechGlass];
    // 平时气泡不接受点击；只有更新提示把它打开，点一下弹更新窗口。
    self.speechClickButton = [[CCPetsStatusClickButton alloc] initWithFrame:root.bounds];
    self.speechClickButton.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.speechClickButton.bordered = NO;
    self.speechClickButton.transparent = YES;
    self.speechClickButton.title = @"";
    self.speechClickButton.target = self;
    self.speechClickButton.action = @selector(updateBubbleClicked:);
    self.speechClickButton.hidden = YES;
    [root addSubview:self.speechClickButton];
    [self applyBubbleTextStyle];
    self.speechPanel.contentView = root;
}
// 独立气泡只在没有状态卡时出现（有状态卡时话并进它的副行），所以固定放宠物头顶即可，
// 不用再和状态卡抢位置。
- (void)positionSpeechPanel {
    NSRect petFrame = self.panel.frame;
    NSRect visible = (self.panel.screen ?: NSScreen.mainScreen).visibleFrame;
    NSSize size = self.speechPanel.frame.size;
    CGFloat x = NSMidX(petFrame) - size.width / 2.0;
    // 头顶放不下就翻到脚下，尾巴跟着改朝向长在顶边。
    CGFloat inset = 6 * CCPetsBubbleScalePreference();
    CGFloat aboveY = NSMaxY(petFrame) - inset;
    BOOL fitsAbove = aboveY + size.height <= NSMaxY(visible) - 10;
    CGFloat y = fitsAbove ? aboveY : NSMinY(petFrame) - size.height + inset;
    x = fmax(NSMinX(visible) + 10, fmin(x, NSMaxX(visible) - size.width - 10));
    y = fmax(NSMinY(visible) + 10, fmin(y, NSMaxY(visible) - size.height - 10));
    [self.speechPanel setFrameOrigin:NSMakePoint(x, y)];
}
// 说一句。tag 取不到词条、预算用完、或状态卡正展开时都直接不说——
// 两个泡同时挂在宠物头上会很吵。
- (void)speakWithTag:(NSString *)tag {
    if (![self canSpeakNow]) return;
    NSString *text = PetPhraseForTag(tag, [self speechSlots]);
    if (text.length == 0) return;

    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    [self.speechTimestamps addObject:@(now)];
    self.speechCooldownUntil = now + [self speechCooldownSeconds];

    [self presentSpeechText:text];
}
// 话往哪儿显示只在这一处决定：有状态卡就并进它的副行，没有才起独立气泡。
// 调试触发也必须走这里——否则看到的是现实中不会出现的画面（两个泡叠着）。
- (void)presentSpeechText:(NSString *)text {
    if (text.length == 0) return;
    if (self.statusPanel.isVisible) {
        self.statusDetailLabel.stringValue = text;
        [self resizeStatusCardToFitText];
        [self positionAgentStatus];
        // 上一句的独立气泡可能还没淡完，收掉它，别和状态卡叠着。更新气泡不归闲话管。
        if (!self.updateBubbleVisible) [self hideSpeechBubble];
        // 副行是状态卡的正文，借走说一句之后必须还回去，否则闲话会一直挂着，
        // 看起来像状态卡卡死了。
        //
        // 这里刻意不写 lastPetVoiceText/lastPetVoiceTag：那两个是状态文案的
        // 去重缓存，被闲话污染的话 restoreStatusDetail 就没有东西可还，而且
        // 下一次同状态事件会把闲话当成"该状态的文案"复读出来。
        [NSObject cancelPreviousPerformRequestsWithTarget:self
            selector:@selector(restoreStatusDetail) object:nil];
        [self performSelector:@selector(restoreStatusDetail) withObject:nil
            afterDelay:PetSpeechDwell];
        return;
    }
    // 更新气泡挂着时闲话让路，别把还没点的提示顶掉。
    if (self.updateBubbleVisible) return;
    [self showSpeechBubbleWithText:text];
}
// 把副行还给状态文案。lastPetVoiceText 里存的就是当前状态本该显示的那句。
- (void)restoreStatusDetail {
    if (!self.statusPanel.isVisible || self.lastPetVoiceText.length == 0) return;
    self.statusDetailLabel.stringValue = self.lastPetVoiceText;
    [self resizeStatusCardToFitText];
    [self positionAgentStatus];
}
- (void)showSpeechBubbleWithText:(NSString *)text {
    [self showSpeechBubbleWithText:text dwell:PetSpeechDwell];
}
- (void)showSpeechBubbleWithText:(NSString *)text dwell:(NSTimeInterval)dwell {
    [self buildSpeechPanelIfNeeded];
    self.speechLabel.stringValue = text;
    [self resizeSpeechBubbleToFitText];
    [self positionSpeechPanel];
    self.speechPanel.alphaValue = 0;
    [self.speechPanel orderFront:nil];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.18;
        self.speechPanel.animator.alphaValue = 1.0;
    } completionHandler:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(hideSpeechBubble) object:nil];
    [self performSelector:@selector(hideSpeechBubble) withObject:nil afterDelay:dwell];
}
// 调试触发：写一个标签进 defaults，下一跳（≤3 秒）就强制弹一次独立气泡，
// 绕开安静期、概率、预算和状态卡判断，弹完自动把键删掉，不会残留。
//   defaults write com.universewang.cc-pets CCPetsSpeechDebugTag -string idle
// 标签可填 idle / done / fail / quota_low / late_night / long_session / wake
- (void)consumeSpeechDebugTrigger {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id value = [defaults objectForKey:@"CCPetsSpeechDebugTag"];
    if (![value isKindOfClass:NSString.class] || [value length] == 0) return;
    [defaults removeObjectForKey:@"CCPetsSpeechDebugTag"];
    NSString *text = PetPhraseForTag(value, [self speechSlots]);
    if (text.length == 0) text = L(@"(No lines available for this tag)");
    [self presentSpeechText:text];
}
- (void)hideSpeechBubble {
    if (!self.speechPanel) return;
    self.updateBubbleVisible = NO;
    self.speechPanel.ignoresMouseEvents = YES;
    self.speechClickButton.hidden = YES;
    // 被更新气泡临时收起的状态卡还回去（会话已结束或用户关了状态卡就不还）。
    if (self.updateBubbleSuppressedStatus) {
        self.updateBubbleSuppressedStatus = NO;
        if (self.hasAgentStatus && self.statusBubbleExpanded && !self.statusPanel.isVisible) {
            [self positionAgentStatus];
            [self.statusPanel orderFrontRegardless];
        }
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.22;
        self.speechPanel.animator.alphaValue = 0;
    } completionHandler:^{
        if (self.speechPanel.alphaValue <= 0.01) [self.speechPanel orderOut:nil];
    }];
}
// 闲着时候的自发说话。
//
// 光挂在 agent 事件流上是不够的：那样宠物永远只会就着工作说话，late_night /
// long_session / idle 这些词条根本没有属于自己的触发时机，独立气泡也永远不会出现
// （agent 事件必定先把状态卡显示出来，话就并进去了）。
//
// 挂在已有的客户端存活定时器上，不新起 timer——常驻唤醒一个都不该多。
- (void)considerIdleSpeech {
    [self consumeSpeechDebugTrigger];
    if (self.updateBubbleDeferred && ![self agentBusyForSpeech]) [self showUpdateBubble];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    // 真正的判断最多 30 秒做一次，3 秒一跳的定时器上不必每次都算。
    if (now - self.lastIdleSpeechCheck < 30.0) return;
    self.lastIdleSpeechCheck = now;
    // agent 正在干活时闭嘴——工作文案优先级最高，闲话不许顶掉它。
    // 注意判断的是"在不在干活"，不是"状态卡在不在"：状态卡只要客户端活着就常驻，
    // 用它当闸门等于开着终端就永远不碎碎念。
    if ([self agentBusyForSpeech]) return;
    if (![self canSpeakNow]) return;

    // 安静多久才算"没人打扰"。复用无聊曲线那个缩放旋钮，测试时一并压缩。
    double scale = 1.0;
    id scaleValue = [NSUserDefaults.standardUserDefaults objectForKey:@"CCPetsBoredomScale"];
    if ([scaleValue isKindOfClass:NSNumber.class] && [scaleValue doubleValue] > 0) {
        scale = MIN([scaleValue doubleValue], 10.0);
    }
    PetSpeechRate rate = [self speechRate];
    NSTimeInterval quiet = self.lastAgentEventAt > 0 ? now - self.lastAgentEventAt : now;
    if (quiet < rate.quietSeconds * scale) return;

    // 不是每次够条件都说：概率化，免得变成整点报时。
    if (arc4random_uniform(100) >= rate.idleChancePercent) return;

    // 有待更新版本时，这句话有一半机会换成更新提醒。照样记进预算和冷却，
    // 不额外增加说话次数；碎碎念关着时 canSpeakNow 已经挡掉，不会走到这里。
    if (self.pendingUpdateVersion.length > 0 && !self.updating && !self.updateReminderSnoozed &&
        !self.updateBubbleVisible && arc4random_uniform(100) < UpdateReminderSharePercent) {
        [self.speechTimestamps addObject:@(now)];
        self.speechCooldownUntil = now + [self speechCooldownSeconds];
        [self showUpdateBubbleWithText:[self updateReminderText] dwell:UpdateReminderDwell];
        return;
    }

    NSInteger hour = [NSCalendar.currentCalendar component:NSCalendarUnitHour fromDate:NSDate.date];
    NSTimeInterval sessionLength = self.sessionStartedAt > 0 ? now - self.sessionStartedAt : 0;
    if (hour >= 1 && hour < 5) [self speakWithTag:PetPhraseTagLateNight];
    else if (sessionLength > 90 * 60.0) [self speakWithTag:PetPhraseTagLongSession];
    else [self speakWithTag:PetPhraseTagIdle];
}
// 只在显著时刻说话，不是每个 agent 事件都冒泡。
- (void)considerSpeechForRecord:(NSDictionary *)record {
    self.lastAgentEventAt = NSDate.date.timeIntervalSince1970;
    NSString *tool = [record[@"tool"] isKindOfClass:NSString.class] ? record[@"tool"] : nil;
    if (tool.length > 0) self.lastSpeechTool = tool;
    NSString *state = [record[@"state"] isKindOfClass:NSString.class] ? record[@"state"] : @"";
    NSString *event = [record[@"event"] isKindOfClass:NSString.class] ? record[@"event"] : @"";
    BOOL failed = [record[@"failed"] boolValue];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;

    if ([event isEqualToString:@"SessionStart"]) {
        // 久别重逢：距上次会话超过 4 小时才算，不然每开一个终端都要寒暄一遍。
        BOOL longGap = self.sessionStartedAt <= 0 || now - self.sessionStartedAt > 4 * 3600.0;
        self.sessionStartedAt = now;
        self.consecutiveFailures = 0;
        if (longGap) [self speakWithTag:PetPhraseTagWake];
        return;
    }
    if (failed) {
        self.consecutiveFailures += 1;
        // 单次失败很常见，连续两次才值得出声。
        if (self.consecutiveFailures >= 2) [self speakWithTag:PetPhraseTagFail];
        return;
    }
    if ([state isEqualToString:@"completed"]) {
        self.consecutiveFailures = 0;
        NSInteger hour = [NSCalendar.currentCalendar component:NSCalendarUnitHour
            fromDate:NSDate.date];
        NSTimeInterval sessionLength = self.sessionStartedAt > 0 ? now - self.sessionStartedAt : 0;
        // 同一时刻可能同时满足几个情境，按"更值得一提"的顺序挑一个说，不叠着说。
        if (hour >= 1 && hour < 5) [self speakWithTag:PetPhraseTagLateNight];
        else if (sessionLength > 90 * 60.0) [self speakWithTag:PetPhraseTagLongSession];
        else [self speakWithTag:PetPhraseTagDone];
    }
}
// 独立气泡：左右各 16 内边距，没有图标。
- (void)resizeSpeechBubbleToFitText {
    if (!self.speechPanel) return;
    const CGFloat padding = 16;
    CGFloat width = padding * 2 + PetMeasuredLabelWidth(self.speechLabel);
    width = fmax(96.0, fmin(width, 300.0));
    NSSize panelSize = NSMakeSize(width + 12, PetSpeechBodyHeight + 12);
    PetResizeBubblePanel(self.speechPanel, panelSize);
    self.speechGlass.frame = NSMakeRect(6, 6, width, PetSpeechBodyHeight);
    self.speechGlass.cornerRadius = PetSpeechBodyHeight / 2.0;
    self.speechLabel.frame = NSMakeRect(padding, 10, width - padding * 2, 18);
    self.speechClickButton.frame = self.speechPanel.contentView.bounds;
}
@end
