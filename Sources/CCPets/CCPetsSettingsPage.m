#import "CCPetsSettingsPage.h"
#import "CCPetsBridge.h"
#import "CCPetsCLISupport.h"
#import "CCPetsDiagnosticsPage.h"
#import "CCPetsFormBuilder.h"
#import "CCPetsGlassView.h"
#import "CCPetsImageLoader.h"
#import "CCPetsL10n.h"
#import "CCPetsPaths.h"
#import "CCPetsPetSize.h"
#import "CCPetsPhrases.h"
#import "CCPetsPreferences.h"
#import "CCPetsProfiles.h"
#import "CCPetsUsageMode.h"
#import "CCPetsUIStyle.h"
#import <QuartzCore/QuartzCore.h>

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

static NSString *ClickCountText(NSInteger count) {
    return [[NSString stringWithFormat:@"%ld", (long)count] stringByAppendingString:L(@" clicks")];
}

static void RevealFolder(NSString *path) {
    // 第一次用时文件夹可能还不存在；建出来比让按钮点了没反应好。
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES
        attributes:nil error:nil];
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:path isDirectory:YES]];
}

// 三个设置页共用：控件绑定、按 defaults 回填、监听设置变更。
@interface CCPetsSettingsPageBase ()
@property(nonatomic) CCPetsFormBuilder *form;
@property(nonatomic) NSMutableArray<CCPetsSettingsHandler *> *handlers;
// 每个控件一个"按 defaults 回填自己"的 block。设置一变就全部跑一遍。
@property(nonatomic) NSMutableArray<void (^)(void)> *reloaders;
@end

@implementation CCPetsSettingsPageBase

- (id<CCPetsSettingsActions>)actions {
    id delegate = NSApp.delegate;
    return [delegate respondsToSelector:@selector(updatePetScale:)] ? delegate : nil;
}

- (NSString *)pageTitle {
    return @"";
}

- (NSString *)pageSubtitle {
    return @"";
}

- (void)buildContent {
}

- (void)loadView {
    self.handlers = [NSMutableArray array];
    self.reloaders = [NSMutableArray array];
    self.form = [[CCPetsFormBuilder alloc] initWithTitle:[self pageTitle] subtitle:[self pageSubtitle]];
    self.view = self.form.view;
    [self buildContent];
    [self reloadValues];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(preferencesDidChange:)
        name:CCPetsPreferencesDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(preferencesDidChange:)
        name:CCPetsAuthenticationModesDidChangeNotification object:nil];
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

- (void)bind:(NSControl *)control to:(void (^)(id sender))block {
    CCPetsSettingsHandler *handler = [CCPetsSettingsHandler new];
    handler.block = block;
    [self.handlers addObject:handler];
    control.target = handler;
    control.action = @selector(invoke:);
}

- (CCPetsSwitch *)switchWithValue:(BOOL (^)(void))value action:(void (^)(CCPetsSwitch *control))action {
    CCPetsSwitch *control = [CCPetsSwitch new];
    [self bind:control to:^(CCPetsSwitch *sender) { action(sender); }];
    [self.reloaders addObject:^{
        control.state = value() ? NSControlStateValueOn : NSControlStateValueOff;
    }];
    return control;
}

// 普通布尔设置：读写同一个键，写完交给 AppDelegate 生效。
- (NSView *)switchRowWithTitle:(NSString *)title subtitle:(NSString *)subtitle key:(NSString *)key
    apply:(void (^)(id<CCPetsSettingsActions> actions, BOOL enabled))apply {
    __weak typeof(self) weakSelf = self;
    CCPetsSwitch *control = [self switchWithValue:^BOOL { return CCPetsPrefBool(key); }
        action:^(CCPetsSwitch *sender) {
        apply(weakSelf.actions, sender.state == NSControlStateValueOn);
    }];
    return [CCPetsFormBuilder rowWithTitle:title subtitle:subtitle controls:@[control]];
}

// 系统通知要先拿到授权，失败就弹回关闭，所以不能直接用 switchRow。
- (NSView *)notificationRowWithTitle:(NSString *)title subtitle:(NSString *)subtitle key:(NSString *)key {
    __weak typeof(self) weakSelf = self;
    CCPetsSwitch *control = [self switchWithValue:^BOOL { return CCPetsPrefBool(key); }
        action:^(CCPetsSwitch *sender) {
        [weakSelf.actions updateNotification:key enabled:sender.state == NSControlStateValueOn
            completion:^(BOOL enabled) {
            sender.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
        }];
    }];
    return [CCPetsFormBuilder rowWithTitle:title subtitle:subtitle controls:@[control]];
}

