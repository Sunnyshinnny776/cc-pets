#import "CCPetsMenuBarIcon.h"

const NSSize CCPetsMenuBarIconSize = {18, 16};

// 线宽 1.6pt：Retina 下约 3 像素，和系统菜单栏图标的笔画分量接近。
static const CGFloat IconLineWidth = 1.6;

// 用系统色而不是状态卡的颜色：系统色按菜单栏明暗各有一版，深色菜单栏上取更亮的那版；
// 状态卡的工作蓝 (0.33, 0.53, 0.78) 是为浅色玻璃调的，放在深色菜单栏上发灰看不清。
static NSColor *ToneColor(CCPetsMenuBarIconTone tone) {
    switch (tone) {
        case CCPetsMenuBarIconToneWorking: return NSColor.systemBlueColor;
        case CCPetsMenuBarIconToneAttention: return NSColor.systemOrangeColor;
        case CCPetsMenuBarIconToneCompleted: return NSColor.systemGreenColor;
        case CCPetsMenuBarIconToneFailed: return NSColor.systemRedColor;
        default: return NSColor.blackColor;
    }
}

static NSBezierPath *StrokePath(void) {
    NSBezierPath *path = [NSBezierPath bezierPath];
    path.lineWidth = IconLineWidth;
    path.lineCapStyle = NSLineCapStyleRound;
    path.lineJoinStyle = NSLineJoinStyleRound;
    return path;
}

// 窗口里的状态符号，以窗口中心 (9, 8) 为基准：待机和工作中是 >_，审批 •••，完成 ✓，失败 ×。
// 状态同时靠颜色和形状区分，色弱也分得清。
static void DrawGlyph(CCPetsMenuBarIconTone tone) {
    NSBezierPath *path = StrokePath();
    switch (tone) {
        case CCPetsMenuBarIconToneAttention:
            for (NSInteger i = -1; i <= 1; i++) {
                [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(9 + i * 3.2 - 1.05, 8 - 1.05, 2.1, 2.1)] fill];
            }
            return;
        case CCPetsMenuBarIconToneCompleted:
            [path moveToPoint:NSMakePoint(5.8, 8.1)];
            [path lineToPoint:NSMakePoint(8.0, 5.9)];
            [path lineToPoint:NSMakePoint(12.3, 10.2)];
            break;
        case CCPetsMenuBarIconToneFailed:
            [path moveToPoint:NSMakePoint(6.8, 5.8)];
            [path lineToPoint:NSMakePoint(11.2, 10.2)];
            [path moveToPoint:NSMakePoint(6.8, 10.2)];
            [path lineToPoint:NSMakePoint(11.2, 5.8)];
            break;
        default:
            [path moveToPoint:NSMakePoint(5.0, 10.5)];
            [path lineToPoint:NSMakePoint(8.0, 8.0)];
            [path lineToPoint:NSMakePoint(5.0, 5.5)];
            [path moveToPoint:NSMakePoint(9.4, 5.7)];
            [path lineToPoint:NSMakePoint(13.6, 5.7)];
            break;
    }
    [path stroke];
}

static void DrawTerminal(CCPetsMenuBarIconTone tone) {
    // 窗口：坐标按描边中线给，四周留出半个线宽，描边不会被画布裁掉。
    NSBezierPath *frame = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1.8, 2.3, 14.4, 11.4)
        xRadius:3 yRadius:3];
    frame.lineWidth = IconLineWidth;
    [frame stroke];
    DrawGlyph(tone);
}

NSImage *CCPetsMenuBarIconImage(CCPetsMenuBarIconTone tone) {
    NSImage *image = [NSImage imageWithSize:CCPetsMenuBarIconSize flipped:NO drawingHandler:^BOOL(NSRect rect) {
        NSColor *color = ToneColor(tone);
        [color setStroke];
        [color setFill];
        DrawTerminal(tone);
        return YES;
    }];
    // 待机交给系统着色；有状态时要保留彩色，template 会被重新染成黑白。
    image.template = tone == CCPetsMenuBarIconToneNone;
    image.accessibilityDescription = @"CC Pets";
    return image;
}
