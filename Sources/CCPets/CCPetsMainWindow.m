#import "CCPetsMainWindow.h"
#import "CCPetsL10n.h"
#import "CCPetsDiagnosticsPage.h"
#import "CCPetsSettingsPage.h"
#import "CCPetsUsagePage.h"
#import "CCPetsUIStyle.h"
#import "CCPetsWorkbenchPages.h"

NSString *const CCPetsMainWindowPageOverview = @"overview";
NSString *const CCPetsMainWindowPageSessions = @"sessions";
NSString *const CCPetsMainWindowPageUsage = @"usage";
NSString *const CCPetsMainWindowPagePet = @"pet";
NSString *const CCPetsMainWindowPageAlerts = @"alerts";
NSString *const CCPetsMainWindowPageGeneral = @"general";
NSString *const CCPetsMainWindowPageDiagnostics = @"diagnostics";
NSNotificationName const CCPetsPetCardDidChangeNotification = @"CCPetsPetCardDidChange";
static NSString *const MainWindowLastPageKey = @"CCPetsMainWindowLastPage";
// 改版后默认窗口变大了（内容多了概览和表格）。换个名字，不沿用改版前记住的小窗口尺寸。
static NSString *const MainWindowFrameName = @"CCPetsMainWindow.v2";

// 侧边栏里的页面，按显示顺序。group 决定排在哪一组，footer 的那页钉在侧边栏底部。
// 标题现取，切换语言后重建侧边栏即可。
static NSArray<NSDictionary *> *MainWindowPages(void) {
    return @[
        @{@"id": CCPetsMainWindowPageOverview, @"title": L(@"Overview"), @"symbol": @"house",
          @"group": @"workbench", @"class": CCPetsOverviewPage.class},
        @{@"id": CCPetsMainWindowPageSessions, @"title": L(@"Sessions & Messages"), @"symbol": @"terminal",
          @"group": @"workbench", @"class": CCPetsSessionsPage.class},
        @{@"id": CCPetsMainWindowPageUsage, @"title": L(@"Usage"), @"symbol": @"chart.bar",
          @"group": @"workbench", @"class": CCPetsUsagePage.class},
        @{@"id": CCPetsMainWindowPagePet, @"title": L(@"Pet"), @"symbol": @"pawprint",
          @"group": @"workbench", @"class": CCPetsPetPage.class},
        @{@"id": CCPetsMainWindowPageAlerts, @"title": L(@"Alerts"), @"symbol": @"bell",
          @"group": @"settings", @"class": CCPetsAlertsPage.class},
        @{@"id": CCPetsMainWindowPageGeneral, @"title": L(@"Settings"), @"symbol": @"gearshape",
          @"group": @"settings", @"class": CCPetsGeneralPage.class},
        @{@"id": CCPetsMainWindowPageDiagnostics, @"title": L(@"Diagnostics"), @"symbol": @"stethoscope",
          @"group": @"footer", @"class": CCPetsDiagnosticsPage.class},
    ];
}

NSArray<NSString *> *CCPetsMainWindowPageIDs(void) {
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (NSDictionary *entry in MainWindowPages()) [ids addObject:entry[@"id"]];
    return ids;
}

NSString *CCPetsMainWindowResolvePage(NSString *page) {
    if (page.length == 0) return nil;
    if ([CCPetsMainWindowPageIDs() containsObject:page]) return page;
    // 改版前设置是一整页。旧脚本、旧文档里的 `cc-pets open settings` 落到宠物页（原来的第一组）。
    if ([page isEqualToString:@"settings"]) return CCPetsMainWindowPagePet;
    return nil;
}

static NSDictionary *MainWindowPageWithID(NSString *page) {
    for (NSDictionary *entry in MainWindowPages()) {
        if ([entry[@"id"] isEqualToString:page]) return entry;
    }
    return nil;
}

