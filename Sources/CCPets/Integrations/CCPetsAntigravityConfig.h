#import <Foundation/Foundation.h>

@class CCPetsJSONObject;

// Missing or blank files have no configuration. Malformed nonblank files report an error.
CCPetsJSONObject *CCPetsReadAntigravityConfig(NSString *path, NSString **errorMessage);
NSArray<NSString *> *CCPetsInstallAntigravityPetHooks(NSDictionary *profile);
BOOL CCPetsRemoveAntigravityPetHooks(NSDictionary *profile);
BOOL CCPetsAntigravityPetHooksInstalled(NSDictionary *profile);
BOOL CCPetsAntigravityBridgeInstalled(NSDictionary *profile);
NSArray<NSString *> *CCPetsInstallAntigravityBridge(NSDictionary *profile, NSArray<NSString *> *allowed, BOOL registerMcp);
NSArray<NSString *> *CCPetsRemoveAntigravityBridge(NSDictionary *profile, BOOL unregisterMcp);
// Wrap or restore the terminal title command in this native CLI profile only.
void CCPetsConfigureAntigravityBridgeTitle(NSDictionary *profile, BOOL enabled);
// Desktop Sidecars are scoped to the default Gemini root. Custom CLI Homes are ignored.
NSArray<NSString *> *CCPetsConfigureAntigravityAppSidecar(NSDictionary *profile, BOOL enabled);
BOOL CCPetsAntigravityAppSidecarInstalled(NSDictionary *profile);
