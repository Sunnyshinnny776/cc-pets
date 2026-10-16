#import "CCPetsMainWindow.h"
#import "CCPetsL10n.h"
#import "CCPetsSettingsPage.h"

NSString *const CCPetsMainWindowPageSettings = @"settings";
static NSString *const MainWindowLastPageKey = @"CCPetsMainWindowLastPage";
static NSString *const MainWindowFrameName = @"CCPetsMainWindow";

// 侧边栏里的页面，按显示顺序。标题现取，切换语言后重建侧边栏即可。
static NSArray<NSDictionary *> *MainWindowPages(void) {
    return @[
        @{@"id": CCPetsMainWindowPageSettings, @"title": L(@"Settings"), @"symbol": @"gearshape",
          @"class": CCPetsSettingsPage.class},
    ];
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

@interface CCPetsMainSidebarController : NSViewController <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic) NSTableView *tableView;
@property(nonatomic, copy) void (^selectionHandler)(NSString *page);
- (void)selectPage:(NSString *)page;
- (void)reload;
@end

@interface CCPetsMainWindowController () <NSWindowDelegate>
@property(nonatomic) NSSplitViewController *splitController;
@property(nonatomic) CCPetsMainSidebarController *sidebar;
@property(nonatomic) NSViewController *contentController;
@property(nonatomic) NSViewController *pageController;
@property(nonatomic, copy) NSString *currentPage;
@end

static CCPetsMainWindowController *SharedMainWindow;
static id WindowCloseObserver;

@implementation CCPetsMainWindowController

+ (void)presentPage:(NSString *)page {
    if (!SharedMainWindow) SharedMainWindow = [CCPetsMainWindowController new];
    NSString *target = MainWindowPageWithID(page) ? page :
        [NSUserDefaults.standardUserDefaults stringForKey:MainWindowLastPageKey];
    if (!MainWindowPageWithID(target)) target = MainWindowPages().firstObject[@"id"];
    [SharedMainWindow showPage:target];
    [self enterRegularMode];
    [NSApp activateIgnoringOtherApps:YES];
    [SharedMainWindow.window makeKeyAndOrderFront:nil];
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
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 560)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                  NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                  NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:YES];
    if ((self = [super initWithWindow:window])) {
        window.releasedWhenClosed = NO;
        window.minSize = NSMakeSize(640, 440);
        window.delegate = self;
        window.titlebarAppearsTransparent = YES;
        // 空工具栏 + unified：侧边栏一直延伸到标题栏，和系统设置一个样子。
        window.toolbar = [[NSToolbar alloc] initWithIdentifier:@"CCPetsMainWindowToolbar"];
        window.toolbarStyle = NSWindowToolbarStyleUnified;

        self.sidebar = [CCPetsMainSidebarController new];
        __weak typeof(self) weakSelf = self;
        self.sidebar.selectionHandler = ^(NSString *page) { [weakSelf showPage:page]; };
        self.contentController = [NSViewController new];
        self.contentController.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 560)];

        NSSplitViewController *split = [NSSplitViewController new];
        NSSplitViewItem *sidebarItem = [NSSplitViewItem sidebarWithViewController:self.sidebar];
        sidebarItem.minimumThickness = 180;
        sidebarItem.maximumThickness = 240;
        sidebarItem.canCollapse = NO;
        [split addSplitViewItem:sidebarItem];
        NSSplitViewItem *contentItem = [NSSplitViewItem splitViewItemWithViewController:self.contentController];
        contentItem.minimumThickness = 420;
        [split addSplitViewItem:contentItem];
        self.splitController = split;
        window.contentViewController = split;
        [window setContentSize:NSMakeSize(760, 560)];
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
    [self.sidebar selectPage:page];
    self.window.title = entry[@"title"];
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
        // 窗口是 FullSizeContentView，内容区会延伸到标题栏底下；页面从安全区开始排，不压标题。
        [view.topAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.topAnchor],
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

@implementation CCPetsMainSidebarController

- (void)loadView {
    NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    table.style = NSTableViewStyleSourceList;
    table.headerView = nil;
    table.rowHeight = 28;
    table.dataSource = self;
    table.delegate = self;
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"page"];
    // 唯一一列跟着侧边栏宽度走，长标题（英文）不会被默认的 100pt 列宽截断。
    column.resizingMask = NSTableColumnAutoresizingMask;
    [table addTableColumn:column];
    table.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    self.tableView = table;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 200, 560)];
    scroll.documentView = table;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;
    self.view = scroll;
}

- (void)reload {
    NSInteger selected = self.tableView.selectedRow;
    [self.tableView reloadData];
    if (selected >= 0) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)selected]
            byExtendingSelection:NO];
    }
}

- (void)selectPage:(NSString *)page {
    [self view];
    NSArray<NSDictionary *> *pages = MainWindowPages();
    for (NSUInteger index = 0; index < pages.count; index++) {
        if (![pages[index][@"id"] isEqualToString:page]) continue;
        if (self.tableView.selectedRow != (NSInteger)index) {
            [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
        }
        return;
    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)MainWindowPages().count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn
    row:(NSInteger)row {
    NSDictionary *entry = MainWindowPages()[(NSUInteger)row];
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"PageCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"PageCell";
        NSImageView *icon = [NSImageView imageViewWithImage:[NSImage new]];
        NSTextField *label = [NSTextField labelWithString:@""];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:icon];
        [cell addSubview:label];
        cell.imageView = icon;
        cell.textField = label;
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
            [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:18],
            [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:8],
            [label.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-4],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    cell.imageView.image = [NSImage imageWithSystemSymbolName:entry[@"symbol"]
        accessibilityDescription:entry[@"title"]];
    cell.textField.stringValue = entry[@"title"];
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = self.tableView.selectedRow;
    NSArray<NSDictionary *> *pages = MainWindowPages();
    if (row < 0 || row >= (NSInteger)pages.count) return;
    if (self.selectionHandler) self.selectionHandler(pages[(NSUInteger)row][@"id"]);
}

@end