// 有没有还开着的普通窗口。桌宠、状态卡、气泡、额度面板、NSAlert 都是 NSPanel，不算；
// 台词编辑器是 NSWindow，算——它开着时切回 Accessory，编辑器会跟着掉到别的 App 后面。
static BOOL HasVisibleRegularWindow(void) {
    for (NSWindow *window in NSApp.windows) {
        if ([window isKindOfClass:NSPanel.class] || !window.canBecomeMainWindow) continue;
        // 最小化到 Dock 的窗口 isVisible 为 NO，但切回 Accessory 会让它连同 Dock 图标一起找不回来。
        if (window.isVisible || window.isMiniaturized) return YES;
    }
    return NO;
}

#pragma mark - 侧边栏部件

// 侧边栏的中文标题字与字之间各加一个空格（"概 览"、"会 话"），两三个字的短标题排开后
// 更像一列整齐的菜单。只处理全是汉字的标题：英文等其他语言原样显示。读屏仍用原标题。
static NSString *SidebarDisplayTitle(NSString *title) {
    if (title.length < 2) return title;
    NSCharacterSet *han = [NSCharacterSet characterSetWithRange:NSMakeRange(0x4E00, 0x9FFF - 0x4E00 + 1)];
    if ([title rangeOfCharacterFromSet:han.invertedSet].location != NSNotFound) return title;
    NSMutableArray<NSString *> *characters = [NSMutableArray array];
    [title enumerateSubstringsInRange:NSMakeRange(0, title.length) options:NSStringEnumerationByComposedCharacterSequences
        usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
        [characters addObject:character];
    }];
    return [characters componentsJoinedByString:@" "];
}

// 侧边栏里的一项：单色图标 + 标题 + 可选角标。选中时整行铺淡青底，图标和文字换成强调色。
// 自己画而不用 source list 表格：选中色要跟主题走（表格只会用系统强调色），分组、底部钉住的
// 诊断项也更好排。
@interface CCPetsSidebarItem : NSView
@property(nonatomic, copy) NSString *pageID;
// 原标题；显示用的是加了空格的版本。
@property(nonatomic, copy) NSString *title;
@property(nonatomic) BOOL selected;
@property(nonatomic) CCPetsCountBadge *badge;
@property(nonatomic, copy) void (^onSelect)(NSString *pageID);
- (instancetype)initWithPage:(NSDictionary *)page;
@end

@interface CCPetsSidebarItem ()
@property(nonatomic) NSImageView *icon;
@property(nonatomic) NSTextField *label;
@property(nonatomic) BOOL hovering;
@end

@implementation CCPetsSidebarItem

