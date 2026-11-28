#import <Cocoa/Cocoa.h>

@class CCPetsFormBuilder;
extern NSNotificationName const CCPetsCatalogDidInstallNotification;

// 宠物页的在线目录，只在首次切到「发现宠物」时加载。
@interface CCPetsPetCatalog : NSObject
@property(nonatomic, readonly) CCPetsFormBuilder *form;
@property(nonatomic, copy) void (^selectPet)(NSString *petID);
- (void)show;
- (void)pausePreviews;
- (void)setInstalledPets:(NSArray<NSDictionary *> *)options currentID:(NSString *)currentID;
@end
