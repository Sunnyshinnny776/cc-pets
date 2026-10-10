// 右键菜单里的各项设置开关。
#import "CCPetsAppDelegate+Private.h"

@implementation AppDelegate (Settings)
- (NSString *)systemMetricKeyForTag:(NSInteger)tag {
    if (tag == 1) return SystemCPUEnabledKey;
    if (tag == 2) return SystemTemperatureEnabledKey;
    if (tag == 3) return SystemMemoryEnabledKey;
    return nil;
}
- (void)applySystemMetricPreferences {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.quotaView.systemCPUEnabled = [defaults boolForKey:SystemCPUEnabledKey];
    self.quotaView.systemTemperatureEnabled =
        [defaults boolForKey:SystemTemperatureEnabledKey];
    self.quotaView.systemMemoryEnabled = [defaults boolForKey:SystemMemoryEnabledKey];
    self.quotaView.needsDisplay = YES;
}
- (void)applyUsageDisplayModePreferences {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.quotaView.codexShowsAPIUsage =
        [[defaults stringForKey:CodexUsageDisplayModeKey] isEqualToString:@"api"];
    self.quotaView.claudeShowsAPIUsage =
        [[defaults stringForKey:ClaudeUsageDisplayModeKey] isEqualToString:@"api"];
    self.quotaView.needsDisplay = YES;
}
- (void)setUsageDisplayModeFromControl:(NSButton *)sender {
    NSString *key = sender.tag == 1 ? CodexUsageDisplayModeKey
        : (sender.tag == 2 ? ClaudeUsageDisplayModeKey : nil);
    NSString *mode = sender.state == NSControlStateValueOn ? @"api" : @"subscription";
    if (!key) return;
    [NSUserDefaults.standardUserDefaults setObject:mode forKey:key];
    [self applyUsageDisplayModePreferences];
    // 展示模式决定了会话要回溯多远（订阅 8 天 / API 到上月月初），切换之后必须重新聚合，
    // 否则刚打开 API 视图时手里只有一段按 8 天窗口扫出来的数据。
    [self refreshUsage:nil];
}
- (void)toggleSystemMetric:(NSButton *)sender {
    NSString *key = [self systemMetricKeyForTag:sender.tag];
    if (!key) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL enabled = ![defaults boolForKey:key];
    [defaults setBool:enabled forKey:key];
    sender.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self applySystemMetricPreferences];
    [self updateSystemMetricsTimer];
}
// 开关打开时立刻导入一次，不用等下次启动——用户点开关就是想现在看到那些素材。
- (void)toggleImportCodexPets:(NSButton *)sender {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL enabled = ![defaults boolForKey:ImportCodexPetsKey];
    [defaults setBool:enabled forKey:ImportCodexPetsKey];
    sender.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    if (!enabled) return;
    NSUInteger imported = ImportCodexPets();
    if (imported == 0) return;
    [self invalidatePetOptionsCache];
    [self showImportedCodexPetsAlert:imported];
}
- (void)showImportedCodexPetsAlert:(NSUInteger)imported {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [NSAlert new];
    alert.messageText = L(@"Codex Pets Imported");
    [alert addButtonWithTitle:L(@"OK")];
    [alert runModal];
}
- (NSString *)notificationKeyForTag:(NSInteger)tag {
    if (tag == 1) return NotificationCompletionKey;
    if (tag == 2) return NotificationFailureKey;
    if (tag == 3) return NotificationApprovalKey;
    if (tag == 4) return NotificationStallKey;
    return nil;
}
// sender 是菜单里的 MenuChoiceRowView，勾选状态由它自己更新。
- (void)setPanelTheme:(MenuChoiceRowView *)sender {
    NSString *theme = sender.representedObject;
    if (![@[@"classic", @"liquid"] containsObject:theme]) return;
    [NSUserDefaults.standardUserDefaults setObject:theme forKey:CCPetsPanelThemeKey];
    [self.statusGlass applyTheme];
    [self.speechGlass applyTheme];
    [self.quotaGlass applyTheme];
    [self.updateBadgeGlass applyTheme];
    self.statusShadowView.hidden = self.statusGlass.usesLiquidGlass;
    self.quotaView.usesLiquidGlass = self.quotaGlass.usesLiquidGlass;
    self.quotaView.cardScrimAlpha = CCPetsGlassCardScrimAlpha();
    self.quotaView.needsDisplay = YES;
    [self applyBubbleTextStyle];
    // quotaView 换了父视图，mouseExited 不一定会送达；切主题是在宠物右键菜单里点的，
    // 鼠标此刻不在面板上，直接复位，免得面板一直当作"悬停中"不收起。
    self.dashboardHovering = NO;
}
// 状态卡和说话气泡原来是浅色磨砂配深色字；换成原生清透玻璃后背景是任意壁纸加一层
// 压暗，深色字会看不见，改成白字加贴字形的投影，和额度面板一致。
- (void)applyBubbleTextStyle {
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.45];
    shadow.shadowBlurRadius = 2;
    shadow.shadowOffset = NSMakeSize(0, -0.5);
    BOOL statusLiquid = self.statusGlass.usesLiquidGlass;
    self.statusTitleLabel.textColor = statusLiquid ? [NSColor colorWithWhite:1 alpha:0.78]
        : [NSColor colorWithWhite:0.42 alpha:0.90];
    self.statusDetailLabel.textColor = statusLiquid ? [NSColor colorWithWhite:1 alpha:0.97]
        : [NSColor colorWithWhite:0.12 alpha:0.96];
    self.statusTitleLabel.shadow = statusLiquid ? shadow : nil;
    self.statusDetailLabel.shadow = statusLiquid ? shadow : nil;
    BOOL speechLiquid = self.speechGlass.usesLiquidGlass;
    self.speechLabel.textColor = speechLiquid ? [NSColor colorWithWhite:1 alpha:0.97]
        : [NSColor colorWithWhite:0.10 alpha:0.96];
    self.speechLabel.shadow = speechLiquid ? shadow : nil;
    [self applyUpdateBadgeStyle];
}
- (void)setGlassDimLevel:(MenuChoiceRowView *)sender {
    NSNumber *level = sender.representedObject;
    if (![CCPetsGlassDimLevels() containsObject:level]) return;
    [NSUserDefaults.standardUserDefaults setObject:level forKey:CCPetsGlassDimKey];
    [self.quotaGlass applyDimLevel];
    [self.statusGlass applyDimLevel];
    [self.speechGlass applyDimLevel];
    [self.updateBadgeGlass applyDimLevel];
    self.quotaView.cardScrimAlpha = CCPetsGlassCardScrimAlpha();
    self.quotaView.needsDisplay = YES;
}
- (void)toggleSpeech:(NSButton *)sender {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id current = [defaults objectForKey:@"CCPetsSpeechEnabled"];
    BOOL enabled = current == nil ? YES : [current boolValue];
    [defaults setBool:!enabled forKey:@"CCPetsSpeechEnabled"];
    sender.state = !enabled ? NSControlStateValueOn : NSControlStateValueOff;
    // 更新提示不算碎碎念，关掉碎碎念时不收它。
    if (enabled && !self.updateBubbleVisible) [self hideSpeechBubble];
}
- (void)togglePetInteraction:(NSButton *)sender {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL enabled = ![defaults boolForKey:PetInteractionEnabledKey];
    [defaults setBool:enabled forKey:PetInteractionEnabledKey];
    sender.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
}
- (void)setPetInteractionHeartThreshold:(MenuChoiceRowView *)sender {
    NSNumber *value = [sender.representedObject isKindOfClass:NSNumber.class] ?
        sender.representedObject : @3;
    [NSUserDefaults.standardUserDefaults setInteger:MAX((NSInteger)2, value.integerValue)
        forKey:PetInteractionHeartThresholdKey];
}
- (void)setPetInteractionAnnoyedThreshold:(MenuChoiceRowView *)sender {
    NSNumber *value = [sender.representedObject isKindOfClass:NSNumber.class] ?
        sender.representedObject : @10;
    NSInteger heart = MAX((NSInteger)2, [NSUserDefaults.standardUserDefaults
        integerForKey:PetInteractionHeartThresholdKey]);
    [NSUserDefaults.standardUserDefaults setInteger:MAX(heart + 1, value.integerValue)
        forKey:PetInteractionAnnoyedThresholdKey];
}
- (void)setPetInteractionInterval:(MenuChoiceRowView *)sender {
    NSNumber *value = [sender.representedObject isKindOfClass:NSNumber.class] ?
        sender.representedObject : @1.2;
    [NSUserDefaults.standardUserDefaults setDouble:MAX(0.4, MIN(3.0, value.doubleValue))
        forKey:PetInteractionIntervalKey];
}
// 频率档位。改完立刻生效——四道闸都是现读的，不缓存。
// 顺手把冷却清掉，否则刚调高档位还要等完上一档的冷却才见效，会让人以为没生效。
- (void)setSpeechFrequency:(MenuChoiceRowView *)sender {
    NSString *value = [sender.representedObject isKindOfClass:NSString.class] ?
        sender.representedObject : PetSpeechFrequencyNormal;
    [NSUserDefaults.standardUserDefaults setObject:value forKey:PetSpeechFrequencyKey];
    self.speechCooldownUntil = 0;
    self.lastIdleSpeechCheck = 0;
}
- (void)setPhrasesSource:(MenuChoiceRowView *)sender {
    NSString *source = sender.representedObject;
    if (![@[PetPhrasesSourcePet, PetPhrasesSourceDefault] containsObject:source] ||
        [source isEqualToString:PetPhrasesSource()]) return;
    PetPhrasesSetSource(source);
    NSString *tag = self.lastPetVoiceTag;
    self.lastPetVoiceTag = nil;
    self.lastPetVoiceText = nil;
    // 收起旧来源的碎碎念，状态卡副行也立即换成新来源。
    if (!self.updateBubbleVisible) [self hideSpeechBubble];
    if (self.hasAgentStatus && self.lastStatusState.length > 0) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self
            selector:@selector(restoreStatusDetail) object:nil];
        // 保留当前工具对应的小节，不把执行命令、编辑文件等状态退成通用工具态。
        tag = tag ?: [self petVoiceTagForState:self.lastStatusState tool:@""];
        NSString *text = PetPhraseForTag(tag, [self speechSlots]);
        self.lastPetVoiceTag = tag;
        self.lastPetVoiceText = text;
        self.statusDetailLabel.stringValue = text ?: @"";
        [self resizeStatusCardToFitText];
        [self positionAgentStatus];
    }
}

