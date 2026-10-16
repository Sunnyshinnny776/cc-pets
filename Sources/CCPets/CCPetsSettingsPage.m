#import "CCPetsSettingsPage.h"
#import "CCPetsBridge.h"
#import "CCPetsGlassView.h"
#import "CCPetsL10n.h"
#import "CCPetsPaths.h"
#import "CCPetsPetSize.h"
#import "CCPetsPhrases.h"
#import "CCPetsPreferences.h"
#import "CCPetsUIStyle.h"

// 定义在 CCPetsAppDelegate+Speech.m；那边的头文件是 AppDelegate 私有的，这里单独 extern。
extern NSString *const PetSpeechFrequencyKey;

// 控件的 target 只能是对象，用它把 action 转成 block，免得每个控件写一个方法。
@interface CCPetsSettingsHandler : NSObject
@property(nonatomic, copy) void (^block)(id sender);
- (void)invoke:(id)sender;
@end

@implementation CCPetsSettingsHandler
- (void)invoke:(id)sender {
    if (self.block) self.block(sender);
}
@end

// 分组卡片的底色：浅色下比窗口底亮一档，深色下比窗口底浅一档，和系统设置一致。
static NSColor *SettingsCardColor(void) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        BOOL dark = [[appearance bestMatchFromAppearancesWithNames:
            @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
        return dark ? [NSColor colorWithWhite:1 alpha:0.05] : [NSColor colorWithWhite:1 alpha:0.75];
    }];
}

static NSString *ClickCountText(NSInteger count) {
    return [[NSString stringWithFormat:@"%ld", (long)count] stringByAppendingString:L(@" clicks")];
}

@interface CCPetsSettingsPage ()
@property(nonatomic) NSStackView *stack;
@property(nonatomic) NSMutableArray<CCPetsSettingsHandler *> *handlers;
// 每个控件一个"按 defaults 回填自己"的 block。设置一变就全部跑一遍。
@property(nonatomic) NSMutableArray<void (^)(void)> *reloaders;
@end

@implementation CCPetsSettingsPage

- (id<CCPetsSettingsActions>)actions {
    id delegate = NSApp.delegate;
    return [delegate respondsToSelector:@selector(updatePetScale:)] ? delegate : nil;
}

- (void)loadView {
    self.handlers = [NSMutableArray array];
    self.reloaders = [NSMutableArray array];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 560, 560)];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;
    // 文档视图翻转坐标，内容从顶部往下排。
    NSView *document = [[NSView alloc] initWithFrame:NSZeroRect];
    document.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = document;
    NSClipView *clip = scroll.contentView;

    NSStackView *stack = [NSStackView stackViewWithViews:@[]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [document addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [document.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
        [document.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor],
        [document.topAnchor constraintEqualToAnchor:clip.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:28],
        [stack.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-28],
        [stack.topAnchor constraintEqualToAnchor:document.topAnchor constant:20],
        [stack.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-28],
    ]];
    self.stack = stack;
    self.view = scroll;

    [self buildSections];
    [self reloadValues];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(preferencesDidChange:)
        name:CCPetsPreferencesDidChangeNotification object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)preferencesDidChange:(NSNotification *)notification {
    [self reloadValues];
}

- (void)reloadValues {
    for (void (^reload)(void) in self.reloaders) reload();
}

#pragma mark - 控件与布局

- (void)bind:(NSControl *)control to:(void (^)(id sender))block {
    CCPetsSettingsHandler *handler = [CCPetsSettingsHandler new];
    handler.block = block;
    [self.handlers addObject:handler];
    control.target = handler;
    control.action = @selector(invoke:);
}

- (NSView *)rowWithTitle:(NSString *)title controls:(NSArray<NSView *> *)controls {
    NSTextField *label = [NSTextField labelWithString:title];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
        forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *row = [NSStackView stackViewWithViews:[@[label, spacer] arrayByAddingObjectsFromArray:controls]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 8;
    row.edgeInsets = NSEdgeInsetsMake(8, 14, 8, 14);
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:40].active = YES;
    return row;
}

