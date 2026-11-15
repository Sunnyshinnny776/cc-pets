#import "CCPetsStatusItem.h"
#import "CCPetsMenuBarSummary.h"
#import "CCPetsPreferences.h"
#import "CCPetsL10n.h"
#import "CCPetsUsagePage.h"

// 与右键会话菜单同一个上限。
static const NSUInteger StatusItemSessionLimit = 8;

static NSColor *LevelColor(CCPetsMenuBarLevel level) {
    switch (level) {
        case CCPetsMenuBarLevelCritical: return NSColor.systemRedColor;
        case CCPetsMenuBarLevelWarning: return NSColor.systemOrangeColor;
        default: return nil;
    }
}

static NSString *PercentText(id value) {
    if (![value isKindOfClass:NSNumber.class]) return @"--";
    return [NSString stringWithFormat:@"%ld%%", (long)floor([value doubleValue])];
}

// 和悬停面板一致：本机时区 M/d HH:mm。
static NSString *ResetText(id value) {
    if (![value isKindOfClass:NSNumber.class]) return nil;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"M/d HH:mm";
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:[value doubleValue]]];
}

@interface CCPetsStatusItemController ()
@property(nonatomic, weak) id<CCPetsWorkbenchSource, CCPetsPetCardSource> source;
@property(nonatomic) NSStatusItem *item;
@end

@implementation CCPetsStatusItemController

- (instancetype)initWithSource:(id<CCPetsWorkbenchSource, CCPetsPetCardSource>)source {
    if (!(self = [super init])) return nil;
    _source = source;
    _item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSImage *image = [NSImage imageWithSystemSymbolName:@"pawprint.fill" accessibilityDescription:@"CC Pets"];
    image.template = YES;
    _item.button.image = image;
    _item.button.toolTip = @"CC Pets";
    _item.button.target = self;
    _item.button.action = @selector(statusItemClicked:);
    [_item.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[CCPetsPetCardDidChangeNotification,
                                      CCPetsWorkbenchQuotasDidChangeNotification,
                                      CCPetsPreferencesDidChangeNotification,
                                      CCPetsLanguageDidChangeNotification]) {
        [center addObserver:self selector:@selector(sourceDidChange:) name:name object:nil];
    }
    [self refresh];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)invalidate {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (self.item) [NSStatusBar.systemStatusBar removeStatusItem:self.item];
    self.item = nil;
}

- (void)sourceDidChange:(NSNotification *)notification {
    [self refresh];
}

- (void)refresh {
    NSStatusBarButton *button = self.item.button;
    if (!button) return;
    NSUInteger approvals = [[self.source petCardSnapshot][@"approvals"] unsignedIntegerValue];
    NSDictionary *parts = CCPetsMenuBarTitleParts([self.source workbenchQuotas], approvals,
        CCPetsPrefBool(CCPetsMenuBarShowsPercentKey));
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightMedium];
    NSMutableAttributedString *title = [NSMutableAttributedString new];
    if (parts[@"percent"]) {
        NSMutableDictionary *attributes = [NSMutableDictionary dictionaryWithObject:font forKey:NSFontAttributeName];
        NSColor *color = LevelColor([parts[@"level"] integerValue]);
        if (color) attributes[NSForegroundColorAttributeName] = color;
        [title appendAttributedString:[[NSAttributedString alloc]
            initWithString:[@" " stringByAppendingString:parts[@"percent"]] attributes:attributes]];
    }
    if (parts[@"approvals"]) {
        // U+FE0E 让 ⚠ 按文字字形绘制，颜色才跟得上前景色；否则会是一枚彩色 emoji。
        [title appendAttributedString:[[NSAttributedString alloc]
            initWithString:[NSString stringWithFormat:@" ⚠︎%@", parts[@"approvals"]]
            attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.systemRedColor}]];
    }
    button.attributedTitle = title;
    button.imagePosition = title.length > 0 ? NSImageLeft : NSImageOnly;
    NSMutableArray<NSString *> *description = [NSMutableArray arrayWithObject:@"CC Pets"];
    if (parts[@"percent"]) [description addObject:parts[@"percent"]];
    if (parts[@"approvals"]) {
        [description addObject:[NSString stringWithFormat:L(@"%@ awaiting approval"), parts[@"approvals"]]];
    }
    [button setAccessibilityLabel:[description componentsJoinedByString:@", "]];
}

