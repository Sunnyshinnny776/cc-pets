#import <Foundation/Foundation.h>

// name 是面板和偏好设置使用的显示键；key / profileProvider 保留磁盘中的小写标识。
@interface CCPetsProviderDescriptor : NSObject
@property(readonly, copy) NSString *name;
@property(readonly, copy) NSString *key;
@property(readonly, copy) NSString *usedKey;
@property(readonly, copy) NSString *profileProvider;
@end

// 展示顺序固定：Codex、Claude。
NSArray<CCPetsProviderDescriptor *> *CCPetsProviderDescriptors(void);
CCPetsProviderDescriptor *CCPetsProviderForName(NSString *name);
CCPetsProviderDescriptor *CCPetsProviderForProfileProvider(NSString *profileProvider);
