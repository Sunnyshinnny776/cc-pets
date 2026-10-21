#import "CCPetsGlassMenu.h"
#import "CCPetsGlassView.h"

static const CGFloat GlassMenuRowHeight = 24;
static const CGFloat GlassMenuSeparatorHeight = 11;
static const CGFloat GlassMenuPadding = 6;
static const CGFloat GlassMenuTextInset = 30;

static NSShadow *GlassMenuTextShadow(void) {
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.45];
    shadow.shadowBlurRadius = 2;
    shadow.shadowOffset = NSMakeSize(0, -0.5);
    return shadow;
}

@interface CCPetsGlassMenuRow : NSView
@property(nonatomic, strong) NSMenuItem *item;
@end

@implementation CCPetsGlassMenuRow {
    NSTrackingArea *_trackingArea;
    BOOL _hovered;
}
- (BOOL)selectable { return self.item.isEnabled && self.item.action != nil; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
// 这是独立的面板窗口，不在菜单跟踪循环里，进出事件是可靠的。
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
    if (![self selectable]) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (!NSPointInRect(point, self.bounds)) return;
    NSMenuItem *item = self.item;
    [CCPetsGlassMenu dismiss];
    [NSApp sendAction:item.action to:item.target from:item];
}
- (void)drawRect:(NSRect)dirtyRect {
    NSMenuItem *item = self.item;
    if (item.isSeparatorItem) {
        [[NSColor colorWithWhite:1 alpha:0.18] setFill];
        NSRectFill(NSMakeRect(12, floor(NSMidY(self.bounds)), NSWidth(self.bounds) - 24, 1));
        return;
    }
    BOOL highlighted = _hovered && [self selectable];
    if (highlighted) {
        [NSColor.selectedContentBackgroundColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 5, 0)
            xRadius:6 yRadius:6] fill];
    }
    // 标题行（不可点）用浅一档的白，和系统菜单的分组标题一致。
    NSColor *color = [self selectable] ? [NSColor colorWithWhite:1 alpha:0.96]
        : [NSColor colorWithWhite:1 alpha:0.72];
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attributes = @{NSFontAttributeName: [NSFont menuFontOfSize:13],
        NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: style,
        NSShadowAttributeName: highlighted ? [NSShadow new] : GlassMenuTextShadow()};
    CGFloat textHeight = ceil([item.title sizeWithAttributes:attributes].height);
    NSRect textRect = NSMakeRect(GlassMenuTextInset, (NSHeight(self.bounds) - textHeight) / 2.0,
        NSWidth(self.bounds) - GlassMenuTextInset - 14, textHeight);
    [item.title drawInRect:textRect withAttributes:attributes];
    if (item.state == NSControlStateValueOn) {
        [@"✓" drawAtPoint:NSMakePoint(13, NSMinY(textRect)) withAttributes:attributes];
    }
}
@end

// 翻转坐标，行从上往下排，滚动视图默认停在顶部。
@interface CCPetsGlassMenuDocument : NSView
@end
@implementation CCPetsGlassMenuDocument
- (BOOL)isFlipped { return YES; }
@end

@interface CCPetsGlassMenuPanel : NSPanel
@end
@implementation CCPetsGlassMenuPanel
- (BOOL)canBecomeKeyWindow { return NO; }
@end

static CCPetsGlassMenuPanel *ActivePanel;
static id LocalMonitor;
static id GlobalMonitor;

@implementation CCPetsGlassMenu
+ (void)dismiss {
    if (LocalMonitor) [NSEvent removeMonitor:LocalMonitor];
    if (GlobalMonitor) [NSEvent removeMonitor:GlobalMonitor];
    LocalMonitor = nil;
    GlobalMonitor = nil;
    [ActivePanel orderOut:nil];
    ActivePanel = nil;
}