- (NSSwitch *)switchWithValue:(BOOL (^)(void))value action:(void (^)(NSSwitch *control))action {
    NSSwitch *control = [NSSwitch new];
    control.controlSize = NSControlSizeSmall;
    [self bind:control to:^(NSSwitch *sender) { action(sender); }];
    [self.reloaders addObject:^{
        control.state = value() ? NSControlStateValueOn : NSControlStateValueOff;
    }];
    return control;
}

// 普通布尔设置：读写同一个键，写完交给 AppDelegate 生效。
- (NSView *)switchRowWithTitle:(NSString *)title key:(NSString *)key
    apply:(void (^)(id<CCPetsSettingsActions> actions, BOOL enabled))apply {
    __weak typeof(self) weakSelf = self;
    NSSwitch *control = [self switchWithValue:^BOOL { return CCPetsPrefBool(key); }
        action:^(NSSwitch *sender) {
        apply(weakSelf.actions, sender.state == NSControlStateValueOn);
    }];
    return [self rowWithTitle:title controls:@[control]];
}

- (NSPopUpButton *)popUpWithOptions:(NSArray<NSArray *> *)options selected:(id (^)(void))selected
    action:(void (^)(id value))action {
    NSPopUpButton *popUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSArray *option in options) {
        [popUp addItemWithTitle:option[0]];
        popUp.lastItem.representedObject = option[1];
    }
    [self bind:popUp to:^(NSPopUpButton *sender) { action(sender.selectedItem.representedObject); }];
    [self.reloaders addObject:^{
        id value = selected();
        for (NSMenuItem *item in popUp.itemArray) {
            if (![item.representedObject isEqual:value]) continue;
            [popUp selectItem:item];
            break;
        }
    }];
    return popUp;
}

// 步进器 + 数值标签。菜单里只有三档，这里可以连续调。
- (NSView *)stepperRowWithTitle:(NSString *)title key:(NSString *)key minimum:(double)minimum
    maximum:(double)maximum increment:(double)increment fallback:(double)fallback
    format:(NSString *(^)(double value))format {
    NSStepper *stepper = [NSStepper new];
    stepper.minValue = minimum;
    stepper.maxValue = maximum;
    stepper.increment = increment;
    stepper.valueWraps = NO;
    NSTextField *valueLabel = [NSTextField labelWithString:@""];
    valueLabel.alignment = NSTextAlignmentRight;
    valueLabel.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular];
    __weak typeof(self) weakSelf = self;
    [self bind:stepper to:^(NSStepper *sender) {
        // 步进 0.1 的浮点累加会出现 1.2000000002，按步长取整再交出去。
        double value = round(sender.doubleValue / increment) * increment;
        [weakSelf.actions updatePetInteractionValue:@(value) forKey:key];
    }];
    [self.reloaders addObject:^{
        id stored = [NSUserDefaults.standardUserDefaults objectForKey:key];
        double value = [stored isKindOfClass:NSNumber.class] ? [stored doubleValue] : fallback;
        // 生气阈值的下限跟着比心阈值走，和 CCPetsPrefNormalizedValue 的钳制一致。
        if ([key isEqualToString:PetInteractionAnnoyedThresholdKey]) {
            stepper.minValue = MAX((NSInteger)2, [NSUserDefaults.standardUserDefaults
                integerForKey:PetInteractionHeartThresholdKey]) + 1;
        }
        stepper.doubleValue = value;
        valueLabel.stringValue = format(value);
    }];
    return [self rowWithTitle:title controls:@[valueLabel, stepper]];
}

- (NSView *)buttonRowWithTitle:(NSString *)title buttonTitle:(NSString *)buttonTitle
    action:(void (^)(void))action {
    NSButton *button = [NSButton buttonWithTitle:buttonTitle target:nil action:nil];
    button.controlSize = NSControlSizeSmall;
    [self bind:button to:^(id sender) { action(); }];
    return [self rowWithTitle:title controls:@[button]];
}

