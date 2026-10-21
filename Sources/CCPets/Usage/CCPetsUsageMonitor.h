#import <Foundation/Foundation.h>

@interface CCPetsUsageMonitor : NSObject
@property(copy) void (^changeHandler)(NSDictionary *codexUsage, NSDictionary *claudeUsage);
@property(readonly) NSDictionary *codexUsage;
@property(readonly) NSDictionary *claudeUsage;
// profileId → 当前用量；profiles 保持用户添加顺序。默认账号同时保留在旧属性中以兼容现有调用方。
@property(readonly) NSDictionary<NSString *, NSDictionary *> *profileUsages;
@property(readonly) NSArray<NSDictionary *> *profiles;
- (void)start;
- (void)refreshNow;
- (void)stop;
@end
