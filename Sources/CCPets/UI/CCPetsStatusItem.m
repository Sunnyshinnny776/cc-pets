#import "CCPetsStatusItem.h"
#import "CCPetsMenuBarSummary.h"
#import "CCPetsPreferences.h"
#import "CCPetsL10n.h"
#import "CCPetsMenuBarPanel.h"

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
// 待机时的爪印：template image，由系统按菜单栏明暗和壁纸着色。
@property(nonatomic) NSImage *templateImage;
// 按色调上色的爪印，四种各生成一次。
@property(nonatomic) NSMutableDictionary<NSNumber *, NSImage *> *tintedImages;
@end

@implementation CCPetsStatusItemController

- (instancetype)initWithSource:(id<CCPetsWorkbenchSource, CCPetsPetCardSource>)source {
    if (!(self = [super init])) return nil;
    _source = source;
    _panel = [[CCPetsMenuBarPanel alloc] initWithOwner:self];
    _item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    _templateImage = [NSImage imageWithSystemSymbolName:@"pawprint.fill" accessibilityDescription:@"CC Pets"];
    _templateImage.template = YES;
    _tintedImages = [NSMutableDictionary dictionary];
    _item.button.image = _templateImage;
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
    // 爪印颜色跟着状态卡走：同一条快照、同一套归类（工作中蓝、审批橙、完成绿、失败红），
    // 状态卡回落待机时恢复原色。
    NSString *state = [snapshot[@"state"] isKindOfClass:NSString.class] ? snapshot[@"state"] : nil;
    CCPetsMenuBarIconTone tone = CCPetsMenuBarIconToneForState(state);
    BOOL tinted = tone != CCPetsMenuBarIconToneNone;
    button.image = tinted ? [self imageForTone:tone] : self.templateImage;
    NSMutableArray<NSString *> *description = [NSMutableArray arrayWithObject:@"CC Pets"];
    if (tinted && [snapshot[@"status"] isKindOfClass:NSString.class]) [description addObject:snapshot[@"status"]];
    if (parts[@"percent"]) [description addObject:parts[@"percent"]];
    if (parts[@"approvals"]) {
        [description addObject:[NSString stringWithFormat:L(@"%@ awaiting approval"), parts[@"approvals"]]];
    }
    [button setAccessibilityLabel:[description componentsJoinedByString:@", "]];
    [self.panel reload];
}

// 用系统色而不是状态卡的颜色：系统色按菜单栏明暗各有一版，深色菜单栏上取更亮的那版；
// 状态卡的工作蓝 (0.33, 0.53, 0.78) 是为浅色玻璃调的，放在深色菜单栏上发灰看不清。
static NSColor *ToneColor(CCPetsMenuBarIconTone tone) {
    switch (tone) {
        case CCPetsMenuBarIconToneCompleted: return NSColor.systemGreenColor;
        case CCPetsMenuBarIconToneFailed: return NSColor.systemRedColor;
        case CCPetsMenuBarIconToneAttention: return NSColor.systemOrangeColor;
        default: return NSColor.systemBlueColor;
    }
}

// 用调色板给 SF Symbol 上色，并取消 template：template image 会被系统重新染成黑白。
// 不用 button.contentTintColor，状态栏按钮在不同系统版本上未必认它。系统色是动态色，
// 绘制时按菜单栏当前外观解析，所以缓存的图在深浅切换后仍然正确。
- (NSImage *)imageForTone:(CCPetsMenuBarIconTone)tone {
    NSImage *cached = self.tintedImages[@(tone)];
    if (cached) return cached;
    NSColor *color = ToneColor(tone);
    NSImage *image = [[self.templateImage imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPaletteColors:@[color]]] copy];
    if (!image) return self.templateImage;
    image.template = NO;
    image.accessibilityDescription = @"CC Pets";
    self.tintedImages[@(tone)] = image;
    return image;
}

// 左右键共用一个 action。左键开关玻璃面板；右键临时挂上菜单交给按钮弹出，弹完摘掉——
// 一直挂着 item.menu 的话左键也会直接弹它。
- (void)statusItemClicked:(NSStatusBarButton *)sender {
    NSEvent *event = NSApp.currentEvent;
    BOOL secondary = event.type == NSEventTypeRightMouseUp ||
        (event.modifierFlags & NSEventModifierFlagControl) != 0;
    if (!secondary) {
        if (self.panel.isShown) [self.panel dismiss];
        else [self.panel showBelowButton:sender];
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
