#import "CCPetsMenuBarPanel.h"
#import "CCPetsStatusItem.h"
#import "CCPetsMenuBarSummary.h"
#import "CCPetsGlassView.h"
#import "CCPetsL10n.h"
#import "CCPetsUsagePage.h"

static const CGFloat PanelWidth = 300;
static const CGFloat PanelPadding = 6;
static const CGFloat RowInset = 14;
static const NSUInteger PanelSessionLimit = 5;

typedef void (^MenuBarRowDrawer)(NSRect bounds, BOOL hovered);

#pragma mark - 绘制小工具

static NSColor *PrimaryInk(void) { return [NSColor colorWithWhite:0.97 alpha:1]; }
static NSColor *SecondaryInk(void) { return [NSColor colorWithWhite:0.80 alpha:1]; }
static NSColor *TertiaryInk(void) { return [NSColor colorWithWhite:0.80 alpha:0.62]; }

// 与悬停面板同一组品牌色：Codex 青、Claude 紫（原生玻璃上提亮一档）。
static NSColor *ProviderColor(NSString *provider, BOOL liquid) {
    if ([provider isEqualToString:@"Claude"]) {
        return liquid ? [NSColor colorWithRed:0.80 green:0.66 blue:1.00 alpha:1]
            : [NSColor colorWithRed:0.66 green:0.43 blue:0.94 alpha:1];
    }
    return [NSColor colorWithRed:0.30 green:0.82 blue:0.90 alpha:1];
}

static NSColor *LevelColor(CCPetsMenuBarLevel level, NSColor *normal) {
    if (level == CCPetsMenuBarLevelCritical) return NSColor.systemRedColor;
    if (level == CCPetsMenuBarLevelWarning) return NSColor.systemOrangeColor;
    return normal;
}

// 单行文字，按 rect 垂直居中，放不下截尾。
static void DrawText(NSString *text, NSRect rect, CGFloat size, NSFontWeight weight,
    NSColor *color, NSTextAlignment alignment) {
    if (text.length == 0) return;
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineBreakMode = NSLineBreakByTruncatingTail;
    style.alignment = alignment;
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:size weight:weight],
        NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: style,
        NSShadowAttributeName: CCPetsGlassTextShadow()};
    CGFloat height = ceil([text sizeWithAttributes:attributes].height);
    [text drawInRect:NSMakeRect(NSMinX(rect), NSMidY(rect) - height / 2.0, NSWidth(rect), height)
        withAttributes:attributes];
}

static CGFloat TextWidth(NSString *text, CGFloat size, NSFontWeight weight) {
    if (text.length == 0) return 0;
    return ceil([text sizeWithAttributes:@{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:size weight:weight]}].width);
}

// 剩余额度环：底轨 + 从 12 点钟顺时针的剩余弧。fraction < 0 表示没有数据，只画底轨。
static void DrawRing(NSRect box, double fraction, NSColor *color) {
    NSRect ring = NSInsetRect(box, 2, 2);
    NSBezierPath *track = [NSBezierPath bezierPathWithOvalInRect:ring];
    track.lineWidth = 3;
    [[NSColor colorWithWhite:1 alpha:0.16] setStroke];
    [track stroke];
    if (fraction <= 0) return;
    NSBezierPath *arc = [NSBezierPath bezierPath];
    // 行视图是翻转坐标：y 向下，顺时针在这里要写成 clockwise:NO。
    [arc appendBezierPathWithArcWithCenter:NSMakePoint(NSMidX(ring), NSMidY(ring))
        radius:NSWidth(ring) / 2.0 startAngle:-90 endAngle:-90 + 360 * MIN(1, fraction) clockwise:NO];
    arc.lineWidth = 3;
    arc.lineCapStyle = NSLineCapStyleRound;
    [color setStroke];
    [arc stroke];
}

static void DrawDot(NSPoint center, CGFloat diameter, NSColor *color) {
    [color setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(center.x - diameter / 2.0,
        center.y - diameter / 2.0, diameter, diameter)] fill];
}

