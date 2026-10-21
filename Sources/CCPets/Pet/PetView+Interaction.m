#import "PetView+Private.h"

// 按下后位移超过这个距离才判定为拖动，之内视为点击。
static const CGFloat PetDragThreshold = 3.0;
// 拖动滞后只做水平方向。窗口左右各有 43px 余量，而下方是 0——垂直滞后往下一点就被裁掉，
// 只留向上会变成不对称的怪动作，不如不做。反正拖动本来就按水平方向选跑动行，
// 水平滞后正好强化那个方向感。
static const CGFloat PetDragLagMax = 13.0;
static const CGFloat PetDragLagFactor = 0.85;
// 松手后的"落脚"：先压扁再回弹到静止。锚点在脚底，所以压扁是往下坐，不会越界。
static const NSTimeInterval PetSettleDuration = 0.34;

@implementation PetView (Interaction)
// 桌宠是 LSUIElement + NSNonactivatingPanel，几乎永远不是活跃应用。不接受 first mouse
// 的话，AppKit 会把点击非活跃应用窗口的第一次 mouseDown 当成"激活点击"消耗掉，视图
// 根本收不到——表现为要点两下才拖得动。以前靠 movableByWindowBackground 拖动时不受
// 影响（窗口背景拖动在窗口服务器层处理，不走视图的 first mouse 判定），关掉它之后
// 这个缺陷才暴露出来。
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
// 精灵区的拖动由 runWindowDragWithEvent: 自己发起，不让 AppKit 的窗口背景拖动同时
// 介入同一次按下；窗口透明区没有这个覆写，继续走 movableByWindowBackground。
// 两条路径底层都是窗口服务器拖动，手感一致。
- (BOOL)mouseDownCanMoveWindow { return NO; }
// 阈值起点取事件自带的坐标，不用 NSEvent.mouseLocation（那是"处理这条事件时"鼠标的实时
// 位置）。主线程被别的活儿占住时，mouseDown 会晚一截才被处理，实时位置早已跟着手滑走，
// 起点于是落在远处，后面要多走同样的距离才够过阈值——表现为按住之后宠物迟迟不动。
// 阈值判定发生在窗口服务器接手拖动之前，窗口此刻还没动，所以窗口坐标是稳定的参照系。
- (void)mouseDown:(NSEvent *)event {
    [self noteActivity];
    self.agentActive = NO;
    self.dragStartMouse = event.locationInWindow;
}
- (void)mouseDragged:(NSEvent *)event {
    if (self.draggingPet) return;
    NSPoint current = event.locationInWindow;
    CGFloat horizontal = current.x - self.dragStartMouse.x;
    CGFloat vertical = current.y - self.dragStartMouse.y;
    if (hypot(horizontal, vertical) < PetDragThreshold) return;
    [self runWindowDragWithEvent:event movingRight:horizontal >= 0];
}
// 拖动交给窗口服务器：它不依赖应用事件流，所以掠过其他窗口、拖出屏幕、
// 应用非活跃都不会中断。这个 API 会立即返回，且 mouseUp 可能不会发回应用，
// 因此不能在调用后立刻恢复 idle；释放兜底由 nextFrame: 检查物理按键状态。
- (void)runWindowDragWithEvent:(NSEvent *)event movingRight:(BOOL)movingRight {
    self.draggingPet = YES;
    if (self.pocketHoverChanged) self.pocketHoverChanged(NO);
    if (self.dragStateChanged) self.dragStateChanged(YES);
    [self playRow:movingRight ? 1 : 2 throughFrame:7 oneShot:NO];
    [self startObservingWindowMove];

    [self.window performWindowDragWithEvent:event];
}
- (void)startObservingWindowMove {
    if (self.observingWindowMove || !self.window) return;
    self.lastDragWindowOrigin = self.window.frame.origin;
    self.observingWindowMove = YES;
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(petWindowMovedWhileDragging:)
        name:NSWindowDidMoveNotification object:self.window];
}
- (void)stopObservingWindowMove {
    if (!self.observingWindowMove) return;
    self.observingWindowMove = NO;
    [NSNotificationCenter.defaultCenter removeObserver:self
        name:NSWindowDidMoveNotification object:self.window];
}
// 精灵在窗口内往反方向落后一点，看着就有了重量。滞后量跟这一帧的位移走，
// 停手不动时位移为 0，会自然归位。
- (void)petWindowMovedWhileDragging:(NSNotification *)notification {
    if (!self.draggingPet || self.reduceMotion) return;
    NSPoint origin = self.window.frame.origin;
    CGFloat dx = origin.x - self.lastDragWindowOrigin.x;
    self.lastDragWindowOrigin = origin;

    CGFloat lag = -dx * PetDragLagFactor;
    lag = MAX(-PetDragLagMax, MIN(PetDragLagMax, lag));
    // 缩短隐式动画时长：默认 0.25s 追不上手，看着是糊而不是滞后。0.12s 既平滑又跟手。
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.12];
    [CATransaction setAnimationTimingFunction:
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
    self.spriteLayer.transform = CATransform3DMakeTranslation(lag, 0, 0);
    [CATransaction commit];
}
- (void)endPetDrag {
    if (!self.draggingPet) return;
    self.draggingPet = NO;
    [self stopObservingWindowMove];
    if (self.dragStateChanged) self.dragStateChanged(NO);
    [self playRow:0 throughFrame:5 oneShot:NO];
    [self playSettleAnimation];
}
// 落脚：从当前滞后位置 → 压扁 → 轻微回弹过冲 → 静止。
// 整段只动 transform 一个属性，和挂在 position.y 上的呼吸互不干扰。
- (void)playSettleAnimation {
    CALayer *layer = self.spriteLayer;
    if (!layer) return;
    if (self.reduceMotion) {
        layer.transform = CATransform3DIdentity;
        return;
    }
    CATransform3D current = ((CALayer *)layer.presentationLayer ?: layer).transform;
    CAKeyframeAnimation *settle = [CAKeyframeAnimation animationWithKeyPath:@"transform"];
    settle.values = @[
        [NSValue valueWithCATransform3D:current],
        [NSValue valueWithCATransform3D:CATransform3DMakeScale(1.07, 0.92, 1.0)],
        [NSValue valueWithCATransform3D:CATransform3DMakeScale(0.97, 1.04, 1.0)],
        [NSValue valueWithCATransform3D:CATransform3DIdentity]
    ];
    settle.keyTimes = @[@0.0, @0.34, @0.68, @1.0];
    settle.duration = PetSettleDuration;
    settle.timingFunction = [CAMediaTimingFunction
        functionWithName:kCAMediaTimingFunctionEaseOut];
    // 先把 model 值落到静止态且不触发隐式动画，否则它会和下面的关键帧同时跑。
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.transform = CATransform3DIdentity;
    [CATransaction commit];
    [layer addAnimation:settle forKey:@"settle"];
}
- (void)mouseUp:(NSEvent *)event {
    if (self.draggingPet) {
        [self endPetDrag];
        return;
    }
    [self handleInteractionClick];
}
- (void)handleInteractionClick {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults boolForKey:PetInteractionEnabledKey]) {
        [self playRow:7 throughFrame:5 oneShot:YES];
        return;
    }
    NSTimeInterval interval = [defaults doubleForKey:PetInteractionIntervalKey];
    interval = MAX(0.4, MIN(3.0, interval));
    NSInteger heartThreshold = MAX((NSInteger)2,
        [defaults integerForKey:PetInteractionHeartThresholdKey]);
    NSInteger annoyedThreshold = MAX(heartThreshold + 1,
        [defaults integerForKey:PetInteractionAnnoyedThresholdKey]);
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - self.lastInteractionClickAt > interval) {
        self.interactionClickCount = 0;
    }
    self.lastInteractionClickAt = now;
    self.interactionClickCount++;

    if (self.interactionClickCount >= annoyedThreshold) {
        [self spawnInteractionSymbols:@[@"💢", @"╬", @"!"]
            color:NSColor.systemOrangeColor];
        [self playRow:5 throughFrame:7 oneShot:YES];
        if (self.interactionPhraseRequested) {
            self.interactionPhraseRequested(@"click_annoyed");
        }
        return;
    }
    if (self.interactionClickCount >= heartThreshold) {
        [self spawnInteractionSymbols:@[@"♥︎", @"♥︎", @"♥︎"]
            color:NSColor.systemPinkColor];
        [self playRow:3 throughFrame:3 oneShot:YES];
        if (self.interactionPhraseRequested) {
            self.interactionPhraseRequested(@"click_heart");
        }
        return;
    }
    [self playRow:7 throughFrame:5 oneShot:YES];
}
- (void)spawnInteractionSymbols:(NSArray<NSString *> *)symbols color:(NSColor *)color {
    NSTimeInterval duration = self.reduceMotion ? 0.45 : 0.95;
    for (NSUInteger index = 0; index < symbols.count; index++) {
        CGFloat x = 34.0 + arc4random_uniform(66);
        CGFloat y = 104.0 + arc4random_uniform(12);
        NSTextField *label = [NSTextField labelWithString:symbols[index]];
        label.alignment = NSTextAlignmentCenter;
        label.font = [NSFont systemFontOfSize:index == 0 ? 21 : 17
            weight:NSFontWeightBold];
        label.textColor = color;
        label.frame = NSMakeRect(x, y, 30, 28);
        label.wantsLayer = YES;
        label.layer.zPosition = 20;
        [self addSubview:label];

        CFTimeInterval delay = index * 0.08;
        CGPoint start = label.layer.position;
        CGPoint end = CGPointMake(start.x + ((NSInteger)index - 1) * 10,
            start.y + (self.reduceMotion ? 0 : 34 + index * 5));
        CAKeyframeAnimation *position = [CAKeyframeAnimation animationWithKeyPath:@"position"];
        position.values = @[[NSValue valueWithPoint:start], [NSValue valueWithPoint:end]];
        CAKeyframeAnimation *opacity = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        opacity.values = @[@0.0, @1.0, @1.0, @0.0];
        opacity.keyTimes = @[@0.0, @0.18, @0.68, @1.0];
        CAKeyframeAnimation *scale = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
        scale.values = @[@0.65, @1.12, @1.0];
        scale.keyTimes = @[@0.0, @0.35, @1.0];
        CAAnimationGroup *group = [CAAnimationGroup animation];
        group.animations = @[position, opacity, scale];
        group.duration = duration;
        group.beginTime = CACurrentMediaTime() + delay;
        group.fillMode = kCAFillModeBoth;
        group.removedOnCompletion = NO;
        [label.layer addAnimation:group forKey:@"interactionFloat"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)((duration + delay + 0.05) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [label removeFromSuperview];
            });
    }
}
@end
