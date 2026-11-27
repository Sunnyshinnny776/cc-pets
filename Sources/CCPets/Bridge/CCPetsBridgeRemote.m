#import "CCPetsBridgeRemote.h"
#import "CCPetsBridgeCore.h"
#import "CCPetsBridgeStore.h"
#import "CCPetsCLISupport.h"

BOOL CCBridgeIsRemoteHost(NSDictionary *peer) {
    return !peer[@"gateway"] && [peer[@"provider"] isEqual:CCBridgeSlackProvider] && [peer[@"session"] hasPrefix:@"slack-host-"];
}

NSDictionary *CCBridgeRemoteAdvertisement(NSDictionary *local) {
    return @{@"id": CCBridgeSHA1Hex(local[@"session"]), @"name": local[@"name"],
        @"provider": local[@"provider"], @"status": [local[@"status"] isEqual:@"busy"] ? @"busy" : @"idle"};
}

NSDictionary *CCBridgeRemoteIdentity(NSDictionary *peer, NSDictionary *entry) {
    if (![entry isKindOfClass:NSDictionary.class]) return nil;
    NSString *key = entry[@"id"], *name = entry[@"name"];
    if (![key isKindOfClass:NSString.class] || key.length != 40 ||
        [key rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location != NSNotFound ||
        ![name isKindOfClass:NSString.class] || ![name isEqual:CCBridgeNormalizeSessionName(name)] ||
        ![@[@"idle", @"busy"] containsObject:entry[@"status"] ?: @""] ||
        ![@[@"Claude", @"Codex", CCBridgeAntigravityProvider, CCBridgeAntigravityAppProvider] containsObject:entry[@"provider"] ?: @""]) return nil;
    NSString *sid = [NSString stringWithFormat:@"%@.%@", peer[@"session"], key];
    return @{@"session": sid, @"name": [NSString stringWithFormat:@"%@/%@", peer[@"name"], name],
        @"ref": CCBridgeSessionRef(sid), @"provider": CCBridgeSlackProvider, @"status": entry[@"status"],
        @"remoteProvider": entry[@"provider"], @"remoteID": key, @"gateway": peer[@"session"]};
}

static NSString *DirectoryFile(NSDictionary *peer) {
    return [CCBridgeSubdirectory(@[@"slack-directories"]) stringByAppendingPathComponent:
        [peer[@"session"] stringByAppendingString:@".json"]];
}

NSDictionary *CCBridgeRemoteDirectory(NSDictionary *peer) {
    NSDictionary *directory = CCBridgeReadJSON(DirectoryFile(peer));
    if (![directory isKindOfClass:NSDictionary.class] || ![directory[@"pid"] isEqual:CCBridgeSessionHostPID(peer)] ||
        [directory[@"expiresAt"] longLongValue] <= CCPetsMilliseconds()) return nil;
    return directory;
}

void CCBridgeClearRemoteDirectory(NSDictionary *peer) {
    CCBridgeWriteJSON(DirectoryFile(peer), @{});
}

// The Socket Mode receiver is the only writer. Use Slack's event timestamp,
// including for edits, so duplicate or delayed deliveries cannot revive a host.
BOOL CCBridgeSaveRemoteDirectory(NSDictionary *peer, NSString *eventTS, NSArray *entries, NSString *instance) {
    long long expires = (long long)(eventTS.doubleValue * 1000) + 90000;
    if (expires <= CCPetsMilliseconds() || ![entries isKindOfClass:NSArray.class]) return NO;
    NSDictionary *old = CCBridgeRemoteDirectory(peer);
    if (old && [old[@"ts"] compare:eventTS options:NSNumericSearch] != NSOrderedAscending) return NO;
    NSMutableArray *sessions = [NSMutableArray array];
    NSMutableSet *ids = [NSMutableSet set];
    for (NSDictionary *entry in entries) {
        NSDictionary *session = CCBridgeRemoteIdentity(peer, entry);
        if (!session || [ids containsObject:session[@"session"]]) return NO;
        [sessions addObject:session];
        [ids addObject:session[@"session"]];
    }
    CCBridgeWriteJSON(DirectoryFile(peer), @{@"ts": eventTS, @"expiresAt": @(expires),
        @"pid": CCBridgeSessionHostPID(peer), @"sessions": sessions, @"instance": instance});
    return YES;
}

NSArray<NSDictionary *> *CCBridgeMessageRecipients(NSArray<NSDictionary *> *local) {
    NSMutableArray *recipients = [NSMutableArray array];
    for (NSDictionary *session in local) {
        if (CCBridgeIsRemoteHost(session)) {
            [recipients addObjectsFromArray:CCBridgeRemoteDirectory(session)[@"sessions"] ?: @[]];
        } else {
            [recipients addObject:session];
        }
    }
    return recipients;
}

// The incoming envelope is also a reply address. Its receipt can predate the
// first roster or a rename. Preserve the authenticated thread's original target.
NSDictionary *CCBridgeResolveMessageRecipient(id address, NSDictionary *sender, NSArray<NSDictionary *> *local) {
    NSString *text = [address isKindOfClass:NSString.class] ?
        [address stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : nil;
    if ([text containsString:@"/"] && [text containsString:@"#"]) {
        NSSet *online = [NSSet setWithArray:[local valueForKey:@"session"]];
        for (NSDictionary *receipt in CCBridgeListReceipts()) {
            NSDictionary *from = receipt[@"from"];
            if (from[@"gateway"] && [online containsObject:from[@"gateway"]] &&
                [receipt[@"to"][@"session"] isEqual:sender[@"session"]] && [CCBridgeDescribeSession(from) isEqual:text] &&
                CCPetsMilliseconds() - [receipt[@"createdAt"] longLongValue] < 2 * CCBridgeMessageTTL) {
                return @{@"session": from};
            }
        }
    }
    // Unqualified names and refs retain the local lookup order, including when
    // a remote session happens to have a matching short ref.
    if (![text containsString:@"/"]) {
        NSMutableArray *ordinary = [NSMutableArray array];
        for (NSDictionary *session in local) {
            if (!CCBridgeIsRemoteHost(session)) [ordinary addObject:session];
        }
        return CCBridgeResolveTarget(text, ordinary);
    }
    return CCBridgeResolveTarget(text, CCBridgeMessageRecipients(local));
}