- (NSPopUpButton *)popUpWithOptions:(NSArray<NSArray *> *)options selected:(id (^)(void))selected
    action:(void (^)(id value))action {
    NSPopUpButton *popUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    popUp.controlSize = NSControlSizeSmall;
    popUp.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
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

// 档位少（四个以内）的单选用分段控件，一眼看到全部选项；多了再用弹出菜单。
- (NSSegmentedControl *)segmentedWithOptions:(NSArray<NSArray *> *)options selected:(id (^)(void))selected
    action:(void (^)(id value))action {
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    for (NSArray *option in options) [labels addObject:option[0]];
    NSSegmentedControl *control = [NSSegmentedControl segmentedControlWithLabels:labels
        trackingMode:NSSegmentSwitchTrackingSelectOne target:nil action:nil];
    control.controlSize = NSControlSizeSmall;
    control.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    CCPetsApplyAccent(control);
    [self bind:control to:^(NSSegmentedControl *sender) {
        if (sender.selectedSegment >= 0) action(options[(NSUInteger)sender.selectedSegment][1]);
    }];
    [self.reloaders addObject:^{
        id value = selected();
        for (NSUInteger index = 0; index < options.count; index++) {
            if ([options[index][1] isEqual:value]) control.selectedSegment = (NSInteger)index;
        }
    }];
    return control;
}

// 步进器 + 数值标签。菜单里只有三档，这里可以连续调。
- (NSView *)stepperRowWithTitle:(NSString *)title key:(NSString *)key minimum:(double)minimum
    maximum:(double)maximum increment:(double)increment fallback:(double)fallback
    format:(NSString *(^)(double value))format {
    NSStepper *stepper = [NSStepper new];
    stepper.controlSize = NSControlSizeSmall;
    stepper.minValue = minimum;
    stepper.maxValue = maximum;
    stepper.increment = increment;
    stepper.valueWraps = NO;
    NSTextField *valueLabel = CCPetsNumberLabel(@"", 12, NSFontWeightRegular, CCPetsInkColor());
    valueLabel.alignment = NSTextAlignmentRight;
    [valueLabel.widthAnchor constraintGreaterThanOrEqualToConstant:52].active = YES;
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
    return [CCPetsFormBuilder rowWithTitle:title controls:@[valueLabel, stepper]];
}

- (NSButton *)smallButtonWithTitle:(NSString *)title action:(void (^)(void))action {
    NSButton *button = [NSButton buttonWithTitle:title target:nil action:nil];
    button.controlSize = NSControlSizeSmall;
    button.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    [self bind:button to:^(id sender) { action(); }];
    return button;
}

- (NSSlider *)sliderWithMinimum:(double)minimum maximum:(double)maximum width:(CGFloat)width {
    NSSlider *slider = [NSSlider sliderWithValue:minimum minValue:minimum maxValue:maximum target:nil action:nil];
    slider.continuous = YES;
    slider.controlSize = NSControlSizeSmall;
    CCPetsApplyAccent(slider);
    [slider.widthAnchor constraintEqualToConstant:width].active = YES;
    return slider;
}

- (NSTextField *)sliderValueLabel {
    NSTextField *label = CCPetsNumberLabel(@"", 12, NSFontWeightRegular, CCPetsSecondaryInkColor());
    label.alignment = NSTextAlignmentRight;
    [label.widthAnchor constraintEqualToConstant:40].active = YES;
    return label;
}

@end

#pragma mark - 多账号

@interface CCPetsAccountsPage ()
// 上次建页时的账号与集成状态；没变就不重建，免得切页、回到前台时整页闪一下。
@property(nonatomic, copy) NSArray<NSDictionary *> *entries;
// 控件回调（弹出菜单、确认框、选文件面板）期间主队列照样会跑，这时重建会释放正在执行的
// 闭包和弹出菜单所依附的按钮，只记下来，等回调返回后再建。
@property(nonatomic) NSInteger interactionDepth;
@property(nonatomic) BOOL needsRebuild;
@end

@implementation CCPetsAccountsPage

- (NSString *)pageTitle {
    return L(@"Multi-Account");
}

- (NSString *)pageSubtitle {
    return L(@"Add and manage Claude and Codex Homes.");
}

- (void)loadView {
    [super loadView];
    // 集成状态还取决于 CC Bridge 开关和各 Home 的配置文件：诊断修复、命令行改动之后回到 App 时也要重读。
    for (NSNotificationName name in @[CCPetsProfilesDidChangeNotification, CCPetsDiagnosticsDidChangeNotification,
        NSApplicationDidBecomeActiveNotification]) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(profilesDidChange:)
            name:name object:nil];
    }
}

- (void)viewWillAppear {
    [super viewWillAppear];
    [self profilesDidChange:nil];
}

- (void)profilesDidChange:(NSNotification *)notification {
    if (notification && !self.view.window) return;
    if (self.interactionDepth > 0) {
        self.needsRebuild = YES;
        return;
    }
    if ([self.entries isEqualToArray:[self currentEntries]]) return;
    [self.handlers removeAllObjects];
    [self.reloaders removeAllObjects];
    [self.form removeAllContent];
    [self buildContent];
}

- (NSArray<NSDictionary *> *)currentEntries {
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSDictionary *profile in CCPetsProfiles()) {
        [entries addObject:@{@"profile": profile, @"state": CCPetsProfileStatus(profile)[@"state"] ?: @""}];
    }
    return entries.copy;
}

- (void)bind:(NSControl *)control to:(void (^)(id sender))block {
    __weak typeof(self) weakSelf = self;
    [super bind:control to:^(id sender) {
        typeof(self) strongSelf = weakSelf;
        strongSelf.interactionDepth++;
        block(sender);
        strongSelf.interactionDepth--;
        if (strongSelf.interactionDepth > 0 || !strongSelf.needsRebuild) return;
        strongSelf.needsRebuild = NO;
        // 下一轮再建：现在还在这个控件的闭包里。
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf profilesDidChange:nil]; });
    }];
}

