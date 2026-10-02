// AppDelegate 主干：启动、退出、窗口跟随。各功能模块在 CCPetsAppDelegate+<模块>.m 里，
// 共享常量和跨文件的方法声明见 CCPetsAppDelegate+Private.h。
#import "CCPetsAppDelegate+Private.h"

@implementation CCPetsStatusClickButton
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}
@end

@implementation CCPetsApprovalBadgeView
- (void)setCount:(NSUInteger)count {
    if (_count == count) return;
    _count = count;
    self.hidden = count == 0;
    self.needsDisplay = YES;
}
- (void)setFillColor:(NSColor *)fillColor {
    if ([_fillColor isEqual:fillColor]) return;
    _fillColor = fillColor;
    self.needsDisplay = YES;
}
// 角标压在圆形状态图标的右上角，但不能把那颗按钮的点击吃掉。
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (void)drawRect:(NSRect)dirtyRect {
    if (self.count == 0) return;
    // 描边是给玻璃卡片准备的：审批色和卡片背景都偏亮，没有这圈白边角标会糊在一起。
    NSRect circle = NSInsetRect(self.bounds, 1.0, 1.0);
    NSBezierPath *fill = [NSBezierPath bezierPathWithOvalInRect:circle];
    [(self.fillColor ?: [NSColor colorWithRed:0.86 green:0.24 blue:0.24 alpha:1]) setFill];
    [fill fill];
    fill.lineWidth = 1.5;
    [[NSColor colorWithWhite:1 alpha:0.92] setStroke];
    [fill stroke];
    BOOL overflow = self.count > 9;
    NSString *text = overflow ? @"9+" : @(self.count).stringValue;
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:overflow ? 8.5 : 10
            weight:NSFontWeightBold],
        NSForegroundColorAttributeName: NSColor.whiteColor
    };
    NSSize size = [text sizeWithAttributes:attributes];
    [text drawAtPoint:NSMakePoint(NSMidX(self.bounds) - size.width / 2.0,
        NSMidY(self.bounds) - size.height / 2.0) withAttributes:attributes];
}
@end