// 分组标题前的彩色图标块和侧边栏同一套（CCPetsSymbolTile），一眼能分出是哪一组。
- (void)addSectionWithTitle:(NSString *)title symbol:(NSString *)symbol color:(NSColor *)color
    rows:(NSArray<NSView *> *)rows footer:(NSString *)footer {
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:NSFont.systemFontSize + 1 weight:NSFontWeightSemibold];
    NSImageView *icon = [NSImageView imageViewWithImage:CCPetsSymbolTile(symbol, color, 22)];
    [icon.widthAnchor constraintEqualToConstant:22].active = YES;
    [icon.heightAnchor constraintEqualToConstant:22].active = YES;
    NSStackView *header = [NSStackView stackViewWithViews:@[icon, label]];
    header.spacing = 8;
    header.alignment = NSLayoutAttributeCenterY;
    if (self.stack.arrangedSubviews.count > 0) {
        [self.stack setCustomSpacing:24 afterView:self.stack.arrangedSubviews.lastObject];
    }
    [self.stack addArrangedSubview:header];
    [self.stack setCustomSpacing:10 afterView:header];

    NSStackView *content = [NSStackView stackViewWithViews:@[]];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.spacing = 0;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *row in rows) {
        if (content.arrangedSubviews.count > 0) {
            NSBox *separator = [NSBox new];
            separator.boxType = NSBoxSeparator;
            [content addArrangedSubview:separator];
            [separator.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14].active = YES;
            [separator.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14].active = YES;
        }
        [content addArrangedSubview:row];
        [row.leadingAnchor constraintEqualToAnchor:content.leadingAnchor].active = YES;
        [row.trailingAnchor constraintEqualToAnchor:content.trailingAnchor].active = YES;
    }

    NSBox *card = [NSBox new];
    card.boxType = NSBoxCustom;
    card.titlePosition = NSNoTitle;
    card.cornerRadius = 8;
    card.borderWidth = 1;
    card.borderColor = NSColor.separatorColor;
    card.fillColor = SettingsCardColor();
    card.contentViewMargins = NSZeroSize;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [card.contentView addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
    ]];
    [self.stack addArrangedSubview:card];
    [card.leadingAnchor constraintEqualToAnchor:self.stack.leadingAnchor].active = YES;
    [card.trailingAnchor constraintEqualToAnchor:self.stack.trailingAnchor].active = YES;

    if (footer.length == 0) return;
    NSTextField *note = [NSTextField wrappingLabelWithString:footer];
    note.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    note.textColor = NSColor.secondaryLabelColor;
    note.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack addArrangedSubview:note];
    [note.leadingAnchor constraintEqualToAnchor:self.stack.leadingAnchor constant:4].active = YES;
    [note.trailingAnchor constraintEqualToAnchor:self.stack.trailingAnchor constant:-4].active = YES;
}

static void RevealFolder(NSString *path) {
    // 第一次用时文件夹可能还不存在；建出来比让按钮点了没反应好。
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES
        attributes:nil error:nil];
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:path isDirectory:YES]];
}

#pragma mark - 各分组

