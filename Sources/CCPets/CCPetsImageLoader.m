#import "CCPetsImageLoader.h"
#import <ImageIO/ImageIO.h>

NSImage *LoadPetSpriteImage(NSString *path, NSSize cellSize, NSInteger rowCount) {
    if (path.length == 0 || rowCount <= 0) return nil;
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) return nil;
    NSDictionary *properties = CFBridgingRelease(
        CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    CGFloat sourceWidth = [properties[(NSString *)kCGImagePropertyPixelWidth] doubleValue];
    CGFloat sourceHeight = [properties[(NSString *)kCGImagePropertyPixelHeight] doubleValue];
    // cellSize 是逻辑点，ImageIO 的缩略尺寸是物理像素。按 1x 解码再画入
    // Retina 的 2x 帧缓存，只会放大已经丢掉细节的缩略图。
    // 加载发生在窗口创建前，取所有屏幕的最高倍率，并至少保留 2x，避免
    // 从普通屏移到 Retina 时源图不足。标准 Codex 精灵图因此直接保留原图。
    CGFloat backingScale = 2.0;
    for (NSScreen *screen in NSScreen.screens) {
        backingScale = MAX(backingScale, screen.backingScaleFactor);
    }
    CGFloat desiredWidth = MAX(1.0, cellSize.width) * backingScale * 8.0;
    CGFloat desiredHeight = MAX(1.0, cellSize.height) * backingScale * rowCount;
    CGFloat scale = MIN(1.0, MAX(desiredWidth / MAX(1.0, sourceWidth),
        desiredHeight / MAX(1.0, sourceHeight)));
    if (scale >= 0.98) {
        CFRelease(source);
        return [[NSImage alloc] initWithContentsOfFile:path];
    }
    CGFloat maximumPixelSize = ceil(MAX(sourceWidth, sourceHeight) * scale);
    NSDictionary *options = @{
        (NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (NSString *)kCGImageSourceThumbnailMaxPixelSize: @(maximumPixelSize),
        (NSString *)kCGImageSourceShouldCacheImmediately: @YES
    };
    CGImageRef imageRef = CGImageSourceCreateThumbnailAtIndex(
        source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!imageRef) return [[NSImage alloc] initWithContentsOfFile:path];
    NSImage *image = [[NSImage alloc] initWithCGImage:imageRef
        size:NSMakeSize(CGImageGetWidth(imageRef), CGImageGetHeight(imageRef))];
    CGImageRelease(imageRef);
    return image;
}
