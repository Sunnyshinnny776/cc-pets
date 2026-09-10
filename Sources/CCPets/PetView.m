#import "PetView.h"
#import <QuartzCore/QuartzCore.h>
#import "MenuToggleSwitch.h"
#import "CCPetsPaths.h"
#import "CCPetsImageLoader.h"

// 碎碎念频率档位的 defaults 键。定义在 CCPetsAppDelegate.m，这里只读不写；
// 单独 extern 而不 import 那个头文件，是因为它反过来 import 了 PetView.h。
extern NSString *const PetSpeechFrequencyKey;

NSString *const PetInteractionEnabledKey = @"CCPetsInteractionEnabled";
NSString *const PetInteractionHeartThresholdKey = @"CCPetsInteractionHeartThreshold";
NSString *const PetInteractionAnnoyedThresholdKey = @"CCPetsInteractionAnnoyedThreshold";
NSString *const PetInteractionIntervalKey = @"CCPetsInteractionInterval";

// 按下后位移超过这个距离才判定为拖动，之内视为点击。
static const CGFloat PetDragThreshold = 3.0;
// 菜单里自绘行的宽度：主菜单要撑满 menu.minimumWidth，子菜单按自身内容收窄，
// 三个子菜单（用量展示模式 / 系统通知 / 系统状态）用同一个宽度，看起来才是一套。
static const CGFloat PetMenuRowWidth = 194.0;
static const CGFloat PetSubmenuRowWidth = 134.0;
// 与“系统通知”里文案到开关的间距共用，素材名称到删除按钮也保持一致。
static const CGFloat PetMenuControlGap = 8.0;
static const NSInteger PetMenuCheckViewTag = 1001;
static const NSInteger PetMenuDeleteButtonTag = 1002;
// 呼吸：只向上浮，不做上下对称摆动。宠物视图在 230×170 的窗口里位于 (43,0,144,150)，
// 下方一点余量都没有，往下 1px 就被窗口裁掉。静止位不变，所以离屏基准图不受影响。
static const CGFloat PetBreathRise = 1.5;
static const NSTimeInterval PetBreathPeriod = 3.6;
// 拖动滞后只做水平方向。窗口左右各有 43px 余量，而下方是 0——垂直滞后往下一点就被裁掉，
// 只留向上会变成不对称的怪动作，不如不做。反正拖动本来就按水平方向选跑动行，
// 水平滞后正好强化那个方向感。
static const CGFloat PetDragLagMax = 13.0;
static const CGFloat PetDragLagFactor = 0.85;
// 松手后的"落脚"：先压扁再回弹到静止。锚点在脚底，所以压扁是往下坐，不会越界。
static const NSTimeInterval PetSettleDuration = 0.34;
// 微动层：待机时每隔一段随机时间做一个有始有终的小动作。间隔必须随机——固定周期
// 会被下意识数出拍子，一旦数出来就全毁了。
static const NSTimeInterval PetMicroIntervalMin = 8.0;
static const NSTimeInterval PetMicroIntervalMax = 25.0;
// 无聊曲线的三个拐点（秒）。闲久了先躁动、再倦、最后几乎不动，是条先升后降的曲线。
static const NSTimeInterval PetBoredomRestless = 120.0;
static const NSTimeInterval PetBoredomTired = 600.0;
static const NSTimeInterval PetBoredomDrowsy = 1800.0;
// 十六向朝向定格保持多久（秒）。这是素材本来就设计成静止的格子，定格不违和。
static const NSTimeInterval PetGlanceHoldMin = 0.7;
static const NSTimeInterval PetGlanceHoldMax = 1.6;
// 生理余韵：agent 干完活之后呼吸会快一阵，再用几十秒平复回基线。
// 事件结束不等于状态归零——这种跨状态的连续性是免费的活物感。
static const double PetExertionPerEvent = 0.15;
static const NSTimeInterval PetExertionHalfLife = 25.0;
// 上次交互时间落盘的键。重启后接着算无聊曲线，隔了几小时再开就是从"打盹"开始，
// 而不是每次启动都精神抖擞。
static NSString *const PetLastActivityKey = @"CCPetsLastActivityAt";
static const NSTimeInterval PetActivitySaveInterval = 60.0;

// 微动的种类。加新动作就往这里加一项、再往 microBehaviorTable 里登记一行，
// 调度器不用改。
typedef NS_ENUM(NSInteger, PetMicroBehaviorKind) {
    PetMicroBehaviorGlance,  // 逐格转头看鼠标，需要十六向朝向行
    PetMicroBehaviorScan,    // row 3 张望，任何素材都有
};

