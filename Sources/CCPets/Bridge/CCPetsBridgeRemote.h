#import <Foundation/Foundation.h>

// Only message discovery sees these remote identities. They never enter the
// local session registry, process detection, reservation list or --from lookup.
NSArray<NSDictionary *> *CCBridgeMessageRecipients(NSArray<NSDictionary *> *local);
NSDictionary *CCBridgeResolveMessageRecipient(id address, NSDictionary *sender, NSArray<NSDictionary *> *local);
BOOL CCBridgeIsRemoteHost(NSDictionary *peer);
NSDictionary *CCBridgeRemoteAdvertisement(NSDictionary *local);
NSDictionary *CCBridgeRemoteIdentity(NSDictionary *peer, NSDictionary *advertisement);
NSDictionary *CCBridgeRemoteDirectory(NSDictionary *peer);
BOOL CCBridgeSaveRemoteDirectory(NSDictionary *peer, NSString *eventTS, NSArray *entries, NSString *instance);
void CCBridgeClearRemoteDirectory(NSDictionary *peer);