+ (void)showMenu:(NSMenu *)menu belowView:(NSView *)anchor alignRightTo:(NSView *)alignView {
    [self dismiss];
    NSWindow *anchorWindow = anchor.window;
    if (!anchorWindow) return;
    NSDictionary *measure = @{NSFontAttributeName: [NSFont menuFontOfSize:13]};
    CGFloat textWidth = 0, contentHeight = 0;
    for (NSMenuItem *item in menu.itemArray) {
        if (item.isHidden) continue;
        contentHeight += item.isSeparatorItem ? GlassMenuSeparatorHeight : GlassMenuRowHeight;
        textWidth = MAX(textWidth, ceil([item.title sizeWithAttributes:measure].width));
    }
    CGFloat width = MIN(MAX(textWidth + GlassMenuTextInset + 20, 220), 560);

    NSRect anchorRect = [anchorWindow convertRectToScreen:[anchor convertRect:anchor.bounds toView:nil]];
    NSRect alignRect = [anchorWindow convertRectToScreen:[alignView convertRect:alignView.bounds toView:nil]];
    NSRect visible = NSInsetRect((anchorWindow.screen ?: NSScreen.mainScreen).visibleFrame, 4, 4);
    // 会话、消息多的时候不能无限长：限高，超出部分在面板内滚动。
    CGFloat height = MIN(contentHeight + GlassMenuPadding * 2, MIN(420, NSHeight(visible)));
    CGFloat x = NSMaxX(alignRect) - width;
    x = MIN(MAX(x, NSMinX(visible)), NSMaxX(visible) - width);
    // 优先放在状态卡下方，放不下再放上方；两边都放不下时夹在屏幕可见区域内（会盖住状态卡）。
    CGFloat below = NSMinY(anchorRect) - 6 - height;
    CGFloat above = NSMaxY(anchorRect) + 6;
    CGFloat y = below >= NSMinY(visible) ? below
        : (above + height <= NSMaxY(visible) ? above : below);
    y = MIN(MAX(y, NSMinY(visible)), NSMaxY(visible) - height);

    CCPetsGlassMenuPanel *panel = [[CCPetsGlassMenuPanel alloc]
        initWithContentRect:NSMakeRect(x, y, width, height)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    panel.opaque = NO;
    panel.backgroundColor = NSColor.clearColor;
    panel.hasShadow = NO;
    panel.level = anchorWindow.level + 1;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.hidesOnDeactivate = NO;
    panel.acceptsMouseMovedEvents = YES;

    CCPetsGlassView *glass = [[CCPetsGlassView alloc] initWithFrame:NSMakeRect(0, 0, width, height)
        material:NSVisualEffectMaterialMenu appearance:NSAppearanceNameDarkAqua cornerRadius:12];
    glass.edgeShadeHeight = 10;
    glass.edgeShadeAlpha = 0.6;
    glass.usesWidgetGlass = YES;
    CCPetsGlassMenuDocument *document = [[CCPetsGlassMenuDocument alloc]
        initWithFrame:NSMakeRect(0, 0, width, contentHeight)];
    CGFloat rowY = 0;
    for (NSMenuItem *item in menu.itemArray) {
        if (item.isHidden) continue;
        CGFloat rowHeight = item.isSeparatorItem ? GlassMenuSeparatorHeight : GlassMenuRowHeight;
        CCPetsGlassMenuRow *row = [[CCPetsGlassMenuRow alloc]
            initWithFrame:NSMakeRect(0, rowY, width, rowHeight)];
        row.item = item;
        if (item.toolTip.length > 0) row.toolTip = item.toolTip;
        [document addSubview:row];
        rowY += rowHeight;
    }
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, GlassMenuPadding,
        width, height - GlassMenuPadding * 2)];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.drawsBackground = NO;
    scroll.contentView.drawsBackground = NO;
    scroll.borderType = NSNoBorder;
    scroll.hasVerticalScroller = contentHeight > NSHeight(scroll.frame);
    scroll.autohidesScrollers = YES;
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    scroll.documentView = document;
    [glass.contentView addSubview:scroll];
    panel.contentView = glass;
    [panel orderFrontRegardless];
    ActivePanel = panel;

    // 点面板以外的任何地方就收起，和系统菜单一致。桌宠是非激活 App，大部分点击落在别的
    // App 上，要靠全局监听；落在本 App 其他窗口（宠物、状态卡）上的走本地监听。
    NSEventMask mask = NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown;
    GlobalMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:mask handler:^(NSEvent *event) {
        [CCPetsGlassMenu dismiss];
    }];
    // 键盘：面板刻意不抢焦点（抢了会把前台终端的焦点夺走），所以只有本 App 恰好在前台时
    // Esc 才生效，也不支持方向键选择。这是替代系统菜单的已知取舍，不用全局键盘监听来补。
    LocalMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask | NSEventMaskKeyDown
        handler:^NSEvent *(NSEvent *event) {
            if (event.type == NSEventTypeKeyDown) {
                if (event.keyCode == 53) { [CCPetsGlassMenu dismiss]; return nil; }
                return event;
            }
            if (event.window != ActivePanel) [CCPetsGlassMenu dismiss];
            return event;
        }];
}
@end