- (instancetype)initWithPage:(NSDictionary *)page {
    if ((self = [super initWithFrame:NSZeroRect])) {
        self.pageID = page[@"id"];
        self.wantsLayer = YES;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration
            configurationWithPointSize:13 weight:NSFontWeightRegular];
        NSImage *image = [[NSImage imageWithSystemSymbolName:page[@"symbol"] accessibilityDescription:nil]
            imageWithSymbolConfiguration:configuration] ?: [NSImage new];
        NSImageView *icon = [NSImageView imageViewWithImage:image];
        icon.symbolConfiguration = configuration;
        NSTextField *label = CCPetsLabel(SidebarDisplayTitle(page[@"title"]), 13, NSFontWeightRegular, CCPetsInkColor());
        self.title = page[@"title"];
        [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
            forOrientation:NSLayoutConstraintOrientationHorizontal];
        CCPetsCountBadge *badge = [CCPetsCountBadge new];
        for (NSView *view in @[icon, label, badge]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:view];
        }
        [badge setContentCompressionResistancePriority:NSLayoutPriorityRequired
            forOrientation:NSLayoutConstraintOrientationHorizontal];
        self.icon = icon;
        self.label = label;
        self.badge = badge;
        [NSLayoutConstraint activateConstraints:@[
            [self.heightAnchor constraintEqualToConstant:30],
            [icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
            [icon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:18],
            [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:8],
            [label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [label.trailingAnchor constraintLessThanOrEqualToAnchor:badge.leadingAnchor constant:-6],
            [badge.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
            [badge.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
        [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
            options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp | NSTrackingInVisibleRect
            owner:self userInfo:nil]];
        [self applyStyle];
    }
    return self;
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    [self applyStyle];
}

- (void)applyStyle {
    self.icon.contentTintColor = self.selected ? CCPetsAccentColor() : CCPetsSecondaryInkColor();
    self.label.font = [NSFont systemFontOfSize:13 weight:self.selected ? NSFontWeightSemibold : NSFontWeightRegular];
    self.needsDisplay = YES;
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)updateLayer {
    self.layer.cornerRadius = 7;
    self.layer.backgroundColor = self.selected ? CCPetsSelectionColor().CGColor
        : (self.hovering ? CCPetsHoverColor().CGColor : NSColor.clearColor.CGColor);
}

- (void)mouseEntered:(NSEvent *)event {
    self.hovering = YES;
    self.needsDisplay = YES;
}

- (void)mouseExited:(NSEvent *)event {
    self.hovering = NO;
    self.needsDisplay = YES;
}

- (void)mouseDown:(NSEvent *)event {
    if (self.onSelect) self.onSelect(self.pageID);
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (BOOL)isAccessibilityElement {
    return YES;
}

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityButtonRole;
}

- (NSString *)accessibilityLabel {
    return self.title;
}

- (BOOL)isAccessibilitySelected {
    return self.selected;
}

- (BOOL)accessibilityPerformPress {
    if (self.onSelect) self.onSelect(self.pageID);
    return YES;
}

@end

// 侧边栏顶部的宠物名片：会动的当前宠物、名字、Agent 状态。
@interface CCPetsPetCardView : NSView
- (void)reload;
@end

@interface CCPetsPetCardView ()
@property(nonatomic) CCPetsSpriteView *sprite;
@property(nonatomic) NSTextField *nameLabel;
@property(nonatomic) NSView *statusDot;
@property(nonatomic) NSTextField *statusLabel;
@property(nonatomic) CCPetsStatusKind kind;
@end

@implementation CCPetsPetCardView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        CCPetsSpriteView *sprite = [[CCPetsSpriteView alloc] initWithFrame:NSZeroRect];
        self.sprite = sprite;
        NSTextField *name = CCPetsLabel(@"", 13, NSFontWeightBold, CCPetsInkColor());
        self.nameLabel = name;
        NSView *dot = [NSView new];
        dot.wantsLayer = YES;
        dot.layer.cornerRadius = 3;
        self.statusDot = dot;
        NSTextField *status = CCPetsLabel(@"", 11, NSFontWeightRegular, CCPetsSecondaryInkColor());
        self.statusLabel = status;
        for (NSView *view in @[sprite, name, dot, status]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:view];
        }
        [name setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
            forOrientation:NSLayoutConstraintOrientationHorizontal];
        [status setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
            forOrientation:NSLayoutConstraintOrientationHorizontal];
        [NSLayoutConstraint activateConstraints:@[
            // 素材格子是 140×150，按同样比例缩到 40pt 宽。
            [sprite.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:6],
            [sprite.topAnchor constraintEqualToAnchor:self.topAnchor],
            [sprite.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [sprite.widthAnchor constraintEqualToConstant:40],
            [sprite.heightAnchor constraintEqualToConstant:43],
            [name.leadingAnchor constraintEqualToAnchor:sprite.trailingAnchor constant:8],
            [name.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-6],
            [name.bottomAnchor constraintEqualToAnchor:sprite.centerYAnchor constant:1],
            [dot.leadingAnchor constraintEqualToAnchor:name.leadingAnchor constant:1],
            [dot.widthAnchor constraintEqualToConstant:6],
            [dot.heightAnchor constraintEqualToConstant:6],
            [dot.centerYAnchor constraintEqualToAnchor:status.centerYAnchor],
            [status.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:5],
            [status.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-6],
            [status.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:1],
        ]];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload)
            name:CCPetsPetCardDidChangeNotification object:nil];
        [self reload];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self applyDotColor];
}

- (void)applyDotColor {
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self.statusDot.layer.backgroundColor = CCPetsStatusColor(self.kind).CGColor;
    }];
}

