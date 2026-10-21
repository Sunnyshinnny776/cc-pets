#import "PetView+Private.h"
#import "CCPetsL10n.h"
#import "MenuToggleSwitch.h"
#import "MenuHintView.h"
#import "CCPetsPaths.h"
#import "CCPetsImageLoader.h"
#import "CCPetsBridge.h"
#import "CCPetsGlassView.h"
#import "MenuChoiceRow.h"
#import "MenuPetSizeView.h"
#import "CCPetsPetSize.h"
#import "CCPetsProfiles.h"
#import "CCPetsUsageMode.h"

// 菜单里自绘行的宽度：主菜单要撑满 menu.minimumWidth，子菜单按自身内容收窄，
// 三个子菜单（用量展示模式 / 系统通知 / 系统状态）用同一个宽度，看起来才是一套。
static const CGFloat PetMenuRowWidth = 194.0;
// 两者都只是下限：译文长短差得多（"等待审批" 对 "Awaiting approval"），开关行会按自己的
// 标题撑宽，菜单再把同一子菜单里的行统一拉到最宽那一行。
static const CGFloat PetSubmenuRowWidth = 134.0;
// 与“系统通知”里文案到开关的间距共用，素材名称到删除按钮也保持一致。
static const CGFloat PetMenuControlGap = 8.0;
static const NSInteger PetMenuCheckViewTag = 1001;
static const NSInteger PetMenuDeleteButtonTag = 1002;