@interface PetView ()
@property(weak) NSMenu *activePetSwitchMenu;
@property(copy) NSString *pendingDeletePetID;
// 素材能力：由行数在 applySheet: 时一次算出，之后全程只读这个，不再各处判行数。
//
// 散在各处写 rowCount == 11 的话，每加一个行为就多一处分支，测试翻倍且迟早漂移。
// 收成能力位之后，差异降级成"微动表里哪几行可用"这一个数据问题，调度器根本
// 不知道有分档这回事。
@property BOOL hasLookRows;
// 按能力过滤后的可用微动表，每项 @{kind, weight}。
@property NSArray<NSDictionary *> *microBehaviorTable;
// 精灵内容单独挂一层：呼吸、弹簧、落地 squash 都要对这一层做 CA 动画，放在视图自己的
// layer 上会连带影响命中测试和子视图几何。
@property CALayer *spriteLayer;
// 当前帧已经停了几拍，够 frameHolds 里那个数才推进。
@property NSUInteger holdTicks;
// 待机当前的速度档（拍/帧）。行为已关，字段留给微动层的慢放用。
@property NSUInteger idleHold;
// 微动层：独立于 oneShot 的一套标志。
//
// 绝对不能复用 oneShot——它在 nextFrame: 里播完会连带把 agentActive 清成 NO
// （见那一处注释）。微动是待机期间的自发动作，跟 agent 状态毫无关系，借它的壳会把
// "agent 正在干活"这个状态误清掉。
@property BOOL microActive;
// 下一次换图走一次短淡入淡出。进出微动那一下是硬切，加这一下过渡就不突兀了。
@property BOOL fadeNextContents;
@property NSInteger microCountdown;
// 最后一次"有事发生"的时间：agent 事件、鼠标交互、拖动都算。无聊曲线按它算。
//
// 不要改用 agentActive 判断闲了多久：mouseDown: 会无条件把它清成 NO，不管 agent
// 是不是还在跑，用户随手点一下宠物就会让无聊曲线误启动。
@property NSTimeInterval lastActivityTime;
// 注意力：真正在看的方向、以及这次注意力还能维持多久。
@property NSTimeInterval attentionUntil;
@property NSTimeInterval attentionCooldownUntil;
// 生理余韵：用力程度（0~1，按半衰期衰减）、上次更新时刻、当前呼吸档位。
@property double exertion;
@property NSTimeInterval exertionUpdatedAt;
@property NSInteger breathLevel;
@property NSTimeInterval lastActivitySavedAt;
// 拖动期间记上一次窗口位置，用来算这一帧走了多远。窗口服务器接管拖动后不给应用连续
// 事件，但 NSWindowDidMoveNotification 照发，这是拖动中唯一拿得到的位移信号。
@property NSPoint lastDragWindowOrigin;
@property BOOL observingWindowMove;
// 连击只统计没有变成拖动的左键释放。
@property NSInteger interactionClickCount;
@property NSTimeInterval lastInteractionClickAt;
// 按格栅格化的位图。视网膜下每格 280×300×4 ≈ 328KB，整表 88 格会到 28MB，
// 所以设 cost 上限让它只留住真正在播的那些格。
@property NSCache<NSNumber *, id> *cellCache;
@end

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
#pragma mark - 微动层

