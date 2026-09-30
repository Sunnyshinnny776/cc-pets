#import "MenuHintView.h"

// 与系统 toolTip 的节奏接近：首次悬停要停稳一会儿，刚看过一条再移到相邻行时立即显示。
static const NSTimeInterval MenuHintInitialDelay = 0.8;
static const NSTimeInterval MenuHintFollowupWindow = 0.5;
static const CGFloat MenuHintMaxTextWidth = 260.0;
static const CGFloat MenuHintPadding = 7.0;

static NSPanel *HintPanel;
static NSTextField *HintLabel;
static NSTimer *HintTimer;
static NSTimeInterval HintHiddenAt;

@implementation MenuHint
+ (void)preparePanel {
    if (HintPanel) return;
    HintPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 10, 10)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:YES];
    HintPanel.opaque = NO;
    HintPanel.backgroundColor = NSColor.clearColor;
    HintPanel.hasShadow = YES;
    HintPanel.ignoresMouseEvents = YES;
    // 菜单窗口在 NSPopUpMenuWindowLevel，低于它会被菜单挡住。
    HintPanel.level = NSPopUpMenuWindowLevel + 1;
    HintPanel.collectionBehavior = NSWindowCollectionBehaviorTransient |
        NSWindowCollectionBehaviorMoveToActiveSpace;

    NSVisualEffectView *background = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    background.material = NSVisualEffectMaterialToolTip;
    background.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    background.state = NSVisualEffectStateActive;
    background.wantsLayer = YES;
    background.layer.cornerRadius = 6.0;
    background.layer.masksToBounds = YES;
    background.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    HintLabel = [NSTextField wrappingLabelWithString:@""];
    HintLabel.font = [NSFont toolTipsFontOfSize:0];
    HintLabel.textColor = NSColor.labelColor;
    HintLabel.selectable = NO;
    [background addSubview:HintLabel];
    HintPanel.contentView = background;
}
+ (void)scheduleText:(NSString *)text belowScreenRect:(NSRect)rect {
    [HintTimer invalidate];
    HintTimer = nil;
    if (text.length == 0) {
        [self cancel];
        return;
    }
    BOOL followup = HintPanel.isVisible ||
        NSDate.date.timeIntervalSince1970 - HintHiddenAt < MenuHintFollowupWindow;
    // 菜单打开期间主线程跑在 event tracking 模式，默认模式的定时器不会触发。
    HintTimer = [NSTimer timerWithTimeInterval:followup ? 0.05 : MenuHintInitialDelay repeats:NO
        block:^(NSTimer *timer) {
            HintTimer = nil;
            [self showText:text belowScreenRect:rect];
        }];
    [NSRunLoop.mainRunLoop addTimer:HintTimer forMode:NSRunLoopCommonModes];
}
+ (void)showText:(NSString *)text belowScreenRect:(NSRect)rect {
    [self preparePanel];
    HintLabel.stringValue = text;
    NSSize textSize = [HintLabel.cell cellSizeForBounds:
        NSMakeRect(0, 0, MenuHintMaxTextWidth, CGFLOAT_MAX)];
    textSize.width = ceil(MIN(textSize.width, MenuHintMaxTextWidth));
    textSize.height = ceil(textSize.height);
    HintLabel.frame = NSMakeRect(MenuHintPadding, MenuHintPadding - 2, textSize.width, textSize.height);
    NSSize panelSize = NSMakeSize(textSize.width + MenuHintPadding * 2,
        textSize.height + MenuHintPadding * 2 - 4);

    NSPoint mouse = NSEvent.mouseLocation;
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    for (NSScreen *candidate in NSScreen.screens) {
        if (NSPointInRect(mouse, candidate.frame)) {
            screen = candidate;
            break;
        }
    }
    NSRect visible = screen.visibleFrame;
    // 贴着行的下沿、从鼠标所在位置起，与系统 toolTip 的位置习惯一致；下方放不下就放到行上方。
    CGFloat x = MIN(MAX(mouse.x, NSMinX(visible)), NSMaxX(visible) - panelSize.width);
    CGFloat y = NSMinY(rect) - panelSize.height - 2;
    if (y < NSMinY(visible)) y = NSMaxY(rect) + 2;
    [HintPanel setFrame:NSMakeRect(x, y, panelSize.width, panelSize.height) display:YES];
    [HintPanel orderFront:nil];
}
+ (void)cancel {
    [HintTimer invalidate];
    HintTimer = nil;
    if (HintPanel.isVisible) {
        HintHiddenAt = NSDate.date.timeIntervalSince1970;
        [HintPanel orderOut:nil];
    }
}
@end

@implementation MenuHintRowView {
    NSTrackingArea *_hintTrackingArea;
}
- (void)setHint:(NSString *)hint {
    _hint = [hint copy];
    [self setAccessibilityHelp:hint];
}
// 菜单属于前台之外的 App 时也要收到进出事件，所以用 ActiveAlways。
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hintTrackingArea) [self removeTrackingArea:_hintTrackingArea];
    _hintTrackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:_hintTrackingArea];
}
- (void)mouseEntered:(NSEvent *)event {
    if (self.hint.length == 0 || !self.window) return;
    NSRect rect = [self.window convertRectToScreen:[self convertRect:self.bounds toView:nil]];
    [MenuHint scheduleText:self.hint belowScreenRect:rect];
}
- (void)mouseExited:(NSEvent *)event {
    [MenuHint cancel];
}
// 菜单关闭时行视图会被移出窗口，此时不一定还能收到 mouseExited。
- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    [super viewWillMoveToWindow:newWindow];
    if (!newWindow && self.hint.length > 0) [MenuHint cancel];
}
@end