static NSString *PercentText(id value) {
    if (![value isKindOfClass:NSNumber.class] || !isfinite([value doubleValue])) return @"--";
    return [NSString stringWithFormat:@"%ld%%", (long)floor(fmax(0, fmin(100, [value doubleValue])))];
}

static NSString *ResetText(id value) {
    if (![value isKindOfClass:NSNumber.class]) return nil;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"M/d HH:mm";
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:[value doubleValue]]];
}

#pragma mark - 视图

// 一行：内容交给 drawer 画，有 action 才可点、才有悬停高亮。
@interface CCPetsMenuBarRow : NSView
@property(nonatomic, copy) MenuBarRowDrawer drawer;
@property(nonatomic, copy) void (^action)(void);
@end

@implementation CCPetsMenuBarRow {
    NSTrackingArea *_trackingArea;
    BOOL _hovered;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) [self removeTrackingArea:_trackingArea];
    _trackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:_trackingArea];
}
- (void)mouseEntered:(NSEvent *)event { _hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)event { _hovered = NO; self.needsDisplay = YES; }
- (void)mouseDown:(NSEvent *)event {}
- (void)mouseUp:(NSEvent *)event {
    if (!self.action) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(point, self.bounds)) self.action();
}
- (void)drawRect:(NSRect)dirtyRect {
    BOOL hovered = _hovered && self.action != nil;
    if (hovered) {
        [[NSColor colorWithWhite:1 alpha:0.14] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 6, 1) xRadius:7 yRadius:7] fill];
    }
    if (self.drawer) self.drawer(self.bounds, hovered);
}
@end

@interface CCPetsMenuBarDocument : NSView
@end
@implementation CCPetsMenuBarDocument
- (BOOL)isFlipped { return YES; }
@end

@interface CCPetsMenuBarWindow : NSPanel
@end
@implementation CCPetsMenuBarWindow
- (BOOL)canBecomeKeyWindow { return NO; }
@end

#pragma mark - 面板

@interface CCPetsMenuBarPanel ()
@property(nonatomic, weak) CCPetsStatusItemController *owner;
@property(nonatomic) CCPetsMenuBarWindow *window;
@property(nonatomic) CCPetsGlassView *glass;
@property(nonatomic, weak) NSStatusBarButton *button;
@property(nonatomic) id localMonitor;
@property(nonatomic) id globalMonitor;
@end

@implementation CCPetsMenuBarPanel

- (instancetype)initWithOwner:(CCPetsStatusItemController *)owner {
    if (!(self = [super init])) return nil;
    _owner = owner;
    return self;
}

- (BOOL)isShown {
    return self.window.isVisible;
}

- (void)dismiss {
    if (self.localMonitor) [NSEvent removeMonitor:self.localMonitor];
    if (self.globalMonitor) [NSEvent removeMonitor:self.globalMonitor];
    self.localMonitor = nil;
    self.globalMonitor = nil;
    [self.window orderOut:nil];
    self.window = nil;
    self.glass = nil;
    self.button.highlighted = NO;
}

- (void)showBelowButton:(NSStatusBarButton *)button {
    [self dismiss];
    if (!button.window) return;
    self.button = button;
    CCPetsMenuBarWindow *window = [[CCPetsMenuBarWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, PanelWidth, 100)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
    window.hasShadow = NO;
    window.level = NSPopUpMenuWindowLevel;
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorTransient;
    window.hidesOnDeactivate = NO;
    window.acceptsMouseMovedEvents = YES;
    CCPetsGlassView *glass = [[CCPetsGlassView alloc] initWithFrame:NSMakeRect(0, 0, PanelWidth, 100)
        material:NSVisualEffectMaterialMenu appearance:NSAppearanceNameDarkAqua cornerRadius:12];
    glass.edgeShadeHeight = 10;
    glass.edgeShadeAlpha = 0.6;
    glass.usesWidgetGlass = YES;
    glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    window.contentView = glass;
    self.window = window;
    self.glass = glass;
    [self layoutContent];
    [window orderFrontRegardless];
    // 按钮的 action 在松开鼠标时触发，AppKit 处理完这次点击会把高亮复位，所以放到下一轮再按下去。
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.isShown && self.button == button) button.highlighted = YES;
    });

    // 点面板以外就收起。点在菜单栏图标上的那一下留给图标自己的 action 去切换，
    // 否则这里先收起、紧接着 action 又打开，面板会关不掉。
    __weak typeof(self) weakSelf = self;
    NSEventMask mask = NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown;
    self.globalMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:mask handler:^(NSEvent *event) {
        [weakSelf dismiss];
    }];
    self.localMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask | NSEventMaskKeyDown
        handler:^NSEvent *(NSEvent *event) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return event;
        if (event.type == NSEventTypeKeyDown) {
            if (event.keyCode == 53) { [strongSelf dismiss]; return nil; }
            return event;
        }
        if (event.window != strongSelf.window && event.window != strongSelf.button.window) [strongSelf dismiss];
        return event;
    }];
}