- (void)noteActivity {
    self.lastActivityTime = CFAbsoluteTimeGetCurrent();
    [self scheduleNextMicroBehavior];
    [self persistLastActivityThrottled];
}
// 落盘限流：noteActivity 在鼠标划过宠物时会被高频调用，每次都写 defaults 没必要。
- (void)persistLastActivityThrottled {
    if (self.lastActivityTime - self.lastActivitySavedAt < PetActivitySaveInterval) return;
    self.lastActivitySavedAt = self.lastActivityTime;
    [NSUserDefaults.standardUserDefaults setDouble:self.lastActivityTime
        forKey:PetLastActivityKey];
}
- (void)restoreLastActivity {
    double saved = [NSUserDefaults.standardUserDefaults doubleForKey:PetLastActivityKey];
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    // 只认过去的时间戳：系统时钟被调过或 defaults 被写坏时，宁可当成"刚刚活动过"，
    // 也不能让宠物一启动就以为闲置了几十年直接进打盹。
    if (saved > 0 && saved <= now) self.lastActivityTime = saved;
    else self.lastActivityTime = now;
    self.lastActivitySavedAt = self.lastActivityTime;
    [self scheduleNextMicroBehavior];
}
// 当前用力程度，按半衰期衰减。
- (double)currentExertion {
    NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - self.exertionUpdatedAt;
    if (elapsed <= 0) return self.exertion;
    return self.exertion * pow(0.5, elapsed / PetExertionHalfLife);
}
- (void)bumpExertion {
    self.exertion = MIN(1.0, [self currentExertion] + PetExertionPerEvent);
    self.exertionUpdatedAt = CFAbsoluteTimeGetCurrent();
    [self updateBreathingIfExertionChanged];
}
// 分档而不是连续调：改呼吸快慢要重加 CA 动画，相位会跳一下（最多 1.5px）。
// 分成三档之后一次任务里只会重加两三次，跳动察觉不到；连续调就是每拍都跳。
- (NSInteger)exertionLevel {
    double exertion = [self currentExertion];
    if (exertion < 0.2) return 0;
    if (exertion < 0.6) return 1;
    return 2;
}
- (void)updateBreathingIfExertionChanged {
    NSInteger level = [self exertionLevel];
    if (level == self.breathLevel) return;
    self.breathLevel = level;
    [self.spriteLayer removeAnimationForKey:@"breath"];
    [self updateBreathingAnimation];
}
// 无聊曲线：闲久了先躁动（微动变频繁）、再倦、最后几乎不动。
// 这条曲线是非单调的，本身就是叙事——"闲得发慌"和"待久了发蔫"是两种不同的状态。
// 调试用：把无聊曲线的三个拐点整体缩放，好在几十秒内走完本来要半小时的过程。
//   defaults write com.universewang.cc-pets CCPetsBoredomScale -float 0.25
//   defaults delete com.universewang.cc-pets CCPetsBoredomScale   # 恢复正常
// 域名必须是 bundle identifier，写成 "cc-pets" 会落到另一个 plist，桌宠读不到。
// 每次排期都现读，改完立刻生效，不用重启桌宠。缺省 1.0，也就是不缩放。
- (double)boredomScale {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:@"CCPetsBoredomScale"];
    if (![value isKindOfClass:NSNumber.class]) return 1.0;
    double scale = [value doubleValue];
    if (!(scale > 0)) return 1.0;
    return MIN(scale, 10.0);
}
- (double)microIntervalScale {
    NSTimeInterval idle = (CFAbsoluteTimeGetCurrent() - self.lastActivityTime) / [self boredomScale];
    if (idle < PetBoredomRestless) return 1.0;
    if (idle < PetBoredomTired) return 0.5;      // 躁动：间隔减半
    if (idle < PetBoredomDrowsy) return 2.0;     // 倦
    return 6.0;                                   // 打盹
}
- (void)scheduleNextMicroBehavior {
    double scale = [self microIntervalScale];
    double span = PetMicroIntervalMax - PetMicroIntervalMin;
    double seconds = (PetMicroIntervalMin + span * (arc4random_uniform(1000) / 1000.0)) * scale;
    self.microCountdown = (NSInteger)llround(seconds / PetFrameInterval);
}
// 待机之外一律不做：agent 在干活、正在拖、正在播一次性动作、十六向跟随中都不打断。
- (BOOL)canStartMicroBehavior {
    return !self.microActive && !self.agentActive && !self.oneShot && !self.draggingPet &&
        !self.animationSuspended && self.lookDirection < 0 && self.window != nil &&
        [self isIdleRow:self.rowIndex];
}
// 微动只用"有始有终的动作"，不改待机流本身的节奏。
//
// 9 行素材只有 row 3（观察）语义足够中性——它是一个独立动作，读起来是"它张望了一下"。
// 强语义行（row 1 跑/bash、row 7 工作/edit）绝不能用：待机时冒出来，用户会以为
// agent 在干活。
// 11 行素材额外可以用 row 9/10 的十六向定格：那是素材本来就设计成静止的格子，
// 定格不违和，且语义纯粹是"朝某个方向看"。
// 鼠标当前在哪个方向。算法和 updateLookForScreenPoint: 同源，-1 表示算不出来。
- (NSInteger)directionTowardScreenPoint:(NSPoint)screenPoint {
    if (!self.window) return -1;
    NSPoint center = [self convertPoint:NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds)) toView:nil];
    center = [self.window convertPointToScreen:center];
    CGFloat dx = screenPoint.x - center.x;
    CGFloat dy = screenPoint.y - center.y;
    if (hypot(dx, dy) <= 1.0) return -1;
    CGFloat degrees = fmod(atan2(dx, dy) * 180.0 / M_PI + 360.0, 360.0);
    return ((NSInteger)llround(degrees / 22.5)) % 16;
}
// 十六向是绕一圈排的，两个方向之间要走近的那一侧，否则会绕远大半圈。
- (NSInteger)directionStepFrom:(NSInteger)from to:(NSInteger)to {
    NSInteger forward = ((to - from) + 16) % 16;
    return forward <= 8 ? 1 : -1;
}
// 转头：从目标方向的前几格逐格扫过去 → 停一下 → 再逐格扫回来。
//
// 素材里 row 9/10 那 16 格本来只是"朝某个方向的静止姿势"，但按角度顺序连着播，
// 白捡一个转头动画——不需要任何新素材。这是十六向素材最值钱的用法。
- (BOOL)startGlanceMicroBehavior {
    NSInteger target = [self directionTowardScreenPoint:NSEvent.mouseLocation];
    if (target < 0) return NO;

    const NSInteger sweep = 3;
    NSInteger step = [self directionStepFrom:(target - sweep + 16) % 16 to:target];
    NSTimeInterval hold = PetGlanceHoldMin +
        (PetGlanceHoldMax - PetGlanceHoldMin) * (arc4random_uniform(1000) / 1000.0);
    NSUInteger holdTicks = MAX((NSUInteger)1, (NSUInteger)llround(hold / PetFrameInterval));

    NSMutableArray<NSNumber *> *rows = [NSMutableArray array];
    NSMutableArray<NSNumber *> *cols = [NSMutableArray array];
    NSMutableArray<NSNumber *> *holds = [NSMutableArray array];
    // 转过去
    for (NSInteger index = sweep; index >= 0; index--) {
        NSInteger direction = ((target - index * step) % 16 + 16) % 16;
        [rows addObject:@(9 + direction / 8)];
        [cols addObject:@(direction % 8)];
        [holds addObject:index == 0 ? @(holdTicks) : @1];
    }
    // 转回来。最后一格不重复停在目标上，直接从倒数第二格开始退。
    for (NSInteger index = 1; index <= sweep; index++) {
        NSInteger direction = ((target - index * step) % 16 + 16) % 16;
        [rows addObject:@(9 + direction / 8)];
        [cols addObject:@(direction % 8)];
        [holds addObject:@1];
    }

    // 不动 lookDirection：那个字段一旦 >=0 就进注意力模式，nextFrame: 只做到期检查，
    // 这段序列就没人推进了。
    self.frameRows = rows;
    self.frames = cols;
    self.frameHolds = holds;
    self.holdTicks = 0;
    self.sequenceIndex = 0;
    self.rowIndex = rows.firstObject.integerValue;
    self.frameIndex = cols.firstObject.integerValue;
    self.fadeNextContents = YES;
    self.needsDisplay = YES;
    return YES;
}
// 能力集在换素材时算一次。未知行数（比如第三方给了 10 行）自动落到无朝向档，
// 是安全的降级方向。
- (void)rebuildCapabilities {
    self.hasLookRows = self.spriteRowCount >= 11;
    NSMutableArray<NSDictionary *> *table = [NSMutableArray array];
    // 两档的行为密度要接近，只让表现形式不同。11 行档不该因为花样多就动得更频繁——
    // 用户切素材时该读作"这只性格不一样"，而不是"这只功能残缺"。
    if (self.hasLookRows) {
        [table addObject:@{@"kind": @(PetMicroBehaviorGlance), @"weight": @6}];
    }
    [table addObject:@{@"kind": @(PetMicroBehaviorScan), @"weight": @4}];
    self.microBehaviorTable = table;
}
- (void)startScanMicroBehavior {
    self.frameRows = nil;
    self.rowIndex = 3;
    self.frames = [self framesFromZeroThrough:3];
    self.frameHolds = [self uniformHoldsForCount:self.frames.count];
    self.holdTicks = 0;
    self.sequenceIndex = 0;
    self.frameIndex = 0;
    self.fadeNextContents = YES;
    self.needsDisplay = YES;
}
- (void)startMicroBehavior {
    self.microActive = YES;
    NSInteger total = 0;
    for (NSDictionary *entry in self.microBehaviorTable) total += [entry[@"weight"] integerValue];
    NSInteger roll = total > 0 ? (NSInteger)arc4random_uniform((uint32_t)total) : 0;
    for (NSDictionary *entry in self.microBehaviorTable) {
        roll -= [entry[@"weight"] integerValue];
        if (roll >= 0) continue;
        // 转头要拿得到鼠标方向，拿不到就顺势退到张望，不算失败。
        if ([entry[@"kind"] integerValue] == PetMicroBehaviorGlance &&
            [self startGlanceMicroBehavior]) {
            return;
        }
        break;
    }
    [self startScanMicroBehavior];
}
// 收尾只回待机，绝不碰 agentActive。
- (void)endMicroBehavior {
    self.microActive = NO;
    self.frameRows = nil;
    self.fadeNextContents = YES;
    self.rowIndex = 0;
    self.frames = [self framesFromZeroThrough:5];
    self.frameHolds = [self uniformHoldsForCount:self.frames.count];
    self.holdTicks = 0;
    self.sequenceIndex = 0;
    self.frameIndex = 0;
    [self scheduleNextMicroBehavior];
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
// 每一格都用**原来 drawRect: 那一次绘制**预先栅格化成位图，再交给 layer。
//
// 试过两条更"聪明"的路，都不行，别改回去：
//   1. CGImageCreateWithImageInRect 预裁——素材经 LoadPetSpriteImage 缩略后不保证能被
//      8 列 rowCount 行整除（默认素材 1536×1872 会装成 1120×1365，cellHeight=151.67），
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
    NSUInteger cellCost = (NSUInteger)(ceil(pointSize.width * scale) *
        ceil(pointSize.height * scale) * 4);
    NSUInteger affordable = MIN((NSUInteger)(self.spriteRowCount * 8), (NSUInteger)20);
    self.cellCache.totalCostLimit = MAX(cellCost * affordable, (NSUInteger)(2 * 1024 * 1024));
    [self updateSpriteContents];
}
// 视网膜屏上必须按 backingScaleFactor 栅格化。原来 drawRect: 是直接画进 2x 的后备存储，
// 等于用更高分辨率去采样那个 151.67 高的源格；预栅格化成 1x 位图再让 layer 放大，
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
    [self layoutSpriteLayer];
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
- (void)selectPetFromButton:(NSButton *)sender {
    NSString *petID = sender.identifier;
    if (petID.length == 0) return;
    [self resetPendingDeleteButton];
    if (self.switchPetRequested) self.switchPetRequested(petID);
    [self refreshPetMenuRows];
}
- (void)deletePetFromButton:(NSButton *)sender {
    NSString *petID = sender.identifier;
    if (petID.length == 0) return;
    if (![self.pendingDeletePetID isEqualToString:petID]) {
        [self resetPendingDeleteButton];
        self.pendingDeletePetID = petID;
        [self configureDeleteButton:sender confirming:YES];
        return;
    }

    BOOL deleted = self.deletePetRequested && self.deletePetRequested(petID);
    if (!deleted) {
        [self resetPendingDeleteButton];
        return;
    }
    self.pendingDeletePetID = nil;
    for (NSMenuItem *item in self.activePetSwitchMenu.itemArray.copy) {
        NSDictionary *pet = [item.representedObject isKindOfClass:NSDictionary.class]
            ? item.representedObject : nil;
        if ([pet[@"id"] isEqualToString:petID]) {
            [self.activePetSwitchMenu removeItem:item];
            break;
        }
    }
    [self refreshPetMenuRows];
}
- (void)configureDeleteButton:(NSButton *)button confirming:(BOOL)confirming {
    button.bordered = confirming;
    button.title = @"";
    button.attributedTitle = confirming
        ? [[NSAttributedString alloc] initWithString:@"确认" attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: NSColor.systemRedColor,
        }]
        : [[NSAttributedString alloc] initWithString:@""];
    button.image = confirming ? nil : [NSImage imageNamed:NSImageNameTrashEmpty];
    button.imagePosition = confirming ? NSNoImage : NSImageOnly;
    button.contentTintColor = nil;
    button.bezelStyle = NSBezelStyleRounded;
    button.hasDestructiveAction = YES;
    button.toolTip = confirming ? @"再次点击确认删除" : @"删除素材";
    [button setAccessibilityLabel:button.toolTip];
}
- (void)resetPendingDeleteButton {
    if (self.pendingDeletePetID.length == 0) return;
    for (NSMenuItem *item in self.activePetSwitchMenu.itemArray) {
        NSButton *button = (NSButton *)[item.view viewWithTag:PetMenuDeleteButtonTag];
        if ([button isKindOfClass:NSButton.class] &&
            [button.identifier isEqualToString:self.pendingDeletePetID]) {
            [self configureDeleteButton:button confirming:NO];
            break;
        }
    }
    self.pendingDeletePetID = nil;
}
- (void)refreshPetMenuRows {
    for (NSMenuItem *item in self.activePetSwitchMenu.itemArray) {
        NSDictionary *pet = [item.representedObject isKindOfClass:NSDictionary.class]
            ? item.representedObject : nil;
        NSString *petID = [pet[@"id"] isKindOfClass:NSString.class] ? pet[@"id"] : @"";
        BOOL selected = [petID isEqualToString:self.currentPetID];
        item.state = selected ? NSControlStateValueOn : NSControlStateValueOff;

        NSTextField *check = (NSTextField *)[item.view viewWithTag:PetMenuCheckViewTag];
        if ([check isKindOfClass:NSTextField.class]) check.stringValue = selected ? @"✓" : @"";

        NSButton *deleteButton = (NSButton *)[item.view viewWithTag:PetMenuDeleteButtonTag];
        if (![deleteButton isKindOfClass:NSButton.class]) continue;
        BOOL deletable = [petID hasPrefix:@"external:"] && !selected;
        deleteButton.hidden = !deletable;
        deleteButton.enabled = deletable;
        if (!deletable && [self.pendingDeletePetID isEqualToString:petID]) {
            [self configureDeleteButton:deleteButton confirming:NO];
            self.pendingDeletePetID = nil;
        }
    }
}
- (NSString *)displayNameForPetName:(NSString *)name font:(NSFont *)font maxWidth:(CGFloat)maxWidth {
    if (![name isKindOfClass:NSString.class]) return @"";
    NSDictionary<NSAttributedStringKey, id> *attributes = @{NSFontAttributeName: font};
    if ([name sizeWithAttributes:attributes].width <= maxWidth) return name;

    NSString *suffix = @"...";
    NSMutableString *prefix = [NSMutableString string];
    [name enumerateSubstringsInRange:NSMakeRange(0, name.length)
        options:NSStringEnumerationByComposedCharacterSequences
        usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
            NSString *candidate = [NSString stringWithFormat:@"%@%@%@", prefix, substring, suffix];
            if ([candidate sizeWithAttributes:attributes].width > maxWidth) {
                *stop = YES;
                return;
            }
            [prefix appendString:substring];
        }];
    return [prefix stringByAppendingString:suffix];
}
- (NSMenuItem *)addPetOption:(NSDictionary *)pet toMenu:(NSMenu *)menu {
    NSString *petID = [pet[@"id"] isKindOfClass:NSString.class] ? pet[@"id"] : @"";
    NSString *name = [pet[@"name"] isKindOfClass:NSString.class] ? pet[@"name"] : @"";
    BOOL selected = [petID isEqualToString:self.currentPetID];
    BOOL deletable = [petID hasPrefix:@"external:"];

    NSFont *font = [NSFont menuFontOfSize:13];
    CGFloat nameWidth = ceil([@"桌宠素材名..." sizeWithAttributes:@{NSFontAttributeName: font}].width);
    NSString *displayName = [self displayNameForPetName:name font:font maxWidth:nameWidth];
    const CGFloat checkWidth = 14;
    const CGFloat leadingInset = 6;
    const CGFloat nameX = leadingInset + checkWidth;
    const CGFloat deleteWidth = 40;
    const CGFloat trailingInset = 2;
    CGFloat deleteX = nameX + nameWidth + PetMenuControlGap;
    CGFloat rowWidth = deleteX + deleteWidth + trailingInset;

    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:displayName action:nil keyEquivalent:@""];
    item.representedObject = pet;
    item.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, rowWidth, 28)];

    NSTextField *check = [NSTextField labelWithString:selected ? @"✓" : @""];
    check.frame = NSMakeRect(leadingInset, 5, checkWidth, 18);
    check.tag = PetMenuCheckViewTag;
    check.font = font;
    check.textColor = NSColor.labelColor;
    [row addSubview:check];

    NSTextField *nameLabel = [NSTextField labelWithString:displayName];
    nameLabel.frame = NSMakeRect(nameX, 5, nameWidth, 18);
    nameLabel.font = font;
    nameLabel.textColor = NSColor.labelColor;
    nameLabel.lineBreakMode = NSLineBreakByClipping;
    nameLabel.toolTip = name;
    [row addSubview:nameLabel];

    // 透明按钮覆盖勾选和名称区域，既让整块都能点击，也避免 NSButton 自带的标题
    // 内边距破坏“最大文案末尾到删除按钮 8pt”的精确间距。
    NSButton *selectButton = [[NSButton alloc]
        initWithFrame:NSMakeRect(0, 0, nameX + nameWidth, 28)];
    selectButton.bordered = NO;
    selectButton.title = @"";
    selectButton.identifier = petID;
    selectButton.target = self;
    selectButton.action = @selector(selectPetFromButton:);
    selectButton.focusRingType = NSFocusRingTypeNone;
    selectButton.toolTip = name;
    [selectButton setAccessibilityLabel:[NSString stringWithFormat:@"切换到桌宠 %@", name]];
    [row addSubview:selectButton];

    NSButton *deleteButton = [[NSButton alloc] initWithFrame:NSMakeRect(deleteX, 3, deleteWidth, 22)];
    deleteButton.tag = PetMenuDeleteButtonTag;
    deleteButton.imageScaling = NSImageScaleProportionallyDown;
    deleteButton.identifier = petID;
    deleteButton.target = self;
    deleteButton.action = @selector(deletePetFromButton:);
    deleteButton.enabled = deletable && !selected;
    deleteButton.hidden = !deleteButton.enabled;
    [self configureDeleteButton:deleteButton confirming:NO];
    deleteButton.toolTip = [NSString stringWithFormat:@"删除素材 %@", name];
    [deleteButton setAccessibilityLabel:deleteButton.toolTip];
    [row addSubview:deleteButton];

    item.view = row;
    [menu addItem:item];
    return item;
}
- (NSImage *)menuPreviewForPet:(NSDictionary *)pet {
    NSString *path = [pet[@"path"] isKindOfClass:NSString.class] ? pet[@"path"] : nil;
    NSInteger rowCount = [pet[@"spriteRowCount"] integerValue];
    if (path.length == 0 || rowCount <= 0) return nil;

    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    NSTimeInterval modifiedAt = [attributes[NSFileModificationDate] timeIntervalSince1970];
    unsigned long long fileSize = [attributes[NSFileSize] unsignedLongLongValue];
    NSString *cacheKey = [NSString stringWithFormat:@"%@:%ld:%.6f:%llu",
        path, (long)rowCount, modifiedAt, fileSize];
    NSImage *cached = [self.petMenuPreviewCache objectForKey:cacheKey];
    if (cached) return cached;

    NSImage *sheet = LoadPetSpriteImage(path, NSMakeSize(92, 76), rowCount);
    if (!sheet || sheet.size.width <= 0 || sheet.size.height <= 0) return nil;

    CGFloat cellWidth = sheet.size.width / 8.0;
    CGFloat cellHeight = sheet.size.height / rowCount;
    NSRect firstFrame = NSMakeRect(0, sheet.size.height - cellHeight, cellWidth, cellHeight);
    CGFloat previewHeight = 76.0;
    CGFloat previewWidth = round(previewHeight * cellWidth / cellHeight);
    NSImage *preview = [[NSImage alloc] initWithSize:NSMakeSize(previewWidth, previewHeight)];
    [preview lockFocus];
    [sheet drawInRect:NSMakeRect(0, 0, previewWidth, previewHeight) fromRect:firstFrame
        operation:NSCompositingOperationSourceOver fraction:1.0
        respectFlipped:NO hints:@{NSImageHintInterpolation: @(NSImageInterpolationNone)}];
    [preview unlockFocus];
    NSUInteger cost = (NSUInteger)ceil(previewWidth * previewHeight * 4.0);
    [self.petMenuPreviewCache setObject:preview forKey:cacheKey cost:cost];
    return preview;
}
- (void)preparePetMenuPreviewPanel {
    if (self.petMenuPreviewPanel) return;

    NSRect panelFrame = NSMakeRect(0, 0, 92, 100);
    self.petMenuPreviewPanel = [[NSPanel alloc] initWithContentRect:panelFrame
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    self.petMenuPreviewPanel.opaque = NO;
    self.petMenuPreviewPanel.backgroundColor = NSColor.clearColor;
    self.petMenuPreviewPanel.hasShadow = YES;
    self.petMenuPreviewPanel.ignoresMouseEvents = YES;
    self.petMenuPreviewPanel.level = NSPopUpMenuWindowLevel + 1;
    self.petMenuPreviewPanel.collectionBehavior = NSWindowCollectionBehaviorTransient |
        NSWindowCollectionBehaviorMoveToActiveSpace;

    NSVisualEffectView *background = [[NSVisualEffectView alloc] initWithFrame:panelFrame];
    background.material = NSVisualEffectMaterialMenu;
    background.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    background.state = NSVisualEffectStateActive;
    background.wantsLayer = YES;
    background.layer.cornerRadius = 10.0;
    background.layer.masksToBounds = YES;

    self.petMenuPreviewImageView = [[NSImageView alloc] initWithFrame:NSInsetRect(panelFrame, 8, 8)];
    self.petMenuPreviewImageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.petMenuPreviewImageView.animates = NO;
    [background addSubview:self.petMenuPreviewImageView];
    self.petMenuPreviewPanel.contentView = background;
}
- (void)showMenuPreviewForPet:(NSDictionary *)pet item:(NSMenuItem *)item menu:(NSMenu *)menu {
    NSImage *preview = [self menuPreviewForPet:pet];
    if (!preview) {
        [self.petMenuPreviewPanel orderOut:nil];
        return;
    }
    [self preparePetMenuPreviewPanel];
    self.petMenuPreviewImageView.image = preview;

    NSRect itemFrame = item.accessibilityFrame;
    NSRect menuFrame = menu.accessibilityFrame;
    if (NSIsEmptyRect(menuFrame)) {
        NSPoint mouse = NSEvent.mouseLocation;
        menuFrame = NSMakeRect(mouse.x - menu.size.width / 2.0,
            mouse.y - menu.size.height / 2.0, menu.size.width, menu.size.height);
    }
    if (NSIsEmptyRect(itemFrame)) {
        NSPoint mouse = NSEvent.mouseLocation;
        itemFrame = NSMakeRect(menuFrame.origin.x, mouse.y - 11.0, menuFrame.size.width, 22.0);
    }

    // 子菜单可能根据屏幕空间展开到主菜单左侧。预览应放在整组菜单外侧，
    // 不能只按当前子菜单定位，否则会覆盖它右边的主菜单。
    NSRect menuGroupFrame = menuFrame;
    for (NSMenu *ancestor = menu.supermenu; ancestor; ancestor = ancestor.supermenu) {
        NSRect ancestorFrame = ancestor.accessibilityFrame;
        if (!NSIsEmptyRect(ancestorFrame)) menuGroupFrame = NSUnionRect(menuGroupFrame, ancestorFrame);
    }

    NSPoint menuCenter = NSMakePoint(NSMidX(menuGroupFrame), NSMidY(menuGroupFrame));
    NSScreen *targetScreen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    for (NSScreen *screen in NSScreen.screens) {
        if (NSPointInRect(menuCenter, screen.frame)) {
            targetScreen = screen;
            break;
        }
    }
    NSRect screenFrame = targetScreen.visibleFrame;
    NSSize previewSize = self.petMenuPreviewPanel.frame.size;
    CGFloat x = NSMaxX(menuGroupFrame) + 8.0;
    if (x + previewSize.width > NSMaxX(screenFrame)) {
        x = NSMinX(menuGroupFrame) - previewSize.width - 8.0;
    }
    CGFloat y = NSMidY(itemFrame) - previewSize.height / 2.0;
    y = MIN(MAX(y, NSMinY(screenFrame)), NSMaxY(screenFrame) - previewSize.height);
    [self.petMenuPreviewPanel setFrameOrigin:NSMakePoint(x, y)];
    [self.petMenuPreviewPanel orderFront:nil];
}
- (void)menu:(NSMenu *)menu willHighlightItem:(NSMenuItem *)item {
    NSDictionary *pet = [item.representedObject isKindOfClass:NSDictionary.class]
        ? item.representedObject : nil;
    if (pet) [self showMenuPreviewForPet:pet item:item menu:menu];
    else [self.petMenuPreviewPanel orderOut:nil];
}
- (void)menuDidClose:(NSMenu *)menu {
    [self resetPendingDeleteButton];
    [self.petMenuPreviewPanel orderOut:nil];
}
// 主菜单的行要撑满 menu.minimumWidth；子菜单只有自己这几项，撑到 194 会让短标题和开关
// 之间空出一大段。宽度交给调用方定，行内布局按同一套边距（左 12 / 右 8）算。
- (NSMenuItem *)addPersistentSwitchToMenu:(NSMenu *)menu
    title:(NSString *)title
    checked:(BOOL)checked
    action:(SEL)action
    width:(CGFloat)width
    tag:(NSInteger)tag {
    const CGFloat toggleWidth = 36;
    const CGFloat trailingInset = PetMenuControlGap;
    const CGFloat leadingInset = 12;
    CGFloat toggleX = width - trailingInset - toggleWidth;
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, 28)];
    NSTextField *label = [NSTextField labelWithString:title];
    label.frame = NSMakeRect(leadingInset, 5, toggleX - leadingInset - trailingInset, 18);
    label.font = [NSFont menuFontOfSize:13];
    label.textColor = NSColor.labelColor;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [row addSubview:label];
    MenuToggleSwitch *toggle = [[MenuToggleSwitch alloc]
        initWithFrame:NSMakeRect(toggleX, 3, toggleWidth, 22)];
    toggle.target = NSApp.delegate;
    toggle.action = action;
    toggle.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
    toggle.tag = tag;
    [toggle setAccessibilityLabel:title];
    [row addSubview:toggle];
    item.view = row;
    [menu addItem:item];
    return item;
}
- (NSMenuItem *)addUsageModeControlToMenu:(NSMenu *)menu
    provider:(NSString *)provider
    preferenceKey:(NSString *)preferenceKey
    tag:(NSInteger)tag {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 134, 28)];
    NSTextField *label = [NSTextField labelWithString:provider];
    label.frame = NSMakeRect(12, 5, 48, 18);
    label.font = [NSFont menuFontOfSize:13];
    label.textColor = NSColor.labelColor;
    [row addSubview:label];

    MenuUsageModeButton *control = [[MenuUsageModeButton alloc] initWithFrame:NSMakeRect(68, 3, 58, 22)];
    control.target = NSApp.delegate;
    control.action = @selector(setUsageDisplayModeFromControl:);
    control.state = [[NSUserDefaults.standardUserDefaults stringForKey:preferenceKey]
        isEqualToString:@"api"] ? NSControlStateValueOn : NSControlStateValueOff;
    control.tag = tag;
    [control setAccessibilityLabel:[provider stringByAppendingString:@"用量展示模式"]];
    [row addSubview:control];
    item.view = row;
    [menu addItem:item];
    return item;
}
- (void)rightMouseDown:(NSEvent *)event {
    NSArray<NSDictionary *> *availablePets = self.petOptionsRequested ? self.petOptionsRequested() : @[];
    NSMenu *menu = [NSMenu new];
    menu.minimumWidth = 194.0;
    NSMenuItem *switchItem = [menu addItemWithTitle:@"管理桌宠" action:nil keyEquivalent:@""];
    NSMenu *switchMenu = [NSMenu new];
    switchMenu.delegate = self;
    for (NSDictionary *pet in availablePets) {
        [self addPetOption:pet toMenu:switchMenu];
    }
    self.activePetSwitchMenu = switchMenu;
    switchItem.submenu = switchMenu;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *refreshItem = [menu addItemWithTitle:@"刷新用量" action:@selector(refreshUsage:) keyEquivalent:@"r"];
    refreshItem.target = NSApp.delegate;
    [self addPersistentSwitchToMenu:menu
        title:@"显示消息气泡"
        checked:[NSUserDefaults.standardUserDefaults boolForKey:StatusBubbleExpandedKey]
        action:@selector(toggleStatusBubbleFromMenu:)
        width:PetMenuRowWidth
        tag:0];
    [self addPersistentSwitchToMenu:menu
        title:@"导入 Codex 素材"
        checked:[NSUserDefaults.standardUserDefaults boolForKey:ImportCodexPetsKey]
        action:@selector(toggleImportCodexPets:)
        width:PetMenuRowWidth
        tag:0];
    NSMenuItem *usageModeItem = [menu addItemWithTitle:@"用量展示模式" action:nil keyEquivalent:@""];
    NSMenu *usageModeMenu = [NSMenu new];
    [self addUsageModeControlToMenu:usageModeMenu provider:@"Codex"
        preferenceKey:CodexUsageDisplayModeKey tag:1];
    [self addUsageModeControlToMenu:usageModeMenu provider:@"Claude"
        preferenceKey:ClaudeUsageDisplayModeKey tag:2];
    usageModeItem.submenu = usageModeMenu;
    NSMenuItem *notificationItem = [menu addItemWithTitle:@"系统通知" action:nil keyEquivalent:@""];
    NSMenu *notificationMenu = [NSMenu new];
    NSArray<NSDictionary *> *notificationOptions = @[
        @{@"title": @"任务完成", @"key": NotificationCompletionKey, @"tag": @1},
        @{@"title": @"任务失败", @"key": NotificationFailureKey, @"tag": @2},
        @{@"title": @"等待审批", @"key": NotificationApprovalKey, @"tag": @3}
    ];
    for (NSDictionary *option in notificationOptions) {
        [self addPersistentSwitchToMenu:notificationMenu
            title:option[@"title"]
            checked:[NSUserDefaults.standardUserDefaults boolForKey:option[@"key"]]
            action:@selector(toggleNotification:)
            width:PetSubmenuRowWidth
            tag:[option[@"tag"] integerValue]];
    }
    notificationItem.submenu = notificationMenu;
    NSMenuItem *interactionItem = [menu addItemWithTitle:@"连击互动" action:nil keyEquivalent:@""];
    NSMenu *interactionMenu = [NSMenu new];
    [self addPersistentSwitchToMenu:interactionMenu
        title:@"启用互动"
        checked:[NSUserDefaults.standardUserDefaults boolForKey:PetInteractionEnabledKey]
        action:@selector(togglePetInteraction:)
        width:PetSubmenuRowWidth
        tag:1];
    NSArray<NSDictionary *> *interactionGroups = @[
        @{@"title": @"桃心触发", @"key": PetInteractionHeartThresholdKey,
          @"action": NSStringFromSelector(@selector(setPetInteractionHeartThreshold:)),
          @"values": @[@3, @5, @7], @"suffix": @" 次"},
        @{@"title": @"烦躁触发", @"key": PetInteractionAnnoyedThresholdKey,
          @"action": NSStringFromSelector(@selector(setPetInteractionAnnoyedThreshold:)),
          @"values": @[@10, @12, @15], @"suffix": @" 次"},
        @{@"title": @"连击间隔", @"key": PetInteractionIntervalKey,
          @"action": NSStringFromSelector(@selector(setPetInteractionInterval:)),
          @"values": @[@0.8, @1.2, @1.8], @"suffix": @" 秒"},
    ];
    for (NSDictionary *group in interactionGroups) {
        NSMenuItem *groupItem = [interactionMenu addItemWithTitle:group[@"title"]
            action:nil keyEquivalent:@""];
        NSMenu *options = [NSMenu new];
        NSNumber *current = [NSUserDefaults.standardUserDefaults objectForKey:group[@"key"]];
        for (NSNumber *value in group[@"values"]) {
            NSString *number = value.doubleValue == value.integerValue ?
                [NSString stringWithFormat:@"%ld", (long)value.integerValue] :
                [NSString stringWithFormat:@"%.1f", value.doubleValue];
            NSMenuItem *option = [options addItemWithTitle:
                [number stringByAppendingString:group[@"suffix"]]
                action:NSSelectorFromString(group[@"action"]) keyEquivalent:@""];
            option.target = NSApp.delegate;
            option.representedObject = value;
            option.state = fabs(current.doubleValue - value.doubleValue) < 0.001 ?
                NSControlStateValueOn : NSControlStateValueOff;
        }
        groupItem.submenu = options;
    }
    [interactionMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *editInteractionPhrases = [interactionMenu addItemWithTitle:@"编辑互动配文…"
        action:@selector(editPhrasesFile:) keyEquivalent:@""];
    editInteractionPhrases.target = NSApp.delegate;
    interactionItem.submenu = interactionMenu;
    NSMenuItem *systemStatusItem = [menu addItemWithTitle:@"系统状态" action:nil keyEquivalent:@""];
    NSMenu *systemStatusMenu = [NSMenu new];
    NSArray<NSDictionary *> *systemStatusOptions = @[
        @{@"title": @"CPU 占用", @"key": SystemCPUEnabledKey, @"tag": @1},
        @{@"title": @"CPU 温度", @"key": SystemTemperatureEnabledKey, @"tag": @2},
        @{@"title": @"内存占用", @"key": SystemMemoryEnabledKey, @"tag": @3}
    ];
    for (NSDictionary *option in systemStatusOptions) {
        [self addPersistentSwitchToMenu:systemStatusMenu
            title:option[@"title"]
            checked:[NSUserDefaults.standardUserDefaults boolForKey:option[@"key"]]
            action:@selector(toggleSystemMetric:)
            width:PetSubmenuRowWidth
            tag:[option[@"tag"] integerValue]];
    }
    systemStatusItem.submenu = systemStatusMenu;
    NSMenuItem *speechItem = [menu addItemWithTitle:@"碎碎念" action:nil keyEquivalent:@""];
    NSMenu *speechMenu = [NSMenu new];
    id speechValue = [NSUserDefaults.standardUserDefaults objectForKey:@"CCPetsSpeechEnabled"];
    [self addPersistentSwitchToMenu:speechMenu
        title:@"启用碎碎念"
        checked:speechValue == nil ? YES : [speechValue boolValue]
        action:@selector(toggleSpeech:)
        width:PetSubmenuRowWidth
        tag:1];
    // 频率是四道闸的组合，单调任何一道都不会真的变频繁，所以只给一个档位。
    // 用系统的打勾单选行，不用自绘开关：这几项互斥，开关会看起来像四个独立选项。
    [speechMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *frequencyHeader = [speechMenu addItemWithTitle:@"频率" action:nil keyEquivalent:@""];
    frequencyHeader.enabled = NO;
    NSString *frequency = [NSUserDefaults.standardUserDefaults
        stringForKey:PetSpeechFrequencyKey] ?: @"normal";
    NSArray<NSDictionary *> *frequencyOptions = @[
        @{@"title": @"很少", @"value": @"low"},
        @{@"title": @"正常", @"value": @"normal"},
        @{@"title": @"较多", @"value": @"high"},
        @{@"title": @"话痨", @"value": @"chatty"},
    ];
    for (NSDictionary *option in frequencyOptions) {
        NSMenuItem *item = [speechMenu addItemWithTitle:option[@"title"]
            action:@selector(setSpeechFrequency:) keyEquivalent:@""];
        item.target = NSApp.delegate;
        item.representedObject = option[@"value"];
        item.state = [frequency isEqualToString:option[@"value"]] ?
            NSControlStateValueOn : NSControlStateValueOff;
        item.indentationLevel = 1;
    }
    [speechMenu addItem:NSMenuItem.separatorItem];
    // 没有这个入口，九成用户不会知道台词可以自己改。
    NSMenuItem *editPhrases = [speechMenu addItemWithTitle:@"编辑台词…"
        action:@selector(editPhrasesFile:) keyEquivalent:@""];
    editPhrases.target = NSApp.delegate;
    speechItem.submenu = speechMenu;
    NSMenuItem *updateItem = [menu addItemWithTitle:@"检查更新…" action:@selector(checkForUpdates:) keyEquivalent:@""];
    updateItem.target = NSApp.delegate;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quitItem = [menu addItemWithTitle:@"退出桌宠" action:@selector(terminate:) keyEquivalent:@"q"];
    quitItem.target = NSApp;
    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
    self.activePetSwitchMenu = nil;
    [self.petMenuPreviewPanel orderOut:nil];
}
@end