@implementation AppDelegate
- (NSString *)applicationSupportDirectory {
    return ApplicationSupportDirectory();
}
// 建一个只有"编辑"的主菜单。
//
// ⌘C/⌘V/⌘A/⌘Z 不是 NSTextView 自己处理的：按键先走 NSApp.mainMenu 的
// performKeyEquivalent:，命中菜单项之后才沿响应者链发 copy: / paste: 这些消息。
// 这个 app 是 LSUIElement，之前从没设过主菜单，所以台词编辑器里这些快捷键全部落空。
//
// LSUIElement 等价于 NSApplicationActivationPolicyAccessory，按定义不显示自己的菜单栏，
// 所以这个菜单只是一张快捷键路由表，用户看不见它。桌宠面板是 NSNonactivatingPanel，
// 点它根本不激活 app，更碰不到这里。
//
// action 一律留给响应者链（target 为 nil），谁是第一响应者谁处理——写死 target 的话
// 编辑器之外的文本框就用不上了。
- (void)installEditMenu {
    if (NSApp.mainMenu) return;
    NSMenu *mainMenu = [NSMenu new];
    NSMenuItem *editItem = [mainMenu addItemWithTitle:@"编辑" action:nil keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];

    NSArray<NSArray *> *entries = @[
        @[@"撤销", NSStringFromSelector(@selector(undo:)), @"z", @(NSEventModifierFlagCommand)],
        @[@"重做", NSStringFromSelector(@selector(redo:)), @"z",
          @(NSEventModifierFlagCommand | NSEventModifierFlagShift)],
        @[@"-", @"", @"", @0],
        @[@"剪切", NSStringFromSelector(@selector(cut:)), @"x", @(NSEventModifierFlagCommand)],
        @[@"拷贝", NSStringFromSelector(@selector(copy:)), @"c", @(NSEventModifierFlagCommand)],
        @[@"粘贴", NSStringFromSelector(@selector(paste:)), @"v", @(NSEventModifierFlagCommand)],
        @[@"删除", NSStringFromSelector(@selector(delete:)), @"", @0],
        @[@"全选", NSStringFromSelector(@selector(selectAll:)), @"a", @(NSEventModifierFlagCommand)],
    ];
    for (NSArray *entry in entries) {
        if ([entry[0] isEqualToString:@"-"]) {
            [editMenu addItem:NSMenuItem.separatorItem];
            continue;
        }
        NSMenuItem *item = [editMenu addItemWithTitle:entry[0]
            action:NSSelectorFromString(entry[1]) keyEquivalent:entry[2]];
        item.keyEquivalentModifierMask = (NSEventModifierFlags)[entry[3] unsignedIntegerValue];
    }
    editItem.submenu = editMenu;
    NSApp.mainMenu = mainMenu;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // 没有主菜单的话，台词编辑器里 ⌘C/⌘V/⌘A/⌘Z 全部没反应。
    [self installEditMenu];
    // 台词全在这个文件里，代码里没有第二份。首次启动先从默认词库拷一份出来，
    // 否则新装的桌宠一句话都不会说。
    PetPhrasesEnsureFileExists();
    if (![NSUserDefaults.standardUserDefaults boolForKey:PetInteractionPhrasesV1MigratedKey] &&
        PetPhrasesEnsureInteractionSections()) {
        [NSUserDefaults.standardUserDefaults setBool:YES
            forKey:PetInteractionPhrasesV1MigratedKey];
    }
    self.managedByCLI = [NSProcessInfo.processInfo.arguments containsObject:@"--managed"];
    NSString *binaryDir = NSProcessInfo.processInfo.arguments.firstObject.stringByStandardizingPath.stringByDeletingLastPathComponent;
    NSBundle *mainBundle = NSBundle.mainBundle;
    BOOL runsFromAppBundle = [mainBundle.bundlePath.pathExtension.lowercaseString isEqualToString:@"app"];
    self.binaryDirectory = runsFromAppBundle && mainBundle.resourcePath.length > 0
        ? mainBundle.resourcePath
        : binaryDir;
    // 必须在 waitForPetOptions 之前：否则自己的目录还空着、素材全在 Codex 那边时，
    // 会先弹一次"没有找到桌宠素材"，等用户点完重新扫描才导入。
    if ([NSUserDefaults.standardUserDefaults boolForKey:ImportCodexPetsKey]) ImportCodexPets();
    NSArray<NSDictionary *> *petOptions = [self waitForPetOptions];
    if (petOptions.count == 0) {
        [NSApp terminate:nil];
        return;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{StatusBubbleExpandedKey: @YES,
        CodexUsageDisplayModeKey: @"subscription",
        ClaudeUsageDisplayModeKey: @"subscription"}];
    [defaults registerDefaults:@{
        SystemCPUEnabledKey: @YES,
        SystemTemperatureEnabledKey: @YES,
        SystemMemoryEnabledKey: @YES,
        PetInteractionEnabledKey: @YES,
        PetInteractionHeartThresholdKey: @3,
        PetInteractionAnnoyedThresholdKey: @10,
        PetInteractionIntervalKey: @1.2,
        BridgeBadgeEnabledKey: @YES,
        BridgeNotificationKey: @NO
    }];
    if (![defaults boolForKey:StatusBubblePreferenceV2Key]) {
        [defaults setBool:YES forKey:StatusBubbleExpandedKey];
        [defaults setBool:YES forKey:StatusBubblePreferenceV2Key];
    }
    self.statusBubbleExpanded = [defaults boolForKey:StatusBubbleExpandedKey];
    NSString *selected = [defaults stringForKey:@"CCPetsSelectedSprite"];
    if (selected.length > 0 && ![selected containsString:@":"]) selected = [@"builtin:" stringByAppendingString:selected];
    NSDictionary *selectedOption = [self petOptionWithID:selected inOptions:petOptions] ?: petOptions.firstObject;
    selected = selectedOption[@"id"];
    NSString *spritePath = selectedOption[@"path"];
    NSImage *image = LoadPetSpriteImage(spritePath, NSMakeSize(140, 150),
        [selectedOption[@"spriteRowCount"] integerValue] ?: 9);
    if (!image) {
        fprintf(stderr, "无法读取桌宠素材: %s\n", spritePath.UTF8String);
        [NSApp terminate:nil];
        return;
    }

    NSSize size = NSMakeSize(230, 170);
    self.panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    self.panel.opaque = NO;
    self.panel.backgroundColor = NSColor.clearColor;
    self.panel.hasShadow = NO;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    // 与 1.0 一致：透明背景交给 AppKit 原生拖动；PetView 通过
    // mouseDownCanMoveWindow=NO 保留自己的点击和奔跑动画拖动，两条路径按命中区隔离。
    self.panel.movableByWindowBackground = YES;
    self.panel.hidesOnDeactivate = NO;

    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    self.panel.contentView = root;
    NSInteger spriteRowCount = [selectedOption[@"spriteRowCount"] integerValue] ?: 9;
    self.petView = [[PetView alloc] initWithFrame:NSMakeRect(43, 0, 144, 150)
        sheet:image rowCount:spriteRowCount];
    self.petView.currentPetID = selected;
    // 台词层要知道现在是哪只宠物，才能去找它的专属词库。启动这一处和 switchPetToID:
    // 那一处是仅有的两个入口——删除宠物后的回落也走 switchPetToID:。
    PetPhrasesSetCurrentPetID(selected);
    __weak typeof(self) weakSelf = self;
    self.petView.pocketHoverChanged = ^(BOOL hovering) {
        weakSelf.pocketHovering = hovering;
        if (hovering) [weakSelf showQuotaDashboard];
        else [weakSelf scheduleQuotaDashboardHide];
    };
    self.petView.petOptionsRequested = ^NSArray<NSDictionary *> *{
        return [weakSelf petOptions] ?: @[];
    };
    self.petView.switchPetRequested = ^(NSString *petID) {
        [weakSelf switchPetToID:petID];
    };
    self.petView.deletePetRequested = ^BOOL(NSString *petID) {
        return [weakSelf deletePetWithID:petID];
    };
    self.petView.dragStateChanged = ^(BOOL dragging) {
        weakSelf.petDragging = dragging;
        if (!dragging) [weakSelf scheduleQuotaDashboardHide];
    };
    self.petView.interactionPhraseRequested = ^(NSString *tag) {
        NSString *text = PetPhraseForTag(tag, [weakSelf speechSlots]);
        if (text.length > 0) [weakSelf presentSpeechText:text];
    };
    // 附属面板的跟随必须挂在窗口自身的移动通知上，不能只挂 PetView 的拖动回调：
    // panel 开了 movableByWindowBackground，按在 PetView 之外的透明边上时由 AppKit
    // 直接搬窗口，PetView 的 mouseDragged 根本不触发，气泡就会留在原地。
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(petWindowDidMove:)
        name:NSWindowDidMoveNotification object:self.panel];
    [root addSubview:self.petView];
    // 有新版本时挂在宠物右上角的「↑」角标：气泡只冒一会儿，角标一直在，点一下弹更新窗口。
    // 底子用和状态卡、气泡同一套 CCPetsGlassView，跟着面板主题和压暗档位走。
    // 在 petView 之后加入，点击先落到角标上。
    NSView *updateBadge = [[NSView alloc] initWithFrame:NSMakeRect(
        NSMaxX(self.petView.frame) - 30, NSMaxY(self.petView.frame) - 28,
        PetUpdateBadgeSize, PetUpdateBadgeSize)];
    updateBadge.hidden = YES;
    self.updateBadgeGlass = [[CCPetsGlassView alloc]
        initWithFrame:updateBadge.bounds material:NSVisualEffectMaterialPopover
        appearance:NSAppearanceNameAqua cornerRadius:PetUpdateBadgeSize / 2.0];
    self.updateBadgeGlass.edgeShadeHeight = 4;
    self.updateBadgeGlass.edgeShadeAlpha = 0.5;
    self.updateBadgeGlass.usesWidgetGlass = YES;
    [updateBadge addSubview:self.updateBadgeGlass];
    self.updateBadgeArrow = [[NSImageView alloc] initWithFrame:updateBadge.bounds];
    self.updateBadgeArrow.imageScaling = NSImageScaleNone;
    self.updateBadgeArrow.image = [[NSImage imageWithSystemSymbolName:@"arrow.up"
        accessibilityDescription:@"有新版本"] imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightBold]];
    [updateBadge addSubview:self.updateBadgeArrow];
    CCPetsStatusClickButton *updateClick = [[CCPetsStatusClickButton alloc]
        initWithFrame:updateBadge.bounds];
    updateClick.bordered = NO;
    updateClick.transparent = YES;
    updateClick.title = @"";
    updateClick.target = self;
    updateClick.action = @selector(updateBubbleClicked:);
    [updateBadge addSubview:updateClick];
    self.updateBadgeButton = updateClick;
    self.updateBadgeView = updateBadge;
    [root addSubview:updateBadge];
    [self applyUpdateBadgeStyle];

    NSSize statusGlassSize = NSMakeSize(340, PetStatusBodyHeight);
    NSSize statusSize = NSMakeSize(statusGlassSize.width + 12, statusGlassSize.height + 12);
    self.statusPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0,
        statusSize.width, statusSize.height)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    self.statusPanel.opaque = NO;
    self.statusPanel.backgroundColor = NSColor.clearColor;
    self.statusPanel.hasShadow = NO;
    self.statusPanel.ignoresMouseEvents = NO;
    self.statusPanel.level = NSFloatingWindowLevel;
    self.statusPanel.collectionBehavior =
        NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.statusPanel.hidesOnDeactivate = NO;
    NSView *statusRoot = [[NSView alloc] initWithFrame:NSMakeRect(
        0, 0, statusSize.width, statusSize.height)];
    NSView *statusShadow = [[NSView alloc] initWithFrame:NSMakeRect(
        6, 6, statusGlassSize.width, statusGlassSize.height)];
    self.statusShadowView = statusShadow;
    statusShadow.wantsLayer = YES;
    statusShadow.layer.cornerRadius = statusGlassSize.height / 2.0;
    statusShadow.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.01].CGColor;
    statusShadow.layer.cornerCurve = kCACornerCurveContinuous;
    statusShadow.layer.shadowColor = NSColor.blackColor.CGColor;
    statusShadow.layer.shadowOpacity = 0.24;
    statusShadow.layer.shadowRadius = 8;
    statusShadow.layer.shadowOffset = NSMakeSize(0, -3);
    CGPathRef statusShadowPath = CGPathCreateWithRoundedRect(
        statusShadow.bounds, statusGlassSize.height / 2.0,
        statusGlassSize.height / 2.0, NULL);
    statusShadow.layer.shadowPath = statusShadowPath;
    CGPathRelease(statusShadowPath);
    [statusRoot addSubview:statusShadow];

    self.statusGlass = [[CCPetsGlassView alloc]
        initWithFrame:NSMakeRect(6, 6, statusGlassSize.width, statusGlassSize.height)
        material:NSVisualEffectMaterialPopover appearance:NSAppearanceNameAqua
        cornerRadius:statusGlassSize.height / 2.0];
    // 胶囊比面板矮，边缘高光占比更大；10pt / 0.6 是对照截图里深色背景下刚好压住的值。
    self.statusGlass.edgeShadeHeight = 10;
    self.statusGlass.edgeShadeAlpha = 0.6;
    self.statusGlass.usesWidgetGlass = YES;

    self.statusTitleLabel = [NSTextField labelWithString:@""];
    // 层级是反的：宠物是主角，事实退成眉标。
    // 标题 11 Medium 浅灰只负责"到底在干什么"这个锚点，副行 14 Medium 深色才是正文。
    self.statusTitleLabel.frame = NSMakeRect(20, 34, statusGlassSize.width - 80, 14);
    self.statusTitleLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.statusTitleLabel.textColor = [NSColor colorWithWhite:0.42 alpha:0.90];
    self.statusTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.statusGlass.contentView addSubview:self.statusTitleLabel];

    self.statusDetailLabel = [NSTextField labelWithString:@""];
    self.statusDetailLabel.frame = NSMakeRect(20, 10, statusGlassSize.width - 80, 22);
    self.statusDetailLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
    self.statusDetailLabel.textColor = [NSColor colorWithWhite:0.12 alpha:0.96];
    self.statusDetailLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.statusGlass.contentView addSubview:self.statusDetailLabel];

    self.statusIconButton = [[CCPetsStatusClickButton alloc] initWithFrame:NSMakeRect(
        statusGlassSize.width - 48, 12, 34, 34)];
    self.statusIconButton.bordered = NO;
    self.statusIconButton.imagePosition = NSImageOnly;
    self.statusIconButton.wantsLayer = YES;
    self.statusIconButton.layer.cornerRadius = 17;
    self.statusIconButton.layer.masksToBounds = YES;
    self.statusIconButton.toolTip = @"查看最近 Agent 会话与 CC Bridge 消息";
    self.statusIconButton.target = self;
    self.statusIconButton.action = @selector(showAgentSessionsMenu:);
    [self.statusGlass.contentView addSubview:self.statusIconButton];
    // 原生玻璃自带阴影，再叠手工阴影会糊成两层。
    self.statusShadowView.hidden = self.statusGlass.usesLiquidGlass;
    [statusRoot addSubview:self.statusGlass];
    [self applyBubbleTextStyle];
    CCPetsStatusClickButton *statusClick = [[CCPetsStatusClickButton alloc]
        initWithFrame:NSMakeRect(6, 6, statusGlassSize.width - 56, statusGlassSize.height)];
    statusClick.bordered = NO;
    statusClick.transparent = YES;
    statusClick.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    statusClick.title = @"";
    statusClick.toolTip = @"返回触发此状态的 Agent 终端";
    statusClick.target = self;
    statusClick.action = @selector(focusLatestAgentTerminal:);
    self.statusClickButton = statusClick;
    [statusRoot addSubview:statusClick];
    // 角标挂在 statusRoot 而不是玻璃内容里：玻璃卡片会按胶囊形状裁切，
    // 右上角正好落在圆角外面，放进去会被裁掉一半。
    CCPetsApprovalBadgeView *badge = [[CCPetsApprovalBadgeView alloc]
        initWithFrame:NSMakeRect(0, 0, PetApprovalBadgeSize, PetApprovalBadgeSize)];
    badge.hidden = YES;
    self.approvalBadgeView = badge;
    [statusRoot addSubview:badge];
    // CC Bridge 消息角标压在图标右下角，与右上角的审批角标错开。点击同样穿透到图标，
    // 打开的会话菜单里列出最近的跨会话消息。
    CCPetsApprovalBadgeView *bridgeBadge = [[CCPetsApprovalBadgeView alloc]
        initWithFrame:NSMakeRect(0, 0, PetApprovalBadgeSize, PetApprovalBadgeSize)];
    bridgeBadge.hidden = YES;
    bridgeBadge.fillColor = [NSColor colorWithRed:0.20 green:0.47 blue:0.90 alpha:1];
    self.bridgeBadgeView = bridgeBadge;
    [statusRoot addSubview:bridgeBadge];
    [self layoutApprovalBadge];
    self.statusPanel.contentView = statusRoot;

    NSSize quotaSize = NSMakeSize(QuotaLogicalWidth * QuotaScale, QuotaLogicalHeight * QuotaScale);
    self.quotaPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, quotaSize.width, quotaSize.height)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    self.quotaPanel.opaque = NO;
    self.quotaPanel.backgroundColor = NSColor.clearColor;
    self.quotaPanel.hasShadow = YES;
    self.quotaPanel.acceptsMouseMovedEvents = YES;
    self.quotaPanel.ignoresMouseEvents = NO;
    self.quotaPanel.level = NSFloatingWindowLevel;
    self.quotaPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.quotaPanel.hidesOnDeactivate = NO;
    NSView *quotaRoot = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, quotaSize.width, quotaSize.height)];
    self.quotaGlass = [[CCPetsGlassView alloc] initWithFrame:quotaRoot.bounds
        material:NSVisualEffectMaterialUnderWindowBackground
        appearance:NSAppearanceNameDarkAqua cornerRadius:13];
    self.quotaGlass.usesWidgetGlass = YES;
    [quotaRoot addSubview:self.quotaGlass];
    self.quotaView = [[QuotaDashboardView alloc] initWithFrame:NSMakeRect(0, 0, quotaSize.width, quotaSize.height)];
    self.quotaView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.quotaView.usesLiquidGlass = self.quotaGlass.usesLiquidGlass;
    self.quotaView.cardScrimAlpha = CCPetsGlassCardScrimAlpha();
    [self applySystemMetricPreferences];
    [self applyUsageDisplayModePreferences];
    self.quotaView.codexLogo = OfficialAppIcon(@"com.openai.codex", @"icon-chatgpt.icns");
    self.quotaView.claudeLogo = OfficialAppIcon(@"com.anthropic.claudefordesktop", @"electron.icns");
    self.quotaView.hoverChanged = ^(BOOL hovering) {
        weakSelf.dashboardHovering = hovering;
        if (!hovering) [weakSelf scheduleQuotaDashboardHide];
    };
    [self.quotaGlass.contentView addSubview:self.quotaView];
    self.quotaPanel.contentView = quotaRoot;
    // 先探测再第一次显示：否则面板会先按两张卡的高度弹出来再收缩一下。
    [self refreshDetectedProviders];

    NSScreen *screen = NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;
    [self.panel setFrameOrigin:NSMakePoint(NSMaxX(visible) - size.width - 24, NSMinY(visible) + 18)];
    [self.panel orderFrontRegardless];
    self.usageMonitor = [CCPetsUsageMonitor new];
    self.systemMonitor = [CCPetsSystemMonitor new];
    self.agentEventPartialLine = [NSMutableData data];
    self.pendingApprovalRecords = [NSMutableDictionary dictionary];
    self.stallNotifiedSessionKeys = [NSMutableSet set];
    self.usageMonitor.changeHandler = ^(NSDictionary *codexUsage, NSDictionary *claudeUsage) {
        [weakSelf applyCodexUsage:codexUsage claudeUsage:claudeUsage];
        [weakSelf considerQuotaSpeech];
    };
    [self.usageMonitor start];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--preview-dashboard"]) {
        self.pocketHovering = YES;
        [self showQuotaDashboard];
    }
    [self rescheduleUsageTimer];
    [self refreshClientLifecycle:nil];
    NSTimer *lifecycleTimer = [NSTimer scheduledTimerWithTimeInterval:ClientLifecycleInterval
        target:self selector:@selector(refreshClientLifecycle:) userInfo:nil repeats:YES];
    lifecycleTimer.tolerance = ClientLifecycleInterval * 0.3;
    [self startAgentEventReader];
    NSTimer *readerTimer = [NSTimer scheduledTimerWithTimeInterval:AgentEventReaderCheckInterval
        target:self selector:@selector(ensureAgentEventReader:) userInfo:nil repeats:YES];
    readerTimer.tolerance = AgentEventReaderCheckInterval * 0.3;
    // 启动前的消息不算"未读"：角标只提示桌宠运行期间新发生的跨会话往来。通知同理。
    self.bridgeSeenAt = NSDate.date.timeIntervalSince1970;
    self.bridgeNotifiedAt = self.bridgeSeenAt;
    [self refreshBridgeState:nil];
    NSTimer *bridgeTimer = [NSTimer scheduledTimerWithTimeInterval:BridgeRefreshInterval
        target:self selector:@selector(refreshBridgeState:) userInfo:nil repeats:YES];
    bridgeTimer.tolerance = BridgeRefreshInterval * 0.3;
    // 这里刻意不使用 occlusionState / NSWindowDidChangeOcclusionStateNotification：
    // 桌宠是置顶的（NSFloatingWindowLevel + FullScreenAuxiliary），全屏应用也压不住它，
    // 所以“被遮挡”几乎不会真实发生，收益接近零；而实测中 occlusionState 会在
    // Space / 全屏过渡期间报出长达十几秒的“不可见”，那会把一只用户正看着的桌宠冻在
    // 某一帧上。显示器睡眠则是无歧义的信号：屏幕灭了，桌宠必定不可见。
    NSNotificationCenter *workspaceCenter = NSWorkspace.sharedWorkspace.notificationCenter;
    [workspaceCenter addObserver:self selector:@selector(screensDidSleep:)
        name:NSWorkspaceScreensDidSleepNotification object:nil];
    [workspaceCenter addObserver:self selector:@selector(screensDidWake:)
        name:NSWorkspaceScreensDidWakeNotification object:nil];
    // 启动先让界面和事件流就位，再联网检查更新，别和启动抢时间。
    [self performSelector:@selector(silentCheckForUpdate) withObject:nil afterDelay:5.0];
}
// CLI 启动时桌宠若已在运行，`open -g` 不会重新启动它，只会发一个 reopen 事件过来。
// 借这个时机同样静默检查一次更新（silentCheckForUpdate 自己做节流）。
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    [self silentCheckForUpdate];
    return NO;
}
- (void)screensDidSleep:(NSNotification *)notification {
    [self.petView setAnimationSuspended:YES];
}
- (void)screensDidWake:(NSNotification *)notification {
    [self.petView setAnimationSuspended:NO];
}
- (void)petWindowDidMove:(NSNotification *)notification {
    if (self.quotaPanel.isVisible) [self positionQuotaDashboard];
    if (self.statusPanel.isVisible) [self positionAgentStatus];
    if (self.speechPanel.isVisible) [self positionSpeechPanel];
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.usageMonitor stop];
    [self.systemMetricsTimer invalidate];
    self.systemMetricsTimer = nil;
    if (self.agentEventSource) {
        dispatch_source_cancel(self.agentEventSource);
        self.agentEventSource = nil;
    }
}
@end
