#import "CCPetsUIStyle.h"
#import <QuartzCore/QuartzCore.h>

NSImage *CCPetsSymbolTile(NSString *symbol, NSColor *color, CGFloat size) {
    NSImageSymbolConfiguration *configuration = [[NSImageSymbolConfiguration
        configurationWithPointSize:size * 0.52 weight:NSFontWeightSemibold]
        configurationByApplyingConfiguration:
        [NSImageSymbolConfiguration configurationWithPaletteColors:@[NSColor.whiteColor]]];
    NSImage *glyph = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]
        imageWithSymbolConfiguration:configuration];
    // drawingHandler 版本在每种缩放下按需重画，Retina 上不糊；颜色在绘制时解析，深浅色自动跟随。
    return [NSImage imageWithSize:NSMakeSize(size, size) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        NSBezierPath *tile = [NSBezierPath bezierPathWithRoundedRect:rect
            xRadius:size * 0.24 yRadius:size * 0.24];
        NSColor *base = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: color;
        // 上亮下暗的轻微渐变，系统设置里的图标块就是这样，纯色会显得平。
        NSColor *top = [base blendedColorWithFraction:0.18 ofColor:NSColor.whiteColor] ?: base;
        [[[NSGradient alloc] initWithStartingColor:top endingColor:base] drawInBezierPath:tile angle:-90];
        if (glyph) {
            NSSize glyphSize = glyph.size;
            NSRect target = NSMakeRect(NSMidX(rect) - glyphSize.width / 2,
                NSMidY(rect) - glyphSize.height / 2, glyphSize.width, glyphSize.height);
            [glyph drawInRect:target];
        }
        return YES;
    }];
}

// 和 PetView.handleAgentEvent: 用的行一致：{行, 最后一帧}。
static void SpriteRowForState(NSString *state, NSInteger *row, NSInteger *lastFrame) {
    NSDictionary<NSString *, NSArray<NSNumber *> *> *rows = @{
        @"thinking": @[@5, @7], @"starting": @[@4, @4], @"auto_review": @[@8, @5],
        @"approval": @[@4, @4], @"notification": @[@4, @4],
        @"tool": @[@8, @5], @"subagent": @[@6, @5],
        @"tool_completed": @[@7, @5], @"completed": @[@3, @3],
        @"tool_failed": @[@5, @7], @"failed": @[@5, @7],
    };
    NSArray<NSNumber *> *entry = rows[state ?: @""] ?: @[@0, @5];
    *row = entry[0].integerValue;
    *lastFrame = entry[1].integerValue;
}

static const NSTimeInterval SpriteFrameInterval = 0.16;

@interface CCPetsSpriteView ()
@property(nonatomic) CGImageRef sheetImage;
@property(nonatomic) NSImage *sheet;
@property(nonatomic) NSInteger rowCount;
@property(nonatomic) NSInteger row;
@property(nonatomic) NSInteger lastFrame;
@property(nonatomic) NSInteger frameIndex;
@property(nonatomic) NSTimer *timer;
@end

@implementation CCPetsSpriteView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        // 像素素材放大用最近邻，和桌宠本体一致。
        self.layer.magnificationFilter = kCAFilterNearest;
        self.layer.minificationFilter = kCAFilterNearest;
        self.layer.contentsGravity = kCAGravityResizeAspect;
        _lastFrame = 5;
        [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self
            selector:@selector(updateTimer)
            name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [_timer invalidate];
    if (_sheetImage) CGImageRelease(_sheetImage);
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}

- (void)setSheet:(NSImage *)sheet rowCount:(NSInteger)rowCount {
    if (sheet == self.sheet && rowCount == self.rowCount) return;
    self.sheet = sheet;
    self.rowCount = MAX((NSInteger)1, rowCount);
    if (_sheetImage) CGImageRelease(_sheetImage);
    CGImageRef image = [sheet CGImageForProposedRect:NULL context:nil hints:nil];
    _sheetImage = image ? CGImageRetain(image) : NULL;
    [self applyState];
}

- (void)setState:(NSString *)state {
    if ([_state isEqualToString:state]) return;
    _state = [state copy];
    [self applyState];
}

- (void)applyState {
    NSInteger row = 0, lastFrame = 5;
    SpriteRowForState(self.state, &row, &lastFrame);
    if (row >= self.rowCount) {
        row = 0;
        lastFrame = 5;
    }
    self.row = row;
    self.lastFrame = lastFrame;
    self.frameIndex = 0;
    [self showCurrentFrame];
    [self updateTimer];
}

- (void)showCurrentFrame {
    if (!_sheetImage) {
        self.layer.contents = nil;
        return;
    }
    size_t width = CGImageGetWidth(_sheetImage), height = CGImageGetHeight(_sheetImage);
    CGFloat cellWidth = width / 8.0, cellHeight = (CGFloat)height / self.rowCount;
    // CGImage 坐标原点在左上角，行号从上往下数，正好不用翻转。
    CGRect cell = CGRectIntegral(CGRectMake(self.frameIndex * cellWidth, self.row * cellHeight,
        cellWidth, cellHeight));
    CGImageRef frame = CGImageCreateWithImageInRect(_sheetImage, cell);
    [CATransaction begin];
    // 换 contents 默认有 0.25s 淡入，逐帧动画上会拖影。
    [CATransaction setDisableActions:YES];
    self.layer.contents = (__bridge id)frame;
    [CATransaction commit];
    if (frame) CGImageRelease(frame);
}

- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    [super viewWillMoveToWindow:newWindow];
    for (NSNotificationName name in @[NSWindowDidMiniaturizeNotification,
                                      NSWindowDidDeminiaturizeNotification, NSWindowWillCloseNotification]) {
        [NSNotificationCenter.defaultCenter removeObserver:self name:name object:nil];
    }
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) {
        for (NSNotificationName name in @[NSWindowDidMiniaturizeNotification,
                                          NSWindowDidDeminiaturizeNotification]) {
            [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateTimer)
                name:name object:self.window];
        }
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowWillClose:)
            name:NSWindowWillCloseNotification object:self.window];
    }
    [self updateTimer];
}

- (void)windowWillClose:(NSNotification *)notification {
    [self.timer invalidate];
    self.timer = nil;
}

// 窗口在屏幕上才走表，关窗、最小化都不耗电。不看"是否被别的窗口挡住"：那要靠遮挡状态，
// 它在 Space / 全屏过渡期间会误报十几秒不可见，桌宠本体已经因此弃用（见 tests/test.sh）。
- (void)updateTimer {
    BOOL visible = self.window.isVisible && !self.window.isMiniaturized;
    BOOL shouldRun = visible && _sheetImage && self.lastFrame > 0 &&
        !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    if (shouldRun == self.timer.isValid) return;
    [self.timer invalidate];
    self.timer = nil;
    if (!shouldRun) {
        self.frameIndex = 0;
        [self showCurrentFrame];
        return;
    }
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:SpriteFrameInterval repeats:YES block:^(NSTimer *timer) {
        CCPetsSpriteView *view = weakSelf;
        if (!view) return;
        view.frameIndex = view.frameIndex >= view.lastFrame ? 0 : view.frameIndex + 1;
        [view showCurrentFrame];
    }];
    self.timer.tolerance = SpriteFrameInterval * 0.25;
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}

@end