// 台词交给内置编辑器，不再 openURL: 丢给"文本编辑"。
//
// 换掉的理由是反馈：系统编辑器保存完什么都不会说，小节名拼错、句子超 30 字、槽位
// 写错名字全是静默失效，用户只知道"改了没用"。内置编辑器保存时校验并当场报出来，
// 还能"试说一句"直接听效果。
- (void)editPhrasesFile:(id)sender {
    // 编辑器只管文本，不认识气泡；把"说出来"这一步作为回调注入。
    __weak typeof(self) weakSelf = self;
    [PetPhrasesEditorController setSpeakHandler:^(NSString *text) {
        [weakSelf presentSpeechText:text];
    }];
    [PetPhrasesEditorController present];
}
- (void)toggleNotification:(NSButton *)sender {
    NSString *key = [self notificationKeyForTag:sender.tag];
    if (!key) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:key]) {
        [defaults setBool:NO forKey:key];
        sender.state = NSControlStateValueOff;
        return;
    }
    [UNUserNotificationCenter.currentNotificationCenter
        requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
        completionHandler:^(BOOL granted, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (granted) {
                [defaults setBool:YES forKey:key];
                sender.state = NSControlStateValueOn;
            } else {
                sender.state = NSControlStateValueOff;
                NSString *message = error.localizedDescription ?:
                    L(@"Allow notifications in System Settings → Notifications → CC Pets, then try again.");
                [self showAlertWithTitle:L(@"Can't Enable Notifications") message:message];
            }
        });
    }];
}
// 菜单每次右键现建，切换后下次打开就是新语言；这里只刷新常驻的界面。
- (void)setLanguagePreferenceFromMenu:(NSMenuItem *)sender {
    NSString *preference = [sender.representedObject isKindOfClass:NSString.class] ?
        sender.representedObject : CCPetsLanguageSystem;
    if ([preference isEqualToString:CCPetsLanguagePreference()]) return;
    CCPetsSetLanguagePreference(preference);
}
- (void)languageDidChange:(NSNotification *)notification {
    PetPhrasesAdoptLanguageDefaults();
    NSApp.mainMenu = nil;
    [self installEditMenu];
    self.quotaView.needsDisplay = YES;
    // 状态卡标题和副行都是按状态现算的，按最后的状态重排一遍。工具名没留，
    // 工具态会暂时退成"正在使用工具"，下一条事件就会补回来。
    if (self.hasAgentStatus && self.lastStatusState.length > 0) {
        [self applyStatusPresentationForState:self.lastStatusState
            provider:self.lastStatusProvider ?: @"Agent" tool:@""];
    }
    // 正在显示的碎碎念是旧语言的，收起即可，下一句自然是新语言。更新提示由更新逻辑自己重排。
    if (!self.updateBubbleVisible) [self hideSpeechBubble];
}
@end
