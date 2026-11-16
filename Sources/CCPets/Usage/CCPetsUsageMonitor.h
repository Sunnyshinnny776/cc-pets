#import <Foundation/Foundation.h>

@interface CCPetsUsageMonitor : NSObject
@property(copy) void (^changeHandler)(NSDictionary<NSString *, NSDictionary *> *usageByProvider);
@property(readonly, copy) NSDictionary<NSString *, NSDictionary *> *usageByProvider;
// profileId → 当前用量；profiles 保持用户添加顺序。默认账号同时保留在 usageByProvider 中。
@property(readonly) NSDictionary<NSString *, NSDictionary *> *profileUsages;
@property(readonly) NSArray<NSDictionary *> *profiles;
- (void)start;
- (void)refreshNow;
- (void)stop;
@end