// 左右键共用一个 action：按下时临时挂上菜单再交给按钮弹出，弹完摘掉。
// 一直挂着 item.menu 的话左键也会直接弹它，就分不出两种菜单了。
- (void)statusItemClicked:(NSStatusBarButton *)sender {
    NSEvent *event = NSApp.currentEvent;
    BOOL secondary = event.type == NSEventTypeRightMouseUp ||
        (event.modifierFlags & NSEventModifierFlagControl) != 0;
    NSMenu *menu = secondary && self.contextMenuProvider ? self.contextMenuProvider() : [self quickMenu];
    if (!menu) return;
    self.item.menu = menu;
    [sender performClick:nil];
    self.item.menu = nil;
    if (secondary && self.contextMenuFinished) self.contextMenuFinished();
}

- (NSMenu *)quickMenu {
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    [self addSessionItemsToMenu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    NSArray<NSDictionary *> *quotas = [self.source workbenchQuotas];
    for (NSDictionary *quota in quotas) [menu addItem:[self itemForQuota:quota]];
    NSNumber *today = CCPetsMenuBarTodayTokens(quotas);
    NSMenuItem *todayItem = [menu addItemWithTitle:[NSString stringWithFormat:L(@"Today %@"),
        today ? CCPetsFormatTokens(today.unsignedLongLongValue) : @"--"] action:nil keyEquivalent:@""];
    todayItem.enabled = NO;
    [menu addItem:NSMenuItem.separatorItem];

    NSString *pending = self.pendingUpdateVersionProvider ? self.pendingUpdateVersionProvider() : nil;
    if (pending.length > 0) {
        NSMenuItem *update = [menu addItemWithTitle:[NSString stringWithFormat:L(@"Update to %@…"), pending]
            action:@selector(showUpdate:) keyEquivalent:@""];
        update.target = self;
    }
    NSMenuItem *pet = [menu addItemWithTitle:L(@"Show Pet") action:@selector(togglePet:) keyEquivalent:@""];
    pet.target = self;
    pet.state = self.petVisibleProvider && self.petVisibleProvider() ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem *open = [menu addItemWithTitle:L(@"Main menu") action:@selector(openMainWindow:) keyEquivalent:@","];
    open.target = self;
    NSMenuItem *quit = [menu addItemWithTitle:L(@"Quit CC Pets") action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    return menu;
}

- (void)addSessionItemsToMenu:(NSMenu *)menu {
    NSArray<NSDictionary *> *sessions = [self.source workbenchSessions];
    NSMenuItem *heading = [menu addItemWithTitle:L(@"Recent Agent Sessions") action:nil keyEquivalent:@""];
    heading.enabled = NO;
    if (sessions.count == 0) {
        NSMenuItem *empty = [menu addItemWithTitle:L(@"No sessions online.") action:nil keyEquivalent:@""];
        empty.enabled = NO;
        empty.indentationLevel = 1;
        return;
    }
    NSUInteger count = MIN(sessions.count, StatusItemSessionLimit);
    for (NSDictionary *session in [sessions subarrayWithRange:NSMakeRange(0, count)]) {
        BOOL approval = [session[@"state"] isEqual:@"approval"];
        NSString *name = [session[@"displayName"] isKindOfClass:NSString.class] && [session[@"displayName"] length] > 0
            ? session[@"displayName"] : session[@"provider"];
        NSMutableArray<NSString *> *fields = [NSMutableArray arrayWithObjects:name ?: @"Agent",
            session[@"status"] ?: @"", nil];
        if ([session[@"terminal"] length] > 0) [fields addObject:session[@"terminal"]];
        NSUInteger waiting = [session[@"pendingMessages"] unsignedIntegerValue];
        if (waiting > 0) [fields addObject:[NSString stringWithFormat:@"📬 %lu", (unsigned long)waiting]];
        NSString *title = [fields componentsJoinedByString:@" · "];
        if (approval) title = [@"⚠️ " stringByAppendingString:title];
        NSMenuItem *item = [menu addItemWithTitle:title action:@selector(focusSession:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = session[@"id"];
        item.indentationLevel = 1;
    }
}

// 两行：账号名，下面是 5 小时 / 本周剩余与重置时间（API 账号换成本月用量）。
// 点一下打开主窗口概览，那里有完整的账号卡片。
- (NSMenuItem *)itemForQuota:(NSDictionary *)quota {
    NSString *provider = quota[@"provider"] ?: @"Agent";
    NSString *profileName = [quota[@"profileName"] isKindOfClass:NSString.class] ? quota[@"profileName"] : nil;
    NSString *name = profileName.length > 0 && [profileName caseInsensitiveCompare:provider] != NSOrderedSame
        ? [NSString stringWithFormat:@"%@ · %@", provider, profileName] : provider;
    NSDictionary *usage = [quota[@"usage"] isKindOfClass:NSDictionary.class] ? quota[@"usage"] : @{};
    NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:name
        attributes:@{NSFontAttributeName: [NSFont menuFontOfSize:13]}];
    NSDictionary *detailAttributes = @{NSFontAttributeName: [NSFont menuFontOfSize:11],
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor};
    NSMutableAttributedString *detail = [NSMutableAttributedString new];
    if ([quota[@"apiMode"] boolValue]) {
        NSDictionary *tokens = [usage[@"tokenUsage"] isKindOfClass:NSDictionary.class] ? usage[@"tokenUsage"] : nil;
        NSDictionary *month = [tokens[@"month"] isKindOfClass:NSDictionary.class] ? tokens[@"month"] : nil;
        if (month) {
            NSString *total = CCPetsFormatTokens([month[@"total_tokens"] unsignedLongLongValue]);
            NSString *calls = [NSNumberFormatter localizedStringFromNumber:@([month[@"request_count"] unsignedLongLongValue])
                numberStyle:NSNumberFormatterDecimalStyle];
            [detail appendAttributedString:[[NSAttributedString alloc] initWithString:
                [NSString stringWithFormat:L(@"This month: %@ tokens · %@ calls"), total, calls]
                attributes:detailAttributes]];
        }
    } else if ([quota[@"state"] isEqual:@"limited"]) {
        NSMutableDictionary *attributes = [detailAttributes mutableCopy];
        attributes[NSForegroundColorAttributeName] = NSColor.systemRedColor;
        [detail appendAttributedString:[[NSAttributedString alloc] initWithString:L(@"Rate limited")
            attributes:attributes]];
    } else if (quota[@"fiveRemaining"] || quota[@"weekRemaining"]) {
        NSString *five = PercentText(quota[@"fiveRemaining"]);
        NSString *text = [NSString stringWithFormat:L(@"5h %@ · Week %@"), five, PercentText(quota[@"weekRemaining"])];
        [detail appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:detailAttributes]];
        // 5 小时那一格按阈值着色，和菜单栏标题同一个判断。
        NSColor *color = LevelColor(CCPetsMenuBarLevelForRemaining(
            CCPetsMenuBarLowestFiveHourRemaining(@[quota])));
        NSRange range = [text rangeOfString:five];
        if (color && range.location != NSNotFound) {
            [detail addAttribute:NSForegroundColorAttributeName value:color range:range];
        }
        NSString *reset = ResetText(quota[@"fiveReset"]);
        if (reset) {
            [detail appendAttributedString:[[NSAttributedString alloc] initWithString:
                [@" · " stringByAppendingString:[NSString stringWithFormat:L(@"Resets %@"), reset]]
                attributes:detailAttributes]];
        }
    }
    if (detail.length == 0 && [quota[@"status"] isKindOfClass:NSString.class]) {
        [detail appendAttributedString:[[NSAttributedString alloc] initWithString:quota[@"status"]
            attributes:detailAttributes]];
    }
    if (detail.length > 0) {
        [title appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
        [title appendAttributedString:detail];
    }
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:name action:@selector(openOverview:) keyEquivalent:@""];
    item.attributedTitle = title;
    item.target = self;
    return item;
}

- (void)focusSession:(NSMenuItem *)sender {
    NSString *sessionID = [sender.representedObject isKindOfClass:NSString.class] ? sender.representedObject : nil;
    if (sessionID) [self.source focusWorkbenchSessionWithID:sessionID];
}

- (void)openOverview:(id)sender {
    [CCPetsMainWindowController presentPage:CCPetsMainWindowPageOverview];
}

- (void)openMainWindow:(id)sender {
    [CCPetsMainWindowController presentPage:nil];
}

- (void)togglePet:(id)sender {
    if (self.togglePetVisible) self.togglePetVisible();
}

- (void)showUpdate:(id)sender {
    if (self.showPendingUpdate) self.showPendingUpdate();
}

@end
