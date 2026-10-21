#import "MenuChoiceRow.h"

@implementation MenuChoiceRowView
+ (NSMenuItem *)addToMenu:(NSMenu *)menu title:(NSString *)title group:(NSString *)group
    representedObject:(id)representedObject checked:(BOOL)checked
    target:(id)target action:(SEL)action width:(CGFloat)width {
    // item 要有 action 才会被菜单高亮。鼠标点击由行视图自己处理（菜单不关）；
    // 用键盘选中后按回车走的是这个 action，行为与点击一致，菜单照常关闭。
    // 所有设置单选行统一按文案撑宽，避免英文标题被截断。
    width = MAX(width, ceil([title sizeWithAttributes:
        @{NSFontAttributeName: [NSFont menuFontOfSize:13]}].width) + 42);
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(chooseFromMenuItem:)
        keyEquivalent:@""];
    MenuChoiceRowView *row = [[MenuChoiceRowView alloc] initWithFrame:NSMakeRect(0, 0, width, 24)];
    row.autoresizingMask = NSViewWidthSizable;
    row.title = title;
    row.group = group;
    row.representedObject = representedObject;
    row.checked = checked;
    row.enabled = YES;
    row.target = target;
    row.action = action;
    [row setAccessibilityRole:NSAccessibilityRadioButtonRole];
    [row setAccessibilityLabel:title];
    item.target = row;
    item.view = row;
    [menu addItem:item];
    return item;
}
- (void)chooseFromMenuItem:(id)sender { [self choose]; }
// 手绘行不是 NSButton，VoiceOver 的"按下"要自己接到 choose 上。
- (BOOL)accessibilityPerformPress {
    if (!self.enabled) return NO;
    [self choose];
    return YES;
}
// 置灰的行不让菜单高亮，和系统禁用项一致。
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem { return self.enabled; }
- (void)setChecked:(BOOL)checked {
    _checked = checked;
    [self setAccessibilityValue:@(checked)];
    self.needsDisplay = YES;
}
- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    [self setAccessibilityEnabled:enabled];
    self.needsDisplay = YES;
}
// 不实现 mouseDown: 的话按下事件会沿响应链交给菜单，菜单会当作一次普通选择然后收起。
- (void)mouseDown:(NSEvent *)event {}
- (void)mouseUp:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(point, self.bounds)) [self choose];
}
- (void)choose {
    if (!self.enabled || self.checked) return;
    [NSApp sendAction:self.action to:self.target from:self];
    for (NSMenuItem *item in self.enclosingMenuItem.menu.itemArray) {
        if (![item.view isKindOfClass:MenuChoiceRowView.class]) continue;
        MenuChoiceRowView *row = (MenuChoiceRowView *)item.view;
        if ([row.group isEqualToString:self.group]) row.checked = row == self;
        if (row.enabledHandler) row.enabled = row.enabledHandler();
    }
    [self.enclosingMenuItem.menu update];
}
- (void)drawRect:(NSRect)dirtyRect {
    // 高亮跟随菜单自己的高亮项，而不是自己跟踪鼠标进出：菜单跟踪期间 mouseExited 经常
    // 收不到，自己跟踪会让划过的每一行都停在高亮。菜单同一时刻只高亮一项，切换时会重绘视图。
    BOOL highlighted = self.enclosingMenuItem.isHighlighted && self.enabled;
    if (highlighted) {
        [NSColor.selectedContentBackgroundColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 5, 0)
            xRadius:6 yRadius:6] fill];
    }
    NSColor *textColor = !self.enabled ? NSColor.tertiaryLabelColor
        : (highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor);
    CGFloat x = 12 + self.indentation;
    if (self.checked) {
        NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration
            configurationWithPointSize:11 weight:NSFontWeightSemibold];
        NSImage *mark = [[NSImage imageWithSystemSymbolName:@"checkmark"
            accessibilityDescription:nil] imageWithSymbolConfiguration:configuration];
        NSImage *tinted = [NSImage imageWithSize:mark.size flipped:NO
            drawingHandler:^BOOL(NSRect rect) {
                [mark drawInRect:rect];
                [textColor set];
                NSRectFillUsingOperation(rect, NSCompositingOperationSourceAtop);
                return YES;
            }];
        [tinted drawInRect:NSMakeRect(x, (NSHeight(self.bounds) - mark.size.height) / 2.0,
            mark.size.width, mark.size.height)];
    }
    NSDictionary *attributes = @{NSFontAttributeName: [NSFont menuFontOfSize:13],
        NSForegroundColorAttributeName: textColor};
    NSSize size = [self.title sizeWithAttributes:attributes];
    [self.title drawAtPoint:NSMakePoint(x + 18, (NSHeight(self.bounds) - size.height) / 2.0)
        withAttributes:attributes];
}
@end