- (void)reload {
    id source = NSApp.delegate;
    NSDictionary *snapshot = [source conformsToProtocol:@protocol(CCPetsPetCardSource)]
        ? [source petCardSnapshot] : nil;
    [self.sprite setSheet:snapshot[@"sheet"] rowCount:[snapshot[@"rowCount"] integerValue] ?: 9];
    NSString *state = snapshot[@"state"] ?: @"idle";
    self.sprite.state = state;
    self.nameLabel.stringValue = snapshot[@"name"] ?: @"CC Pets";
    self.statusLabel.stringValue = snapshot[@"status"] ?: L(@"Idle");
    self.kind = CCPetsStatusKindForAgentState(state);
    [self applyDotColor];
}

@end

#pragma mark - 侧边栏

@interface CCPetsMainSidebarController : NSViewController
@property(nonatomic) CCPetsPetCardView *card;
@property(nonatomic) NSMutableDictionary<NSString *, CCPetsSidebarItem *> *items;
@property(nonatomic) NSStackView *navigation;
@property(nonatomic) NSView *footer;
@property(nonatomic, copy) NSString *currentPage;
@property(nonatomic, copy) void (^selectionHandler)(NSString *page);
@property(nonatomic) NSArray<NSLayoutConstraint *> *leadingConstraints;
- (void)selectPage:(NSString *)page;
// 全屏时整列内容右移 shift pt（侧边栏同时加宽），退出时传 0。
- (void)setContentShift:(CGFloat)shift;
- (void)reload;
@end

@implementation CCPetsMainSidebarController

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 210, 560)];
    CCPetsPetCardView *card = [[CCPetsPetCardView alloc] initWithFrame:NSZeroRect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    self.card = card;
    NSView *cardRule = [CCPetsLineView new];
    NSStackView *navigation = [NSStackView stackViewWithViews:@[]];
    navigation.orientation = NSUserInterfaceLayoutOrientationVertical;
    navigation.alignment = NSLayoutAttributeLeading;
    navigation.spacing = 2;
    self.navigation = navigation;
    NSView *footer = [NSView new];
    self.footer = footer;
    NSView *footerRule = [CCPetsLineView new];
    for (NSView *view in @[card, cardRule, navigation, footer, footerRule]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:view];
    }
    NSLayoutConstraint *cardLeading = [card.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:10];
    NSLayoutConstraint *cardRuleLeading = [cardRule.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:16];
    NSLayoutConstraint *navigationLeading = [navigation.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:10];
    NSLayoutConstraint *footerRuleLeading = [footerRule.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:16];
    NSLayoutConstraint *footerLeading = [footer.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:10];
    self.leadingConstraints = @[cardLeading, cardRuleLeading, navigationLeading, footerRuleLeading, footerLeading];
    [NSLayoutConstraint activateConstraints:@[
        // 名片从标题栏下沿开始，左右和导航项对齐。
        [card.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:2],
        cardLeading,
        [card.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-10],
        [cardRule.topAnchor constraintEqualToAnchor:card.bottomAnchor constant:12],
        cardRuleLeading,
        [cardRule.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-16],
        [cardRule.heightAnchor constraintEqualToConstant:1],
        [navigation.topAnchor constraintEqualToAnchor:cardRule.bottomAnchor constant:12],
        navigationLeading,
        [navigation.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-10],
        [navigation.bottomAnchor constraintLessThanOrEqualToAnchor:footerRule.topAnchor constant:-8],
        footerRuleLeading,
        [footerRule.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-16],
        [footerRule.heightAnchor constraintEqualToConstant:1],
        [footerRule.bottomAnchor constraintEqualToAnchor:footer.topAnchor constant:-8],
        footerLeading,
        [footer.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-10],
        [footer.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-10],
    ]];
    self.view = root;
    [self rebuildItems];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshBadges)
        name:CCPetsPetCardDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshBadges)
        name:CCPetsDiagnosticsDidChangeNotification object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (NSTextField *)groupLabel:(NSString *)title {
    NSTextField *label = CCPetsLabel(SidebarDisplayTitle(title), 11, NSFontWeightSemibold, CCPetsTertiaryInkColor());
    label.accessibilityLabel = title;
    return label;
}

