#import "PetView+Private.h"
#import "CCPetsPaths.h"

// 呼吸：只向上浮，不做上下对称摆动。宠物视图在 230×170 的窗口里位于 (43,0,144,150)，
// 下方一点余量都没有，往下 1px 就被窗口裁掉。静止位不变，所以离屏基准图不受影响。
static const CGFloat PetBreathRise = 1.5;
static const NSTimeInterval PetBreathPeriod = 3.6;

@implementation PetView
- (instancetype)initWithFrame:(NSRect)frame sheet:(NSImage *)sheet rowCount:(NSInteger)rowCount {
    if ((self = [super initWithFrame:frame])) {
        _sheet = sheet;
        _spriteRowCount = rowCount;
        _lookDirection = -1;
        _frames = @[@0, @1, @2, @3, @4, @5];
        _frameHolds = @[@1, @1, @1, @1, @1, @1];
        _petMenuPreviewCache = [NSCache new];
        _petMenuPreviewCache.countLimit = 24;
        _petMenuPreviewCache.totalCostLimit = 4 * 1024 * 1024;
        _cellCache = [NSCache new];
        _cellCache.totalCostLimit = 6 * 1024 * 1024;
        self.wantsLayer = YES;
        _spriteLayer = [CALayer layer];
        // 像素素材放大必须用最近邻，等价于原来 drawRect: 里的 NSImageInterpolationNone。
        _spriteLayer.magnificationFilter = kCAFilterNearest;
        _spriteLayer.minificationFilter = kCAFilterNearest;
        // contentsScale 由 rebuildSpriteCache 按 backingScaleFactor 定，这里不预设。
        // 锚点放在脚底：呼吸和之后的落地 squash 都该以脚为支点，锚在正中会变成
        // "整体缩放"，看着像忽远忽近而不是有重量。
        _spriteLayer.anchorPoint = CGPointMake(0.5, 0.0);
        [self.layer addSublayer:_spriteLayer];
        [self layoutSpriteLayer];
        [self rebuildSpriteCache];
        [NSNotificationCenter.defaultCenter addObserver:self
            selector:@selector(powerStateDidChange:)
            name:NSProcessInfoPowerStateDidChangeNotification object:nil];
        [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self
            selector:@selector(powerStateDidChange:)
            name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
        [self updatePowerPreferences];
        [self updateFrameTimer];
        NSTrackingArea *tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
            options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                    NSTrackingActiveAlways | NSTrackingInVisibleRect
            owner:self userInfo:nil];
        [self addTrackingArea:tracking];
        [self rebuildCapabilities];
        [self updateLookTracking];
    }
    return self;
}
// 只碰 ivar，不走属性 setter：setter 会调用 updateFrameTimer，在 dealloc 期间
// 重新排一个定时器出来。
- (void)dealloc {
    [_frameTimer invalidate];
    if (_globalMouseMonitor) [NSEvent removeMonitor:_globalMouseMonitor];
    if (_localMouseMonitor) [NSEvent removeMonitor:_localMouseMonitor];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}
