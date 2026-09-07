#import <Foundation/Foundation.h>

// 通过 `codex app-server` 的 account/rateLimits/read 读取服务端当前额度。会话转录里的
// rate_limits 只是一份历史快照，不能作为当前窗口的唯一事实来源。
@interface CCPetsCodexRateLimitsReader : NSObject
@property(copy) void (^liveUsageHandler)(NSDictionary *liveUsage);
- (void)refresh;
- (void)stop;
@end

// 把实时额度覆盖到会话读取器产出的用量上；本机 Token 聚合等非官方字段会被保留。
NSDictionary *CodexUsageByApplyingLiveUsage(NSDictionary *sessionUsage,
    NSDictionary *liveUsage);