- (void)rebuildItems {
    for (NSView *view in [self.navigation.arrangedSubviews copy]) {
        [self.navigation removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    for (NSView *view in [self.footer.subviews copy]) [view removeFromSuperview];
    self.items = [NSMutableDictionary dictionary];
    __weak typeof(self) weakSelf = self;
    NSString *group = nil;
    NSDictionary *groupTitles = @{@"workbench": L(@"Workbench"), @"settings": L(@"General")};
    for (NSDictionary *page in MainWindowPages()) {
        CCPetsSidebarItem *item = [[CCPetsSidebarItem alloc] initWithPage:page];
        item.onSelect = ^(NSString *pageID) {
            if (weakSelf.selectionHandler) weakSelf.selectionHandler(pageID);
        };
        self.items[page[@"id"]] = item;
        if ([page[@"group"] isEqualToString:@"footer"]) {
            [self.footer addSubview:item];
            [NSLayoutConstraint activateConstraints:@[
                [item.leadingAnchor constraintEqualToAnchor:self.footer.leadingAnchor],
                [item.trailingAnchor constraintEqualToAnchor:self.footer.trailingAnchor],
                [item.topAnchor constraintEqualToAnchor:self.footer.topAnchor],
                [item.bottomAnchor constraintEqualToAnchor:self.footer.bottomAnchor],
            ]];
            continue;
        }
        if (![page[@"group"] isEqualToString:group]) {
            group = page[@"group"];
            NSTextField *label = [self groupLabel:groupTitles[group] ?: @""];
            NSView *last = self.navigation.arrangedSubviews.lastObject;
            if (last) [self.navigation setCustomSpacing:14 afterView:last];
            [self.navigation addArrangedSubview:label];
            [self.navigation setCustomSpacing:4 afterView:label];
            [label.leadingAnchor constraintEqualToAnchor:self.navigation.leadingAnchor constant:10].active = YES;
        }
        [self.navigation addArrangedSubview:item];
        [item.leadingAnchor constraintEqualToAnchor:self.navigation.leadingAnchor].active = YES;
        [item.trailingAnchor constraintEqualToAnchor:self.navigation.trailingAnchor].active = YES;
    }
    if (self.currentPage) [self selectPage:self.currentPage];
    [self refreshBadges];
}

// 角标：会话页是在线会话数（有等审批的就用提醒色），诊断页是要处理的问题数。
- (void)refreshBadges {
    id source = NSApp.delegate;
    NSDictionary *snapshot = [source conformsToProtocol:@protocol(CCPetsPetCardSource)]
        ? [source petCardSnapshot] : nil;
    CCPetsCountBadge *sessions = self.items[CCPetsMainWindowPageSessions].badge;
    sessions.count = [snapshot[@"sessions"] integerValue];
    sessions.warn = [snapshot[@"approvals"] integerValue] > 0;
    CCPetsCountBadge *diagnostics = self.items[CCPetsMainWindowPageDiagnostics].badge;
    diagnostics.count = (NSInteger)CCPetsDiagnosticsStore.issueCount;
    diagnostics.warn = YES;
}

- (void)reload {
    [self.card reload];
    [self rebuildItems];
}

- (void)setContentShift:(CGFloat)shift {
    [self view];
    // 每条左边距的基准值：名片、导航、底部诊断 10pt，两条分隔线 16pt。
    static const CGFloat bases[] = {10, 16, 10, 16, 10};
    for (NSUInteger index = 0; index < self.leadingConstraints.count; index++) {
        self.leadingConstraints[index].constant = bases[index] + shift;
    }
}

- (void)selectPage:(NSString *)page {
    [self view];
    self.currentPage = page;
    [self.items enumerateKeysAndObjectsUsingBlock:^(NSString *pageID, CCPetsSidebarItem *item, BOOL *stop) {
        item.selected = [pageID isEqualToString:page];
    }];
}

@end

#pragma mark - 窗口

static const CGFloat PageTopLift = 36;

static NSLayoutConstraint *PageTopConstraint(NSView *view, NSView *host) {
    NSLayoutConstraint *top = [view.topAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.topAnchor
        constant:-PageTopLift];
    top.priority = NSLayoutPriorityDefaultHigh;
    return top;
}

@interface CCPetsMainWindowController () <NSWindowDelegate>
@property(nonatomic) NSSplitViewController *splitController;
@property(nonatomic) CCPetsMainSidebarController *sidebar;
@property(nonatomic) NSViewController *contentController;
@property(nonatomic) NSViewController *pageController;
@property(nonatomic, copy) NSString *currentPage;
@property(nonatomic) NSSplitViewItem *sidebarItem;
// 进全屏前侧边栏的宽度，退出时还原。
@property(nonatomic) CGFloat windowedSidebarWidth;
@end

// 全屏时屏幕宽，侧边栏在常规宽度上加宽 10pt，内容右移 5pt，和铺满的内容区比例更协调。
static const CGFloat SidebarFullScreenExtraWidth = 10, SidebarFullScreenShift = 5;

static CCPetsMainWindowController *SharedMainWindow;
static id WindowCloseObserver;

@implementation CCPetsMainWindowController

+ (void)presentPage:(NSString *)page {
    if (!SharedMainWindow) SharedMainWindow = [CCPetsMainWindowController new];
    NSString *target = CCPetsMainWindowResolvePage(page) ?:
        CCPetsMainWindowResolvePage([NSUserDefaults.standardUserDefaults stringForKey:MainWindowLastPageKey]);
    if (!target) target = MainWindowPages().firstObject[@"id"];
    [SharedMainWindow showPage:target];
    [self enterRegularMode];
    [NSApp activateIgnoringOtherApps:YES];
    [SharedMainWindow.window makeKeyAndOrderFront:nil];
    // 侧边栏的诊断角标要先检查一遍；结果缓存一阵，频繁开关窗口不会反复跑。
    [CCPetsDiagnosticsStore refreshIfStale];
}

// 有 Dock 图标、能 ⌘Tab、显示菜单栏。顺带开始盯普通窗口的关闭，最后一个关掉时切回去。
+ (void)enterRegularMode {
    if (NSApp.activationPolicy != NSApplicationActivationPolicyRegular) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    }
    if (WindowCloseObserver) return;
    WindowCloseObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:NSWindowWillCloseNotification object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *note) {
        // willClose 时窗口还在屏幕上，等它真的收起再判断。
        dispatch_async(dispatch_get_main_queue(), ^{ [CCPetsMainWindowController leaveRegularModeIfIdle]; });
    }];
}