- (void)reload {
    if (self.isShown) [self layoutContent];
}

// 按内容重排并定位：顶边贴在菜单栏图标下方，水平居中对齐图标，夹在屏幕可见区域内。
- (void)layoutContent {
    NSStatusBarButton *button = self.button;
    if (!self.window || !button.window) return;
    NSArray<CCPetsMenuBarRow *> *rows = [self buildRows];
    CGFloat contentHeight = 0;
    for (CCPetsMenuBarRow *row in rows) contentHeight += NSHeight(row.frame);
    NSRect buttonRect = [button.window convertRectToScreen:[button convertRect:button.bounds toView:nil]];
    NSRect visible = NSInsetRect((button.window.screen ?: NSScreen.mainScreen).visibleFrame, 4, 4);
    CGFloat height = MIN(contentHeight + PanelPadding * 2, NSHeight(visible));
    CGFloat x = MIN(MAX(NSMidX(buttonRect) - PanelWidth / 2.0, NSMinX(visible)), NSMaxX(visible) - PanelWidth);
    CGFloat top = MIN(NSMinY(buttonRect) - 4, NSMaxY(visible));
    [self.window setFrame:NSMakeRect(x, top - height, PanelWidth, height) display:NO];

    CCPetsMenuBarDocument *document = [[CCPetsMenuBarDocument alloc]
        initWithFrame:NSMakeRect(0, 0, PanelWidth, contentHeight)];
    CGFloat y = 0;
    for (CCPetsMenuBarRow *row in rows) {
        row.frame = NSMakeRect(0, y, PanelWidth, NSHeight(row.frame));
        [document addSubview:row];
        y += NSHeight(row.frame);
    }
    for (NSView *view in self.glass.contentView.subviews.copy) [view removeFromSuperview];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, PanelPadding,
        PanelWidth, height - PanelPadding * 2)];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.drawsBackground = NO;
    scroll.contentView.drawsBackground = NO;
    scroll.borderType = NSNoBorder;
    scroll.hasVerticalScroller = contentHeight > NSHeight(scroll.frame);
    scroll.autohidesScrollers = YES;
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    scroll.documentView = document;
    [self.glass.contentView addSubview:scroll];
}

#pragma mark - 内容

- (CCPetsMenuBarRow *)rowWithHeight:(CGFloat)height drawer:(MenuBarRowDrawer)drawer action:(void (^)(void))action {
    CCPetsMenuBarRow *row = [[CCPetsMenuBarRow alloc] initWithFrame:NSMakeRect(0, 0, PanelWidth, height)];
    row.drawer = drawer;
    row.action = action;
    return row;
}

- (CCPetsMenuBarRow *)separator {
    return [self rowWithHeight:11 drawer:^(NSRect bounds, BOOL hovered) {
        [[NSColor colorWithWhite:1 alpha:0.09] setFill];
        NSRectFill(NSMakeRect(RowInset, floor(NSMidY(bounds)), NSWidth(bounds) - RowInset * 2, 1));
    } action:nil];
}

