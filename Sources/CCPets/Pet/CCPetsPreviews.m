#import "CCPetsPreviews.h"
#import "CCPetsL10n.h"
#import "QuotaDashboardView.h"
#import "MenuToggleSwitch.h"
#import "CCPetsUsage.h"
#import "PetView.h"
#import "CCPetsImageLoader.h"
#import <Cocoa/Cocoa.h>

int RenderQuotaDashboard(NSString *path) {
    [NSApplication sharedApplication];
    QuotaDashboardView *view = [[QuotaDashboardView alloc] initWithFrame:NSMakeRect(0, 0,
        QuotaLogicalWidth * QuotaScale, QuotaLogicalHeight * QuotaScale)];
    // 本地视觉验收可用 CC_PETS_PREVIEW_API=1 渲染 API 用量态，不改用户偏好。
    BOOL previewsAPIUsage = [NSProcessInfo.processInfo.environment[@"CC_PETS_PREVIEW_API"] boolValue];
    view.codexShowsAPIUsage = previewsAPIUsage;
    view.claudeShowsAPIUsage = previewsAPIUsage;
    view.codexLogo = OfficialAppIcon(@"com.openai.codex", @"icon-chatgpt.icns");
    view.claudeLogo = OfficialAppIcon(@"com.anthropic.claudefordesktop", @"electron.icns");
    view.codexUsage = LatestUsage() ?: @{
        @"fiveHour": @{@"used_percent": @34, @"resets_at": @([NSDate.date timeIntervalSince1970] + 7200)},
        @"week": @{@"used_percent": @51, @"resets_at": @([NSDate.date timeIntervalSince1970] + 172800)},
        @"tokenUsage": @{
            @"fiveHour": @{@"total_tokens": @1284000},
            @"week": @{@"total_tokens": @8642000},
            @"today": @{@"total_tokens": @2140000},
            @"recentWeek": @{@"total_tokens": @8980000},
            @"source": @"local"
        }
    };
    view.claudeUsage = LatestClaudeUsage() ?: @{
        @"fiveHour": @{@"used_percentage": @23, @"resets_at": @([NSDate.date timeIntervalSince1970] + 3600)},
        @"week": @{@"used_percentage": @41, @"resets_at": @([NSDate.date timeIntervalSince1970] + 86400)},
        @"tokenUsage": @{
            @"fiveHour": @{@"total_tokens": @962000},
            @"week": @{@"total_tokens": @5310000},
            @"today": @{@"total_tokens": @1470000},
            @"recentWeek": @{@"total_tokens": @5620000},
            @"source": @"local"
        }
    };
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSTimeInterval day = 24 * 60 * 60;
    view.codexHistory = @[
        @{@"timestamp": @(now - 6.5 * day), @"remaining": @88},
        @{@"timestamp": @(now - 5.5 * day), @"remaining": @81},
        @{@"timestamp": @(now - 4.5 * day), @"remaining": @75},
        @{@"timestamp": @(now - 3.5 * day), @"remaining": @68},
        @{@"timestamp": @(now - 2.5 * day), @"remaining": @62},
        @{@"timestamp": @(now - 1.5 * day), @"remaining": @55},
        @{@"timestamp": @(now - 0.5 * day), @"remaining": @49}
    ];
    view.claudeHistory = @[
        @{@"timestamp": @(now - 6.5 * day), @"remaining": @92},
        @{@"timestamp": @(now - 5.5 * day), @"remaining": @86},
        @{@"timestamp": @(now - 4.5 * day), @"remaining": @78},
        @{@"timestamp": @(now - 3.5 * day), @"remaining": @72},
        @{@"timestamp": @(now - 2.5 * day), @"remaining": @64},
        @{@"timestamp": @(now - 1.5 * day), @"remaining": @58},
        @{@"timestamp": @(now - 0.5 * day), @"remaining": @51}
    ];
    view.activeAgentCount = 1;
    // 预览里刻意只让一家在线，好把"有额度数据但客户端已退出"的离线态也画出来。
    view.liveProviders = [NSSet setWithObject:@"Claude"];
    // 预览图始终画完整的两张卡：它是 README 里的样张，不该受这台机器装了几家 CLI 影响。
    // 尺寸也因此固定在 QuotaLogicalHeight（tests/test.sh 断言的 441 x 343）。
    view.detectedProviders = [NSSet setWithObjects:@"Codex", @"Claude", nil];
    view.lastUpdatedAt = NSDate.date.timeIntervalSince1970 - 12;
    NSInteger pixelWidth = (NSInteger)ceil(NSWidth(view.bounds));
    NSInteger pixelHeight = (NSInteger)ceil(NSHeight(view.bounds));
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
        pixelsWide:pixelWidth
        pixelsHigh:pixelHeight
        bitsPerSample:8
        samplesPerPixel:4
        hasAlpha:YES
        isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace
        bytesPerRow:0
        bitsPerPixel:0];
    bitmap.size = view.bounds.size;
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = context;
    [view displayRectIgnoringOpacity:view.bounds inContext:context];
    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES] ? EXIT_SUCCESS : EXIT_FAILURE;
}