+ (void)leaveRegularModeIfIdle {
    if (HasVisibleRegularWindow()) return;
    if (WindowCloseObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:WindowCloseObserver];
        WindowCloseObserver = nil;
    }
    if (NSApp.activationPolicy == NSApplicationActivationPolicyAccessory) return;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    // 切回 Accessory 后菜单栏不会自己让出来，主动交还给下一个 App。
    [NSApp deactivate];
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 940, 640)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                  NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                  NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:YES];
    if ((self = [super initWithWindow:window])) {
        window.releasedWhenClosed = NO;
        window.minSize = NSMakeSize(760, 520);
        window.delegate = self;
        window.titlebarAppearsTransparent = YES;
        window.titleVisibility = NSWindowTitleHidden;
        // 内容区的底色；标题栏透明，延伸到标题栏底下的部分也是这个颜色。
        window.backgroundColor = CCPetsBackgroundColor();
        // 空工具栏 + unified：侧边栏一直延伸到标题栏，和系统设置一个样子。
        window.toolbar = [[NSToolbar alloc] initWithIdentifier:@"CCPetsMainWindowToolbar"];
        window.toolbarStyle = NSWindowToolbarStyleUnified;

        self.sidebar = [CCPetsMainSidebarController new];
        __weak typeof(self) weakSelf = self;
        self.sidebar.selectionHandler = ^(NSString *page) { [weakSelf showPage:page]; };
        self.contentController = [NSViewController new];
        self.contentController.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 720, 640)];

        NSSplitViewController *split = [NSSplitViewController new];
        NSSplitViewItem *sidebarItem = [NSSplitViewItem sidebarWithViewController:self.sidebar];
        sidebarItem.minimumThickness = 200;
        sidebarItem.maximumThickness = 240;
        sidebarItem.canCollapse = NO;
        self.sidebarItem = sidebarItem;
        [split addSplitViewItem:sidebarItem];
        NSSplitViewItem *contentItem = [NSSplitViewItem splitViewItemWithViewController:self.contentController];
        contentItem.minimumThickness = 520;
        [split addSplitViewItem:contentItem];
        self.splitController = split;
        window.contentViewController = split;
        [window setContentSize:NSMakeSize(940, 640)];
        // 记住上次的位置和大小；第一次打开时居中。
        if (![window setFrameUsingName:MainWindowFrameName]) [window center];
        window.frameAutosaveName = MainWindowFrameName;

        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(languageDidChange:)
            name:CCPetsLanguageDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)showPage:(NSString *)page {
    NSDictionary *entry = MainWindowPageWithID(page);
    if (!entry) return;
    // 标题栏不显示标题（页头里已经有），但窗口菜单和调度中心要用它。
    self.window.title = entry[@"title"];
    [self.sidebar selectPage:page];
    if ([self.currentPage isEqualToString:page] && self.pageController) return;
    [self.pageController.view removeFromSuperview];
    [self.pageController removeFromParentViewController];
    NSViewController *controller = [entry[@"class"] new];
    [self.contentController addChildViewController:controller];
    NSView *host = self.contentController.view;
    NSView *view = controller.view;
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        // 窗口是 FullSizeContentView，内容区会延伸到标题栏底下。空工具栏让安全区有 66pt，
        // 页头标题上方显得太空，往上收 36pt（原空白 72pt 的一半）；红绿灯在侧边栏那一侧，压不到。
        // 全屏时工具栏收起、安全区变成 0，这时至少离顶边 24pt，标题不贴着屏幕边。
        [view.topAnchor constraintGreaterThanOrEqualToAnchor:host.topAnchor constant:24],
        PageTopConstraint(view, host),
        [view.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
    ]];
    self.pageController = controller;
    self.currentPage = page;
    [NSUserDefaults.standardUserDefaults setObject:page forKey:MainWindowLastPageKey];
}