@implementation PetView (Menu)
- (void)selectPetFromButton:(NSButton *)sender {
    NSString *petID = sender.identifier;
    if (petID.length == 0) return;
    [self resetPendingDeleteButton];
    if (self.switchPetRequested) self.switchPetRequested(petID);
    [self refreshPetMenuRows];
}
- (void)deletePetFromButton:(NSButton *)sender {
    NSString *petID = sender.identifier;
    if (petID.length == 0) return;
    if (![self.pendingDeletePetID isEqualToString:petID]) {
        [self resetPendingDeleteButton];
        self.pendingDeletePetID = petID;
        [self configureDeleteButton:sender confirming:YES];
        return;
    }

    BOOL deleted = self.deletePetRequested && self.deletePetRequested(petID);
    if (!deleted) {
        [self resetPendingDeleteButton];
        return;
    }
    self.pendingDeletePetID = nil;
    for (NSMenuItem *item in self.activePetSwitchMenu.itemArray.copy) {
        NSDictionary *pet = [item.representedObject isKindOfClass:NSDictionary.class]
            ? item.representedObject : nil;
        if ([pet[@"id"] isEqualToString:petID]) {
            [self.activePetSwitchMenu removeItem:item];
            break;
        }
    }
    [self refreshPetMenuRows];
}
- (void)configureDeleteButton:(NSButton *)button confirming:(BOOL)confirming {
    button.bordered = confirming;
    button.title = @"";
    button.attributedTitle = confirming
        ? [[NSAttributedString alloc] initWithString:L(@"Confirm") attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: NSColor.systemRedColor,
        }]
        : [[NSAttributedString alloc] initWithString:@""];
    button.image = confirming ? nil : [NSImage imageNamed:NSImageNameTrashEmpty];
    button.imagePosition = confirming ? NSNoImage : NSImageOnly;
    button.contentTintColor = nil;
    button.bezelStyle = NSBezelStyleRounded;
    button.hasDestructiveAction = YES;
    button.toolTip = confirming ? L(@"Click again to delete") : L(@"Delete pet");
    [button setAccessibilityLabel:button.toolTip];
}
- (void)resetPendingDeleteButton {
    if (self.pendingDeletePetID.length == 0) return;
    for (NSMenuItem *item in self.activePetSwitchMenu.itemArray) {
        NSButton *button = (NSButton *)[item.view viewWithTag:PetMenuDeleteButtonTag];
        if ([button isKindOfClass:NSButton.class] &&
            [button.identifier isEqualToString:self.pendingDeletePetID]) {
            [self configureDeleteButton:button confirming:NO];
            break;
        }
    }
    self.pendingDeletePetID = nil;
}
- (void)refreshPetMenuRows {
    for (NSMenuItem *item in self.activePetSwitchMenu.itemArray) {
        NSDictionary *pet = [item.representedObject isKindOfClass:NSDictionary.class]
            ? item.representedObject : nil;
        NSString *petID = [pet[@"id"] isKindOfClass:NSString.class] ? pet[@"id"] : @"";
        BOOL selected = [petID isEqualToString:self.currentPetID];
        item.state = selected ? NSControlStateValueOn : NSControlStateValueOff;

        NSTextField *check = (NSTextField *)[item.view viewWithTag:PetMenuCheckViewTag];
        if ([check isKindOfClass:NSTextField.class]) check.stringValue = selected ? @"✓" : @"";

        NSButton *deleteButton = (NSButton *)[item.view viewWithTag:PetMenuDeleteButtonTag];
        if (![deleteButton isKindOfClass:NSButton.class]) continue;
        BOOL deletable = [petID hasPrefix:@"external:"] && !selected;
        deleteButton.hidden = !deletable;
        deleteButton.enabled = deletable;
        if (!deletable && [self.pendingDeletePetID isEqualToString:petID]) {
            [self configureDeleteButton:deleteButton confirming:NO];
            self.pendingDeletePetID = nil;
        }
    }
}
- (NSString *)displayNameForPetName:(NSString *)name font:(NSFont *)font maxWidth:(CGFloat)maxWidth {
    if (![name isKindOfClass:NSString.class]) return @"";
    NSDictionary<NSAttributedStringKey, id> *attributes = @{NSFontAttributeName: font};
    if ([name sizeWithAttributes:attributes].width <= maxWidth) return name;

    NSString *suffix = @"...";
    NSMutableString *prefix = [NSMutableString string];
    [name enumerateSubstringsInRange:NSMakeRange(0, name.length)
        options:NSStringEnumerationByComposedCharacterSequences
        usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
            NSString *candidate = [NSString stringWithFormat:@"%@%@%@", prefix, substring, suffix];
            if ([candidate sizeWithAttributes:attributes].width > maxWidth) {
                *stop = YES;
                return;
            }
            [prefix appendString:substring];
        }];
    return [prefix stringByAppendingString:suffix];
}
- (NSMenuItem *)addPetOption:(NSDictionary *)pet toMenu:(NSMenu *)menu {
    NSString *petID = [pet[@"id"] isKindOfClass:NSString.class] ? pet[@"id"] : @"";
    NSString *name = [pet[@"name"] isKindOfClass:NSString.class] ? pet[@"name"] : @"";
    BOOL selected = [petID isEqualToString:self.currentPetID];
    BOOL deletable = [petID hasPrefix:@"external:"];

    NSFont *font = [NSFont menuFontOfSize:13];
    CGFloat nameWidth = ceil([L(@"Pet sprite name...") sizeWithAttributes:@{NSFontAttributeName: font}].width);
    NSString *displayName = [self displayNameForPetName:name font:font maxWidth:nameWidth];
    const CGFloat checkWidth = 14;
    const CGFloat leadingInset = 6;
    const CGFloat nameX = leadingInset + checkWidth;
    const CGFloat deleteWidth = 40;
    const CGFloat trailingInset = 2;
    CGFloat deleteX = nameX + nameWidth + PetMenuControlGap;
    CGFloat rowWidth = deleteX + deleteWidth + trailingInset;

    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:displayName action:nil keyEquivalent:@""];
    item.representedObject = pet;
    item.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, rowWidth, 28)];

    NSTextField *check = [NSTextField labelWithString:selected ? @"✓" : @""];
    check.frame = NSMakeRect(leadingInset, 5, checkWidth, 18);
    check.tag = PetMenuCheckViewTag;
    check.font = font;
    check.textColor = NSColor.labelColor;
    [row addSubview:check];

    NSTextField *nameLabel = [NSTextField labelWithString:displayName];
    nameLabel.frame = NSMakeRect(nameX, 5, nameWidth, 18);
    nameLabel.font = font;
    nameLabel.textColor = NSColor.labelColor;
    nameLabel.lineBreakMode = NSLineBreakByClipping;
    nameLabel.toolTip = name;
    [row addSubview:nameLabel];

    // 透明按钮覆盖勾选和名称区域，既让整块都能点击，也避免 NSButton 自带的标题
    // 内边距破坏“最大文案末尾到删除按钮 8pt”的精确间距。
    NSButton *selectButton = [[NSButton alloc]
        initWithFrame:NSMakeRect(0, 0, nameX + nameWidth, 28)];
    selectButton.bordered = NO;
    selectButton.title = @"";
    selectButton.identifier = petID;
    selectButton.target = self;
    selectButton.action = @selector(selectPetFromButton:);
    selectButton.focusRingType = NSFocusRingTypeNone;
    selectButton.toolTip = name;
    [selectButton setAccessibilityLabel:[NSString stringWithFormat:L(@"Switch to %@"), name]];
    [row addSubview:selectButton];

    NSButton *deleteButton = [[NSButton alloc] initWithFrame:NSMakeRect(deleteX, 3, deleteWidth, 22)];
    deleteButton.tag = PetMenuDeleteButtonTag;
    deleteButton.imageScaling = NSImageScaleProportionallyDown;
    deleteButton.identifier = petID;
    deleteButton.target = self;
    deleteButton.action = @selector(deletePetFromButton:);
    deleteButton.enabled = deletable && !selected;
    deleteButton.hidden = !deleteButton.enabled;
    [self configureDeleteButton:deleteButton confirming:NO];
    deleteButton.toolTip = [NSString stringWithFormat:L(@"Delete %@"), name];
    [deleteButton setAccessibilityLabel:deleteButton.toolTip];
    [row addSubview:deleteButton];

    item.view = row;
    [menu addItem:item];
    return item;
}
- (NSImage *)menuPreviewForPet:(NSDictionary *)pet {
    NSString *path = [pet[@"path"] isKindOfClass:NSString.class] ? pet[@"path"] : nil;
    NSInteger rowCount = [pet[@"spriteRowCount"] integerValue];
    if (path.length == 0 || rowCount <= 0) return nil;

    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    NSTimeInterval modifiedAt = [attributes[NSFileModificationDate] timeIntervalSince1970];
    unsigned long long fileSize = [attributes[NSFileSize] unsignedLongLongValue];
    NSString *cacheKey = [NSString stringWithFormat:@"%@:%ld:%.6f:%llu",
        path, (long)rowCount, modifiedAt, fileSize];
    NSImage *cached = [self.petMenuPreviewCache objectForKey:cacheKey];
    if (cached) return cached;

    NSImage *sheet = LoadPetSpriteImage(path, NSMakeSize(92, 76), rowCount);
    if (!sheet || sheet.size.width <= 0 || sheet.size.height <= 0) return nil;

    CGFloat cellWidth = sheet.size.width / 8.0;
    CGFloat cellHeight = sheet.size.height / rowCount;
    NSRect firstFrame = NSMakeRect(0, sheet.size.height - cellHeight, cellWidth, cellHeight);
    CGFloat previewHeight = 76.0;
    CGFloat previewWidth = round(previewHeight * cellWidth / cellHeight);
    NSImage *preview = [[NSImage alloc] initWithSize:NSMakeSize(previewWidth, previewHeight)];
    [preview lockFocus];
    [sheet drawInRect:NSMakeRect(0, 0, previewWidth, previewHeight) fromRect:firstFrame
        operation:NSCompositingOperationSourceOver fraction:1.0
        respectFlipped:NO hints:@{NSImageHintInterpolation: @(NSImageInterpolationNone)}];
    [preview unlockFocus];
    NSUInteger cost = (NSUInteger)ceil(previewWidth * previewHeight * 4.0);
    [self.petMenuPreviewCache setObject:preview forKey:cacheKey cost:cost];
    return preview;
}
- (void)preparePetMenuPreviewPanel {
    if (self.petMenuPreviewPanel) return;

    NSRect panelFrame = NSMakeRect(0, 0, 92, 100);
    self.petMenuPreviewPanel = [[NSPanel alloc] initWithContentRect:panelFrame
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    self.petMenuPreviewPanel.opaque = NO;
    self.petMenuPreviewPanel.backgroundColor = NSColor.clearColor;
    self.petMenuPreviewPanel.hasShadow = YES;
    self.petMenuPreviewPanel.ignoresMouseEvents = YES;
    self.petMenuPreviewPanel.level = NSPopUpMenuWindowLevel + 1;
    self.petMenuPreviewPanel.collectionBehavior = NSWindowCollectionBehaviorTransient |
        NSWindowCollectionBehaviorMoveToActiveSpace;

    NSVisualEffectView *background = [[NSVisualEffectView alloc] initWithFrame:panelFrame];
    background.material = NSVisualEffectMaterialMenu;
    background.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    background.state = NSVisualEffectStateActive;
    background.wantsLayer = YES;
    background.layer.cornerRadius = 10.0;
    background.layer.masksToBounds = YES;

    self.petMenuPreviewImageView = [[NSImageView alloc] initWithFrame:NSInsetRect(panelFrame, 8, 8)];
    self.petMenuPreviewImageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.petMenuPreviewImageView.animates = NO;
    [background addSubview:self.petMenuPreviewImageView];
    self.petMenuPreviewPanel.contentView = background;
}
- (void)showMenuPreviewForPet:(NSDictionary *)pet item:(NSMenuItem *)item menu:(NSMenu *)menu {
    NSImage *preview = [self menuPreviewForPet:pet];
    if (!preview) {
        [self.petMenuPreviewPanel orderOut:nil];
        return;
    }
    [self preparePetMenuPreviewPanel];
    self.petMenuPreviewImageView.image = preview;

    NSRect itemFrame = item.accessibilityFrame;
    NSRect menuFrame = menu.accessibilityFrame;
    if (NSIsEmptyRect(menuFrame)) {
        NSPoint mouse = NSEvent.mouseLocation;
        menuFrame = NSMakeRect(mouse.x - menu.size.width / 2.0,
            mouse.y - menu.size.height / 2.0, menu.size.width, menu.size.height);
    }
    if (NSIsEmptyRect(itemFrame)) {
        NSPoint mouse = NSEvent.mouseLocation;
        itemFrame = NSMakeRect(menuFrame.origin.x, mouse.y - 11.0, menuFrame.size.width, 22.0);
    }

    // 子菜单可能根据屏幕空间展开到主菜单左侧。预览应放在整组菜单外侧，
    // 不能只按当前子菜单定位，否则会覆盖它右边的主菜单。
    NSRect menuGroupFrame = menuFrame;
    for (NSMenu *ancestor = menu.supermenu; ancestor; ancestor = ancestor.supermenu) {
        NSRect ancestorFrame = ancestor.accessibilityFrame;
        if (!NSIsEmptyRect(ancestorFrame)) menuGroupFrame = NSUnionRect(menuGroupFrame, ancestorFrame);
    }

    NSPoint menuCenter = NSMakePoint(NSMidX(menuGroupFrame), NSMidY(menuGroupFrame));
    NSScreen *targetScreen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    for (NSScreen *screen in NSScreen.screens) {
        if (NSPointInRect(menuCenter, screen.frame)) {
            targetScreen = screen;
            break;
        }
    }
    NSRect screenFrame = targetScreen.visibleFrame;
    NSSize previewSize = self.petMenuPreviewPanel.frame.size;
    CGFloat x = NSMaxX(menuGroupFrame) + 8.0;
    if (x + previewSize.width > NSMaxX(screenFrame)) {
        x = NSMinX(menuGroupFrame) - previewSize.width - 8.0;
    }
    CGFloat y = NSMidY(itemFrame) - previewSize.height / 2.0;
    y = MIN(MAX(y, NSMinY(screenFrame)), NSMaxY(screenFrame) - previewSize.height);
    [self.petMenuPreviewPanel setFrameOrigin:NSMakePoint(x, y)];
    [self.petMenuPreviewPanel orderFront:nil];
}
- (void)menu:(NSMenu *)menu willHighlightItem:(NSMenuItem *)item {
    NSDictionary *pet = [item.representedObject isKindOfClass:NSDictionary.class]
        ? item.representedObject : nil;
    if (pet) [self showMenuPreviewForPet:pet item:item menu:menu];
    else [self.petMenuPreviewPanel orderOut:nil];
    // 自绘行的说明由 MenuHintRowView 自己的进出事件管，这里不能去取消它。
    if (item.view) return;
    NSString *hint = [item.representedObject isKindOfClass:NSString.class] ? item.representedObject : nil;
    NSRect itemFrame = item.accessibilityFrame;
    if (hint && !NSIsEmptyRect(itemFrame)) [MenuHint scheduleText:hint belowScreenRect:itemFrame];
    else [MenuHint cancel];
}
- (void)menuDidClose:(NSMenu *)menu {
    [MenuHint cancel];
    // CC Bridge 子菜单也以 self 为代理（为了悬停说明），删除确认和预览只属于"管理桌宠"。
    if (menu != self.activePetSwitchMenu) return;
    [self resetPendingDeleteButton];
    [self.petMenuPreviewPanel orderOut:nil];
}
// 主菜单的行要撑满 menu.minimumWidth；子菜单只有自己这几项，撑到 194 会让短标题和开关
// 之间空出一大段。调用方给的是最小宽度，标题放不下时按标题撑宽；行设成可横向拉伸、
// 开关贴右，菜单会把同一子菜单里的行统一拉到最宽那一行。行内边距左 12 / 右 8。
- (NSMenuItem *)addPersistentSwitchToMenu:(NSMenu *)menu
    title:(NSString *)title
    checked:(BOOL)checked
    action:(SEL)action
    width:(CGFloat)width
    tag:(NSInteger)tag {
    const CGFloat toggleWidth = 36;
    const CGFloat trailingInset = PetMenuControlGap;
    const CGFloat leadingInset = 12;
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont menuFontOfSize:13];
    width = MAX(width, ceil(label.intrinsicContentSize.width) + leadingInset + trailingInset * 2 +
        toggleWidth);
    CGFloat toggleX = width - trailingInset - toggleWidth;
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    NSView *row = [[MenuHintRowView alloc] initWithFrame:NSMakeRect(0, 0, width, 28)];
    row.autoresizingMask = NSViewWidthSizable;
    label.frame = NSMakeRect(leadingInset, 5, toggleX - leadingInset - trailingInset, 18);
    label.autoresizingMask = NSViewWidthSizable;
    label.textColor = NSColor.labelColor;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [row addSubview:label];
    MenuToggleSwitch *toggle = [[MenuToggleSwitch alloc]
        initWithFrame:NSMakeRect(toggleX, 3, toggleWidth, 22)];
    toggle.target = NSApp.delegate;
    toggle.action = action;
    toggle.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
    toggle.tag = tag;
    toggle.autoresizingMask = NSViewMinXMargin;
    [toggle setAccessibilityLabel:title];
    [row addSubview:toggle];
    item.view = row;
    [menu addItem:item];
    return item;
}
- (NSMenuItem *)addUsageModeControlToMenu:(NSMenu *)menu
    provider:(NSString *)provider
    preferenceKey:(NSString *)preferenceKey
    tag:(NSInteger)tag profile:(NSDictionary *)profile {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    CGFloat labelWidth = MAX(48, MIN(180, ceil([provider sizeWithAttributes:
        @{NSFontAttributeName: [NSFont menuFontOfSize:13]}].width) + 4));
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, labelWidth + 86, 28)];
    // 菜单会按最宽的一行统一宽度；名称随之伸展，按钮始终贴住同一右边距。
    row.autoresizingMask = NSViewWidthSizable;
    NSTextField *label = [NSTextField labelWithString:provider];
    label.frame = NSMakeRect(12, 5, labelWidth, 18);
    label.autoresizingMask = NSViewWidthSizable;
    label.font = [NSFont menuFontOfSize:13];
    label.textColor = NSColor.labelColor;
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    label.toolTip = provider;
    [row addSubview:label];

    MenuUsageModeButton *control = [[MenuUsageModeButton alloc] initWithFrame:NSMakeRect(labelWidth + 20, 3, 58, 22)];
    control.autoresizingMask = NSViewMinXMargin;
    control.target = NSApp.delegate;
    control.action = @selector(setUsageDisplayModeFromControl:);
    BOOL api = profile ? CCPetsProfileShowsAPIUsage(profile)
        : [[NSUserDefaults.standardUserDefaults stringForKey:preferenceKey] isEqualToString:@"api"];
    control.state = api ? NSControlStateValueOn : NSControlStateValueOff;
    control.identifier = profile[@"id"];
    control.enabled = !profile || CCPetsProfileCanSwitchUsageMode(profile);
    if (!control.enabled) control.toolTip = L(@"API authentication: usage display is fixed to API.");
    control.tag = tag;
    [control setAccessibilityLabel:[NSString stringWithFormat:L(@"%@ usage display"), provider]];
    [row addSubview:control];
    item.view = row;
    [menu addItem:item];
    return item;
}
// CC Bridge 开关组。状态每次打开菜单时现读（开关文件 / 选项），不在视图里缓存。
// 除"消息角标 / 新消息通知"这两项只影响桌宠外，其余开关都通过 cc-pets bridge enable / configure
// 落到 Claude Code / Codex 的配置里。
- (void)addBridgeSwitchToMenu:(NSMenu *)menu title:(NSString *)title checked:(BOOL)checked
    action:(SEL)action tag:(NSInteger)tag toolTip:(NSString *)toolTip {
    // 与其他子菜单同宽。菜单宽度取最宽的一行：标题都控制在 5 个字以内，说明性文字放进悬停提示，
    // 否则长文字行会把菜单撑宽，而自绘开关行是固定宽度，开关就不再贴右边。
    // 说明不用系统 toolTip：它只在 App 激活时显示，见 MenuHintView.h。
    NSMenuItem *item = [self addPersistentSwitchToMenu:menu title:title checked:checked
        action:action width:PetSubmenuRowWidth tag:tag];
    ((MenuHintRowView *)item.view).hint = toolTip;
}
// 一级子菜单只放启用和最常动的两个开关（开关在上、二级菜单在下）；免审批（设一次就不动）和只影响桌宠的提醒各收进二级菜单。
// 未开启时只留"启用"一行：其余开关此时都不生效，列出来只是占地方。开启是异步的，
// 菜单停留期间不会自己长出其余项，下次打开时按实际状态重建。
- (void)addBridgeMenuToMenu:(NSMenu *)menu {
    NSMenuItem *bridgeItem = [menu addItemWithTitle:@"CC Bridge" action:nil keyEquivalent:@""];
    NSMenu *bridgeMenu = [NSMenu new];
    // 免审批 / 桌宠提醒 是普通菜单项，悬停说明走 menu:willHighlightItem:。
    bridgeMenu.delegate = self;
    bridgeItem.submenu = bridgeMenu;
    BOOL enabled = CCBridgeEnabled();
    [self addBridgeSwitchToMenu:bridgeMenu title:L(@"Enable") checked:enabled
        action:@selector(toggleBridgeEnabled:) tag:0
        toolTip:L(@"Let local Claude Code / Codex sessions message and wake each other and reserve files")];
    if (!enabled) return;

    // 状态放在"启用"行的第二行，省掉底部单独的状态行和分隔线。开关上移与标题对齐，
    // 状态文字才能占满整行宽度，不被开关截断。
    NSDictionary *sessions = CCBridgeSessions();
    NSUInteger reservations = CCBridgeActiveReservationCount([NSSet setWithArray:sessions.allKeys]);
    MenuHintRowView *enableRow = (MenuHintRowView *)bridgeMenu.itemArray.lastObject.view;
    enableRow.hint = [enableRow.hint stringByAppendingString:L(@"\nBelow: online sessions · active file reservations")];
    const CGFloat statusHeight = 14;
    [enableRow setFrameSize:NSMakeSize(NSWidth(enableRow.frame), NSHeight(enableRow.frame) + statusHeight)];
    for (NSView *subview in enableRow.subviews) {
        [subview setFrameOrigin:NSMakePoint(NSMinX(subview.frame), NSMinY(subview.frame) + statusHeight - 2)];
    }
    NSTextField *status = [NSTextField labelWithString:[NSString stringWithFormat:L(@"%lu sessions · %lu reserved"),
        (unsigned long)sessions.count, (unsigned long)reservations]];
    status.frame = NSMakeRect(12, 4, NSWidth(enableRow.frame) - 12 - PetMenuControlGap, statusHeight);
    status.font = [NSFont menuFontOfSize:11];
    status.textColor = NSColor.secondaryLabelColor;
    status.lineBreakMode = NSLineBreakByTruncatingTail;
    status.autoresizingMask = NSViewWidthSizable;
    [enableRow addSubview:status];

    [bridgeMenu addItem:NSMenuItem.separatorItem];
    NSDictionary *options = CCBridgeOptions();
    [self addBridgeSwitchToMenu:bridgeMenu title:L(@"Auto-wake") checked:[options[@"wake"] boolValue]
        action:@selector(toggleBridgeWake:) tag:0
        toolTip:L(@"Wake idle sessions automatically. When off, messages wait in the inbox until that session's next input, which saves tokens. Codex needs a session restart")];
    [self addBridgeSwitchToMenu:bridgeMenu title:L(@"Edit guard") checked:[options[@"editGuard"] boolValue]
        action:@selector(toggleBridgeEditGuard:) tag:0
        toolTip:L(@"Pause once with an explanation when editing a file another session reserved; retrying goes through. Codex needs a session restart")];

    NSMenuItem *approvalItem = [bridgeMenu addItemWithTitle:L(@"Auto-approve") action:nil keyEquivalent:@""];
    approvalItem.representedObject = L(@"Each group applies to both Codex approvals and Claude permissions. Codex needs a session restart");
    NSMenu *approvalMenu = [NSMenu new];
    NSArray<NSDictionary *> *groups = @[
        @{@"title": L(@"Read"), @"group": @"view", @"tag": @1,
          @"tip": L(@"Listing sessions, viewing reservations and reading the inbox. Read-only and safe")},
        @{@"title": L(@"Send"), @"group": @"send", @"tag": @2,
          @"tip": L(@"When on, Agents can message other sessions without asking")},
        @{@"title": L(@"Reserve"), @"group": @"reserve", @"tag": @3,
          @"tip": L(@"Reserving and releasing files")},
        @{@"title": L(@"Rename"), @"group": @"name", @"tag": @4,
          @"tip": L(@"Renaming the current session in CC Bridge")}
    ];
    NSSet *codex = [NSSet setWithArray:options[@"codexApprove"]];
    NSSet *claude = [NSSet setWithArray:options[@"claudeAllow"]];
    for (NSDictionary *group in groups) {
        NSSet *tools = [NSSet setWithArray:CCBridgeToolGroup(group[@"group"])];
        BOOL checked = tools.count > 0 && [tools isSubsetOfSet:codex] && [tools isSubsetOfSet:claude];
        [self addBridgeSwitchToMenu:approvalMenu title:group[@"title"] checked:checked
            action:@selector(toggleBridgeApproval:) tag:[group[@"tag"] integerValue] toolTip:group[@"tip"]];
    }
    approvalItem.submenu = approvalMenu;

    NSMenuItem *alertItem = [bridgeMenu addItemWithTitle:L(@"Pet alerts") action:nil keyEquivalent:@""];
    alertItem.representedObject = L(@"Only affects the pet, not Claude Code / Codex settings");
    NSMenu *alertMenu = [NSMenu new];
    [self addBridgeSwitchToMenu:alertMenu title:L(@"Badge")
        checked:[NSUserDefaults.standardUserDefaults boolForKey:BridgeBadgeEnabledKey]
        action:@selector(toggleBridgeBadge:) tag:0
        toolTip:L(@"Bottom-right of the status icon: blue for new deliveries, orange for a backed-up inbox")];
    [self addBridgeSwitchToMenu:alertMenu title:L(@"Notify")
        checked:[NSUserDefaults.standardUserDefaults boolForKey:BridgeNotificationKey]
        action:@selector(toggleBridgeNotification:) tag:0
        toolTip:L(@"Send a notification when a message is delivered between sessions (sender and recipient only, no content)")];
    alertItem.submenu = alertMenu;
}