- (NSButton *)manageButtonForProfile:(NSDictionary *)profile {
    __weak typeof(self) weakSelf = self;
    NSButton *button = [NSButton buttonWithTitle:L(@"Manage…") target:nil action:nil];
    button.controlSize = NSControlSizeSmall;
    button.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    [self bind:button to:^(NSButton *sender) {
        NSMenu *menu = [NSMenu new];
        NSMutableArray<NSArray *> *actions = [@[
            @[L(@"Repair Integration"), NSStringFromSelector(@selector(repairAgentProfile:))],
            @[L(@"Rename…"), NSStringFromSelector(@selector(renameAgentProfile:))]
        ] mutableCopy];
        if (!CCPetsProfileIsOfficialDefault(profile)) {
            [actions addObject:@[L(@"Relocate Home…"), NSStringFromSelector(@selector(relocateAgentProfile:))]];
            [actions addObject:@[L(@"Remove Integration…"), NSStringFromSelector(@selector(removeAgentProfile:))]];
        }
        for (NSArray *action in actions) {
            NSMenuItem *item = [menu addItemWithTitle:action[0]
                action:NSSelectorFromString(action[1]) keyEquivalent:@""];
            item.target = weakSelf.actions;
            item.representedObject = profile[@"id"];
        }
        [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSMaxY(sender.bounds)) inView:sender];
    }];
    return button;
}

- (void)buildContent {
    __weak typeof(self) weakSelf = self;
    [self.form setAccessoryViews:@[
        [self smallButtonWithTitle:L(@"Add Claude Home…") action:^{ [weakSelf.actions addClaudeProfile:nil]; }],
        [self smallButtonWithTitle:L(@"Add Codex Home…") action:^{ [weakSelf.actions addCodexProfile:nil]; }]
    ]];
    self.entries = [self currentEntries];
    if (self.entries.count == 0) {
        [self.form addGroupWithTitle:nil rows:@[
            [CCPetsFormBuilder rowWithTitle:L(@"No Agent accounts detected")
                subtitle:L(@"Use the buttons above to add an existing Claude or Codex Home.") controls:@[]]
        ] footer:nil];
        return;
    }
    for (NSString *provider in @[CCPetsProfileProviderClaude, CCPetsProfileProviderCodex]) {
        NSMutableArray<NSView *> *rows = [NSMutableArray array];
        for (NSDictionary *entry in self.entries) {
            NSDictionary *profile = entry[@"profile"];
            if (![profile[@"provider"] isEqualToString:provider]) continue;
            NSString *state = entry[@"state"];
            NSColor *color = [state isEqualToString:CCPetsProfileStateIntegrated]
                ? CCPetsSecondaryInkColor() : NSColor.systemOrangeColor;
            NSTextField *label = CCPetsLabel(CCPetsProfileStateTitle(state), 11, NSFontWeightRegular, color);
            NSView *row = [CCPetsFormBuilder rowWithTitle:profile[@"displayName"] ?: profile[@"slug"]
                subtitle:CCPetsTildePath(profile[@"home"])
                controls:@[label, [self manageButtonForProfile:profile]]];
            row.toolTip = profile[@"home"];
            [rows addObject:row];
        }
        if (rows.count > 0) [self.form addGroupWithTitle:
            [provider isEqualToString:CCPetsProfileProviderClaude] ? @"Claude" : @"Codex" rows:rows footer:nil];
    }
}

@end

#pragma mark - 宠物

@interface CCPetsPetPage ()
@property(nonatomic) NSStackView *pickerRows;
@property(nonatomic) NSMutableDictionary<NSString *, CCPetsTileView *> *petTiles;
@property(nonatomic) NSMutableDictionary<NSString *, CCPetsSpriteView *> *petSprites;
@property(nonatomic) NSMutableDictionary<NSString *, NSImage *> *sheetCache;
@property(nonatomic) NSTextField *sampleLine;
@end

// 选择列表一行几只。窗口最窄时（内容区约 520pt）每张卡也有 110pt 以上，名字放得下。
static const NSUInteger PetPickerColumns = 4;

@implementation CCPetsPetPage

- (NSString *)pageTitle {
    return L(@"Pet");
}

- (NSString *)pageSubtitle {
    return L(@"Pick the pet that lives on your desktop, its size, how chatty it is and how it reacts when poked.");
}

- (void)loadView {
    self.petTiles = [NSMutableDictionary dictionary];
    self.petSprites = [NSMutableDictionary dictionary];
    self.sheetCache = [NSMutableDictionary dictionary];
    [super loadView];
    // 切宠物不走 defaults 写入口（选中项记在桌宠自己身上），靠名片通知得知换了。
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(petDidChange:)
        name:CCPetsPetCardDidChangeNotification object:nil];
}

- (void)petDidChange:(NSNotification *)notification {
    [self updatePetSelection];
}