// 页面里的文案都是建页面时取的，换语言后整页重建，比逐个控件改标题省事也不会漏。
- (void)languageDidChange:(NSNotification *)notification {
    [self.sidebar reload];
    NSString *page = self.currentPage;
    self.currentPage = nil;
    [self showPage:page];
}

// 空工具栏只是为了让侧边栏延伸到标题栏。全屏时系统把它画成一条不透明的横条，
// 压在页头上（标题被盖住），所以全屏期间收起，退出时再放回来。
- (void)windowWillEnterFullScreen:(NSNotification *)notification {
    self.window.toolbar.visible = NO;
    CGFloat width = NSWidth(self.sidebar.view.frame);
    self.windowedSidebarWidth = width > 0 ? width : 240;
    CGFloat fullWidth = self.windowedSidebarWidth + SidebarFullScreenExtraWidth;
    self.sidebarItem.maximumThickness = fullWidth;
    self.sidebarItem.minimumThickness = fullWidth;
    [self.sidebar setContentShift:SidebarFullScreenShift];
}

- (void)windowDidExitFullScreen:(NSNotification *)notification {
    self.window.toolbar.visible = YES;
    self.sidebarItem.minimumThickness = 200;
    self.sidebarItem.maximumThickness = 240;
    [self.splitController.splitView setPosition:self.windowedSidebarWidth ofDividerAtIndex:0];
    [self.sidebar setContentShift:0];
}

- (void)windowWillClose:(NSNotification *)notification {
    // 关窗即释放：页面持有的观察者、定时器随之结束，主窗口不占后台资源。
    [self.pageController.view removeFromSuperview];
    [self.pageController removeFromParentViewController];
    self.pageController = nil;
    if (SharedMainWindow == self) {
        dispatch_async(dispatch_get_main_queue(), ^{ SharedMainWindow = nil; });
    }
}

@end
