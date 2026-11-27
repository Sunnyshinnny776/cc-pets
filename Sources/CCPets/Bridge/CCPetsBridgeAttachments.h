#import <Foundation/Foundation.h>

extern const NSUInteger CCBridgeAttachmentCountLimit;
extern const NSUInteger CCBridgeAttachmentBytesLimit;

// Incoming Slack files keep their original names in the receiving Mac's dated directory.
// Outgoing snapshots and already delivered legacy paths stay in the temporary state directory.
BOOL CCBridgeSlackFileIDValid(id value);
NSString *CCBridgeAttachmentDay(NSTimeInterval time);
NSString *CCBridgeDownloadedAttachmentPath(NSString *day, NSString *mid, NSString *fileID, NSString *filename);
void CCBridgePruneAttachmentFiles(long long now);
BOOL CCBridgeWriteAttachment(NSData *data, NSString *path);
NSArray<NSString *> *CCBridgeSnapshotAttachments(id paths, NSDictionary *sender, NSString *mid, NSString **error);