int RenderAgentStatusCard(NSString *path) {
    [NSApplication sharedApplication];
    NSSize glassSize = NSMakeSize(340, 58);
    NSSize size = NSMakeSize(glassSize.width + 12, glassSize.height + 12);
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    NSView *shadowView = [[NSView alloc] initWithFrame:NSMakeRect(
        6, 6, glassSize.width, glassSize.height)];
    shadowView.wantsLayer = YES;
    shadowView.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.01].CGColor;
    shadowView.layer.cornerRadius = glassSize.height / 2.0;
    shadowView.layer.cornerCurve = kCACornerCurveContinuous;
    shadowView.layer.shadowColor = NSColor.blackColor.CGColor;
    shadowView.layer.shadowOpacity = 0.24;
    shadowView.layer.shadowRadius = 8;
    shadowView.layer.shadowOffset = NSMakeSize(0, -3);
    CGPathRef shadowPath = CGPathCreateWithRoundedRect(shadowView.bounds,
        glassSize.height / 2.0, glassSize.height / 2.0, NULL);
    shadowView.layer.shadowPath = shadowPath;
    CGPathRelease(shadowPath);
    [root addSubview:shadowView];

    NSVisualEffectView *glass = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(
        6, 6, glassSize.width, glassSize.height)];
    glass.material = NSVisualEffectMaterialPopover;
    glass.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    glass.state = NSVisualEffectStateActive;
    glass.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    glass.wantsLayer = YES;
    glass.layer.cornerRadius = glassSize.height / 2.0;
    glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;
    glass.layer.borderWidth = 1;
    glass.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.48].CGColor;
    [root addSubview:glass];

    NSTextField *title = [NSTextField labelWithString:L(@"Codex · Task completed")];
    title.frame = NSMakeRect(20, 30, glassSize.width - 80, 18);
    title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    title.textColor = [NSColor colorWithWhite:0.10 alpha:0.96];
    [glass addSubview:title];
    NSTextField *detail = [NSTextField labelWithString:L(@"The current task is done.")];
    detail.frame = NSMakeRect(20, 12, glassSize.width - 80, 17);
    detail.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    detail.textColor = [NSColor colorWithWhite:0.34 alpha:0.88];
    [glass addSubview:detail];

    NSButton *icon = [[NSButton alloc] initWithFrame:NSMakeRect(glassSize.width - 48, 12, 34, 34)];
    icon.bordered = NO;
    icon.imagePosition = NSImageOnly;
    icon.wantsLayer = YES;
    icon.layer.cornerRadius = 17;
    icon.layer.masksToBounds = YES;
    NSColor *green = [NSColor colorWithRed:0.18 green:0.68 blue:0.35 alpha:1];
    icon.layer.backgroundColor = [green colorWithAlphaComponent:0.28].CGColor;
    NSImage *image = [NSImage imageWithSystemSymbolName:@"checkmark"
        accessibilityDescription:L(@"Task completed")];
    icon.image = [image imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightBold]];
    icon.contentTintColor = [green blendedColorWithFraction:0.18
        ofColor:NSColor.blackColor] ?: green;
    [glass addSubview:icon];

    NSInteger pixelWidth = (NSInteger)ceil(size.width);
    NSInteger pixelHeight = (NSInteger)ceil(size.height);
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:pixelWidth pixelsHigh:pixelHeight
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    bitmap.size = size;
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = context;
    [root displayRectIgnoringOpacity:root.bounds inContext:context];
    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES] ? EXIT_SUCCESS : EXIT_FAILURE;
}