// 分组标题：左边小号灰字，右边可选一段补充（额度组放今日用量）。
- (CCPetsMenuBarRow *)sectionTitle:(NSString *)title trailing:(NSString *)trailing {
    return [self rowWithHeight:22 drawer:^(NSRect bounds, BOOL hovered) {
        NSRect inner = NSInsetRect(bounds, RowInset, 0);
        DrawText(title, inner, 11, NSFontWeightSemibold, TertiaryInk(), NSTextAlignmentLeft);
        DrawText(trailing, inner, 11, NSFontWeightMedium, SecondaryInk(), NSTextAlignmentRight);
    } action:nil];
}

- (NSArray<CCPetsMenuBarRow *> *)buildRows {
    CCPetsStatusItemController *owner = self.owner;
    id<CCPetsWorkbenchSource, CCPetsPetCardSource> source = owner.source;
    if (!source) return @[];
    NSMutableArray<CCPetsMenuBarRow *> *rows = [NSMutableArray array];
    [rows addObject:[self headerRow:[source petCardSnapshot]]];
    [rows addObject:[self separator]];
    [rows addObjectsFromArray:[self sessionRows:[source workbenchSessions]]];
    [rows addObject:[self separator]];
    NSArray<NSDictionary *> *quotas = [source workbenchQuotas];
    NSNumber *today = CCPetsMenuBarTodayTokens(quotas);
    [rows addObject:[self sectionTitle:L(@"Quota") trailing:[NSString stringWithFormat:L(@"Today %@"),
        today ? CCPetsFormatTokens(today.unsignedLongLongValue) : @"--"]]];
    for (NSDictionary *quota in quotas) [rows addObject:[self quotaRow:quota]];
    [rows addObject:[self separator]];
    [rows addObjectsFromArray:[self footerRows]];
    return rows;
}

// 宠物名片：第一帧缩略图、名字、此刻在做什么；有人等审批时右边一枚红色胶囊。
- (CCPetsMenuBarRow *)headerRow:(NSDictionary *)snapshot {
    NSImage *sheet = [snapshot[@"sheet"] isKindOfClass:NSImage.class] ? snapshot[@"sheet"] : nil;
    NSInteger rowCount = MAX(1, [snapshot[@"rowCount"] integerValue]);
    NSString *name = [snapshot[@"name"] isKindOfClass:NSString.class] ? snapshot[@"name"] : @"CC Pets";
    NSString *status = [snapshot[@"status"] isKindOfClass:NSString.class] ? snapshot[@"status"] : @"";
    NSColor *statusColor = [snapshot[@"statusColor"] isKindOfClass:NSColor.class]
        ? snapshot[@"statusColor"] : SecondaryInk();
    NSUInteger approvals = [snapshot[@"approvals"] unsignedIntegerValue];
    return [self rowWithHeight:50 drawer:^(NSRect bounds, BOOL hovered) {
        CGFloat x = RowInset;
        if (sheet) {
            // 精灵图 8 列；第一行第一格是默认待机帧。翻转视图里按图片自身坐标取格子。
            NSSize cell = NSMakeSize(sheet.size.width / 8.0, sheet.size.height / rowCount);
            CGFloat height = 40, width = height * cell.width / MAX(1, cell.height);
            [sheet drawInRect:NSMakeRect(x - 4, NSMidY(bounds) - height / 2.0, width, height)
                fromRect:NSMakeRect(0, sheet.size.height - cell.height, cell.width, cell.height)
                operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
            x += width;
        }
        CGFloat badgeWidth = 0;
        if (approvals > 0) {
            NSString *badge = [NSString stringWithFormat:@"⚠︎ %lu", (unsigned long)approvals];
            badgeWidth = TextWidth(badge, 11, NSFontWeightSemibold) + 14;
            NSRect pill = NSMakeRect(NSMaxX(bounds) - RowInset - badgeWidth, NSMidY(bounds) - 10, badgeWidth, 20);
            [[NSColor.systemRedColor colorWithAlphaComponent:0.85] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:10 yRadius:10] fill];
            DrawText(badge, pill, 11, NSFontWeightSemibold, NSColor.whiteColor, NSTextAlignmentCenter);
            badgeWidth += 8;
        }
        CGFloat textWidth = NSMaxX(bounds) - RowInset - badgeWidth - x;
        DrawText(name, NSMakeRect(x, NSMidY(bounds) - 17, textWidth, 18), 13, NSFontWeightSemibold,
            PrimaryInk(), NSTextAlignmentLeft);
        DrawDot(NSMakePoint(x + 3.5, NSMidY(bounds) + 9), 7, statusColor);
        DrawText(status, NSMakeRect(x + 12, NSMidY(bounds) + 1, textWidth - 12, 16), 11, NSFontWeightRegular,
            SecondaryInk(), NSTextAlignmentLeft);
    } action:nil];
}

