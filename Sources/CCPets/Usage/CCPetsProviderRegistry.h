#import <Foundation/Foundation.h>

typedef NSDictionary *(^CCPetsUsageNormalizer)(NSDictionary *rawUsage, BOOL showsAPIUsage);

// name 是面板和偏好设置使用的显示键；key / profileProvider 保留磁盘中的小写标识。
@interface CCPetsProviderDescriptor : NSObject
@property(readonly, copy) NSString *name;
@property(readonly, copy) NSString *key;
@property(readonly, copy) NSString *usedKey;
@property(readonly, copy) NSString *billing;
@property(readonly, copy) NSArray<NSDictionary *> *windowSpecs;
@property(readonly, copy) CCPetsUsageNormalizer normalizer;
@property(readonly, copy) NSString *profileProvider;
// Foundation-only 元数据；颜色分量顺序为 red、green、blue。
@property(readonly, copy) NSArray<NSNumber *> *standardColorRGB;
@property(readonly, copy) NSArray<NSNumber *> *glassColorRGB;
@property(readonly, copy) NSString *logoBundleIdentifier;
@property(readonly, copy) NSString *logoResourceName;
@property(readonly, copy) NSString *usageDisplayModeDefaultsKey;
@end

// 展示顺序固定：Codex、Claude。
NSArray<CCPetsProviderDescriptor *> *CCPetsProviderDescriptors(void);
CCPetsProviderDescriptor *CCPetsProviderForName(NSString *name);
CCPetsProviderDescriptor *CCPetsProviderForProfileProvider(NSString *profileProvider);
