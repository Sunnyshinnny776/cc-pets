#import "PetView+Private.h"
#import "CCPetsPaths.h"

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

@implementation PetView (MicroBehavior)
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
@end
