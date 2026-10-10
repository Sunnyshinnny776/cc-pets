#import <Cocoa/Cocoa.h>

// cellSize 使用逻辑点；按至少 2x 及当前屏幕最高倍率解码，保留 Retina 细节，
// 同时限制超大外部素材的 RGBA 内存占用。无需降采样时保留原图。
NSImage *LoadPetSpriteImage(NSString *path, NSSize cellSize, NSInteger rowCount);