- (NSArray<CCPetsMenuBarRow *> *)sessionRows:(NSArray<NSDictionary *> *)sessions {
    NSMutableArray<CCPetsMenuBarRow *> *rows = [NSMutableArray array];
    [rows addObject:[self sectionTitle:L(@"Sessions") trailing:nil]];
    if (sessions.count == 0) {
        [rows addObject:[self rowWithHeight:26 drawer:^(NSRect bounds, BOOL hovered) {
            DrawText(L(@"No sessions online."), NSInsetRect(bounds, RowInset, 0), 12, NSFontWeightRegular,
                SecondaryInk(), NSTextAlignmentLeft);
        } action:nil]];
        return rows;
    }
    __weak typeof(self) weakSelf = self;
    NSColor *(^stateColor)(NSString *) = self.owner.stateColorProvider;
    NSUInteger shown = MIN(sessions.count, PanelSessionLimit);
    for (NSDictionary *session in [sessions subarrayWithRange:NSMakeRange(0, shown)]) {
        NSString *display = [session[@"displayName"] isKindOfClass:NSString.class] ? session[@"displayName"] : @"";
        NSString *name = display.length > 0 ? display : (session[@"provider"] ?: @"Agent");
        NSString *state = [session[@"state"] isKindOfClass:NSString.class] ? session[@"state"] : @"";
        NSString *status = session[@"status"] ?: @"";
        NSString *terminal = [session[@"terminal"] isKindOfClass:NSString.class] ? session[@"terminal"] : @"";
        NSUInteger waiting = [session[@"pendingMessages"] unsignedIntegerValue];
        NSColor *dotColor = (stateColor ? stateColor(state) : nil) ?: SecondaryInk();
        BOOL approval = [state isEqualToString:@"approval"];
        NSString *sessionID = session[@"id"];
        CCPetsMenuBarRow *row = [self rowWithHeight:28 drawer:^(NSRect bounds, BOOL hovered) {
            DrawDot(NSMakePoint(RowInset + 4, NSMidY(bounds)), 8, dotColor);
            NSString *trailing = waiting > 0
                ? [NSString stringWithFormat:@"%@ · ✉︎ %lu", status, (unsigned long)waiting] : status;
            CGFloat trailingWidth = MIN(TextWidth(trailing, 11, NSFontWeightMedium), 130);
            NSRect inner = NSMakeRect(RowInset + 16, NSMinY(bounds), NSWidth(bounds) - RowInset * 2 - 16, NSHeight(bounds));
            DrawText(trailing, inner, 11, NSFontWeightMedium,
                approval ? NSColor.systemOrangeColor : SecondaryInk(), NSTextAlignmentRight);
            DrawText(name, NSMakeRect(NSMinX(inner), NSMinY(inner), NSWidth(inner) - trailingWidth - 10, NSHeight(inner)),
                13, NSFontWeightRegular, PrimaryInk(), NSTextAlignmentLeft);
        } action:^{
            [weakSelf dismiss];
            [weakSelf.owner.source focusWorkbenchSessionWithID:sessionID];
        }];
        row.toolTip = terminal.length > 0 ? [NSString stringWithFormat:@"%@ · %@", name, terminal] : name;
        [rows addObject:row];
    }
    if (sessions.count > shown) {
        NSString *more = [NSString stringWithFormat:L(@"%@ more sessions…"), @(sessions.count - shown)];
        [rows addObject:[self rowWithHeight:24 drawer:^(NSRect bounds, BOOL hovered) {
            DrawText(more, NSInsetRect(bounds, RowInset + 16, 0), 11, NSFontWeightMedium, SecondaryInk(),
                NSTextAlignmentLeft);
        } action:^{
            [weakSelf dismiss];
            [CCPetsMainWindowController presentPage:CCPetsMainWindowPageSessions];
        }]];
    }
    return rows;
}