int RenderMenuSwitches(NSString *path) {
    [NSApplication sharedApplication];
    NSSize size = NSMakeSize(220, 72);
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    view.wantsLayer = YES;
    view.layer.backgroundColor = [NSColor colorWithWhite:0.86 alpha:1].CGColor;
    NSArray<NSDictionary *> *rows = @[
        @{@"title": L(@"Task done"), @"state": @YES, @"y": @40},
        @{@"title": L(@"Task failed"), @"state": @NO, @"y": @10}
    ];
    for (NSDictionary *row in rows) {
        CGFloat y = [row[@"y"] doubleValue];
        NSTextField *label = [NSTextField labelWithString:row[@"title"]];
        label.frame = NSMakeRect(14, y + 3, 130, 18);
        label.font = [NSFont menuFontOfSize:13];
        label.textColor = NSColor.labelColor;
        [view addSubview:label];
        MenuToggleSwitch *toggle = [[MenuToggleSwitch alloc] initWithFrame:NSMakeRect(168, y, 36, 22)];
        toggle.state = [row[@"state"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        [view addSubview:toggle];
    }

    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)size.width pixelsHigh:(NSInteger)size.height
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    bitmap.size = size;
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = context;
    [view displayRectIgnoringOpacity:view.bounds inContext:context];
    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES] ? EXIT_SUCCESS : EXIT_FAILURE;
}

// 逐格渲染 PetView，用于 M1 渲染层改造的等价校验。
// 尺寸取运行时真实值：视图 144×150（AppDelegate 建 PetView 用的就是这个），
// 素材按 NSMakeSize(140, 150) 装载——两处任何一个写错，改造后的图都会对不上。
// 走 cacheDisplayInRect: 而不是 displayRectIgnoringOpacity:，因为改成 layer-backed
// 之后内容在 layer 里，后者抓不到。宿主窗口是必需的：无窗口的视图 cacheDisplay 行为
// 不保证。
int RenderPetSheet(NSString *path, NSString *sheetPath, NSInteger rowCount) {
    [NSApplication sharedApplication];
    if (rowCount <= 0) rowCount = 9;
    NSImage *sheet = LoadPetSpriteImage(sheetPath, NSMakeSize(140, 150), rowCount);
    if (!sheet) {
        fprintf(stderr, "%s\n", [NSString stringWithFormat:L(@"Can't load the sprite: %@"), sheetPath].UTF8String);
        return EXIT_FAILURE;
    }

    const NSInteger columns = 8;
    NSRect cellFrame = NSMakeRect(0, 0, 144, 150);
    PetView *view = [[PetView alloc] initWithFrame:cellFrame sheet:sheet rowCount:rowCount];
    view.animationSuspended = YES;

    NSWindow *host = [[NSWindow alloc] initWithContentRect:cellFrame
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    host.contentView = view;

    NSSize size = NSMakeSize(NSWidth(cellFrame) * columns, NSHeight(cellFrame) * rowCount);
    NSBitmapImageRep *canvas = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)size.width pixelsHigh:(NSInteger)size.height
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    canvas.size = size;
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:canvas];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = context;

    for (NSInteger row = 0; row < rowCount; row++) {
        for (NSInteger frame = 0; frame < columns; frame++) {
            view.rowIndex = row;
            view.frameIndex = frame;
            view.needsDisplay = YES;
            [view displayIfNeeded];

            NSBitmapImageRep *cell = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
            if (!cell) continue;
            [view cacheDisplayInRect:view.bounds toBitmapImageRep:cell];
            // 行 0 画在最上面，和素材表本身的排列一致，肉眼比对时不用换算。
            NSPoint origin = NSMakePoint(frame * NSWidth(cellFrame),
                size.height - (row + 1) * NSHeight(cellFrame));
            [cell drawInRect:NSMakeRect(origin.x, origin.y, NSWidth(cellFrame), NSHeight(cellFrame))
                fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0
                respectFlipped:NO hints:@{NSImageHintInterpolation: @(NSImageInterpolationNone)}];
        }
    }

    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [canvas representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES] ? EXIT_SUCCESS : EXIT_FAILURE;
}
