#import "CCPetsBridgeSlackFiles.h"
#import "CCPetsBridgeAttachments.h"
#import "CCPetsBridgeStore.h"
#import "CCPetsBridge.h"
#import "CCPetsCLISupport.h"
#import <sys/stat.h>

static BOOL SlackFileURL(NSURL *url) {
    return [url.scheme.lowercaseString isEqual:@"https"] && [url.host.lowercaseString isEqual:@"files.slack.com"] &&
        !url.user && !url.password && (!url.port || url.port.integerValue == 443);
}

static NSDictionary *Failure(NSString *reason) { return @{@"error": reason}; }

static NSDictionary *Retryable(NSDictionary *reply) {
    NSString *error = reply[@"error"] ?: @"invalid_response";
    if (reply[@"delay"]) return reply;
    if ([error hasPrefix:@"HTTP 0 /"] || [error hasPrefix:@"HTTP 5"] ||
        [@[@"internal_error", @"request_timeout", @"service_unavailable"] containsObject:error]) {
        return @{@"error": error, @"delay": @5};
    }
    return Failure(error);
}

// Cap the actual received bytes, including for chunked responses, and never
// forward a token or upload body to a redirect destination.
@interface CCBridgeFileTransfer : NSObject <NSURLSessionDataDelegate>
@property (nonatomic) NSUInteger limit;
@property (nonatomic, strong) NSMutableData *data;
@property (nonatomic, strong) dispatch_semaphore_t done;
@property (nonatomic, copy) NSDictionary *failure;
@end

@implementation CCBridgeFileTransfer
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {
    completion(nil);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    NSHTTPURLResponse *response = (NSHTTPURLResponse *)task.response;
    if (response.statusCode != 200) return;
    if (data.length > self.limit - self.data.length) {
        self.failure = Failure(@"file_size_mismatch");
        [task cancel];
    } else {
        [self.data appendData:data];
    }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSHTTPURLResponse *response = (NSHTTPURLResponse *)task.response;
    if (!self.failure && (error || response.statusCode != 200)) {
        if (response.statusCode == 429) {
            self.failure = @{@"error": @"ratelimited", @"delay": @(MAX(1, [[response valueForHTTPHeaderField:@"Retry-After"] integerValue]))};
        } else {
            self.failure = Retryable(Failure([NSString stringWithFormat:@"HTTP %ld / URL error %ld", (long)response.statusCode, (long)error.code]));
        }
    }
    dispatch_semaphore_signal(self.done);
}
@end

static NSDictionary *Transfer(NSString *urlText, NSString *token, NSString *uploadPath, NSUInteger limit) {
    NSURL *url = [urlText isKindOfClass:NSString.class] ? [NSURL URLWithString:urlText] : nil;
    if (!SlackFileURL(url)) return Failure(@"untrusted_slack_file_url");
    CCBridgeFileTransfer *transfer = [CCBridgeFileTransfer new];
    transfer.limit = limit;
    transfer.data = [NSMutableData data];
    transfer.done = dispatch_semaphore_create(0);
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForResource = 120;
    config.URLCache = nil;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:transfer delegateQueue:nil];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    NSURLSessionTask *task;
    if (uploadPath) {
        request.HTTPMethod = @"POST";
        [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
        task = [session uploadTaskWithRequest:request fromFile:[NSURL fileURLWithPath:uploadPath]];
    } else {
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
        task = [session dataTaskWithRequest:request];
    }
    [task resume];
    dispatch_semaphore_wait(transfer.done, DISPATCH_TIME_FOREVER);
    [session finishTasksAndInvalidate];
    return transfer.failure ?: @{@"data": transfer.data};
}