- (void)buildContent {
    __weak typeof(self) weakSelf = self;

    NSStackView *rows = [NSStackView stackViewWithViews:@[]];
    rows.orientation = NSUserInterfaceLayoutOrientationVertical;
    rows.alignment = NSLayoutAttributeLeading;
    rows.spacing = 10;
    self.pickerRows = rows;
    [self.form addView:rows];
    [self rebuildPicker];

    // 大小
    NSSlider *scale = [self sliderWithMinimum:CCPetsPetMinimumScale maximum:CCPetsPetMaximumScale width:200];
    NSTextField *scaleLabel = [self sliderValueLabel];
    [self bind:scale to:^(NSSlider *sender) { [weakSelf.actions updatePetScale:sender.doubleValue]; }];
    [self.reloaders addObject:^{
        CGFloat value = CCPetsPetScalePreference();
        scale.doubleValue = value;
        scaleLabel.stringValue = [NSString stringWithFormat:@"%ld%%", (long)lround(value * 100)];
    }];
    [self.form addGroupWithTitle:nil rows:@[
        [CCPetsFormBuilder rowWithTitle:L(@"Pet Size") controls:@[scale, scaleLabel]],
        [self switchRowWithTitle:L(@"Import Codex Pets") subtitle:L(@"Copy pets from ~/.codex/pets into your own folder")
            key:ImportCodexPetsKey
            apply:^(id<CCPetsSettingsActions> actions, BOOL enabled) { [actions updateImportCodexPets:enabled]; }],
    ] footer:nil];

    // 碎碎念
    NSSegmentedControl *frequency = [self segmentedWithOptions:@[
        @[L(@"Rarely"), @"low"], @[L(@"Normal"), @"normal"], @[L(@"Often"), @"high"], @[L(@"Chatty"), @"chatty"]]
        selected:^id { return [NSUserDefaults.standardUserDefaults stringForKey:PetSpeechFrequencyKey] ?: @"normal"; }
        action:^(NSString *value) { [weakSelf.actions updateSpeechFrequency:value]; }];
    NSPopUpButton *source = [self popUpWithOptions:@[
        @[L(@"Pet-specific Lines"), PetPhrasesSourcePet], @[L(@"Default Lines"), PetPhrasesSourceDefault]]
        selected:^id { return PetPhrasesSource(); }
        action:^(NSString *value) { [weakSelf.actions updatePhrasesSource:value]; }];

    // 先抽一句给用户看，满意再让桌面上的宠物说：换了台词来源能马上听到区别。
    NSTextField *sample = CCPetsLabel(@"", 12, NSFontWeightRegular, CCPetsSecondaryInkColor());
    [sample setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
        forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.sampleLine = sample;
    NSButton *say = [self smallButtonWithTitle:L(@"Say It") action:^{
        NSString *text = weakSelf.sampleLine.toolTip;
        if (text.length == 0) text = [weakSelf.actions sampleSpeechLine];
        if (text.length > 0) [weakSelf.actions presentSpeechText:text];
        [weakSelf drawSampleLine];
    }];
    NSButton *edit = [self smallButtonWithTitle:L(@"Edit Lines…") action:^{ [weakSelf.actions editPhrasesFile:nil]; }];
    [self drawSampleLine];
    [self.reloaders addObject:^{ [weakSelf drawSampleLine]; }];

    [self.form addGroupWithTitle:L(@"Chatter") rows:@[
        [self switchRowWithTitle:L(@"Let the pet talk on its own") subtitle:nil key:PetSpeechEnabledKey
            apply:^(id<CCPetsSettingsActions> actions, BOOL enabled) { [actions updateSpeechEnabled:enabled]; }],
        [CCPetsFormBuilder rowWithTitle:L(@"Frequency") controls:@[frequency]],
        [CCPetsFormBuilder rowWithTitle:L(@"Line Source") controls:@[source]],
        [CCPetsFormBuilder rowWithTitle:L(@"Try a Line") controls:@[sample, say, edit]],
    ] footer:nil];

    // 戳它的反应是宠物自己的性格，和碎碎念放在一起，不和系统通知混在一页。
    [self.form addGroupWithTitle:L(@"Click Reactions") rows:@[
        [self switchRowWithTitle:L(@"React when poked") subtitle:nil key:PetInteractionEnabledKey
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
}

- (void)drawSampleLine {
    NSString *text = [self.actions sampleSpeechLine];
    self.sampleLine.toolTip = text;
    self.sampleLine.stringValue = text.length > 0 ? [NSString stringWithFormat:L(@"“%@”"), text] : @"";
}

// 宠物卡片：精灵图 + 名字 + 来源。最后一张是"添加宠物"，打开素材文件夹。
- (void)rebuildPicker {
    for (NSView *view in [self.pickerRows.arrangedSubviews copy]) {
        [self.pickerRows removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    [self.petTiles removeAllObjects];
    [self.petSprites removeAllObjects];
    NSArray<NSDictionary *> *options = [self.actions petPickerOptions] ?: @[];
    NSMutableArray<NSView *> *tiles = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    for (NSDictionary *option in options) {
        NSString *petID = option[@"id"];
        CCPetsSpriteView *sprite = [[CCPetsSpriteView alloc] initWithFrame:NSZeroRect];
        CCPetsTileView *tile = [self tileWithTop:sprite title:option[@"name"]
            subtitle:[option[@"builtin"] boolValue] ? L(@"Built-in") : L(@"Your folder")];
        tile.onClick = ^{ [weakSelf.actions switchPetToID:petID]; };
        tile.toolTip = option[@"name"];
        self.petTiles[petID] = tile;
        self.petSprites[petID] = sprite;
        [tiles addObject:tile];
        [self loadSheetForOption:option intoSprite:sprite];
    }
    NSTextField *plus = CCPetsLabel(@"+", 30, NSFontWeightLight, CCPetsTertiaryInkColor());
    plus.alignment = NSTextAlignmentCenter;
    CCPetsTileView *add = [self tileWithTop:plus title:L(@"Add a Pet") subtitle:L(@"cc-pets pet add <name>")];
    add.onClick = ^{ RevealFolder(OwnPetsDirectory()); };
    add.toolTip = L(@"Opens your pets folder. Put a sprite sheet in its own folder there, or run cc-pets pet add <name>.");
    [tiles addObject:add];

    for (NSUInteger start = 0; start < tiles.count; start += PetPickerColumns) {
        NSMutableArray<NSView *> *rowViews = [NSMutableArray array];
        for (NSUInteger index = start; index < start + PetPickerColumns; index++) {
            // 末行不满时用空视图占位，卡片宽度和上面几行对齐。
            [rowViews addObject:index < tiles.count ? tiles[index] : [NSView new]];
        }
        NSStackView *row = [NSStackView stackViewWithViews:rowViews];
        row.distribution = NSStackViewDistributionFillEqually;
        row.spacing = 10;
        row.alignment = NSLayoutAttributeTop;
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [self.pickerRows addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.pickerRows.widthAnchor].active = YES;
    }
    [self updatePetSelection];
}

- (CCPetsTileView *)tileWithTop:(NSView *)top title:(NSString *)title subtitle:(NSString *)subtitle {
    CCPetsTileView *tile = [CCPetsTileView new];
    NSTextField *name = CCPetsLabel(title, 12, NSFontWeightSemibold, CCPetsInkColor());
    NSTextField *detail = CCPetsLabel(subtitle, 11, NSFontWeightRegular, CCPetsTertiaryInkColor());
    for (NSTextField *label in @[name, detail]) {
        label.alignment = NSTextAlignmentCenter;
        [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
            forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    for (NSView *view in @[top, name, detail]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [tile addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        // 素材格子是 140×150，按同样比例缩小。
        [top.topAnchor constraintEqualToAnchor:tile.topAnchor constant:12],
        [top.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [top.widthAnchor constraintEqualToConstant:66],
        [top.heightAnchor constraintEqualToConstant:72],
        [name.topAnchor constraintEqualToAnchor:top.bottomAnchor constant:6],
        [name.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:8],
        [name.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-8],
        [detail.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:1],
        [detail.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:8],
        [detail.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-8],
        [detail.bottomAnchor constraintEqualToAnchor:tile.bottomAnchor constant:-12],
    ]];
    return tile;
}

// 精灵图解码要几十毫秒一张，Codex 导入的宠物可能有几十只：每张放到下一轮主线程再解，
// 页面先出来，图一张张补上。解码器会读屏幕倍率，所以留在主线程。
- (void)loadSheetForOption:(NSDictionary *)option intoSprite:(CCPetsSpriteView *)sprite {
    NSString *path = option[@"path"];
    NSInteger rowCount = [option[@"rowCount"] integerValue] ?: 9;
    NSImage *cached = self.sheetCache[path];
    if (cached) {
        [sprite setSheet:cached rowCount:rowCount];
        return;
    }
    __weak typeof(self) weakSelf = self;
    __weak CCPetsSpriteView *weakSprite = sprite;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!weakSelf || !weakSprite || path.length == 0) return;
        NSImage *sheet = LoadPetSpriteImage(path, NSMakeSize(66, 72), rowCount);
        if (!sheet) return;
        weakSelf.sheetCache[path] = sheet;
        [weakSprite setSheet:sheet rowCount:rowCount];
    });
}

- (void)updatePetSelection {
    NSString *current = [self.actions currentPetID];
    [self.petTiles enumerateKeysAndObjectsUsingBlock:^(NSString *petID, CCPetsTileView *tile, BOOL *stop) {
        BOOL selected = [petID isEqualToString:current];
        tile.selected = selected;
        // 只让选中的那只动，其余停在第一帧。
        self.petSprites[petID].playing = selected;
    }];
}

@end

#pragma mark - 提醒

@implementation CCPetsAlertsPage

- (NSString *)pageTitle {
    return L(@"Alerts");
}

- (NSString *)pageSubtitle {
    return L(@"When to interrupt you: system notifications, the status card and message badges.");
}

- (void)buildContent {
    [self.form addGroupWithTitle:L(@"Notifications") rows:@[
        [self notificationRowWithTitle:L(@"Awaiting approval") subtitle:L(@"An Agent is stuck on a permission prompt")
            key:NotificationApprovalKey],
        [self notificationRowWithTitle:L(@"Task failed") subtitle:nil key:NotificationFailureKey],
        [self notificationRowWithTitle:L(@"Task done") subtitle:nil key:NotificationCompletionKey],
        [self notificationRowWithTitle:L(@"Stalled") subtitle:L(@"The same step has been running too long")
            key:NotificationStallKey],
    ] footer:nil];

    // CC Bridge 这里只放只影响桌宠的两项；启用和免审批会改 Claude Code / Codex 的配置，仍在右键菜单里。
    [self.form addGroupWithTitle:L(@"Desktop Status Card") rows:@[
        [self switchRowWithTitle:L(@"Show Status Card") subtitle:L(@"The card next to the pet while an Agent is working")
            key:StatusBubbleExpandedKey
            apply:^(id<CCPetsSettingsActions> actions, BOOL enabled) { [actions updateStatusBubbleExpanded:enabled]; }],
        [self switchRowWithTitle:L(@"CC Bridge unread badge") subtitle:nil key:BridgeBadgeEnabledKey
            apply:^(id<CCPetsSettingsActions> actions, BOOL enabled) { [actions updateBridgeBadgeEnabled:enabled]; }],
        [self notificationRowWithTitle:L(@"CC Bridge message notifications")
            subtitle:L(@"Only who sent it to whom, never the message") key:BridgeNotificationKey],
    ] footer:L(@"Enabling CC Bridge, auto-approve and other options that change Claude Code / Codex settings stay in the pet's right-click menu.")];
}

@end

#pragma mark - 通用

@interface CCPetsGeneralPage ()
@property(nonatomic) NSView *glassPreviewDim;
@property(nonatomic, copy) NSArray<NSDictionary *> *usageProfiles;
@end

@implementation CCPetsGeneralPage

- (void)loadView {
    [super loadView];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(preferencesDidChange:)
        name:CCPetsProfilesDidChangeNotification object:nil];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    [self reloadValues];
}

- (NSArray<NSDictionary *> *)currentUsageProfiles {
    NSMutableArray<NSDictionary *> *profiles = [NSMutableArray array];
    for (NSString *provider in @[@"claude", @"codex"]) {
        NSArray *registered = CCPetsProfilesForProvider(provider);
        [profiles addObjectsFromArray:registered.count > 0 ? registered : @[@{@"provider": provider}]];
    }
    return profiles.copy;
}

- (void)reloadValues {
    if (![self.usageProfiles isEqualToArray:[self currentUsageProfiles]]) {
        // 新增、移除、改名或重新定位账号后重建行，同时释放旧控件的闭包。
        [self.handlers removeAllObjects];
        [self.reloaders removeAllObjects];
        [self.form removeAllContent];
        [self buildContent];
    }
    [super reloadValues];
}

- (NSString *)pageTitle {
    return L(@"Settings");
}

- (NSString *)pageSubtitle {
    return L(@"Language, panel appearance and data folders.");
}

// 主题卡片上方的小预览：三条横线代表面板里的文字行。
- (NSView *)themePreviewLiquid:(BOOL)liquid {
    NSView *preview = [NSView new];
    preview.wantsLayer = YES;
    preview.layer.cornerRadius = 6;
    preview.layer.masksToBounds = YES;
    if (liquid) {
        CAGradientLayer *gradient = [CAGradientLayer layer];
        gradient.colors = @[(id)[NSColor colorWithSRGBRed:0.43 green:0.56 blue:0.70 alpha:1].CGColor,
                            (id)[NSColor colorWithSRGBRed:0.18 green:0.29 blue:0.42 alpha:1].CGColor,
                            (id)[NSColor colorWithSRGBRed:0.25 green:0.37 blue:0.27 alpha:1].CGColor];
        gradient.startPoint = CGPointMake(0, 1);
        gradient.endPoint = CGPointMake(1, 0);
        gradient.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        [preview.layer addSublayer:gradient];
    } else {
        preview.layer.backgroundColor = [NSColor colorWithSRGBRed:0.12 green:0.14 blue:0.16 alpha:1].CGColor;
    }
    NSArray<NSArray *> *bars = @[@[@1.0, liquid ? @0.55 : @0.25], @[@0.7, liquid ? @0.85 : @1.0], @[@0.45, liquid ? @0.55 : @0.25]];
    NSView *previous = nil;
    for (NSUInteger index = 0; index < bars.count; index++) {
        NSView *bar = [NSView new];
        bar.wantsLayer = YES;
        bar.layer.cornerRadius = 2;
        // 经典主题的第二条用强调青，和真正的经典面板一样。
        bar.layer.backgroundColor = (!liquid && index == 1)
            ? [NSColor colorWithSRGBRed:0.31 green:0.83 blue:0.90 alpha:1].CGColor
            : [NSColor colorWithWhite:1 alpha:[bars[index][1] doubleValue]].CGColor;
        bar.translatesAutoresizingMaskIntoConstraints = NO;
        [preview addSubview:bar];
        [NSLayoutConstraint activateConstraints:@[
            [bar.leadingAnchor constraintEqualToAnchor:preview.leadingAnchor constant:10],
            [bar.widthAnchor constraintEqualToAnchor:preview.widthAnchor multiplier:[bars[index][0] doubleValue]
                constant:-20 * [bars[index][0] doubleValue]],
            [bar.heightAnchor constraintEqualToConstant:4],
            previous ? [bar.topAnchor constraintEqualToAnchor:previous.bottomAnchor constant:5]
                     : [bar.topAnchor constraintEqualToAnchor:preview.topAnchor constant:18],
        ]];
        previous = bar;
    }
    if (liquid) {
        // 压暗层：滑块拖动时跟着变深变浅。
        NSView *dim = [NSView new];
        dim.wantsLayer = YES;
        dim.translatesAutoresizingMaskIntoConstraints = NO;
        [preview addSubview:dim];
        [NSLayoutConstraint activateConstraints:@[
            [dim.leadingAnchor constraintEqualToAnchor:preview.leadingAnchor],
            [dim.trailingAnchor constraintEqualToAnchor:preview.trailingAnchor],
            [dim.topAnchor constraintEqualToAnchor:preview.topAnchor],
            [dim.bottomAnchor constraintEqualToAnchor:preview.bottomAnchor],
        ]];
        self.glassPreviewDim = dim;
    }
    return preview;
}

- (CCPetsTileView *)themeTileLiquid:(BOOL)liquid {
    CCPetsTileView *tile = [CCPetsTileView new];
    NSView *preview = [self themePreviewLiquid:liquid];
    NSTextField *title = CCPetsLabel(liquid ? @"Liquid Glass" : L(@"Classic"), 13, NSFontWeightSemibold, CCPetsInkColor());
    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObjects:preview, title, nil];
    NSTextField *note = nil;
    if (liquid) {
        note = CCPetsLabel(L(@"macOS 26 or later"), 11, NSFontWeightRegular, CCPetsTertiaryInkColor());
        [views addObject:note];
    }
    for (NSView *view in views) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [tile addSubview:view];
    }
    NSView *last = note ?: title;
    [NSLayoutConstraint activateConstraints:@[
        [preview.topAnchor constraintEqualToAnchor:tile.topAnchor constant:10],
        [preview.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:10],
        [preview.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-10],
        [preview.heightAnchor constraintEqualToConstant:62],
        [title.topAnchor constraintEqualToAnchor:preview.bottomAnchor constant:10],
        [title.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:12],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:tile.trailingAnchor constant:-12],
        // 两张卡片等高（经典卡没有说明行），所以底边只约束"不超出"，多出的高度留在下面。
        [last.bottomAnchor constraintLessThanOrEqualToAnchor:tile.bottomAnchor constant:-10],
    ]];
    if (note) {
        [NSLayoutConstraint activateConstraints:@[
            [note.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:1],
            [note.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
            [note.bottomAnchor constraintEqualToAnchor:tile.bottomAnchor constant:-10],
        ]];
    }
    return tile;
}

- (void)buildContent {
    __weak typeof(self) weakSelf = self;

    NSMutableArray<NSArray *> *languages = [NSMutableArray arrayWithObject:@[L(@"System Default"), CCPetsLanguageSystem]];
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
    NSSegmentedControl *appearance = [self segmentedWithOptions:@[
        @[L(@"System Default"), @"system"], @[L(@"Light"), @"light"], @[L(@"Dark"), @"dark"]]
        selected:^id { return CCPetsMainWindowAppearancePreference(); }
        action:^(NSString *value) { CCPetsPrefSetObject(CCPetsMainWindowAppearanceKey, value); }];
    [self.form addGroupWithTitle:nil rows:@[
        [CCPetsFormBuilder rowWithTitle:L(@"Language") controls:@[language]],
        [CCPetsFormBuilder rowWithTitle:L(@"Window Appearance")
            subtitle:L(@"Only this window; the pet's panels follow Panel Appearance below") controls:@[appearance]],
    ] footer:nil];

    // 浮层外观：两张主题卡片 + 玻璃压暗滑块。
    [self.form addGroupTitle:L(@"Panel Appearance") note:nil];
    CCPetsTileView *classic = [self themeTileLiquid:NO];
    CCPetsTileView *liquid = [self themeTileLiquid:YES];
    classic.onClick = ^{ [weakSelf.actions updatePanelTheme:@"classic"]; };
    BOOL liquidAvailable = CCPetsLiquidGlassAvailable();
    if (liquidAvailable) liquid.onClick = ^{ [weakSelf.actions updatePanelTheme:@"liquid"]; };
    else liquid.alphaValue = 0.5;
    NSStackView *themes = [NSStackView stackViewWithViews:@[classic, liquid]];
    themes.distribution = NSStackViewDistributionFillEqually;
    themes.alignment = NSLayoutAttributeTop;
    themes.spacing = 10;
    [self.form addView:themes];
    [classic.heightAnchor constraintEqualToAnchor:liquid.heightAnchor].active = YES;

    NSSlider *dim = [self sliderWithMinimum:0 maximum:CCPetsGlassDimMaximum width:200];
    NSTextField *dimLabel = [self sliderValueLabel];
    [self bind:dim to:^(NSSlider *sender) {
        NSInteger value = (NSInteger)lround(sender.doubleValue);
        dimLabel.stringValue = [NSString stringWithFormat:@"%ld%%", (long)value];
        [weakSelf showGlassDim:value];
        [weakSelf.actions updateGlassDimLevel:@(value)];
    }];
    NSView *dimRow = [CCPetsFormBuilder rowWithTitle:L(@"Glass Dimming")
        subtitle:L(@"Raise it when a bright wallpaper makes text hard to read") controls:@[dim, dimLabel]];
    [self.reloaders addObject:^{
        BOOL isLiquid = [CCPetsPanelTheme() isEqualToString:@"liquid"] && liquidAvailable;
        classic.selected = !isLiquid;
        liquid.selected = isLiquid;
        NSInteger level = CCPetsGlassDimLevel();
        dim.doubleValue = level;
        dimLabel.stringValue = [NSString stringWithFormat:@"%ld%%", (long)level];
        // 压暗只作用于原生玻璃，经典主题下没有这层。
        dim.enabled = isLiquid;
        [weakSelf showGlassDim:level];
    }];
    [self.form addGroupWithTitle:nil rows:@[dimRow] footer:nil];

    // 悬停面板：每家一个胶囊，点一下在订阅额度和 Token 用量之间切换，和右键菜单同一个样子。
    [self.form addGroupTitle:L(@"Hover Panel") note:L(@"Click a pill to switch")];
    NSMutableArray<NSView *> *panelRows = [NSMutableArray array];
    self.usageProfiles = [self currentUsageProfiles];
    for (NSDictionary *profile in self.usageProfiles) {
        NSString *provider = [profile[@"provider"] isEqualToString:@"codex"] ? @"Codex" : @"Claude";
        NSString *name = profile[@"displayName"] ?: provider;
        CCPetsPillButton *pill = [CCPetsPillButton new];
        [pill setAccessibilityLabel:[NSString stringWithFormat:L(@"%@ usage display"), name]];
        NSView *row = [CCPetsFormBuilder rowWithTitle:name subtitle:@" " controls:@[pill]];
        NSTextField *detail = [self subtitleLabelInRow:row];
        [self bind:pill to:^(id sender) {
            NSDictionary *current = profile[@"id"] ? CCPetsProfileWithID(profile[@"id"]) : profile;
            if (!current || !CCPetsProfileCanSwitchUsageMode(current)) return;
            BOOL api = CCPetsProfileShowsAPIUsage(current);
            if (current[@"id"]) [weakSelf.actions updateUsageDisplayMode:api ? @"subscription" : @"api" forProfileID:current[@"id"]];
            else [weakSelf.actions updateUsageDisplayMode:api ? @"subscription" : @"api" forKey:CCPetsUsageModePreferenceKey(current)];
        }];
        [self.reloaders addObject:^{
            NSDictionary *current = profile[@"id"] ? CCPetsProfileWithID(profile[@"id"]) : profile;
            BOOL api = current && CCPetsProfileShowsAPIUsage(current);
            pill.enabled = current && CCPetsProfileCanSwitchUsageMode(current);
            pill.toolTip = pill.enabled ? nil : L(@"API authentication: usage display is fixed to API.");
            pill.title = api ? L(@"API") : L(@"Plan");
            // 订阅用绿、用量用蓝，和右键菜单里的胶囊一致。
            pill.fillColor = api ? CCPetsChartColor(6) : CCPetsChartColor(5);
            detail.stringValue = !pill.enabled ? L(@"API authentication: usage display is fixed to API.")
                : (api ? L(@"Token usage: today's new and cached tokens")
                    : L(@"Plan quota: what's left of the 5-hour and weekly limits"));
        }];
        [panelRows addObject:row];
    }
    // 三项可以任意组合：用"可多选"的分段控件，一行放得下，也和上面的分段控件一个样子。
    NSArray<NSString *> *metricKeys = @[SystemCPUEnabledKey, SystemTemperatureEnabledKey, SystemMemoryEnabledKey];
    NSSegmentedControl *metrics = [NSSegmentedControl segmentedControlWithLabels:@[@"CPU", L(@"Temperature"), L(@"Memory")]
        trackingMode:NSSegmentSwitchTrackingSelectAny target:nil action:nil];
    metrics.controlSize = NSControlSizeSmall;
    metrics.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    CCPetsApplyAccent(metrics);
    [self bind:metrics to:^(NSSegmentedControl *sender) {
        NSInteger segment = sender.selectedSegment;
        if (segment < 0 || segment >= (NSInteger)metricKeys.count) return;
        [weakSelf.actions updateSystemMetric:metricKeys[(NSUInteger)segment] enabled:[sender isSelectedForSegment:segment]];
    }];
    [self.reloaders addObject:^{
        for (NSUInteger index = 0; index < metricKeys.count; index++) {
            [metrics setSelected:CCPetsPrefBool(metricKeys[index]) forSegment:(NSInteger)index];
        }
    }];
    [panelRows addObject:[CCPetsFormBuilder rowWithTitle:L(@"System Status") controls:@[metrics]]];
    [self.form addGroupWithTitle:nil rows:panelRows footer:nil];

    [self.form addGroupWithTitle:L(@"Data") rows:@[
        [CCPetsFormBuilder rowWithTitle:L(@"Pet sprites folder") subtitle:[self displayPath:OwnPetsDirectory()]
            controls:@[[self smallButtonWithTitle:L(@"Show in Finder") action:^{ RevealFolder(OwnPetsDirectory()); }]]],
    ] footer:nil];
}

- (NSString *)displayPath:(NSString *)path {
    return path.stringByAbbreviatingWithTildeInPath;
}

// rowWithTitle:subtitle: 里的说明标签，胶囊切换时要跟着改文字。
- (NSTextField *)subtitleLabelInRow:(NSView *)row {
    NSStackView *stack = (NSStackView *)row;
    NSStackView *titles = (NSStackView *)stack.arrangedSubviews.firstObject;
    if (![titles isKindOfClass:NSStackView.class]) return nil;
    return (NSTextField *)titles.arrangedSubviews.lastObject;
}

- (void)showGlassDim:(NSInteger)level {
    self.glassPreviewDim.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:level / 100.0].CGColor;
}

@end
