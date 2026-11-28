#import "CCPetsBridgeSlack.h"
#import "CCPetsBridgeSlackFiles.h"
#import "CCPetsBridgeAttachments.h"
#import "CCPetsBridge.h"
#import "CCPetsBridgeCore.h"
#import "CCPetsBridgeRemote.h"
#import "CCPetsBridgeStore.h"
#import "CCPetsCLISupport.h"
#import "CCPetsL10n.h"
#import <IOKit/IOMessage.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <unistd.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/file.h>
#import <errno.h>

static BOOL Matches(id value, NSString *pattern) {
    return [value isKindOfClass:NSString.class] && [value rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}

static NSDictionary *Object(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSDictionary *Parse(NSData *data) {
    return data.length ? Object([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]) : nil;
}

static void Report(NSString *message) {
    CCPetsPrintLine(stderr, [@"cc-bridge Slack: " stringByAppendingString:message]);
}

// Use form encoding for token-only methods and JSON for chat.postMessage. Never log
// request headers, message bodies or the signed WebSocket URL on failure.
NSDictionary *CCBridgeSlackAPI(NSURLSession *http, NSString *method, NSString *token, NSDictionary *body) {
    NSURL *url = [NSURL URLWithString:[@"https://slack.com/api/" stringByAppendingString:method]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 20;
    [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    BOOL form = [method isEqual:@"files.getUploadURLExternal"] || [method isEqual:@"files.info"];
    if (form) {
        NSMutableArray *items = [NSMutableArray array];
        for (NSString *key in body) {
            [items addObject:[NSURLQueryItem queryItemWithName:key value:[body[key] description]]];
        }
        NSURLComponents *parts = [NSURLComponents new];
        parts.queryItems = items;
        NSString *encoded = [parts.percentEncodedQuery stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
        if ([method isEqual:@"files.info"]) {
            request.HTTPMethod = @"GET";
            NSURLComponents *endpoint = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
            endpoint.percentEncodedQuery = encoded;
            request.URL = endpoint.URL;
        } else {
            request.HTTPBody = [encoded dataUsingEncoding:NSUTF8StringEncoding];
        }
    } else if (body) {
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    }
    [request setValue:(body && !form) ? @"application/json; charset=utf-8" : @"application/x-www-form-urlencoded"
        forHTTPHeaderField:@"Content-Type"];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *result;
    [[http dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode == 429) {
            result = @{@"error": @"ratelimited", @"delay": @(MAX(1, [[httpResponse valueForHTTPHeaderField:@"Retry-After"] integerValue]))};
        } else if (error || httpResponse.statusCode != 200) {
            result = @{@"error": [NSString stringWithFormat:@"HTTP %ld / URL error %ld", (long)httpResponse.statusCode, (long)error.code]};
        } else {
            result = Parse(data);
        }
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return result ?: @{@"error": @"invalid_response"};
}

static NSString *ChannelBot(NSString *channel, NSString *bot) {
    return [NSString stringWithFormat:@"%@/%@", channel, bot];
}

static NSString *SlackRosterRow(NSDictionary *session) {
    NSString *name = session[@"name"];
    NSString *provider = session[@"provider"];
    NSArray<NSString *> *parts = [name componentsSeparatedByString:@"."];
    if (![session[@"nameSource"] isEqual:@"generated"] || parts.count != 3) {
        return [NSString stringWithFormat:@"%@  ·  %@", name, provider];
    }
    // Use the account and project already present in the public session name.
    NSString *account = parts[0], *prefix = [provider.lowercaseString stringByAppendingString:@"-"];
    if ([account hasPrefix:prefix] && account.length > prefix.length) {
        provider = [provider stringByAppendingFormat:@" %@", [account substringFromIndex:prefix.length].uppercaseString];
    } else if (![account isEqual:provider.lowercaseString]) {
        provider = [provider stringByAppendingFormat:@" (%@)", account];
    }
    return [NSString stringWithFormat:@"%@  ·  %@  ·  %@", parts[2], provider, parts[1]];
}

// One configured peer per (channel, bot). Refuse ambiguous addresses at startup.
static NSDictionary *ReadSlackConfig(NSString *path, NSString **error) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return nil;
    NSFileHandle *file = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    NSDictionary *config;
    @try {
        struct stat st;
        if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) return nil;
        config = Parse([file readDataToEndOfFileAndReturnError:nil]);
        if (config[@"app_token"] || config[@"bot_token"]) {
            // Check and restrict the actual file read, even if an editor swaps
            // the pathname concurrently. Keep permission changes off legacy files.
            if (st.st_uid != getuid() || ((st.st_mode & 0777) != 0600 && fchmod(fd, 0600) != 0)) {
                if (error) *error = L(@"Slack token configuration must be owned by you and allow mode 0600.");
                return nil;
            }
            for (NSString *key in @[@"app_token", @"bot_token"]) {
                if (config[key] && ![config[key] isKindOfClass:NSString.class]) return nil;
            }
        }
    } @finally { [file closeAndReturnError:nil]; }
    if (config[@"enabled"] && CFGetTypeID((__bridge CFTypeRef)config[@"enabled"]) != CFBooleanGetTypeID()) return nil;
    NSArray *agents = config[@"agents"];
    NSDictionary *discovery = Object(config[@"discovery"]);
    if (config[@"discovery"] && (!discovery || !Matches(discovery[@"channel"], @"^[CG][A-Z0-9]+\\z") ||
        (discovery[@"name"] && !Matches(discovery[@"name"], @"^[A-Za-z0-9][A-Za-z0-9._-]{0,39}\\z")))) return nil;
    if (agents && ![agents isKindOfClass:NSArray.class]) return nil;
    if (!discovery && !agents.count) return nil;
    NSMutableSet *names = [NSMutableSet set], *endpoints = [NSMutableSet set];
    for (id item in agents) {
        NSDictionary *agent = Object(item);
        NSString *name = agent[@"name"], *bot = agent[@"bot_id"], *user = agent[@"user_id"], *channel = agent[@"channel"];
        if (agent[@"bridge"] && CFGetTypeID((__bridge CFTypeRef)agent[@"bridge"]) != CFBooleanGetTypeID()) return nil;
        if (![name isKindOfClass:NSString.class] || ![CCBridgeNormalizeSessionName(name) isEqual:name] || !Matches(bot, @"^B[A-Z0-9]+\\z") ||
            !Matches(user, @"^[UW][A-Z0-9]+\\z") || !Matches(channel, @"^[CG][A-Z0-9]+\\z")) return nil;
        NSString *endpoint = ChannelBot(channel, bot);
        if ([names containsObject:name] || [endpoints containsObject:endpoint]) return nil;
        [names addObject:name];
        [endpoints addObject:endpoint];
    }
    return config;
}

NSString *CCBridgeSlackConfigPath(void) {
    return [CCBridgeHomeDirectory() stringByAppendingPathComponent:@"bridge-slack.json"];
}

BOOL CCBridgeSlackAutoStartEnabled(void) {
    NSString *error = nil;
    NSDictionary *config = ReadSlackConfig(CCBridgeSlackConfigPath(), &error);
    if (error) Report(error);
    return [config[@"enabled"] isEqual:@YES] && [config[@"app_token"] hasPrefix:@"xapp-"] &&
        [config[@"bot_token"] hasPrefix:@"xoxb-"];
}

BOOL CCBridgeSlackAdapterRunning(void) {
    // The foreground and managed paths share the store's exclusive lock.
    NSString *guard = [CCBridgeStateDirectory() stringByAppendingPathComponent:@"locks/slack-adapter.pid.lock"];
    int fd = open(guard.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NO;
    BOOL held = flock(fd, LOCK_SH | LOCK_NB) != 0 && errno == EWOULDBLOCK;
    close(fd);
    return held;
}

// Successful posts and accepted inbound messages both leave a thread address on
// their receipts. Bind it to the original session ID even if the name is reused.
static NSString *ThreadOwner(NSString *peer, NSString *thread) {
    for (NSDictionary *receipt in CCBridgeListReceipts()) {
        if (CCPetsMilliseconds() - [receipt[@"createdAt"] longLongValue] > 2 * CCBridgeMessageTTL) continue;
        NSDictionary *from = receipt[@"from"], *to = receipt[@"to"];
        if ([from[@"session"] isEqual:peer] && [from[@"slackThread"] isEqual:thread]) return to[@"session"];
        if ([to[@"session"] isEqual:peer] && [receipt[@"transport"][@"thread"] isEqual:thread]) return from[@"session"];
    }
    return nil;
}

static NSString *EscapeSlackText(NSString *text) {
    return [[[text stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
        stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"]
        stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
}

// Slack may rewrite mentions, links and entities in text. Carry the versioned
// packet in the fallback text and show the original body using plain-text blocks.
static NSString *WirePrefix(NSString *user) {
    return user ? [NSString stringWithFormat:@"<@%@> cc-bridge/1 ", user] : @"cc-bridge/discovery/1 ";
}

static NSDictionary *WirePacket(NSString *user, NSString *text) {
    NSString *prefix = WirePrefix(user);
    if (![text hasPrefix:prefix] || text.length > 40000) return nil;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:[text substringFromIndex:prefix.length] options:0];
    return Parse(data);
}

static NSArray *PlainTextBlocks(NSString *display) {
    NSMutableArray *blocks = [NSMutableArray array];
    while (display.length) {
        NSUInteger count = MIN(display.length, 2800);
        if (count < display.length && CFStringIsSurrogateHighCharacter([display characterAtIndex:count - 1])) count--;
        [blocks addObject:@{@"type": @"section", @"text": @{@"type": @"plain_text", @"emoji": @NO,
            @"text": [display substringToIndex:count]}}];
        display = [display substringFromIndex:count];
    }
    return blocks;
}

static NSArray *SlackRosterBlocks(NSString *heading, NSArray<NSString *> *rows) {
    NSDictionary *header = @{@"type": @"header", @"text": @{@"type": @"plain_text", @"text": heading}};
    if (!rows.count) return @[header];
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSString *row in rows) {
        [items addObject:@{@"type": @"rich_text_section", @"elements": @[@{@"type": @"text", @"text": row}]}];
    }
    NSDictionary *list = @{@"type": @"rich_text_list", @"style": @"bullet", @"elements": items};
    return @[header, @{@"type": @"rich_text", @"elements": @[list]}];
}

static NSMutableDictionary *WirePost(NSDictionary *peer, NSDictionary *packet, NSArray *blocks, NSString *thread) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:packet options:NSJSONWritingWithoutEscapingSlashes error:nil];
    NSString *text = [WirePrefix(peer[@"user_id"]) stringByAppendingString:[json base64EncodedStringWithOptions:0]];
    if (text.length > 40000) return nil;
    NSMutableDictionary *post = [@{@"channel": peer[@"channel"], @"text": text, @"blocks": blocks,
        @"unfurl_links": @NO, @"unfurl_media": @NO} mutableCopy];
    if (thread) post[@"thread_ts"] = thread;
    return post;
}

@interface CCBridgeSlackAdapter : NSObject
@property (nonatomic, strong) NSURLSession *http;
@property (nonatomic, copy) NSString *appToken, *botToken, *team, *user, *bot;
// Only the Socket Mode receiver changes peers after startup. Publish immutable snapshots.
@property (atomic, copy) NSDictionary<NSString *, NSDictionary *> *peers;
@property (nonatomic, copy) NSDictionary *discovery;
@property (atomic, copy) NSString *discoveryJoin;
@property (atomic) long long retryPostsAt;
@property (atomic, copy) NSString *connectionID;
// Only the listener installs a socket. The power callback can invalidate it.
@property (nonatomic, strong) NSURLSessionWebSocketTask *activeSocket;
@property (nonatomic) io_connect_t powerConnection;
@property (nonatomic, strong) NSMutableDictionary *publications;
@property (nonatomic) long long nextDirectoryCheck;
@end

static void SlackPowerChanged(void *context, io_service_t service, natural_t message, void *argument) {
    CCBridgeSlackAdapter *adapter = (__bridge CCBridgeSlackAdapter *)context;
    if (message == kIOMessageCanSystemSleep || message == kIOMessageSystemWillSleep) {
        IOAllowPowerChange(adapter.powerConnection, (intptr_t)argument);
    } else if (message == kIOMessageSystemHasPoweredOn) {
        @synchronized (adapter) {
            if (!adapter.activeSocket) return;
            adapter.connectionID = nil;
            [adapter.activeSocket cancel];
            adapter.activeSocket = nil;
        }
        Report(L(@"Mac woke from sleep; reconnecting Socket Mode."));
    }
}

// Scope the pong deadline to the probed socket. Neither a late callback nor
// its timer can cancel a replacement connection.
static void PingSlackSocket(NSURLSessionWebSocketTask *socket) {
    dispatch_semaphore_t pong = dispatch_semaphore_create(0);
    __block BOOL healthy = NO;
    [socket sendPingWithPongReceiveHandler:^(NSError *error) {
        healthy = error == nil;
        dispatch_semaphore_signal(pong);
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10LL * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (socket.state == NSURLSessionTaskStateRunning &&
            (dispatch_semaphore_wait(pong, DISPATCH_TIME_NOW) != 0 || !healthy)) {
            Report(L(@"Socket Mode ping failed or timed out; reconnecting."));
            [socket cancel];
        }
    });
}

// Keep a single receive outstanding during the probe, so new envelopes can be
// processed and acknowledged without waiting for a pong.
static NSURLSessionWebSocketMessage *ReceiveSlackFrame(NSURLSessionWebSocketTask *socket, BOOL connected) {
    dispatch_semaphore_t received = dispatch_semaphore_create(0);
    __block NSURLSessionWebSocketMessage *frame = nil;
    [socket receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        frame = message;
        dispatch_semaphore_signal(received);
    }];
    const int64_t idle = (connected ? 30LL : 15LL) * NSEC_PER_SEC;
    while (dispatch_semaphore_wait(received, dispatch_time(DISPATCH_TIME_NOW, idle)) != 0) {
        if (!connected || socket.state != NSURLSessionTaskStateRunning || !CCBridgeEnabled()) return nil;
        PingSlackSocket(socket);
    }
    return frame;
}

@implementation CCBridgeSlackAdapter

- (void)sendQueued:(NSDictionary *)message peer:(NSDictionary *)peer {
    NSString *mid = message[@"id"], *thread = message[@"to"][@"slackThread"];
    NSDictionary *receipt = CCBridgeReadReceipt(mid);
    if (![receipt[@"status"] isEqual:@"pending"] || !self.connectionID || !CCBridgeEnabled()) return;
    self.retryPostsAt = MAX(self.retryPostsAt, [receipt[@"retryAt"] longLongValue]);
    if (receipt[@"postedAt"]) {
        if (CCPetsMilliseconds() - [receipt[@"postedAt"] longLongValue] > ([message[@"attachments"] count] ? CCBridgeMessageTTL : 180000)) {
            CCBridgeUpdateReceipt(mid, @{@"status": @"undeliverable", @"reason": L(@"The remote Bridge did not confirm receipt.")});
        }
        return;
    }
    if (self.retryPostsAt > CCPetsMilliseconds()) return;
    BOOL remote = CCBridgeIsRemoteHost(peer);
    NSString *failure = nil;
    if ([receipt[@"posting"] boolValue]) {
        failure = L(@"The adapter stopped during a Slack post. Check the thread before retrying.");
    } else if (thread && ![ThreadOwner(message[@"to"][@"session"], thread) isEqual:message[@"from"][@"session"]]) {
        failure = L(@"This Slack thread does not belong to the sending session or has expired.");
    } else {
        NSString *destination = message[@"to"][@"remoteID"];
        if (remote && (!destination || (!thread && ![[CCBridgeRemoteDirectory(peer)[@"sessions"] valueForKey:@"remoteID"] containsObject:destination]))) {
            CCBridgeUpdateReceipt(mid, @{@"status": @"undeliverable", @"reason": L(@"The remote session is offline.")});
            return;
        }
        NSString *comment = [NSString stringWithFormat:@"<@%@> [%@] %@", peer[@"user_id"],
            CCBridgeDescribeSession(message[@"from"]), EscapeSlackText(message[@"body"])];
        NSArray *fileIDs = nil;
        if ([message[@"attachments"] count]) {
            NSDictionary *shared = CCBridgeSlackShareFiles(self.http, self.botToken, message, peer,
                remote ? [NSString stringWithFormat:@"%@ → %@", message[@"from"][@"name"], message[@"to"][@"name"]] : comment, thread);
            if (shared[@"delay"]) {
                self.retryPostsAt = CCPetsMilliseconds() + 1000LL * [shared[@"delay"] longLongValue];
                CCBridgeUpdateReceipt(mid, @{@"retryAt": @(self.retryPostsAt)});
                return;
            }
            if (shared[@"error"]) {
                CCBridgeUpdateReceipt(mid, @{@"status": @"undeliverable", @"reason": shared[@"error"]});
                Report(shared[@"error"]);
                return;
            }
            thread = shared[@"thread"];
            fileIDs = shared[@"ids"];
            if (!remote) {
                CCBridgeUpdateReceipt(mid, @{@"status": @"delivered", @"transport": @{@"kind": @"slack", @"thread": thread}});
                return;
            }
        }
        NSMutableDictionary *post;
        if (remote) {
            NSMutableDictionary *packet = [@{@"type": fileIDs ? @"message-files" : @"message", @"id": mid, @"to": destination,
                @"from": CCBridgeRemoteAdvertisement(message[@"from"]), @"body": message[@"body"]} mutableCopy];
            if (fileIDs) packet[@"files"] = fileIDs;
            NSString *display = [NSString stringWithFormat:@"%@ → %@\n%@", message[@"from"][@"name"],
                message[@"to"][@"name"], message[@"body"]];
            post = WirePost(peer, packet, PlainTextBlocks(display), thread);
            if (!post) {
                CCBridgeUpdateReceipt(mid, @{@"status": @"undeliverable", @"reason": L(@"Message exceeds Slack’s wire size limit.")});
                return;
            }
        } else {
            post = [@{@"channel": peer[@"channel"], @"text": comment, @"unfurl_links": @NO, @"unfurl_media": @NO} mutableCopy];
            if (thread) post[@"thread_ts"] = thread;
        }
        NSDictionary *posting = CCBridgeUpdateReceipt(mid, @{@"posting": @YES});
        if (![posting[@"status"] isEqual:@"pending"] || !CCBridgeEnabled()) return;
        NSDictionary *reply = CCBridgeSlackAPI(self.http, @"chat.postMessage", self.botToken, post);
        if ([reply[@"ok"] isEqual:@YES] && Matches(reply[@"ts"], @"^[0-9]+\\.[0-9]{6}\\z")) {
            NSDictionary *transport = @{@"kind": remote ? @"slack-bridge" : @"slack", @"thread": thread ?: reply[@"ts"]};
            CCBridgeUpdateReceipt(mid, remote ? @{@"postedAt": @(CCPetsMilliseconds()), @"posting": @NO, @"transport": transport}
                : @{@"status": @"delivered", @"posting": @NO, @"transport": transport});
            return;
        }
        if (reply[@"delay"]) {
            self.retryPostsAt = CCPetsMilliseconds() + 1000LL * [reply[@"delay"] integerValue];
            CCBridgeUpdateReceipt(mid, @{@"posting": @NO, @"retryAt": @(self.retryPostsAt)});
            return;
        }
        failure = reply[@"error"] ?: @"invalid_response";
    }
    CCBridgeUpdateReceipt(mid, @{@"status": @"undeliverable", @"reason": failure});
    Report([NSString stringWithFormat:@"%@: %@", mid, failure]);
}

- (void)drainOutboxes {
    for (NSDictionary *peer in self.peers.allValues) {
        NSString *sid = peer[@"session"];
        if (!CCBridgeOldestPendingMessageName(sid)) continue;
        NSArray *batch = CCBridgeClaimInbox(sid);
        if (!batch.count) continue;
        // Only the adapter consumes this inbox. Release the producer lock before
        // the HTTP call. The next claim removes terminal receipts and recovers retries.
        CCBridgeFinishInbox(sid, batch, nil);
        for (NSDictionary *message in batch) [self sendQueued:message peer:peer];
    }
}

- (NSDictionary *)peerForEvent:(NSDictionary *)event {
    NSString *bot = event[@"bot_id"] ?: Object(event[@"bot_profile"])[@"id"];
    if (!Matches(bot, @"^B[A-Z0-9]+\\z") || [bot isEqual:self.bot] || ![event[@"type"] isEqual:@"message"] ||
        (event[@"subtype"] && ![@[@"bot_message", @"file_share"] containsObject:event[@"subtype"]]) || ![event[@"channel"] isKindOfClass:NSString.class]) return nil;
    NSDictionary *peer = self.peers[ChannelBot(event[@"channel"], bot)];
    if (event[@"user"] && ![event[@"user"] isEqual:peer[@"user_id"]]) return nil;
    return peer;
}

// Channel discovery shares one roster across all listeners. Explicit peers still receive addressed rosters.
- (void)publishDirectories {
    long long now = CCPetsMilliseconds();
    if (now < self.nextDirectoryCheck || now < self.retryPostsAt) return;
    self.nextDirectoryCheck = now + 5000;
    NSString *connection = self.connectionID;
    if (!connection) return;
    NSMutableArray *roster = [NSMutableArray array];
    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    for (NSDictionary *session in CCBridgeListSessions()) {
        if (![session[@"provider"] isEqual:CCBridgeSlackProvider] && CCBridgeSessionLive(session)) {
            [roster addObject:CCBridgeRemoteAdvertisement(session)];
            [rows addObject:SlackRosterRow(session)];
        }
    }
    [roster sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"id" ascending:YES]]];
    NSString *count = rows.count == 1 ? L(@"1 session online")
        : [NSString stringWithFormat:L(@"%ld sessions online"), (long)rows.count];
    [rows sortUsingSelector:@selector(localizedStandardCompare:)];
    NSMutableArray *destinations = [NSMutableArray array];
    if (self.discovery) [destinations addObject:self.discovery];
    for (NSDictionary *peer in self.peers.allValues) {
        if (CCBridgeIsRemoteHost(peer) && !peer[@"discovered"]) [destinations addObject:peer];
    }
    for (NSDictionary *peer in destinations) {
        if (!CCBridgeEnabled() || !self.connectionID) return;
        BOOL broadcast = !peer[@"user_id"];
        NSString *sid = broadcast ? peer[@"channel"] : peer[@"session"];
        NSDictionary *last = self.publications[sid];
        NSString *other = (broadcast ? self.discoveryJoin : CCBridgeRemoteDirectory(peer)[@"instance"]) ?: @"";
        if ([last[@"roster"] isEqual:roster] && [last[@"connection"] isEqual:connection] &&
            [last[@"other"] isEqual:other] && now - [last[@"at"] longLongValue] < 30000) continue;
        NSMutableDictionary *packet = [@{@"type": @"roster", @"sessions": roster, @"instance": connection, @"at": @(now)} mutableCopy];
        if (broadcast) packet[@"host"] = self.discovery[@"name"];
        NSString *heading = [NSString stringWithFormat:@"%@ · %@", broadcast ? self.discovery[@"name"] : @"CC Bridge", count];
        NSMutableDictionary *post = WirePost(peer, packet, SlackRosterBlocks(heading, rows), nil);
        if (!post) { Report(L(@"Remote directory exceeds Slack’s wire size limit.")); continue; }
        // A new listener may receive edits without a bot ID. Start with an
        // original bot-authored announcement so it can bind bot and user IDs.
        BOOL newListener = broadcast && (![last[@"other"] isEqual:other] || ![last[@"connection"] isEqual:connection]);
        if (last[@"ts"] && !newListener) post[@"ts"] = last[@"ts"];
        NSDictionary *reply = CCBridgeSlackAPI(self.http, post[@"ts"] ? @"chat.update" : @"chat.postMessage", self.botToken, post);
        if ([reply[@"ok"] isEqual:@YES] && [reply[@"ts"] isKindOfClass:NSString.class]) {
            self.publications[sid] = @{@"ts": reply[@"ts"], @"at": @(now), @"connection": connection,
                @"roster": roster, @"other": other};
        } else {
            if ([@[@"message_not_found", @"edit_window_closed", @"cant_update_message"] containsObject:reply[@"error"] ?: @""]) {
                [self.publications removeObjectForKey:sid];
            }
            self.nextDirectoryCheck = now + 1000LL * MAX(10, [reply[@"delay"] longLongValue]);
            Report(reply[@"error"] ?: @"invalid_response");
            if (reply[@"delay"]) break;
        }
    }
}

// A discovery endpoint is bound to the Slack event author and channel. Never
// take a bot ID, user ID or routing key from the advertised payload.
- (NSDictionary *)discoveryAuthor:(NSDictionary *)event knownPeer:(NSDictionary *)known {
    if (![event[@"channel"] isEqual:self.discovery[@"channel"]] || ![event[@"type"] isEqual:@"message"] ||
        (event[@"subtype"] && ![event[@"subtype"] isEqual:@"bot_message"])) return nil;
    NSDictionary *profile = Object(event[@"bot_profile"]);
    NSString *originTeam = profile[@"team_id"] ?: event[@"team"];
    if (originTeam && ![originTeam isEqual:self.team]) return nil;
    NSString *bot = event[@"bot_id"] ?: profile[@"id"] ?: known[@"bot_id"];
    NSString *user = event[@"user"] ?: profile[@"user_id"] ?: known[@"user_id"];
    if (!Matches(bot, @"^B[A-Z0-9]+\\z") || !Matches(user, @"^[UW][A-Z0-9]+\\z") ||
        [self.bot isEqual:bot] || [self.user isEqual:user]) return nil;
    NSString *editor = Object(event[@"edited"])[@"user"];
    if (editor && ![editor isEqual:user] && ![editor isEqual:bot]) return nil;
    NSString *endpoint = ChannelBot(event[@"channel"], bot);
    NSDictionary *old = self.peers[endpoint];
    if (old) return [old[@"user_id"] isEqual:user] && CCBridgeIsRemoteHost(old) ? old : nil;
    NSString *sid = [@"slack-host-auto-" stringByAppendingString:
        CCBridgeSHA1Hex([NSString stringWithFormat:@"%@/%@/%@/%@", self.team, self.bot, endpoint, user])];
    return @{@"channel": event[@"channel"], @"bot_id": bot, @"user_id": user, @"session": sid,
        @"hostPid": @(getpid()), @"provider": CCBridgeSlackProvider, @"discovered": @YES};
}

- (void)acceptAnnouncement:(NSDictionary *)packet author:(NSDictionary *)author timestamp:(NSString *)timestamp {
    if (!author || !CCBridgeEnabled() || !self.connectionID || ![packet[@"type"] isEqual:@"roster"] ||
        !Matches(packet[@"host"], @"^[A-Za-z0-9][A-Za-z0-9._-]{0,39}\\z") ||
        !Matches(timestamp, @"^[0-9]{1,16}\\.[0-9]{6}\\z") || !Matches(packet[@"instance"], @"^[A-Fa-f0-9-]{36}\\z")) return;
    NSString *endpoint = ChannelBot(author[@"channel"], author[@"bot_id"]);
    NSDictionary *old = self.peers[endpoint];
    NSMutableDictionary *peer = [author mutableCopy];
    if (peer[@"discovered"]) peer[@"name"] = packet[@"host"];
    NSString *previousInstance = CCBridgeRemoteDirectory(peer)[@"instance"];
    if (!CCBridgeSaveRemoteDirectory(peer, timestamp, packet[@"sessions"], packet[@"instance"])) return;
    if (!old) CCBridgeUpsertSession(peer[@"session"], CCBridgeSlackProvider, @(getpid()), nil, nil, @"idle", nil, nil, nil, nil);
    if (peer[@"discovered"] && ![old[@"name"] isEqual:peer[@"name"]]) {
        NSMutableDictionary *snapshot = [self.peers mutableCopy];
        snapshot[endpoint] = peer;
        self.peers = snapshot;
    }
    if (![previousInstance isEqual:packet[@"instance"]]) self.discoveryJoin = NSUUID.UUID.UUIDString;
}

- (NSDictionary *)fetchFiles:(NSArray *)ids peer:(NSDictionary *)peer event:(NSDictionary *)event
        messageID:(NSString *)mid requireRoot:(BOOL)root {
    if (self.retryPostsAt > CCPetsMilliseconds()) return @{@"delay": @1};
    NSDictionary *result = CCBridgeSlackFetchFiles(self.http, self.botToken, ids, peer,
        event[@"thread_ts"] ?: event[@"ts"], root, mid, event[@"downloadDay"] ?: CCBridgeAttachmentDay([event[@"ts"] doubleValue]));
    // The event can precede Slack's file metadata becoming visible.
    if (([result[@"error"] isEqual:@"file_not_found"] || [result[@"error"] isEqual:@"file_share_not_visible"]) &&
        NSDate.date.timeIntervalSince1970 - [event[@"ts"] doubleValue] < 60) {
        result = @{@"delay": @3};
    }
    if (result[@"delay"]) self.retryPostsAt = CCPetsMilliseconds() + 1000LL * [result[@"delay"] longLongValue];
    return result;
}

// Acknowledgements belong to one authenticated peer, original post and thread.
// Keep the sender's receipt pending until the other Bridge has accepted the body.
- (BOOL)handleRemoteEvent:(NSDictionary *)event peer:(NSDictionary *)peer {
    NSDictionary *packet = WirePacket(self.user, event[@"text"]);
    NSString *mid = packet[@"id"], *thread = event[@"thread_ts"] ?: event[@"ts"];
    if (!Matches(mid, @"^m[a-z0-9]{1,64}\\z")) return YES;
    if ([packet[@"type"] isEqual:@"ack"]) {
        NSDictionary *receipt = CCBridgeReadReceipt(mid);
        if (![receipt[@"to"][@"gateway"] isEqual:peer[@"session"]] || !receipt[@"postedAt"] ||
            ![receipt[@"transport"][@"thread"] isEqual:event[@"thread_ts"]]) return YES;
        NSString *state = packet[@"result"];
        if ([state isEqual:@"accepted"]) CCBridgeUpdateReceipt(mid, @{@"status": @"delivered"});
        else if ([state isEqual:@"offline"] || [state isEqual:@"refused"]) {
            NSString *reason = [state isEqual:@"offline"] ? L(@"The remote session is offline.") : L(@"The remote Bridge refused delivery.");
            if (Matches(packet[@"file_error"], @"^[a-z_]{1,64}\\z")) reason = [reason stringByAppendingFormat:@" (%@)", packet[@"file_error"]];
            CCBridgeUpdateReceipt(mid, @{@"status": @"undeliverable", @"reason": reason});
        }
        return YES;
    }
    BOOL withFiles = [packet[@"type"] isEqual:@"message-files"];
    if ((!withFiles && ![packet[@"type"] isEqual:@"message"]) || !Matches(packet[@"to"], @"^[a-f0-9]{40}\\z") ||
        ![packet[@"body"] isKindOfClass:NSString.class]) return YES;
    NSMutableDictionary *from = [CCBridgeRemoteIdentity(peer, packet[@"from"]) mutableCopy];
    if (!from) return YES;
    NSString *incoming = [@"s" stringByAppendingString:CCBridgeSHA1Hex([NSString stringWithFormat:@"%@/%@", peer[@"session"], mid])];
    from[@"slackEventID"] = incoming;
    from[@"slackThread"] = thread;
    NSDictionary *received = CCBridgeReadReceipt(incoming);
    NSString *state = @"offline";
    NSString *fileError = nil;
    if (!received || [received[@"status"] isEqual:@"queued"]) {
        // Resolve only a local session with this full, stable routing ID.
        for (NSDictionary *target in CCBridgeListSessions()) {
            if ([target[@"provider"] isEqual:CCBridgeSlackProvider] ||
                ![CCBridgeSHA1Hex(target[@"session"]) isEqual:packet[@"to"]] || !CCBridgeSessionLive(target)) continue;
            NSString *owner = event[@"thread_ts"] ? ThreadOwner(from[@"session"], thread) : nil;
            if (event[@"thread_ts"] && ![owner isEqual:target[@"session"]] && (owner || !withFiles)) break;
            NSArray *paths = nil;
            if (withFiles) {
                NSDictionary *download = [self fetchFiles:packet[@"files"] peer:peer event:event messageID:incoming
                    requireRoot:!owner];
                if (download[@"delay"]) return NO;
                if (download[@"error"]) {
                    fileError = download[@"error"];
                    Report(fileError);
                    state = @"refused";
                    break;
                }
                paths = download[@"paths"];
            }
            NSDictionary *result = CCBridgeSendMessageWithAttachments(from, target, packet[@"body"], paths, NO);
            received = result[@"receipt"];
            state = @"refused";
            break;
        }
    }
    if (received && ![received[@"status"] isEqual:@"queued"]) {
        state = [@[@"pending", @"delivered"] containsObject:received[@"status"]] ? @"accepted" : @"refused";
    }
    if (!self.connectionID || self.retryPostsAt > CCPetsMilliseconds() || !CCBridgeEnabled()) return NO;
    NSMutableDictionary *ackPacket = [@{@"type": @"ack", @"id": mid, @"result": state} mutableCopy];
    if (fileError) ackPacket[@"file_error"] = fileError;
    NSDictionary *ack = WirePost(peer, ackPacket,
        PlainTextBlocks([NSString stringWithFormat:@"CC Bridge · %@ · %@", mid, state]), thread);
    NSDictionary *reply = CCBridgeSlackAPI(self.http, @"chat.postMessage", self.botToken, ack);
    if ([reply[@"ok"] isEqual:@YES]) return YES;
    NSString *error = reply[@"error"] ?: @"invalid_response";
    Report(error);
    if (!reply[@"delay"] && ![error hasPrefix:@"HTTP "] &&
        ![@[@"internal_error", @"fatal_error", @"request_timeout", @"service_unavailable"] containsObject:error]) return YES;
    self.retryPostsAt = CCPetsMilliseconds() + 1000LL * MAX(5, [reply[@"delay"] longLongValue]);
    return NO;
}

- (BOOL)handleEvent:(NSDictionary *)event peer:(NSDictionary *)peer messageID:(NSString *)mid {
    NSString *thread = event[@"thread_ts"], *text = event[@"text"];
    NSString *owner = thread ? ThreadOwner(peer[@"session"], thread) : nil;
    NSString *mention = [NSString stringWithFormat:@"<@%@>", self.user];
    NSDictionary *target;
    if (owner) {
        target = CCBridgeReadSession(owner);
        if ([text hasPrefix:mention]) text = [text substringFromIndex:mention.length];
    } else {
        // Only an explicit top-level mention can establish a new conversation.
        if (thread || ![text hasPrefix:mention]) return YES;
        NSString *command = [text substringFromIndex:mention.length];
        NSRegularExpression *syntax = [NSRegularExpression regularExpressionWithPattern:
            @"\\A\\s*(?:to|发给)\\s+([a-z0-9._-]+(?: \\[[a-f0-9]{6}\\])?)(?:\\s+([\\s\\S]+))?\\z" options:0 error:nil];
        NSTextCheckingResult *match = [syntax firstMatchInString:command options:0 range:NSMakeRange(0, command.length)];
        if (!match) return YES;
        NSString *priorTarget = CCBridgeReadReceipt(mid)[@"to"][@"session"];
        target = priorTarget ? CCBridgeReadSession(priorTarget) :
            CCBridgeResolveTarget([command substringWithRange:[match rangeAtIndex:1]], CCBridgeLiveSessions())[@"session"];
        NSRange bodyRange = [match rangeAtIndex:2];
        text = bodyRange.location == NSNotFound ? @"" : [command substringWithRange:bodyRange];
        thread = event[@"ts"];
    }
    if (!CCBridgeSessionLive(target) || [target[@"provider"] isEqual:CCBridgeSlackProvider]) {
        Report(L(@"Slack message has no unique online local recipient."));
        return YES;
    }
    NSMutableDictionary *from = [peer mutableCopy];
    from[@"slackThread"] = thread;
    from[@"slackEventID"] = mid;
    text = [[[text stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"] stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"]
        stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    NSArray *paths = nil;
    if (event[@"fileIDs"]) {
        NSDictionary *existing = CCBridgeReadReceipt(mid);
        if (existing && ![existing[@"status"] isEqual:@"queued"]) return YES;
        NSDictionary *download = [self fetchFiles:event[@"fileIDs"] peer:peer event:event messageID:mid requireRoot:NO];
        if (download[@"delay"]) return NO;
        if (download[@"error"]) { Report(download[@"error"]); return YES; }
        paths = download[@"paths"];
    }
    NSDictionary *result = CCBridgeSendMessageWithAttachments(from, target, text, paths, NO);
    if (result[@"error"]) Report(result[@"error"]);
    else if ([result[@"receipt"][@"status"] isEqual:@"undeliverable"]) Report(result[@"receipt"][@"reason"]);
    return YES;
}

// Persist accepted envelopes before ACK. A slow local Codex wake-up or an HTTP
// rate limit must not block Socket Mode acknowledgements or lose accepted work.
- (void)stageEnvelope:(NSDictionary *)envelope {
    NSDictionary *payload = Object(envelope[@"payload"]), *event = Object(payload[@"event"]);
    if (![envelope[@"type"] isEqual:@"events_api"] || ![payload[@"team_id"] isEqual:self.team] ||
        !Matches(payload[@"event_id"], @"^Ev[A-Za-z0-9]+\\z")) return;
    BOOL edit = [event[@"subtype"] isEqual:@"message_changed"];
    NSString *eventTS = event[@"event_ts"] ?: event[@"ts"];
    if (edit) {
        NSMutableDictionary *message = [Object(event[@"message"]) mutableCopy];
        message[@"channel"] = event[@"channel"];
        event = message;
    }
    NSDictionary *peer = [self peerForEvent:event];
    // Some edited bot messages retain only the bot user ID. Only accept that
    // form for presence, bound to the configured user and channel.
    if ((edit || event[@"files"]) && !peer && !event[@"bot_id"] && !Object(event[@"bot_profile"])[@"id"] && [event[@"type"] isEqual:@"message"]) {
        for (NSDictionary *candidate in self.peers.allValues) {
            if ((edit ? CCBridgeIsRemoteHost(candidate) : !CCBridgeIsRemoteHost(candidate)) && [event[@"user"] isEqual:candidate[@"user_id"]] &&
                [event[@"channel"] isEqual:candidate[@"channel"]]) {
                peer = candidate;
                break;
            }
        }
    }
    NSString *text = event[@"text"] ?: (event[@"files"] ? @"" : nil);
    if (![text isKindOfClass:NSString.class]) return;
    if ([event[@"channel"] isEqual:self.discovery[@"channel"]] && [text hasPrefix:WirePrefix(nil)]) {
        if (!event[@"thread_ts"]) {
            [self acceptAnnouncement:WirePacket(nil, text) author:[self discoveryAuthor:event knownPeer:peer] timestamp:eventTS];
        }
        return;
    }
    if (!peer && !edit && [text hasPrefix:WirePrefix(self.user)]) {
        peer = [self discoveryAuthor:event knownPeer:nil];
    }
    NSString *editor = Object(event[@"edited"])[@"user"];
    if (edit && editor && ![editor isEqual:peer[@"user_id"]] && ![editor isEqual:peer[@"bot_id"]]) return;
    if (!peer || !Matches(event[@"ts"], @"^[0-9]{1,16}\\.[0-9]{6}\\z")) return;
    if (event[@"thread_ts"] && !Matches(event[@"thread_ts"], @"^[0-9]{1,16}\\.[0-9]{6}\\z")) return;
    BOOL waitForRoster = peer[@"discovered"] && !CCBridgeRemoteDirectory(peer);
    if (CCBridgeIsRemoteHost(peer)) {
        NSDictionary *packet = WirePacket(self.user, text);
        if ([packet[@"type"] isEqual:@"roster"] && !event[@"thread_ts"] &&
            Matches(eventTS, @"^[0-9]{1,16}\\.[0-9]{6}\\z") && Matches(packet[@"instance"], @"^[A-Fa-f0-9-]{36}\\z")) {
            if (!peer[@"discovered"]) CCBridgeSaveRemoteDirectory(peer, eventTS, packet[@"sessions"], packet[@"instance"]);
            return;
        }
        if (![@[@"message", @"message-files", @"ack"] containsObject:packet[@"type"] ?: @""]) return;
    }
    // Edits can refresh presence, but never trigger or replay a user message.
    if (edit || (!event[@"thread_ts"] && ![text hasPrefix:[NSString stringWithFormat:@"<@%@>", self.user]])) return;
    NSMutableArray *fileIDs = nil;
    if (!CCBridgeIsRemoteHost(peer) && (event[@"files"] || [event[@"subtype"] isEqual:@"file_share"])) {
        NSArray *files = event[@"files"];
        if (![files isKindOfClass:NSArray.class] || !files.count || files.count > CCBridgeAttachmentCountLimit) return;
        fileIDs = [NSMutableArray array];
        for (id file in files) {
            NSString *fid = Object(file)[@"id"];
            if (!CCBridgeSlackFileIDValid(fid)) return;
            [fileIDs addObject:fid];
        }
    }
    NSString *mid = [@"s" stringByAppendingString:CCBridgeSHA1Hex([NSString stringWithFormat:@"%@/%@", peer[@"session"], payload[@"event_id"]])];
    CCBridgeWithLock(@"slack-events", ^id {
        NSDictionary *existing = CCBridgeReadReceipt(mid);
        if (!CCBridgeEnabled() || (existing && ![existing[@"status"] isEqual:@"queued"])) return nil;
        NSString *file = [CCBridgeSubdirectory(@[@"slack-events"]) stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@-%@.json", event[@"ts"], mid]];
        if (![NSFileManager.defaultManager fileExistsAtPath:file]) {
            NSMutableDictionary *message = [NSMutableDictionary dictionary];
            for (NSString *key in @[@"type", @"bot_id", @"user", @"channel", @"ts", @"thread_ts", @"text"]) {
                if (event[key]) message[key] = event[key];
            }
            if (fileIDs) { message[@"fileIDs"] = fileIDs; message[@"text"] = text; }
            message[@"bot_id"] = peer[@"bot_id"];
            long long now = CCPetsMilliseconds();
            // Persist the receiver's local calendar day across retries, including timezone changes.
            message[@"downloadDay"] = CCBridgeAttachmentDay(now / 1000.0);
            NSMutableDictionary *item = [@{@"id": mid, @"peer": peer[@"session"], @"event": message, @"at": @(now)} mutableCopy];
            if (waitForRoster) item[@"registrationDeadline"] = @(now + 90000);
            CCBridgeWriteJSON(file, item);
        }
        return nil;
    });
}

- (void)drainEvents {
    NSString *directory = CCBridgeSubdirectory(@[@"slack-events"]);
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil];
    for (NSString *name in [names sortedArrayUsingSelector:@selector(compare:)]) {
        if (![name hasSuffix:@".json"] || !CCBridgeEnabled()) continue;
        NSString *path = [directory stringByAppendingPathComponent:name];
        NSDictionary *item = Object(CCBridgeReadJSON(path)), *event = Object(item[@"event"]);
        NSDictionary *peer = [self peerForEvent:event];
        long long now = CCPetsMilliseconds();
        BOOL fresh = now - [item[@"at"] longLongValue] < CCBridgeMessageTTL;
        if (item[@"registrationDeadline"] && (!peer || !CCBridgeRemoteDirectory(peer))) {
            if ([item[@"registrationDeadline"] longLongValue] > now) continue;
            fresh = NO;
        }
        // A replay can already be on disk when the adapter restarts, before
        // its sender has renewed discovery in this connection.
        if (!peer && fresh && [item[@"peer"] hasPrefix:@"slack-host-auto-"] && [event[@"channel"] isEqual:self.discovery[@"channel"]]) continue;
        if (peer && [peer[@"session"] isEqual:item[@"peer"]] && fresh) {
            if (CCBridgeIsRemoteHost(peer)) {
                if (![self handleRemoteEvent:event peer:peer]) continue;
            } else {
                if (![self handleEvent:event peer:peer messageID:item[@"id"]]) continue;
            }
        }
        unlink(path.fileSystemRepresentation);
    }
}

// The receiver runs independently of the serial routing loop. Reopen the URL
// for every connection, including Slack's periodic disconnect requests.
- (void)listenWithConnection:(NSDictionary *)initial {
    NSUInteger backoff = 1;
    while (CCBridgeEnabled()) {
        @autoreleasepool {
            NSDictionary *open = initial ?: CCBridgeSlackAPI(self.http, @"apps.connections.open", self.appToken, nil);
            initial = nil;
            NSURL *url = [open[@"url"] isKindOfClass:NSString.class] ? [NSURL URLWithString:open[@"url"]] : nil;
            if ([open[@"ok"] isEqual:@YES] && [url.scheme isEqual:@"wss"]) {
                NSURLSessionWebSocketTask *socket = [self.http webSocketTaskWithURL:url];
                @synchronized (self) {
                    self.activeSocket = socket;
                    [socket resume];
                }
                while (CCBridgeEnabled()) {
                    @autoreleasepool {
                        NSURLSessionWebSocketMessage *frame = ReceiveSlackFrame(socket, self.connectionID != nil);
                        if (!frame) break;
                        NSData *data = frame.type == NSURLSessionWebSocketMessageTypeData ? frame.data : [frame.string dataUsingEncoding:NSUTF8StringEncoding];
                        NSDictionary *envelope = Parse(data);
                        if ([envelope[@"type"] isEqual:@"disconnect"]) break;
                        if ([envelope[@"type"] isEqual:@"hello"]) {
                            @synchronized (self) {
                                if (self.activeSocket != socket) break;
                                self.connectionID = NSUUID.UUID.UUIDString;
                            }
                            backoff = 1;
                            Report(L(@"Socket Mode connected."));
                        }
                        NSString *eid = envelope[@"envelope_id"];
                        if (![eid isKindOfClass:NSString.class]) continue;
                        @try { [self stageEnvelope:envelope]; }
                        @catch (NSException *exception) { Report(exception.reason); break; }
                        NSData *ack = [NSJSONSerialization dataWithJSONObject:@{@"envelope_id": eid} options:0 error:nil];
                        NSString *json = [[NSString alloc] initWithData:ack encoding:NSUTF8StringEncoding];
                        [socket sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:json] completionHandler:^(NSError *error) {
                            if (error) [socket cancel];
                        }];
                    }
                }
                @synchronized (self) {
                    self.activeSocket = nil;
                    self.connectionID = nil;
                }
                [socket cancel];
                for (NSDictionary *peer in self.peers.allValues) {
                    if (CCBridgeIsRemoteHost(peer)) CCBridgeClearRemoteDirectory(peer);
                }
            } else {
                Report(open[@"error"] ?: @"invalid_socket_url");
            }
            sleep((unsigned int)MAX(backoff, [open[@"delay"] unsignedIntegerValue]));
            backoff = MIN(60, backoff * 2);
        }
    }
}
@end

int CCBridgeRunSlack(NSArray<NSString *> *arguments) {
    if (arguments.count > 1 || [arguments.firstObject isEqual:@"--help"]) {
        CCPetsPrintLine(stderr, L(@"Usage: cc-pets bridge slack [config.json] (tokens in JSON or SLACK_APP_TOKEN and SLACK_BOT_TOKEN)"));
        return arguments.count > 1 ? 2 : 0;
    }
    if (!CCBridgeEnabled()) { Report(L(@"CC Bridge is off. Run cc-pets bridge enable first.")); return 1; }
    BOOL managed = [arguments.firstObject isEqual:@"--managed"];
    NSString *path = managed ? CCBridgeSlackConfigPath() : (arguments.firstObject ?: CCBridgeSlackConfigPath());
    NSString *error = nil;
    NSDictionary *config = ReadSlackConfig(path, &error);
    if (!config) { Report(error ?: L(@"Set discovery.channel or configure peers in the agents array in the Slack configuration.")); return 1; }
    if (managed && ![config[@"enabled"] isEqual:@YES]) return 0;
    if (managed) {
        // Only the desktop parent holds the writing end. Closing it on quit,
        // config change, or a parent crash also stops an in-flight HTTP call.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            char byte;
            ssize_t count;
            do { count = read(STDIN_FILENO, &byte, 1); } while (count > 0 || (count < 0 && errno == EINTR));
            _exit(0);
        });
    }
    NSArray *agents = config[@"agents"];
    CCBridgeSlackAdapter *adapter = [CCBridgeSlackAdapter new];
    adapter.appToken = config[@"app_token"];
    adapter.botToken = config[@"bot_token"];
    if (!managed) {
        if (!adapter.appToken.length) adapter.appToken = CCPetsEnvironmentValue(@"SLACK_APP_TOKEN");
        if (!adapter.botToken.length) adapter.botToken = CCPetsEnvironmentValue(@"SLACK_BOT_TOKEN");
    }
    if (![adapter.appToken hasPrefix:@"xapp-"] || ![adapter.botToken hasPrefix:@"xoxb-"]) {
        Report(L(@"Set app_token (xapp-) and bot_token (xoxb-) in the Slack JSON, or supply the tokens in the terminal environment.")); return 1;
    }
    NSString *lock = CCBridgeAcquireLock(@"slack-adapter");
    if (!lock) { Report(L(@"The Slack adapter is already running.")); return 1; }
    NSMutableDictionary *peers = [NSMutableDictionary dictionary];
    IONotificationPortRef powerPort = NULL;
    io_object_t notifier = IO_OBJECT_NULL;
    dispatch_queue_t powerQueue = dispatch_queue_create("cc-pets.slack.power", DISPATCH_QUEUE_SERIAL);
    @try {
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.URLCache = nil;
        adapter.http = [NSURLSession sessionWithConfiguration:configuration];
        NSDictionary *auth = CCBridgeSlackAPI(adapter.http, @"auth.test", adapter.botToken, nil);
        if (![auth[@"ok"] isEqual:@YES] || !Matches(auth[@"team_id"], @"^T[A-Z0-9]+\\z") ||
            !Matches(auth[@"user_id"], @"^[UW][A-Z0-9]+\\z") || !Matches(auth[@"bot_id"], @"^B[A-Z0-9]+\\z")) {
            Report(auth[@"error"] ?: @"invalid_bot_identity"); return 1;
        }
        adapter.team = auth[@"team_id"];
        adapter.user = auth[@"user_id"];
        adapter.bot = auth[@"bot_id"];
        if (config[@"discovery"]) {
            NSString *name = config[@"discovery"][@"name"];
            if (!name && [auth[@"user"] isKindOfClass:NSString.class]) name = CCBridgeNormalizeSessionName(auth[@"user"]);
            adapter.discovery = @{@"channel": config[@"discovery"][@"channel"], @"name": name ?: adapter.bot.lowercaseString};
            adapter.publications = [NSMutableDictionary dictionary];
        }
        NSDictionary *connection = CCBridgeSlackAPI(adapter.http, @"apps.connections.open", adapter.appToken, nil);
        if (![connection[@"ok"] isEqual:@YES]) { Report(connection[@"error"] ?: @"invalid_socket_url"); return 1; }
        for (NSDictionary *agent in agents) {
            if ([agent[@"bot_id"] isEqual:adapter.bot] || [agent[@"user_id"] isEqual:adapter.user]) {
                Report(L(@"A Slack peer cannot be the adapter itself.")); return 1;
            }
            NSString *endpoint = ChannelBot(agent[@"channel"], agent[@"bot_id"]);
            BOOL machine = [agent[@"bridge"] boolValue];
            NSString *prefix = machine ? @"slack-host-" : @"slack-";
            NSString *sid = [prefix stringByAppendingString:CCBridgeSHA1Hex([NSString stringWithFormat:@"%@/%@/%@/%@/%@",
                adapter.team, adapter.bot, endpoint, agent[@"user_id"], agent[@"name"]])];
            NSDictionary *session = CCBridgeUpsertSession(sid, CCBridgeSlackProvider, @(getpid()), nil, nil,
                @"idle", machine ? nil : agent[@"name"], nil, nil, nil);
            NSMutableDictionary *peer = [agent mutableCopy];
            [peer addEntriesFromDictionary:session];
            peers[endpoint] = peer;
            if (machine) peer[@"name"] = agent[@"name"];
            else if (![session[@"name"] isEqual:agent[@"name"]]) {
                Report([NSString stringWithFormat:@"%@ %@", agent[@"name"], L(@"Slack agent name already in use.")]);
                return 1;
            }
            if (CCBridgeIsRemoteHost(peer)) {
                CCBridgeClearRemoteDirectory(peer);
                if (!adapter.publications) adapter.publications = [NSMutableDictionary dictionary];
            }
            Report(CCBridgeDescribeSession(peer));
        }
        adapter.peers = peers;
        // Both foreground and desktop-managed adapters run a blocking CLI loop.
        // Deliver system power notifications on a queue independent of file I/O.
        adapter.powerConnection = IORegisterForSystemPower((__bridge void *)adapter, &powerPort, SlackPowerChanged, &notifier);
        if (adapter.powerConnection) IONotificationPortSetDispatchQueue(powerPort, powerQueue);
        else Report(L(@"System wake notifications unavailable; Socket Mode will use idle pings."));
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [adapter listenWithConnection:connection]; });
        // Heartbeats continue while the routing loop waits on a busy local CLI.
        if (adapter.publications) dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            while (CCBridgeEnabled()) {
                @autoreleasepool {
                    @try { [adapter publishDirectories]; }
                    @catch (NSException *exception) { Report(exception.reason); }
                }
                sleep(5);
            }
        });
        while (CCBridgeEnabled()) {
            @autoreleasepool {
                [adapter drainEvents];
                if (adapter.connectionID) [adapter drainOutboxes];
            }
            usleep(500000);
        }
    } @finally {
        if (notifier) IODeregisterForSystemPower(&notifier);
        if (powerPort) IONotificationPortDestroy(powerPort);
        if (adapter.powerConnection) {
            dispatch_sync(powerQueue, ^{});
            IOServiceClose(adapter.powerConnection);
        }
        [adapter.http invalidateAndCancel];
        for (NSDictionary *peer in (adapter.peers ?: peers).allValues) CCBridgeRemoveSession(peer[@"session"]);
        CCBridgeReleaseLock(lock);
    }
    return 0;
}