// 订阅账号：5 小时额度环 + 大号百分比，第二行本周剩余与重置时间。
// API 账号：右边是本月 Token，第二行本月调用次数。点击都打开主窗口概览。
- (CCPetsMenuBarRow *)quotaRow:(NSDictionary *)quota {
    NSString *provider = [quota[@"provider"] isKindOfClass:NSString.class] ? quota[@"provider"] : @"Agent";
    NSString *profileName = [quota[@"profileName"] isKindOfClass:NSString.class] ? quota[@"profileName"] : nil;
    NSString *name = profileName.length > 0 && [profileName caseInsensitiveCompare:provider] != NSOrderedSame
        ? [NSString stringWithFormat:@"%@ · %@", provider, profileName] : provider;
    BOOL api = [quota[@"apiMode"] boolValue];
    BOOL limited = [quota[@"state"] isEqual:@"limited"];
    NSDictionary *usage = [quota[@"usage"] isKindOfClass:NSDictionary.class] ? quota[@"usage"] : @{};
    NSDictionary *tokens = [usage[@"tokenUsage"] isKindOfClass:NSDictionary.class] ? usage[@"tokenUsage"] : nil;
    NSDictionary *month = [tokens[@"month"] isKindOfClass:NSDictionary.class] ? tokens[@"month"] : nil;
    NSString *status = [quota[@"status"] isKindOfClass:NSString.class] ? quota[@"status"] : @"";
    BOOL liquid = self.glass.usesLiquidGlass;
    NSColor *brand = ProviderColor(provider, liquid);

    NSInteger remaining = CCPetsMenuBarLowestFiveHourRemaining(@[quota]);
    NSColor *accent = LevelColor(CCPetsMenuBarLevelForRemaining(remaining), brand);
    NSString *value, *detail;
    NSColor *valueColor = PrimaryInk();
    if (api) {
        value = month ? CCPetsFormatTokens([month[@"total_tokens"] unsignedLongLongValue]) : @"--";
        detail = month ? [NSString stringWithFormat:L(@"This month · %@ calls"),
            [NSNumberFormatter localizedStringFromNumber:@([month[@"request_count"] unsignedLongLongValue])
                numberStyle:NSNumberFormatterDecimalStyle]] : status;
    } else if (limited) {
        value = L(@"Rate limited");
        valueColor = NSColor.systemRedColor;
        NSString *reset = ResetText(quota[@"fiveReset"]);
        detail = reset ? [NSString stringWithFormat:L(@"Resets %@"), reset] : status;
    } else if (remaining >= 0 || quota[@"weekRemaining"]) {
        value = remaining >= 0 ? PercentText(quota[@"fiveRemaining"]) : @"--";
        if (remaining >= 0 && accent != brand) valueColor = accent;
        NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:
            [NSString stringWithFormat:L(@"Week %@"), PercentText(quota[@"weekRemaining"])]];
        NSString *reset = ResetText(quota[@"fiveReset"]);
        if (reset) [parts addObject:[NSString stringWithFormat:L(@"Resets %@"), reset]];
        detail = [parts componentsJoinedByString:@" · "];
    } else {
        value = @"";
        detail = status;
    }
    double fraction = api ? -1 : (limited ? 0 : (remaining >= 0 ? remaining / 100.0 : -1));
    __weak typeof(self) weakSelf = self;
    CCPetsMenuBarRow *row = [self rowWithHeight:44 drawer:^(NSRect bounds, BOOL hovered) {
        NSRect ringBox = NSMakeRect(RowInset, NSMidY(bounds) - 13, 26, 26);
        if (api) {
            // API 账号没有额度窗口：只画一个品牌色实心点，和订阅账号的环对齐。
            DrawDot(NSMakePoint(NSMidX(ringBox), NSMidY(ringBox)), 10, brand);
        } else {
            DrawRing(ringBox, fraction, accent);
        }
        CGFloat x = NSMaxX(ringBox) + 10;
        CGFloat valueWidth = TextWidth(value, 15, NSFontWeightSemibold);
        NSRect valueRect = NSMakeRect(NSMaxX(bounds) - RowInset - valueWidth, NSMinY(bounds), valueWidth, NSHeight(bounds));
        DrawText(value, valueRect, 15, NSFontWeightSemibold, valueColor, NSTextAlignmentRight);
        CGFloat textWidth = NSMinX(valueRect) - 8 - x;
        DrawText(name, NSMakeRect(x, NSMidY(bounds) - 17, textWidth, 17), 13, NSFontWeightMedium,
            PrimaryInk(), NSTextAlignmentLeft);
        DrawText(detail, NSMakeRect(x, NSMidY(bounds) + 1, textWidth, 15), 11, NSFontWeightRegular,
            SecondaryInk(), NSTextAlignmentLeft);
    } action:^{
        [weakSelf dismiss];
        [CCPetsMainWindowController presentPage:CCPetsMainWindowPageOverview];
    }];
    return row;
}