- (void)rightMouseDown:(NSEvent *)event {
    NSArray<NSDictionary *> *availablePets = self.petOptionsRequested ? self.petOptionsRequested() : @[];
    NSMenu *menu = [NSMenu new];
    menu.minimumWidth = 194.0;
    NSMenuItem *switchItem = [menu addItemWithTitle:L(@"Pets") action:nil keyEquivalent:@""];
    NSMenu *switchMenu = [NSMenu new];
    switchMenu.delegate = self;
    for (NSDictionary *pet in availablePets) {
        [self addPetOption:pet toMenu:switchMenu];
    }
    self.activePetSwitchMenu = switchMenu;
    switchItem.submenu = switchMenu;
    NSMenuItem *sizeItem = [menu addItemWithTitle:L(@"Pet Size") action:nil keyEquivalent:@""];
    NSMenu *sizeMenu = [[NSMenu alloc] initWithTitle:L(@"Pet Size")];
    NSMenuItem *sizeControl = [[NSMenuItem alloc] initWithTitle:L(@"Pet Size")
        action:nil keyEquivalent:@""];
    sizeControl.view = [[MenuPetSizeView alloc] initWithScale:CCPetsPetScalePreference()
        target:NSApp.delegate action:@selector(setPetSizeFromSlider:)];
    [sizeMenu addItem:sizeControl];
    sizeItem.submenu = sizeMenu;
    [menu addItem:NSMenuItem.separatorItem];
    [self addPersistentSwitchToMenu:menu
        title:L(@"Show Status Card")
        checked:[NSUserDefaults.standardUserDefaults boolForKey:StatusBubbleExpandedKey]
        action:@selector(toggleStatusBubbleFromMenu:)
        width:PetMenuRowWidth
        tag:0];
    NSMenuItem *usageModeItem = [menu addItemWithTitle:L(@"Usage Display") action:nil keyEquivalent:@""];
    NSMenu *usageModeMenu = [NSMenu new];
    for (NSString *provider in @[@"Codex", @"Claude"]) {
        BOOL codex = [provider isEqualToString:@"Codex"];
        NSArray *profiles = CCPetsProfilesForProvider(provider.lowercaseString);
        NSString *key = codex ? CodexUsageDisplayModeKey : ClaudeUsageDisplayModeKey;
        if (profiles.count == 0) [self addUsageModeControlToMenu:usageModeMenu provider:provider
            preferenceKey:key tag:codex ? 1 : 2 profile:nil];
        for (NSDictionary *profile in profiles) {
            [self addUsageModeControlToMenu:usageModeMenu provider:profile[@"displayName"] ?: provider
                preferenceKey:key tag:codex ? 1 : 2 profile:profile];
        }
    }
    usageModeItem.submenu = usageModeMenu;
    NSMenuItem *themeItem = [menu addItemWithTitle:L(@"Panel Theme") action:nil keyEquivalent:@""];
    NSMenu *themeMenu = [[NSMenu alloc] initWithTitle:L(@"Panel Theme")];
    // 两组都用自绘单选行：点了立即生效且菜单不收起，方便连着对比主题和压暗档位。
    NSString *selectedTheme = CCPetsPanelTheme();
    for (NSArray<NSString *> *option in @[
        @[L(@"Classic"), @"classic"], @[@"Liquid Glass", @"liquid"]]) {
        NSMenuItem *item = [MenuChoiceRowView addToMenu:themeMenu title:option[0] group:@"theme"
            representedObject:option[1] checked:[selectedTheme isEqualToString:option[1]]
            target:NSApp.delegate action:@selector(setPanelTheme:) width:PetSubmenuRowWidth];
        if ([option[1] isEqualToString:@"liquid"] && !CCPetsLiquidGlassAvailable()) {
            ((MenuChoiceRowView *)item.view).enabled = NO;
            [item.view setAccessibilityHelp:L(@"Requires macOS 26 or later")];
        }
    }
    // 压暗作用于额度面板、状态卡和说话气泡的原生玻璃；经典主题下没有这层，置灰。切主题时当场联动。
    [themeMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *dimHeader = [themeMenu addItemWithTitle:L(@"Glass Dimming") action:nil keyEquivalent:@""];
    dimHeader.enabled = NO;
    BOOL (^dimApplies)(void) = ^BOOL {
        return [CCPetsPanelTheme() isEqualToString:@"liquid"] && CCPetsLiquidGlassAvailable();
    };
    NSDictionary<NSNumber *, NSString *> *dimTitles = @{
        @0: L(@"Clear (0%)"), @15: L(@"Light (15%)"), @25: L(@"Standard (25%)"), @45: L(@"Legible (45%)")};
    // 主窗口里可以调成任意值，菜单只有四档：勾选最接近的那档。
    NSInteger selectedDim = CCPetsNearestGlassDimLevel(CCPetsGlassDimLevel());
    for (NSNumber *level in CCPetsGlassDimLevels()) {
        NSMenuItem *item = [MenuChoiceRowView addToMenu:themeMenu title:dimTitles[level] group:@"dim"
            representedObject:level checked:level.integerValue == selectedDim
            target:NSApp.delegate action:@selector(setGlassDimLevel:) width:PetSubmenuRowWidth];
        MenuChoiceRowView *row = (MenuChoiceRowView *)item.view;
        row.indentation = 10;
        row.enabledHandler = dimApplies;
        row.enabled = dimApplies();
    }
    themeItem.submenu = themeMenu;
    // 启用和免审批会改 Claude Code / Codex 的配置，主窗口还没有对应入口，先留在这里。
    [self addBridgeMenuToMenu:menu];
    // 检查更新和关于收进「帮助」；有新版本时在顶层临时多一项「更新到 x.y.z…」，一步就能更新，
    // 不必展开子菜单。气泡和角标错过了，这里仍是醒目的入口。
    NSString *pendingVersion = self.pendingUpdateVersionRequested ? self.pendingUpdateVersionRequested() : nil;
    if (pendingVersion.length > 0) {
        NSMenuItem *installItem = [menu addItemWithTitle:
            [NSString stringWithFormat:L(@"Update to %@…"), pendingVersion]
            action:@selector(showPendingUpdate:) keyEquivalent:@""];
        installItem.target = NSApp.delegate;
    }
    NSMenuItem *helpItem = [menu addItemWithTitle:L(@"Help") action:nil keyEquivalent:@""];
    NSMenu *helpMenu = [NSMenu new];
    NSMenuItem *updateItem = [helpMenu addItemWithTitle:L(@"Check for Updates…") action:@selector(checkForUpdates:) keyEquivalent:@""];
    updateItem.target = NSApp.delegate;
    NSMenuItem *aboutItem = [helpMenu addItemWithTitle:L(@"About CC Pets") action:@selector(showAboutPanel:) keyEquivalent:@""];
    aboutItem.target = NSApp.delegate;
    helpItem.submenu = helpMenu;
    [menu addItem:NSMenuItem.separatorItem];
    // 主窗口：右键菜单装不下的设置和数据。⌘, 只是提示，和普通 App 的「设置…」一个位置一个键。
    NSMenuItem *openItem = [menu addItemWithTitle:L(@"Main menu")
        action:@selector(openMainWindow:) keyEquivalent:@","];
    openItem.target = NSApp.delegate;
    NSMenuItem *quitItem = [menu addItemWithTitle:L(@"Quit CC Pets") action:@selector(terminate:) keyEquivalent:@"q"];
    quitItem.target = NSApp;
    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
    [MenuHint cancel];
    self.activePetSwitchMenu = nil;
    [self.petMenuPreviewPanel orderOut:nil];
}
@end
