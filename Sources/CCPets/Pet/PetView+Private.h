// PetView 各个 category 共用的私有属性，以及跨文件调用的方法。
#import "PetView.h"
#import <QuartzCore/QuartzCore.h>

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
@property NSSize spriteCacheSize;
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

// 主文件里实现、category 也要用的方法。
- (NSArray<NSNumber *> *)framesFromZeroThrough:(NSInteger)last;
- (NSArray<NSNumber *> *)uniformHoldsForCount:(NSUInteger)count;
- (BOOL)isIdleRow:(NSInteger)row;
- (void)updateBreathingAnimation;
@end

// 微动层：待机时随机插入的小动作、无聊曲线和用力后的呼吸余韵。
@interface PetView (MicroBehavior)
- (void)noteActivity;
- (void)restoreLastActivity;
- (void)bumpExertion;
- (NSInteger)exertionLevel;
- (void)updateBreathingIfExertionChanged;
- (void)scheduleNextMicroBehavior;
- (BOOL)canStartMicroBehavior;
- (void)rebuildCapabilities;
- (void)startMicroBehavior;
- (void)endMicroBehavior;
@end

// 鼠标交互：拖动、松手落脚、连击互动。
@interface PetView (Interaction)
- (void)endPetDrag;
@end
