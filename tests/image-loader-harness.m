#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import "CCPetsImageLoader.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return EXIT_FAILURE;
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        CGImageSourceRef source = CGImageSourceCreateWithURL(
            (__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
        if (!source) return EXIT_FAILURE;
        NSDictionary *properties = CFBridgingRelease(
            CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
        CFRelease(source);
        CGFloat originalWidth = [properties[(NSString *)kCGImagePropertyPixelWidth] doubleValue];
        CGFloat originalHeight = [properties[(NSString *)kCGImagePropertyPixelHeight] doubleValue];
        CGFloat backingScale = 2.0;
        for (NSScreen *screen in NSScreen.screens) {
            backingScale = MAX(backingScale, screen.backingScaleFactor);
        }
        NSImage *image = LoadPetSpriteImage(path, NSMakeSize(140, 150), 9);
        // 标准素材可能小于 Retina 需求，应保留原始细节；不能强制所有素材都降采样。
        CGFloat minimumWidth = MIN(originalWidth, 140 * backingScale * 8);
        CGFloat minimumHeight = MIN(originalHeight, 150 * backingScale * 9);
        if (!image || image.size.width > originalWidth || image.size.height > originalHeight ||
            image.size.width < minimumWidth - 2 || image.size.height < minimumHeight - 2) {
            fprintf(stderr, "精灵图未保留所需显示细节：原图 %.0fx%.0f，加载 %.0fx%.0f，至少 %.0fx%.0f\n",
                originalWidth, originalHeight, image.size.width, image.size.height, minimumWidth, minimumHeight);
            return EXIT_FAILURE;
        }
        // 较小的逻辑显示尺寸验证缩略分支：每格仍需至少 140×150 物理像素。
        NSImage *thumbnail = LoadPetSpriteImage(path,
            NSMakeSize(140 / backingScale, 150 / backingScale), 9);
        if (!thumbnail || thumbnail.size.width >= originalWidth || thumbnail.size.height >= originalHeight ||
            thumbnail.size.width / 8.0 < 139 || thumbnail.size.height / 9.0 < 149) {
            fprintf(stderr, "精灵图未按较小显示尺寸降采样：原图 %.0fx%.0f，加载 %.0fx%.0f\n",
                originalWidth, originalHeight, thumbnail.size.width, thumbnail.size.height);
            return EXIT_FAILURE;
        }
        printf("精灵图 Retina 细节保留与按显示尺寸降采样测试通过: %.0fx%.0f -> %.0fx%.0f\n",
            originalWidth, originalHeight, thumbnail.size.width, thumbnail.size.height);
    }
    return EXIT_SUCCESS;
}
