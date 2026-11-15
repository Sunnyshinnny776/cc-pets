#import "CCPetsStatusItem.h"
#import "CCPetsMenuBarSummary.h"
#import "CCPetsPreferences.h"
#import "CCPetsL10n.h"
#import "CCPetsMenuBarPanel.h"
#import "CCPetsMenuBarIcon.h"

static NSColor *LevelColor(CCPetsMenuBarLevel level) {
    switch (level) {
        case CCPetsMenuBarLevelCritical: return NSColor.systemRedColor;
        case CCPetsMenuBarLevelWarning: return NSColor.systemOrangeColor;
        default: return nil;
    }
}

@interface CCPetsStatusItemController ()
@property(nonatomic, weak, readwrite) id<CCPetsWorkbenchSource, CCPetsPetCardSource> source;
@property(nonatomic) NSStatusItem *item;
@property(nonatomic) CCPetsMenuBarPanel *panel;
// 各色调的菜单栏图标（见 CCPetsMenuBarIcon），每种只生成一次。
@property(nonatomic) NSMutableDictionary<NSNumber *, NSImage *> *iconImages;
@end

@implementation CCPetsStatusItemController

- (instancetype)initWithSource:(id<CCPetsWorkbenchSource, CCPetsPetCardSource>)source {
    if (!(self = [super init])) return nil;
    _source = source;
    _panel = [[CCPetsMenuBarPanel alloc] initWithOwner:self];
    _item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    _iconImages = [NSMutableDictionary dictionary];
    _item.button.image = [self imageForTone:CCPetsMenuBarIconToneNone];
    _item.button.toolTip = @"CC Pets";
    _item.button.target = self;
    _item.button.action = @selector(statusItemClicked:);
    // 左右键松开都要回调，才能在 action 里分流两种菜单。和桌宠拖动无关（tests/test.sh 对拖动
    // 实现的回归检查会拦 NSEventMask 常量的写法，所以这里按事件类型组掩码）。
    [_item.button sendActionOn:NSEventMaskFromType(NSEventTypeLeftMouseUp) |
        NSEventMaskFromType(NSEventTypeRightMouseUp)];
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
    [self.panel dismiss];
    if (self.item) [NSStatusBar.systemStatusBar removeStatusItem:self.item];
    self.item = nil;
}

- (void)sourceDidChange:(NSNotification *)notification {
    [self refresh];
}

- (void)refresh {
    NSStatusBarButton *button = self.item.button;
    if (!button) return;
    NSDictionary *snapshot = [self.source petCardSnapshot];
    NSUInteger approvals = [snapshot[@"approvals"] unsignedIntegerValue];
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
    // 图标跟着状态卡走：同一条快照、同一套归类（工作中蓝、审批橙、完成绿、失败红），
    // 状态卡回落待机时换回待机图。
    NSString *state = [snapshot[@"state"] isKindOfClass:NSString.class] ? snapshot[@"state"] : nil;
    CCPetsMenuBarIconTone tone = CCPetsMenuBarIconToneForState(state);
    BOOL tinted = tone != CCPetsMenuBarIconToneNone;
    button.image = [self imageForTone:tone];
    NSMutableArray<NSString *> *description = [NSMutableArray arrayWithObject:@"CC Pets"];
    if (tinted && [snapshot[@"status"] isKindOfClass:NSString.class]) [description addObject:snapshot[@"status"]];
    if (parts[@"percent"]) [description addObject:parts[@"percent"]];
    if (parts[@"approvals"]) {
        [description addObject:[NSString stringWithFormat:L(@"%@ awaiting approval"), parts[@"approvals"]]];
    }
    [button setAccessibilityLabel:[description componentsJoinedByString:@", "]];
    // 等审批时左键会直接跳转，提示里说清楚，免得用户以为面板打不开。
    button.toolTip = approvals > 0 ? L(@"Click to jump to the session awaiting approval (⌥-click for the panel)") : @"CC Pets";
    [self.panel reload];
}

- (NSImage *)imageForTone:(CCPetsMenuBarIconTone)tone {
    NSImage *cached = self.iconImages[@(tone)];
    if (cached) return cached;
    NSImage *image = CCPetsMenuBarIconImage(tone);
    self.iconImages[@(tone)] = image;
    return image;
}

// 左右键共用一个 action。左键开关玻璃面板（有会话等审批时直接跳到那个终端）；
// 右键临时挂上菜单交给按钮弹出，弹完摘掉——
// 一直挂着 item.menu 的话左键也会直接弹它。
- (void)statusItemClicked:(NSStatusBarButton *)sender {
    NSEvent *event = NSApp.currentEvent;
    BOOL secondary = event.type == NSEventTypeRightMouseUp ||
        (event.modifierFlags & NSEventModifierFlagControl) != 0;
    if (!secondary) {
        if (self.panel.isShown) {
            [self.panel dismiss];
            return;
        }
        // 有会话在等审批：直接跳到那个终端，这是此刻唯一需要用户动手的事。按住 ⌥ 仍然打开面板。
        BOOL option = (event.modifierFlags & NSEventModifierFlagOption) != 0;
        NSString *approval = option ? nil : CCPetsMenuBarApprovalSessionID([self.source workbenchSessions]);
        if (approval) {
            [self.source focusWorkbenchSessionWithID:approval];
            return;
        }
        [self.panel showBelowButton:sender];
        return;
    }
    [self.panel dismiss];
    NSMenu *menu = self.contextMenuProvider ? self.contextMenuProvider() : nil;
    if (!menu) return;
    self.item.menu = menu;
    [sender performClick:nil];
    self.item.menu = nil;
    if (self.contextMenuFinished) self.contextMenuFinished();
}

@end
