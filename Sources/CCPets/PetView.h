#import <Cocoa/Cocoa.h>

// 连击互动配置。放在 PetView 公共契约里，菜单和点击处理共用同一组 defaults 键。
extern NSString *const PetInteractionEnabledKey;
extern NSString *const PetInteractionHeartThresholdKey;
extern NSString *const PetInteractionAnnoyedThresholdKey;
extern NSString *const PetInteractionIntervalKey;

@interface PetView : NSView <NSMenuDelegate>
@property(nonatomic) NSImage *sheet;
@property(nonatomic) NSInteger spriteRowCount;
@property(nonatomic) NSInteger lookDirection;
@property(nonatomic) NSInteger frameIndex;
@property(nonatomic) NSInteger rowIndex;
@property NSArray<NSNumber *> *frames;
// 与 frames 等长，每项是该帧要停留几个动画节拍。全 1 就是原来的匀速播放。
@property NSArray<NSNumber *> *frameHolds;
// 与 frames 等长的行号。为 nil 时整段都用 rowIndex；转头要横跨 row 9/10 两行，
// 只有逐帧带行号才播得出来。
@property NSArray<NSNumber *> *frameRows;
@property NSUInteger sequenceIndex;
@property BOOL oneShot;
@property BOOL draggingPet;
@property BOOL agentActive;
@property NSPoint dragStartMouse;
@property NSString *currentPetID;
@property id globalMouseMonitor;
@property id localMouseMonitor;
@property(copy) void (^pocketHoverChanged)(BOOL hovering);
@property(copy) void (^dragStateChanged)(BOOL dragging);
@property(copy) void (^interactionPhraseRequested)(NSString *tag);
@property(copy) NSArray<NSDictionary *> *(^petOptionsRequested)(void);
@property(copy) void (^switchPetRequested)(NSString *petID);
@property(copy) BOOL (^deletePetRequested)(NSString *petID);
@property NSCache<NSString *, NSImage *> *petMenuPreviewCache;
@property NSPanel *petMenuPreviewPanel;
@property NSImageView *petMenuPreviewImageView;
@property NSTimer *frameTimer;
@property(nonatomic) BOOL animationSuspended;
@property BOOL lowPowerMode;
@property BOOL reduceMotion;
- (instancetype)initWithFrame:(NSRect)frame sheet:(NSImage *)sheet rowCount:(NSInteger)rowCount;
- (void)applySheet:(NSImage *)sheet petID:(NSString *)petID rowCount:(NSInteger)rowCount;
- (void)handleAgentEvent:(NSString *)event tool:(NSString *)tool failed:(BOOL)failed;
- (void)playRow:(NSInteger)row throughFrame:(NSInteger)last oneShot:(BOOL)oneShot;
@end