- (void)powerStateDidChange:(NSNotification *)notification {
    [self updatePowerPreferences];
}
- (void)updatePowerPreferences {
    BOOL lowPower = NSProcessInfo.processInfo.lowPowerModeEnabled;
    BOOL reduceMotion = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    if (self.lowPowerMode == lowPower && self.reduceMotion == reduceMotion) return;
    self.lowPowerMode = lowPower;
    self.reduceMotion = reduceMotion;
    [self.frameTimer invalidate];
    self.frameTimer = nil;
    [self updateFrameTimer];
    [self updateBreathingAnimation];
}
// 定时器只看可见性。十六向跟随期间它也要转——注意力现在是有时限的，到点必须有人
// 把它收回来，而 updateLookForScreenPoint: 只在鼠标移动时才被调用，鼠标一停就没人
// 收尾了。跟随期间 nextFrame: 除了这个到期检查之外仍然什么都不做。
- (void)updateFrameTimer {
    BOOL shouldRun = !self.animationSuspended;
    if (shouldRun == self.frameTimer.isValid) return;
    if (!shouldRun) {
        [self.frameTimer invalidate];
        self.frameTimer = nil;
        return;
    }
    // block 版定时器 + weak self，避免 NSTimer 持有 target 造成 PetView 永不释放。
    __weak PetView *weakSelf = self;
    NSTimeInterval interval = PetFrameInterval;
    if (self.lowPowerMode) interval *= 1.5;
    if (self.reduceMotion) interval *= 2.0;
    // 必须注册到 common modes：performWindowDragWithEvent: 期间主 runloop 处于
    // NSEventTrackingRunLoopMode，只挂在默认 mode 上的定时器不会触发，宠物会
    // 定格在拖动起手的那一帧上，直到松手才继续动。
    self.frameTimer = [NSTimer timerWithTimeInterval:interval repeats:YES
        block:^(NSTimer *timer) { [weakSelf nextFrame:timer]; }];
    self.frameTimer.tolerance = interval * 0.25;
    [NSRunLoop.mainRunLoop addTimer:self.frameTimer forMode:NSRunLoopCommonModes];
}
- (void)setLookDirection:(NSInteger)value {
    if (_lookDirection == value) return;
    _lookDirection = value;
    [self updateFrameTimer];
}
- (void)setAnimationSuspended:(BOOL)suspended {
    if (_animationSuspended == suspended) return;
    _animationSuspended = suspended;
    [self updateFrameTimer];
    // 停表只管得住 NSTimer 驱动的逐帧动画。呼吸、弹簧这些走 CA，时钟在 render server
    // 那边，屏幕睡了照跑——必须把这一层的本地时间也冻住，否则 P0 省下来的电又漏回去。
    [self setSpriteLayerPaused:suspended];
    if (suspended) {
        // 屏幕睡了就把栅格化缓存整个放掉：这是常驻内存里最大的一块，而睡眠期间一格都用不上。
        // 醒来重新栅格化只是几毫秒的事，换十几兆常驻内存很划算。
        [self.cellCache removeAllObjects];
    } else {
        [self updateSpriteContents];
    }
}
// 冻结/恢复 layer 自己的时间轴。恢复时要把暂停期间流逝的时间补回 beginTime，
// 否则动画会从"睡了多久就跳多远"的位置继续。
- (void)setSpriteLayerPaused:(BOOL)paused {
    CALayer *layer = self.spriteLayer;
    if (!layer) return;
    if (paused) {
        if (layer.speed == 0.0) return;
        CFTimeInterval now = [layer convertTime:CACurrentMediaTime() fromLayer:nil];
        layer.speed = 0.0;
        layer.timeOffset = now;
    } else {
        if (layer.speed != 0.0) return;
        CFTimeInterval pausedAt = layer.timeOffset;
        layer.speed = 1.0;
        layer.timeOffset = 0.0;
        layer.beginTime = 0.0;
        layer.beginTime = [layer convertTime:CACurrentMediaTime() fromLayer:nil] - pausedAt;
    }
}
- (void)startLookTracking {
    if (!self.hasLookRows || self.globalMouseMonitor || self.localMouseMonitor) return;
    __weak PetView *weakSelf = self;
    self.globalMouseMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskMouseMoved
        handler:^(NSEvent *event) {
            [weakSelf updateLookForScreenPoint:NSEvent.mouseLocation];
        }];
    self.localMouseMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved
        handler:^NSEvent *(NSEvent *event) {
            [weakSelf updateLookForScreenPoint:NSEvent.mouseLocation];
            return event;
        }];
}
- (void)stopLookTracking {
    if (self.globalMouseMonitor) {
        [NSEvent removeMonitor:self.globalMouseMonitor];
        self.globalMouseMonitor = nil;
    }
    if (self.localMouseMonitor) {
        [NSEvent removeMonitor:self.localMouseMonitor];
        self.localMouseMonitor = nil;
    }
    self.lookDirection = -1;
}
- (void)updateLookTracking {
    if (self.hasLookRows) [self startLookTracking];
    else [self stopLookTracking];
}
// 注意力有惯性也有衰减，这是活物和传感器的分水岭。
//
// 改造前是鼠标一动就实时跟随——那是摄像头。现在是：多数移动它压根不理会，偶尔才
// "注意到"，看一阵子就失去兴趣回正，而且短期内不会再被同一波移动勾走。
// 副作用是开销大幅下降：原来屏幕上每个鼠标事件都要换一次朝向定格并重绘，现在只有
// 真正处于注意状态的那几秒才跟。
- (void)releaseAttention {
    if (self.lookDirection < 0) return;
    self.lookDirection = -1;
    self.attentionCooldownUntil = CFAbsoluteTimeGetCurrent() +
        4.0 + 8.0 * (arc4random_uniform(1000) / 1000.0);
    [self playRow:0 throughFrame:5 oneShot:NO];
}
- (void)updateLookForScreenPoint:(NSPoint)screenPoint {
    if (!self.hasLookRows || self.draggingPet || self.oneShot || self.agentActive ||
        self.microActive || !self.window) return;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (self.lookDirection < 0) {
        if (now < self.attentionCooldownUntil) return;
        // 绝大多数移动都不理会。这一条就是"惰性"本身。
        if (arc4random_uniform(100) >= 12) return;
        self.attentionUntil = now + 3.0 + 5.0 * (arc4random_uniform(1000) / 1000.0);
    }

    NSPoint windowPoint = [self.window convertPointFromScreen:screenPoint];
    NSPoint localPoint = [self convertPoint:windowPoint fromView:nil];
    if (NSPointInRect(localPoint, self.bounds)) return;

    NSPoint center = [self convertPoint:NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds)) toView:nil];
    center = [self.window convertPointToScreen:center];
    CGFloat dx = screenPoint.x - center.x;
    CGFloat dy = screenPoint.y - center.y;
    if (hypot(dx, dy) <= 1.0) return;

    CGFloat degrees = fmod(atan2(dx, dy) * 180.0 / M_PI + 360.0, 360.0);
    NSInteger direction = ((NSInteger)llround(degrees / 22.5)) % 16;
    if (direction == self.lookDirection) return;

    self.lookDirection = direction;
    self.rowIndex = 9 + direction / 8;
    self.frameIndex = direction % 8;
    self.needsDisplay = YES;
}
- (NSArray<NSNumber *> *)framesFromZeroThrough:(NSInteger)last {
    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:last + 1];
    for (NSInteger index = 0; index <= last; index++) [result addObject:@(index)];
    return result;
}
// 全 1 的停留表 = 原来的匀速播放。
- (NSArray<NSNumber *> *)uniformHoldsForCount:(NSUInteger)count {
    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) [result addObject:@1];
    return result;
}
// 待机的停留表：整轮统一放慢或加快，**绝不定格某一帧**。
//
// 试过"随机挑一帧长停 8~18 拍"做发呆，实测很别扭，别改回去。原因是素材不受控：
// 每套素材的待机行内容都不一样，第 0 帧也不保证是自然站姿，随便定格一帧经常停在
// 动作做到一半的姿势上，读起来是"动画卡住了"而不是"它在休息"。
// 改成只调速度：慢下来同样能读出"它安静了"，而且因为始终在动，任何素材都不会翻车。
//
// 速度在 1~3 拍/帧之间随机游走（0.22~0.66s 一帧），并在一轮之内从上一档平滑过渡到
// 新一档，避免在循环接缝处突然变速。上限压在 3 拍，再慢就接近定格了。
// 现在返回匀速，等于关掉了这个行为。frameHolds 机制本身保留：微动层要用它做
// "慢放一个已有动作"和"定格朝向若干拍"，而且全 1 时行为和改造前完全一致，留着零成本。
//
// 两版都试过，都不行，别再往回走：
//   1. 随机挑一帧长停 8~18 拍做"发呆"——素材不受控，第 0 帧也不保证是自然站姿，
//      经常停在动作做到一半的姿势上，读起来是"动画卡住了"。
//   2. 整轮 1~3 拍随机游走做"慢下来"——同样是在改一条连续动画的播放节奏，
//      观感是掉帧，不是休息。
// 结论：待机行本身已经是完整循环，动它的节奏一律读成故障。待机的活物感要靠
// **往流里插入有始有终的动作**（微动层），而不是改流本身的速度。
- (NSArray<NSNumber *> *)idleHoldsForCount:(NSUInteger)count {
    return [self uniformHoldsForCount:count];
}
- (BOOL)isIdleRow:(NSInteger)row {
    return row == 0;
}
- (void)playRow:(NSInteger)row throughFrame:(NSInteger)last oneShot:(BOOL)oneShot {
    if (!oneShot && !self.oneShot && self.rowIndex == row) return;
    // 任何外部动作（悬停、拖动、agent 事件）都直接接管，微动无条件让位。
    if (self.microActive) {
        self.microActive = NO;
        [self scheduleNextMicroBehavior];
    }
    self.lookDirection = -1;
    self.frameRows = nil;
    self.rowIndex = row;
    self.frames = [self framesFromZeroThrough:last];
    self.frameHolds = [self isIdleRow:row] && !oneShot
        ? [self idleHoldsForCount:self.frames.count]
        : [self uniformHoldsForCount:self.frames.count];
    self.holdTicks = 0;
    self.sequenceIndex = 0;
    self.frameIndex = 0;
    self.oneShot = oneShot;
    self.needsDisplay = YES;
}
- (BOOL)isPocketPoint:(NSPoint)point {
    CGFloat centerX = NSMidX(self.bounds);
    CGFloat centerY = NSHeight(self.bounds) * 0.32;
    CGFloat dx = (point.x - centerX) / (NSWidth(self.bounds) * 0.22);
    CGFloat dy = (point.y - centerY) / (NSHeight(self.bounds) * 0.16);
    return dx * dx + dy * dy <= 1.0;
}
- (BOOL)updatePocketHoverForPoint:(NSPoint)point {
    BOOL overPocket = [self isPocketPoint:point];
    if (self.pocketHoverChanged) self.pocketHoverChanged(overPocket);
    if (overPocket) [NSCursor.pointingHandCursor set];
    else [NSCursor.arrowCursor set];
    return overPocket;
}
- (void)updateHoverForPoint:(NSPoint)point {
    [self noteActivity];
    BOOL overPocket = [self updatePocketHoverForPoint:point];
    if (overPocket) {
        [self playRow:5 throughFrame:7 oneShot:NO];
    } else if (point.y >= NSHeight(self.bounds) * 0.58) {
        [NSCursor.pointingHandCursor set];
        [self playRow:4 throughFrame:4 oneShot:NO];
    } else if (point.y <= NSHeight(self.bounds) * 0.20) {
        [NSCursor.pointingHandCursor set];
        [self playRow:6 throughFrame:5 oneShot:NO];
    } else if (point.x >= NSWidth(self.bounds) * 0.66) {
        [NSCursor.arrowCursor set];
        [self playRow:3 throughFrame:3 oneShot:NO];
    } else if (point.x <= NSWidth(self.bounds) * 0.34) {
        [NSCursor.arrowCursor set];
        [self playRow:8 throughFrame:5 oneShot:NO];
    } else {
        [NSCursor.arrowCursor set];
        [self playRow:0 throughFrame:5 oneShot:NO];
    }
}
- (void)mouseEntered:(NSEvent *)event {
    [self mouseMoved:event];
}
- (void)mouseMoved:(NSEvent *)event {
    if (self.draggingPet) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    // 一次性动作只锁定动画，不应锁住面板热区。否则鼠标在动作期间进入后停住，
    // oneShot 结束时不会再收到 mouseMoved，额度面板就一直没有机会展示。
    if (self.oneShot || self.agentActive) {
        [self updatePocketHoverForPoint:point];
        return;
    }
    [self updateHoverForPoint:point];
}
- (void)mouseExited:(NSEvent *)event {
    if (self.draggingPet) return;
    if (self.pocketHoverChanged) self.pocketHoverChanged(NO);
    [NSCursor.arrowCursor set];
    if (self.agentActive || self.oneShot) return;
    [self playRow:0 throughFrame:5 oneShot:NO];
}
- (void)nextFrame:(NSTimer *)timer {
    if (self.lookDirection >= 0) {
        if (CFAbsoluteTimeGetCurrent() >= self.attentionUntil) [self releaseAttention];
        return;
    }
    // performWindowDragWithEvent: 会立即返回，且窗口服务器可能吞掉 mouseUp。
    // 动画时钟同时作为释放兜底，避免拖动状态永久停留在 running 行。
    if (self.draggingPet &&
        !CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft)) {
        [self endPetDrag];
        return;
    }
    // 用力程度随时间衰减，掉档时把呼吸调回慢档。
    if (self.breathLevel != 0) [self updateBreathingIfExertionChanged];

    // 微动调度：只在待机且无人打扰时倒数，到点起一个小动作。
    if ([self canStartMicroBehavior]) {
        self.microCountdown -= 1;
        if (self.microCountdown <= 0) {
            [self startMicroBehavior];
            return;
        }
    }

    // 当前帧还没停够拍数就原地不动。停留期间连 needsDisplay 都不置，这一拍是纯空转。
    self.holdTicks += 1;
    if (self.holdTicks < [self holdForSequenceIndex:self.sequenceIndex]) return;
    self.holdTicks = 0;

    self.sequenceIndex += 1;
    if (self.sequenceIndex >= self.frames.count) {
        if (self.oneShot) {
            self.rowIndex = 0;
            self.frames = [self framesFromZeroThrough:5];
            self.frameHolds = [self idleHoldsForCount:self.frames.count];
            self.oneShot = NO;
            self.agentActive = NO;
            self.microActive = NO;
            [self scheduleNextMicroBehavior];
        } else if (self.microActive) {
            // 微动播完就回待机。这条分支独立于 oneShot，所以不会清 agentActive。
            [self endMicroBehavior];
            self.needsDisplay = YES;
            return;
        }
        self.sequenceIndex = 0;
    }
    self.frameIndex = self.frames[self.sequenceIndex].integerValue;
    self.needsDisplay = YES;
}
- (NSUInteger)holdForSequenceIndex:(NSUInteger)index {
    if (index >= self.frameHolds.count) return 1;
    NSUInteger hold = self.frameHolds[index].unsignedIntegerValue;
    return hold > 0 ? hold : 1;
}
- (void)handleAgentEvent:(NSString *)event tool:(NSString *)tool failed:(BOOL)failed {
    [self noteActivity];
    [self bumpExertion];
    if ([event isEqualToString:@"SessionStart"]) {
        self.agentActive = YES;
        [self playRow:4 throughFrame:4 oneShot:YES];
    } else if ([event isEqualToString:@"UserPromptSubmit"]) {
        self.agentActive = YES;
        [self playRow:5 throughFrame:7 oneShot:NO];
    } else if ([event isEqualToString:@"PermissionRequest"]) {
        self.agentActive = YES;
        [self playRow:4 throughFrame:4 oneShot:NO];
    } else if ([event isEqualToString:@"AutoReviewRequest"]) {
        self.agentActive = YES;
        [self playRow:8 throughFrame:5 oneShot:NO];
    } else if ([event isEqualToString:@"PreToolUse"]) {
        self.agentActive = YES;
        NSString *lower = tool.lowercaseString;
        if ([lower containsString:@"bash"] || [lower containsString:@"exec"]) {
            [self playRow:1 throughFrame:7 oneShot:NO];
        } else if ([lower containsString:@"patch"] || [lower containsString:@"edit"] || [lower containsString:@"write"]) {
            [self playRow:7 throughFrame:5 oneShot:NO];
        } else if ([lower containsString:@"read"] || [lower containsString:@"search"] || [lower containsString:@"find"] ||
                   [lower containsString:@"grep"] || [lower containsString:@"glob"] || [lower containsString:@"web"] ||
                   [lower hasPrefix:@"mcp__"]) {
            [self playRow:3 throughFrame:3 oneShot:NO];
        } else if ([lower isEqualToString:@"task"] || [lower containsString:@"agent"]) {
            [self playRow:6 throughFrame:5 oneShot:NO];
        } else {
            [self playRow:8 throughFrame:5 oneShot:NO];
        }
    } else if ([event isEqualToString:@"SubagentStart"] || [event isEqualToString:@"TaskCreated"]) {
        self.agentActive = YES;
        [self playRow:6 throughFrame:5 oneShot:NO];
    } else if ([event isEqualToString:@"PostToolUse"] || [event isEqualToString:@"PostToolUseFailure"]) {
        self.agentActive = YES;
        [self playRow:failed ? 5 : 7 throughFrame:failed ? 7 : 5 oneShot:YES];
    } else if ([event isEqualToString:@"StopFailure"]) {
        self.agentActive = YES;
        [self playRow:5 throughFrame:7 oneShot:YES];
    } else if ([event isEqualToString:@"Notification"]) {
        self.agentActive = YES;
        [self playRow:4 throughFrame:4 oneShot:YES];
    } else if ([event isEqualToString:@"Stop"] || [event isEqualToString:@"SubagentStop"] ||
               [event isEqualToString:@"TaskCompleted"] || [event isEqualToString:@"SessionEnd"]) {
        self.agentActive = YES;
        [self playRow:3 throughFrame:3 oneShot:YES];
    }
}
// 每一格都用**原来 drawRect: 那一次绘制**预先栅格化成位图，再交给 layer。
//
// 试过两条更"聪明"的路，都不行，别改回去：
//   1. CGImageCreateWithImageInRect 预裁——素材经 LoadPetSpriteImage 缩略后不保证能被
//      8 列 rowCount 行整除（超大素材缩略后可能得到小数尺寸的源格），
//      小数矩形会被取整，采样相位偏掉，边缘整行错位。
//   2. 整表交给 layer + contentsRect 选帧——CA 自己的最近邻缩放相位同样和 NSImage 对不上，
//      实测形状吻合度反而从 99.4% 掉到 93.5%。
// 照搬原来的 drawInRect:fromRect: 才能保证逐像素等价：栅格化的是同一段代码，只是从
// 每帧执行挪到了每格一次。
- (void)rebuildSpriteCache {
    [self.cellCache removeAllObjects];
    CGFloat scale = self.spriteScale;
    self.spriteLayer.contentsScale = scale;
    // 上限按倍率和行数定，不能写死：11 行素材光十六向朝向就占 16 格，加上待机和动作帧，
    // 固定 6MB（视网膜下约 18 格）会卡在淘汰边缘，鼠标绕着宠物转就不停重栅格化。
    //
    // 但也不能给太多。实测这一块是常驻内存最大的单一新增项：视网膜下每格 328KB，
    // 原来给 48 格 = 15.4MB，而真实活跃工作集只有待机 6 帧 + 当前动作 ≤8 帧 +
    // 偶尔几个朝向格，20 格足够，超出的部分纯粹是白占着。
    NSSize pointSize = NSInsetRect(self.bounds, 2, 0).size;
    self.spriteCacheSize = pointSize;
    NSUInteger cellCost = (NSUInteger)(ceil(pointSize.width * scale) *
        ceil(pointSize.height * scale) * 4);
    NSUInteger affordable = MIN((NSUInteger)(self.spriteRowCount * 8), (NSUInteger)20);
    self.cellCache.totalCostLimit = MAX(cellCost * affordable, (NSUInteger)(2 * 1024 * 1024));
    [self updateSpriteContents];
}
// 视网膜屏上必须按 backingScaleFactor 栅格化。原来 drawRect: 是直接画进 2x 的后备存储，
// 等于按实际屏幕分辨率采样源格；预栅格化成 1x 位图再让 layer 放大，
// 会比改造前糊一档。
- (CGFloat)spriteScale {
    CGFloat scale = self.window.backingScaleFactor;
    return scale > 0 ? scale : 1.0;
}
- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    // 换显示器会改 backingScaleFactor，缓存里全是按旧倍率栅格化的位图，必须整体作废。
    [self rebuildSpriteCache];
}
- (CGImageRef)cellImageForRow:(NSInteger)row frame:(NSInteger)frame {
    if (!self.sheet || self.spriteRowCount <= 0) return NULL;
    NSNumber *key = @(row * 8 + frame);
    id cached = [self.cellCache objectForKey:key];
    if (cached) return (__bridge CGImageRef)cached;

    NSRect target = NSInsetRect(self.bounds, 2, 0);
    NSSize pointSize = target.size;
    if (pointSize.width <= 0 || pointSize.height <= 0) return NULL;
    CGFloat scale = self.spriteScale;
    NSInteger pixelWidth = (NSInteger)ceil(pointSize.width * scale);
    NSInteger pixelHeight = (NSInteger)ceil(pointSize.height * scale);

    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:pixelWidth pixelsHigh:pixelHeight
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep.size = pointSize;

    CGFloat cellWidth = self.sheet.size.width / 8.0;
    CGFloat cellHeight = self.sheet.size.height / self.spriteRowCount;
    NSRect source = NSMakeRect(frame * cellWidth,
        self.sheet.size.height - (row + 1) * cellHeight, cellWidth, cellHeight);

    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = context;
    [self.sheet drawInRect:NSMakeRect(0, 0, pointSize.width, pointSize.height) fromRect:source
        operation:NSCompositingOperationSourceOver fraction:1.0
        respectFlipped:NO hints:@{NSImageHintInterpolation: @(NSImageInterpolationNone)}];
    [NSGraphicsContext restoreGraphicsState];

    CGImageRef cell = rep.CGImage;
    if (!cell) return NULL;
    [self.cellCache setObject:(__bridge id)cell forKey:key
        cost:(NSUInteger)(pixelWidth * pixelHeight * 4)];
    return cell;
}
// 只打标记，真正换图交给 AppKit 的显示周期。
//
// 不要改回"在 setter 里同步换 contents"：十六向跟随装的是全局鼠标监听，屏幕上每个
// 鼠标移动事件都会写 rowIndex/frameIndex（一次方向变化还是连写两个）。同步更新等于
// 几百次/秒一次不落，实测疯狂动鼠标时 CPU 6~8%，冷缓存期峰值 12.5%。改造前那两个是
// 无副作用的纯属性 + needsDisplay，由 AppKit 合并成每刷新周期最多一次——这里要还原的
// 就是那个语义。
- (void)updateSpriteContents {
    self.needsDisplay = YES;
}
// layer-backed 视图走 updateLayer 而不是 drawRect:，AppKit 每个显示周期最多调一次。
- (BOOL)wantsUpdateLayer {
    return YES;
}
// 换 contents 会触发 CA 默认的 0.25s 淡入。逐帧动画上那就是一层永久的拖影，必须关掉。
- (void)updateLayer {
    CGImageRef cell = [self cellImageForRow:self.rowIndex frame:self.frameIndex];
    if (!cell) return;
    // 逐帧动画默认必须关掉隐式动画，否则每一帧都带 0.25s 淡入，等于一层永久拖影。
    // 只有进出微动那一下例外：那是两个不相干姿势之间的硬切，给一次短淡化才不突兀。
    if (self.fadeNextContents) {
        self.fadeNextContents = NO;
        CATransition *fade = [CATransition animation];
        fade.type = kCATransitionFade;
        fade.duration = 0.13;
        [self.spriteLayer addAnimation:fade forKey:@"contentsFade"];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.spriteLayer.contents = (__bridge id)cell;
    [CATransaction commit];
}
- (void)layout {
    [super layout];
    [self refreshSpriteSize];
}
- (void)refreshSpriteSize {
    [self layoutSpriteLayer];
    // 每格缓存的键只包含行/帧，尺寸改变后必须清掉旧尺寸的位图。
    if (!NSEqualSizes(self.spriteCacheSize, NSInsetRect(self.bounds, 2, 0).size)) {
        [self rebuildSpriteCache];
    }
}
- (void)setFrame:(NSRect)newFrame {
    [super setFrame:newFrame];
    [self refreshSpriteSize];
}
- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self refreshSpriteSize];
}
// 锚点是脚底 (0.5, 0)，所以不能直接设 frame——那会把锚点当左下角算。改用 bounds + position。
- (void)layoutSpriteLayer {
    NSRect target = NSInsetRect(self.bounds, 2, 0);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.spriteLayer.bounds = CGRectMake(0, 0, NSWidth(target), NSHeight(target));
    self.spriteLayer.position = CGPointMake(NSMidX(target), NSMinY(target));
    [CATransaction commit];
}
// 呼吸是常驻 CA 动画：插值和合成都在 render server 侧，主进程零唤醒。
// 用 byValue 而不是 toValue，动画相对当前 model 值走，换素材或重新布局都不用重设。
- (void)updateBreathingAnimation {
    // reduceMotion 下彻底不做。这不是省电问题——系统开了减弱动效，持续浮动本身就是
    // 用户明确不想要的东西。
    BOOL shouldBreathe = self.window != nil && !self.reduceMotion;
    if (!shouldBreathe) {
        [self.spriteLayer removeAnimationForKey:@"breath"];
        return;
    }
    if ([self.spriteLayer animationForKey:@"breath"]) return;
    // 越用力呼吸越快、起伏越大。平复回基线是自然衰减出来的，不用单独写过渡。
    NSInteger level = [self exertionLevel];
    double tempo = level == 0 ? 1.0 : (level == 1 ? 0.72 : 0.52);
    double rise = level == 0 ? PetBreathRise : PetBreathRise * (level == 1 ? 1.3 : 1.7);
    CABasicAnimation *breath = [CABasicAnimation animationWithKeyPath:@"position.y"];
    breath.byValue = @(rise);
    breath.duration = PetBreathPeriod * tempo / 2.0;
    breath.autoreverses = YES;
    breath.repeatCount = HUGE_VALF;
    breath.timingFunction = [CAMediaTimingFunction
        functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.spriteLayer addAnimation:breath forKey:@"breath"];
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    // 进窗口才知道 backingScaleFactor，缓存要按真实倍率重建；呼吸也从这里起步。
    [self rebuildSpriteCache];
    [self updateBreathingAnimation];
    [self restoreLastActivity];
}
- (void)setRowIndex:(NSInteger)value {
    if (_rowIndex == value) return;
    _rowIndex = value;
    [self updateSpriteContents];
}
- (void)setFrameIndex:(NSInteger)value {
    if (_frameIndex == value) return;
    _frameIndex = value;
    [self updateSpriteContents];
}
- (void)setSheet:(NSImage *)sheet {
    if (_sheet == sheet) return;
    _sheet = sheet;
    [self rebuildSpriteCache];
}
- (void)setSpriteRowCount:(NSInteger)count {
    if (_spriteRowCount == count) return;
    _spriteRowCount = count;
    [self rebuildSpriteCache];
}
- (void)applySheet:(NSImage *)sheet petID:(NSString *)petID rowCount:(NSInteger)rowCount {
    // 直接写 ivar 再统一重建：走 setter 会因为 sheet 和 rowCount 分两次设置而拿旧行数
    // 白裁一遍缓存。
    _sheet = sheet;
    _spriteRowCount = rowCount;
    _rowIndex = 0;
    _frameIndex = 0;
    self.lookDirection = -1;
    self.currentPetID = petID;
    self.sequenceIndex = 0;
    self.frames = [self framesFromZeroThrough:5];
    self.frameHolds = [self idleHoldsForCount:self.frames.count];
    self.holdTicks = 0;
    self.oneShot = NO;
    self.interactionClickCount = 0;
    self.lastInteractionClickAt = 0;
    [self rebuildSpriteCache];
    [self rebuildCapabilities];
    [self updateLookTracking];
}
@end
