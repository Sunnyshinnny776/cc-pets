#import <Cocoa/Cocoa.h>
#import "CCPetsMenuBarIcon.h"

// 菜单栏图标测试：五个色调都能画出同尺寸的图；待机是 template（由系统按菜单栏明暗着色），
// 有状态的保留彩色；画出来的像素确实落在画布里，且有状态时是对应的颜色而不是黑白。

static BOOL Check(BOOL condition, NSString *label) {
    if (!condition) NSLog(@"失败：%@", label);
    return condition;
}

// 在深色外观下按 2x 栅格化，返回不透明像素数与它们的平均颜色。
static NSUInteger Rasterize(NSImage *image, double *red, double *green, double *blue) {
    NSInteger width = (NSInteger)(image.size.width * 2), height = (NSInteger)(image.size.height * 2);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width
        pixelsHigh:height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua] performAsCurrentDrawingAppearance:^{
        [image drawInRect:NSMakeRect(0, 0, width, height)];
    }];
    [NSGraphicsContext restoreGraphicsState];
    NSUInteger count = 0;
    double r = 0, g = 0, b = 0;
    for (NSInteger y = 0; y < height; y++) for (NSInteger x = 0; x < width; x++) {
        NSUInteger p[4];
        [rep getPixel:p atX:x y:y];
        if (p[3] < 200) continue;
        count++;
        r += p[0]; g += p[1]; b += p[2];
    }
    if (count > 0) { *red = r / count; *green = g / count; *blue = b / count; }
    return count;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        BOOL ok = YES;
        CCPetsMenuBarIconTone tones[] = {CCPetsMenuBarIconToneNone, CCPetsMenuBarIconToneWorking,
            CCPetsMenuBarIconToneAttention, CCPetsMenuBarIconToneCompleted, CCPetsMenuBarIconToneFailed};
        NSString *names[] = {@"待机", @"工作中", @"审批", @"完成", @"失败"};
        for (int i = 0; i < 5; i++) {
            NSImage *image = CCPetsMenuBarIconImage(tones[i]);
            ok &= Check(NSEqualSizes(image.size, CCPetsMenuBarIconSize), [NSString stringWithFormat:@"%@ 尺寸一致", names[i]]);
            ok &= Check(image.template == (i == 0), [NSString stringWithFormat:@"%@ 的 template 设置正确", names[i]]);
            double r = 0, g = 0, b = 0;
            NSUInteger pixels = Rasterize(image, &r, &g, &b);
            ok &= Check(pixels > 60, [NSString stringWithFormat:@"%@ 画出了窗口和提示符", names[i]]);
            if (i == 0) continue;
            // 系统色深色版：蓝偏蓝、橙偏红、绿偏绿、红偏红；不能是黑白（没有被当成 template 着色）。
            double spread = MAX(r, MAX(g, b)) - MIN(r, MIN(g, b));
            ok &= Check(spread > 80, [NSString stringWithFormat:@"%@ 是彩色", names[i]]);
            BOOL dominant = i == 1 ? b > r && b > g : (i == 3 ? g > r && g > b : r > b);
            ok &= Check(dominant, [NSString stringWithFormat:@"%@ 的色相正确", names[i]]);
        }
        if (!ok) return 1;
        printf("菜单栏图标绘制测试通过\n");
    }
    return 0;
}