// 底部：有新版本时的更新入口、显示桌宠开关、打开主菜单。退出在右键菜单里。
- (NSArray<CCPetsMenuBarRow *> *)footerRows {
    CCPetsStatusItemController *owner = self.owner;
    __weak typeof(self) weakSelf = self;
    NSMutableArray<CCPetsMenuBarRow *> *rows = [NSMutableArray array];
    NSString *pending = owner.pendingUpdateVersionProvider ? owner.pendingUpdateVersionProvider() : nil;
    if (pending.length > 0) {
        NSString *title = [NSString stringWithFormat:L(@"Update to %@…"), pending];
        [rows addObject:[self footerRowWithTitle:title symbol:@"arrow.up.circle.fill"
            tint:[NSColor colorWithRed:0.30 green:0.82 blue:0.90 alpha:1] trailing:nil action:^{
            [weakSelf dismiss];
            if (weakSelf.owner.showPendingUpdate) weakSelf.owner.showPendingUpdate();
        }]];
    }
    BOOL petVisible = owner.petVisibleProvider && owner.petVisibleProvider();
    [rows addObject:[self footerRowWithTitle:L(@"Show Pet") symbol:petVisible ? @"checkmark.circle.fill" : @"circle"
        tint:petVisible ? NSColor.systemGreenColor : SecondaryInk() trailing:nil action:^{
        if (weakSelf.owner.togglePetVisible) weakSelf.owner.togglePetVisible();
        [weakSelf reload];
    }]];
    [rows addObject:[self footerRowWithTitle:L(@"Main menu") symbol:@"macwindow" tint:SecondaryInk()
        trailing:@"⌘," action:^{
        [weakSelf dismiss];
        [CCPetsMainWindowController presentPage:nil];
    }]];
    return rows;
}

- (CCPetsMenuBarRow *)footerRowWithTitle:(NSString *)title symbol:(NSString *)symbol tint:(NSColor *)tint
    trailing:(NSString *)trailing action:(void (^)(void))action {
    NSImage *icon = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:12
            weight:NSFontWeightMedium]];
    CCPetsMenuBarRow *row = [self rowWithHeight:28 drawer:^(NSRect bounds, BOOL hovered) {
        if (icon) {
            NSImage *tinted = [NSImage imageWithSize:icon.size flipped:NO drawingHandler:^BOOL(NSRect rect) {
                [icon drawInRect:rect];
                [tint set];
                NSRectFillUsingOperation(rect, NSCompositingOperationSourceAtop);
                return YES;
            }];
            [tinted drawInRect:NSMakeRect(RowInset, NSMidY(bounds) - icon.size.height / 2.0,
                icon.size.width, icon.size.height) fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
        }
        NSRect inner = NSMakeRect(RowInset + 22, NSMinY(bounds), NSWidth(bounds) - RowInset * 2 - 22, NSHeight(bounds));
        DrawText(trailing, inner, 11, NSFontWeightRegular, TertiaryInk(), NSTextAlignmentRight);
        DrawText(title, inner, 13, NSFontWeightRegular, PrimaryInk(), NSTextAlignmentLeft);
    } action:action];
    return row;
}

@end