// A file must actually be shared in this channel and thread. Checking only its
// ID or URL would allow a peer to reference files from another conversation.
static NSString *SharedThread(NSDictionary *file, NSString *channel, NSString *thread, BOOL requireRoot) {
    if (![file isKindOfClass:NSDictionary.class] || ![file[@"shares"] isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *visibility in @[@"public", @"private"]) {
        NSDictionary *channels = file[@"shares"][visibility];
        if (![channels isKindOfClass:NSDictionary.class] || ![channels[channel] isKindOfClass:NSArray.class]) continue;
        for (NSDictionary *share in channels[channel]) {
            if (![share isKindOfClass:NSDictionary.class]) continue;
            NSString *ts = share[@"ts"];
            NSString *parent = [share[@"thread_ts"] isKindOfClass:NSString.class] ? share[@"thread_ts"] : ts;
            if (![ts isKindOfClass:NSString.class] || !ts.length || (thread && ![thread isEqual:parent])) continue;
            if (!requireRoot || [ts isEqual:parent]) return parent;
        }
    }
    return nil;
}

NSDictionary *CCBridgeSlackShareFiles(NSURLSession *http, NSString *token, NSDictionary *message, NSDictionary *peer,
        NSString *comment, NSString *thread) {
    NSString *mid = message[@"id"], *channel = peer[@"channel"];
    NSDictionary *receipt = CCBridgeReadReceipt(mid);
    NSMutableArray *ids = [receipt[@"slackFileIDs"] mutableCopy] ?: [NSMutableArray array];
    NSArray *paths = message[@"attachments"];
    for (NSUInteger i = ids.count; i < paths.count; i++) {
        if (!CCBridgeEnabled()) return Failure(@"bridge_disabled");
        NSString *path = paths[i];
        struct stat info;
        if (lstat(path.fileSystemRepresentation, &info) || !S_ISREG(info.st_mode) ||
            info.st_size < 0 || (unsigned long long)info.st_size > CCBridgeAttachmentBytesLimit) return Failure(@"attachment_unavailable");
        NSDictionary *ticket = CCBridgeSlackAPI(http, @"files.getUploadURLExternal", token,
            @{@"filename": path.lastPathComponent, @"length": @(info.st_size)});
        if (![ticket[@"ok"] isEqual:@YES] || !CCBridgeSlackFileIDValid(ticket[@"file_id"])) return Retryable(ticket);
        NSDictionary *sent = Transfer(ticket[@"upload_url"], nil, path, 65536);
        if (sent[@"error"]) return sent;
        [ids addObject:ticket[@"file_id"]];
        CCBridgeUpdateReceipt(mid, @{@"slackFileIDs": ids});
    }
    // Completion is one-shot in Slack. After an uncertain response (or process
    // death), reconcile the original IDs using files.info instead of re-sharing.
    if (![receipt[@"completingFilesAt"] longLongValue] && ![receipt[@"slackFilesShared"] boolValue]) {
        NSMutableArray *files = [NSMutableArray array];
        for (NSString *fid in ids) [files addObject:@{@"id": fid}];
        NSMutableDictionary *body = [@{@"files": files, @"channel_id": channel, @"initial_comment": comment} mutableCopy];
        if (thread) body[@"thread_ts"] = thread;
        NSDictionary *current = CCBridgeUpdateReceipt(mid, @{@"completingFilesAt": @(CCPetsMilliseconds())});
        if (![current[@"status"] isEqual:@"pending"] || !CCBridgeEnabled()) return Failure(@"bridge_disabled");
        NSDictionary *reply = CCBridgeSlackAPI(http, @"files.completeUploadExternal", token, body);
        if (![reply[@"ok"] isEqual:@YES]) {
            if (reply[@"delay"]) CCBridgeUpdateReceipt(mid, @{@"completingFilesAt": @0});
            return Retryable(reply);
        }
        CCBridgeUpdateReceipt(mid, @{@"slackFilesShared": @YES});
        if (thread) return @{@"ids": ids, @"thread": thread};
    }
    if (thread && [receipt[@"slackFilesShared"] boolValue]) return @{@"ids": ids, @"thread": thread};
    NSDictionary *lookup = CCBridgeSlackAPI(http, @"files.info", token, @{@"file": ids.firstObject});
    NSString *parent = SharedThread(lookup[@"file"], channel, thread, !thread);
    if (parent) {
        CCBridgeUpdateReceipt(mid, @{@"slackFilesShared": @YES});
        return @{@"ids": ids, @"thread": parent};
    }
    if (lookup[@"error"] && ![lookup[@"error"] isEqual:@"file_not_found"]) return Retryable(lookup);
    long long started = [CCBridgeReadReceipt(mid)[@"completingFilesAt"] longLongValue];
    return CCPetsMilliseconds() - started < 180000 ? @{@"error": @"file_share_pending", @"delay": @3} : Failure(@"file_share_unconfirmed");
}

NSDictionary *CCBridgeSlackFetchFiles(NSURLSession *http, NSString *token, NSArray *ids, NSDictionary *peer,
        NSString *thread, BOOL requireRoot, NSString *mid, NSString *day) {
    if (![ids isKindOfClass:NSArray.class] || !ids.count || ids.count > CCBridgeAttachmentCountLimit) return Failure(@"invalid_file_list");
    NSUInteger remaining = CCBridgeAttachmentBytesLimit;
    NSMutableArray *paths = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *fid in ids) {
        if (!CCBridgeSlackFileIDValid(fid) || [seen containsObject:fid]) return Failure(@"invalid_file_id");
        [seen addObject:fid];
        NSDictionary *reply = CCBridgeSlackAPI(http, @"files.info", token, @{@"file": fid});
        if (![reply[@"ok"] isEqual:@YES]) return Retryable(reply);
        NSDictionary *file = reply[@"file"];
        if (![file isKindOfClass:NSDictionary.class] || ![file[@"id"] isEqual:fid] || ![@[@"hosted", @"snippet"] containsObject:file[@"mode"] ?: @""] || [file[@"is_external"] boolValue] ||
            !([file[@"user"] isEqual:peer[@"user_id"]] || [file[@"bot_id"] isEqual:peer[@"bot_id"]])) return Failure(@"invalid_file_owner_or_type");
        if (!SharedThread(file, peer[@"channel"], thread, requireRoot)) return Failure(@"file_share_not_visible");
        NSNumber *size = file[@"size"];
        if (![size isKindOfClass:NSNumber.class] || size.longLongValue < 0 || size.unsignedLongLongValue > remaining) return Failure(@"attachment_too_large");
        NSString *path = CCBridgeDownloadedAttachmentPath(day, mid, fid, file[@"name"]);
        if (!path) return Failure(@"invalid_attachment_name_or_directory");
        struct stat info;
        if (lstat(path.fileSystemRepresentation, &info) || !S_ISREG(info.st_mode) || info.st_size != size.longLongValue) {
            NSDictionary *result = Transfer(file[@"url_private_download"] ?: file[@"url_private"], token, nil, size.unsignedIntegerValue);
            if (result[@"error"]) return result;
            NSData *data = result[@"data"];
            if (data.length != size.unsignedIntegerValue) return Failure(@"file_size_mismatch");
            if (!CCBridgeWriteAttachment(data, path)) return Failure(@"cannot_save_attachment");
        }
        [paths addObject:path];
        remaining -= size.unsignedIntegerValue;
    }
    return @{@"paths": paths};
}