- (void)buildSections {
    __weak typeof(self) weakSelf = self;

    // 通用
    NSMutableArray<NSArray *> *languages = [NSMutableArray arrayWithObject:
        @[L(@"System Default"), CCPetsLanguageSystem]];
    for (NSString *language in CCPetsSupportedLanguages()) {
        [languages addObject:@[CCPetsLanguageDisplayName(language), language]];
    }
    NSPopUpButton *language = [self popUpWithOptions:languages
        selected:^id { return CCPetsLanguagePreference(); }
        action:^(NSString *value) {
        if ([value isEqualToString:CCPetsLanguagePreference()]) return;
        // 主窗口收到语言变更会重建本页，别在控件自己的 action 里把它拆掉。
        dispatch_async(dispatch_get_main_queue(), ^{ CCPetsSetLanguagePreference(value); });
    }];

    NSSlider *scale = [NSSlider sliderWithValue:1 minValue:CCPetsPetMinimumScale
        maxValue:CCPetsPetMaximumScale target:nil action:nil];
    scale.continuous = YES;
    scale.controlSize = NSControlSizeSmall;
    [scale.widthAnchor constraintEqualToConstant:160].active = YES;
    NSTextField *scaleLabel = [NSTextField labelWithString:@""];
    scaleLabel.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular];
    scaleLabel.alignment = NSTextAlignmentRight;
    [scaleLabel.widthAnchor constraintEqualToConstant:44].active = YES;
    [self bind:scale to:^(NSSlider *sender) { [weakSelf.actions updatePetScale:sender.doubleValue]; }];
    [self.reloaders addObject:^{
        CGFloat value = CCPetsPetScalePreference();
        scale.doubleValue = value;
        scaleLabel.stringValue = [NSString stringWithFormat:@"%ld%%", (long)lround(value * 100)];
    }];

    [self addSectionWithTitle:L(@"General")
        symbol:@"gearshape.fill" color:NSColor.systemGrayColor rows:@[
        [self rowWithTitle:L(@"Language") controls:@[language]],
        [self rowWithTitle:L(@"Pet Size") controls:@[scale, scaleLabel]],
        [self switchRowWithTitle:L(@"Show Status Card") key:StatusBubbleExpandedKey
            apply:^(id<CCPetsSettingsActions> actions, BOOL enabled) {
            [actions updateStatusBubbleExpanded:enabled];
        }],
    ] footer:nil];

    // 外观
    NSSegmentedControl *theme = [NSSegmentedControl segmentedControlWithLabels:
        @[L(@"Classic"), @"Liquid Glass"] trackingMode:NSSegmentSwitchTrackingSelectOne
        target:nil action:nil];
    if (!CCPetsLiquidGlassAvailable()) {
        [theme setEnabled:NO forSegment:1];
        theme.toolTip = L(@"Requires macOS 26 or later");
    }
    [self bind:theme to:^(NSSegmentedControl *sender) {
        [weakSelf.actions updatePanelTheme:sender.selectedSegment == 1 ? @"liquid" : @"classic"];
    }];
    NSDictionary<NSNumber *, NSString *> *dimTitles = @{
        @0: L(@"Clear (0%)"), @15: L(@"Light (15%)"), @25: L(@"Standard (25%)"), @45: L(@"Legible (45%)")};
    NSMutableArray<NSArray *> *dimOptions = [NSMutableArray array];
    for (NSNumber *level in CCPetsGlassDimLevels()) [dimOptions addObject:@[dimTitles[level] ?: level.stringValue, level]];
    NSPopUpButton *dim = [self popUpWithOptions:dimOptions
        selected:^id { return @(CCPetsGlassDimLevel()); }
        action:^(NSNumber *value) { [weakSelf.actions updateGlassDimLevel:value]; }];
    [self.reloaders addObject:^{
        BOOL liquid = [CCPetsPanelTheme() isEqualToString:@"liquid"] && CCPetsLiquidGlassAvailable();
        theme.selectedSegment = liquid ? 1 : 0;
        // 压暗只作用于原生玻璃，经典主题下没有这层。
        dim.enabled = liquid;
    }];
    [self addSectionWithTitle:L(@"Appearance")
        symbol:@"paintbrush.fill" color:NSColor.systemPurpleColor rows:@[
        [self rowWithTitle:L(@"Panel Theme") controls:@[theme]],
        [self rowWithTitle:L(@"Glass Dimming") controls:@[dim]],
    ] footer:nil];

    // 用量展示：订阅额度还是 API 用量。
    NSMutableArray<NSView *> *usageRows = [NSMutableArray array];
    for (NSArray<NSString *> *provider in @[@[@"Codex", CodexUsageDisplayModeKey],
                                           @[@"Claude", ClaudeUsageDisplayModeKey]]) {
        NSString *key = provider[1];
        NSSegmentedControl *mode = [NSSegmentedControl segmentedControlWithLabels:@[L(@"Plan"), L(@"API")]
            trackingMode:NSSegmentSwitchTrackingSelectOne target:nil action:nil];
        [mode setAccessibilityLabel:[NSString stringWithFormat:L(@"%@ usage display"), provider[0]]];
        [self bind:mode to:^(NSSegmentedControl *sender) {
            [weakSelf.actions updateUsageDisplayMode:sender.selectedSegment == 1 ? @"api" : @"subscription"
                forKey:key];
        }];
        [self.reloaders addObject:^{
            mode.selectedSegment = [[NSUserDefaults.standardUserDefaults stringForKey:key]
                isEqualToString:@"api"] ? 1 : 0;
        }];
        [usageRows addObject:[self rowWithTitle:provider[0] controls:@[mode]]];
    }
    [self addSectionWithTitle:L(@"Usage Display")
        symbol:@"chart.bar.fill" color:NSColor.systemBlueColor rows:usageRows footer:nil];

    // 系统通知：打开时要先拿到系统授权，失败就弹回关闭。
    NSMutableArray<NSView *> *notificationRows = [NSMutableArray array];
    for (NSArray<NSString *> *option in @[@[L(@"Task done"), NotificationCompletionKey],
                                         @[L(@"Task failed"), NotificationFailureKey],
                                         @[L(@"Awaiting approval"), NotificationApprovalKey],
                                         @[L(@"Stalled"), NotificationStallKey]]) {
        NSString *key = option[1];
        NSSwitch *control = [self switchWithValue:^BOOL { return CCPetsPrefBool(key); }
            action:^(NSSwitch *sender) {
            [weakSelf.actions updateNotification:key enabled:sender.state == NSControlStateValueOn
                completion:^(BOOL enabled) {
                sender.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
            }];
        }];
        [notificationRows addObject:[self rowWithTitle:option[0] controls:@[control]]];
    }
    [self addSectionWithTitle:L(@"Notifications")
        symbol:@"bell.badge.fill" color:NSColor.systemRedColor rows:notificationRows footer:nil];

    // 碎碎念
    NSPopUpButton *frequency = [self popUpWithOptions:@[
        @[L(@"Rarely"), @"low"], @[L(@"Normal"), @"normal"], @[L(@"Often"), @"high"], @[L(@"Chatty"), @"chatty"]]
        selected:^id { return [NSUserDefaults.standardUserDefaults stringForKey:PetSpeechFrequencyKey] ?: @"normal"; }
        action:^(NSString *value) { [weakSelf.actions updateSpeechFrequency:value]; }];
    NSPopUpButton *source = [self popUpWithOptions:@[
        @[L(@"Pet-specific Lines"), PetPhrasesSourcePet], @[L(@"Default Lines"), PetPhrasesSourceDefault]]
        selected:^id { return PetPhrasesSource(); }
        action:^(NSString *value) { [weakSelf.actions updatePhrasesSource:value]; }];
    NSButton *editLines = [NSButton buttonWithTitle:L(@"Edit Lines…") target:nil action:nil];
    editLines.controlSize = NSControlSizeSmall;
    [self bind:editLines to:^(id sender) { [weakSelf.actions editPhrasesFile:sender]; }];
    [self addSectionWithTitle:L(@"Chatter")
        symbol:@"bubble.left.fill" color:NSColor.systemGreenColor rows:@[
        [self switchRowWithTitle:L(@"Enable chatter") key:PetSpeechEnabledKey
            apply:^(id<CCPetsSettingsActions> actions, BOOL enabled) { [actions updateSpeechEnabled:enabled]; }],
        [self rowWithTitle:L(@"Frequency") controls:@[frequency]],
        [self rowWithTitle:L(@"Line Source") controls:@[source, editLines]],
    ] footer:nil];

    // 点击互动
    [self addSectionWithTitle:L(@"Click Reactions")
        symbol:@"hand.tap.fill" color:NSColor.systemPinkColor rows:@[
        [self switchRowWithTitle:L(@"Enable reactions") key:PetInteractionEnabledKey
            apply:^(id<CCPetsSettingsActions> actions, BOOL enabled) {
            [actions updatePetInteractionEnabled:enabled];
        }],
        [self stepperRowWithTitle:L(@"Hearts After") key:PetInteractionHeartThresholdKey
            minimum:2 maximum:20 increment:1 fallback:3
            format:^NSString *(double value) { return ClickCountText((NSInteger)value); }],
        [self stepperRowWithTitle:L(@"Annoyed After") key:PetInteractionAnnoyedThresholdKey
            minimum:3 maximum:50 increment:1 fallback:10
            format:^NSString *(double value) { return ClickCountText((NSInteger)value); }],
        [self stepperRowWithTitle:L(@"Click Window") key:PetInteractionIntervalKey
            minimum:0.4 maximum:3.0 increment:0.1 fallback:1.2
            format:^NSString *(double value) {
            return [[NSString stringWithFormat:@"%.1f", value] stringByAppendingString:L(@" s")];
        }],
    ] footer:nil];

    // 额度面板底部的系统指标
    NSMutableArray<NSView *> *systemRows = [NSMutableArray array];
    for (NSArray<NSString *> *option in @[@[L(@"CPU usage"), SystemCPUEnabledKey],
                                         @[L(@"CPU temp"), SystemTemperatureEnabledKey],
                                         @[L(@"Memory"), SystemMemoryEnabledKey]]) {
        NSString *key = option[1];
        [systemRows addObject:[self switchRowWithTitle:option[0] key:key
            apply:^(id<CCPetsSettingsActions> actions, BOOL enabled) {
            [actions updateSystemMetric:key enabled:enabled];
        }]];
    }
    [self addSectionWithTitle:L(@"System Status")
        symbol:@"cpu" color:NSColor.systemOrangeColor rows:systemRows footer:nil];

    // 素材
    [self addSectionWithTitle:L(@"Pet Sprites")
        symbol:@"pawprint.fill" color:NSColor.systemTealColor rows:@[
        [self switchRowWithTitle:L(@"Import Codex Pets") key:ImportCodexPetsKey
            apply:^(id<CCPetsSettingsActions> actions, BOOL enabled) { [actions updateImportCodexPets:enabled]; }],
        [self buttonRowWithTitle:L(@"Pet sprites folder") buttonTitle:L(@"Show in Finder")
            action:^{ RevealFolder(OwnPetsDirectory()); }],
    ] footer:nil];

    // CC Bridge：只放只影响桌宠的两项；启用和免审批会改 Claude Code / Codex 的配置，仍在右键菜单里。
    NSSwitch *bridgeNotify = [self switchWithValue:^BOOL { return CCPetsPrefBool(BridgeNotificationKey); }
        action:^(NSSwitch *sender) {
        [weakSelf.actions updateNotification:BridgeNotificationKey enabled:sender.state == NSControlStateValueOn
            completion:^(BOOL enabled) {
            sender.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
        }];
    }];
    [self addSectionWithTitle:@"CC Bridge"
        symbol:@"point.3.connected.trianglepath.dotted" color:NSColor.systemIndigoColor rows:@[
        [self switchRowWithTitle:L(@"Badge") key:BridgeBadgeEnabledKey
            apply:^(id<CCPetsSettingsActions> actions, BOOL enabled) { [actions updateBridgeBadgeEnabled:enabled]; }],
        [self rowWithTitle:L(@"Notify") controls:@[bridgeNotify]],
    ] footer:L(@"Enabling CC Bridge, auto-approve and other options that change Claude Code / Codex settings stay in the pet's right-click menu.")];

    // 高级
    [self addSectionWithTitle:L(@"Advanced")
        symbol:@"wrench.and.screwdriver.fill" color:NSColor.systemGrayColor rows:@[
        [self buttonRowWithTitle:L(@"App data folder") buttonTitle:L(@"Show in Finder")
            action:^{ RevealFolder(ApplicationSupportDirectory()); }],
    ] footer:nil];
}

@end
