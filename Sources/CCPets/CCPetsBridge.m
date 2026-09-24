#import "CCPetsBridge.h"
#import "CCPetsPaths.h"
#import <errno.h>
#import <signal.h>
#import <unistd.h>

NSString *const BridgeBadgeEnabledKey = @"CCPetsBridgeBadgeEnabled";
NSString *const BridgeNotificationKey = @"CCPetsBridgeNotification";

// 目录里文件数的上限。回执保留 48 小时，正常使用远到不了这个量；
// 真到了说明有东西在刷消息，宁可少显示几条也不让桌宠主线程卡在读盘上。
static const NSUInteger BridgeFileScanLimit = 500;

NSString *CCBridgeStateDirectory(void) {
    NSString *name = [NSString stringWithFormat:@"cc-bridge-%u", getuid()];
    return [PetStateDirectory() stringByAppendingPathComponent:name];
}

static NSString *BridgeHomeDirectory(void) {
    NSString *home = NSProcessInfo.processInfo.environment[@"CC_PETS_HOME"];
    if (home.length == 0) home = [NSHomeDirectory() stringByAppendingPathComponent:@".cc-pets"];
    return home.stringByStandardizingPath;
}

BOOL CCBridgeEnabled(void) {
    return [NSFileManager.defaultManager fileExistsAtPath:
        [BridgeHomeDirectory() stringByAppendingPathComponent:@"bridge-enabled"]];
}

NSArray<NSString *> *CCBridgeToolGroupNames(void) {
    return @[@"view", @"send", @"reserve", @"name"];
}

NSArray<NSString *> *CCBridgeToolGroup(NSString *group) {
    static NSDictionary<NSString *, NSArray<NSString *> *> *groups;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        groups = @{
            @"view": @[@"list_agents", @"list_reservations", @"check_inbox"],
            @"send": @[@"send_message"],
            @"reserve": @[@"reserve_files", @"release_files"],
            @"name": @[@"set_name"]
        };
    });
    return groups[group] ?: @[];
}

static NSArray<NSString *> *KnownTools(id value) {
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *tools = [NSMutableArray array];
    for (NSString *group in CCBridgeToolGroupNames()) {
        for (NSString *tool in CCBridgeToolGroup(group)) {
            if ([value containsObject:tool]) [tools addObject:tool];
        }
    }
    return tools;
}

// 名字、ref、tty 都会进菜单标题。bridge 端已经约束过格式，这里再按同一字符集收一遍，
// 防止被手改的状态文件往菜单里塞奇怪的东西。
static NSString *BridgeSafeString(id value, NSUInteger maximumLength) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    NSMutableString *safe = [NSMutableString string];
    NSString *text = value;
    for (NSUInteger index = 0; index < text.length && safe.length < maximumLength; index++) {
        unichar character = [text characterAtIndex:index];
        if ([allowed characterIsMember:character]) [safe appendFormat:@"%C", character];
    }
    return safe;
}

static NSArray<NSString *> *JSONFilesInDirectory(NSString *directory) {
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil];
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    for (NSString *name in names) {
        if (![name hasSuffix:@".json"]) continue;
        [files addObject:[directory stringByAppendingPathComponent:name]];
        if (files.count >= BridgeFileScanLimit) break;
    }
    return files;
}

static NSDictionary *ReadJSONObject(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length == 0) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

NSDictionary *CCBridgeOptions(void) {
    NSDictionary *raw = nil;
    if (CCBridgeEnabled()) {
        raw = ReadJSONObject([BridgeHomeDirectory() stringByAppendingPathComponent:@"bridge-enabled"]);
    }
    return @{
        @"codexApprove": KnownTools(raw[@"codexApprove"]),
        @"claudeAllow": KnownTools(raw[@"claudeAllow"]),
        @"wake": @(![raw[@"wake"] isEqual:@NO]),
        @"editGuard": @(![raw[@"editGuard"] isEqual:@NO])
    };
}

NSDictionary<NSString *, NSString *> *CCBridgeCLILocator(void) {
    NSDictionary *raw = ReadJSONObject([BridgeHomeDirectory() stringByAppendingPathComponent:@"bridge-cli.json"]);
    NSString *node = [raw[@"node"] isKindOfClass:NSString.class] ? [raw[@"node"] stringByStandardizingPath] : nil;
    NSString *cli = [raw[@"cli"] isKindOfClass:NSString.class] ? [raw[@"cli"] stringByStandardizingPath] : nil;
    NSFileManager *files = NSFileManager.defaultManager;
    if (!node.isAbsolutePath || !cli.isAbsolutePath) return nil;
    if (![files isExecutableFileAtPath:node] || ![files isReadableFileAtPath:cli]) return nil;
    return @{@"node": node, @"cli": cli};
}

NSUInteger CCBridgeActiveReservationCount(NSSet<NSString *> *sessionIds) {
    NSString *directory = [CCBridgeStateDirectory() stringByAppendingPathComponent:@"reservations"];
    double now = NSDate.date.timeIntervalSince1970 * 1000.0;
    NSUInteger count = 0;
    for (NSString *path in JSONFilesInDirectory(directory)) {
        NSDictionary *reservation = ReadJSONObject(path);
        if ([reservation[@"expiresAt"] doubleValue] <= now) continue;
        NSString *session = [reservation[@"session"] isKindOfClass:NSString.class] ? reservation[@"session"] : nil;
        if (session && [sessionIds containsObject:session]) count++;
    }
    return count;
}

static BOOL ProcessAlive(id pidValue) {
    if (![pidValue isKindOfClass:NSNumber.class]) return YES;  // 没记 pid 的会话交给 bridge 端判定
    pid_t pid = [pidValue intValue];
    if (pid <= 1) return YES;
    return kill(pid, 0) == 0 || errno == EPERM;
}

NSDictionary<NSString *, NSDictionary *> *CCBridgeSessions(void) {
    NSString *directory = [CCBridgeStateDirectory() stringByAppendingPathComponent:@"sessions"];
    NSMutableDictionary<NSString *, NSDictionary *> *sessions = [NSMutableDictionary dictionary];
    for (NSString *path in JSONFilesInDirectory(directory)) {
        NSDictionary *record = ReadJSONObject(path);
        NSString *session = BridgeSafeString(record[@"session"], 128);
        NSString *name = BridgeSafeString(record[@"name"], 40);
        if (session.length == 0 || name.length == 0 || !ProcessAlive(record[@"pid"])) continue;
        NSMutableDictionary *entry = [@{
            @"name": name,
            @"ref": BridgeSafeString(record[@"ref"], 6),
            @"provider": BridgeSafeString(record[@"provider"], 16)
        } mutableCopy];
        NSString *tty = BridgeSafeString(record[@"tty"], 32);
        if (tty.length > 0) entry[@"tty"] = tty;
        sessions[session] = entry;
    }
    return sessions;
}

NSArray<NSDictionary *> *CCBridgeRecentDeliveries(NSTimeInterval since, NSUInteger limit) {
    NSString *directory = [CCBridgeStateDirectory() stringByAppendingPathComponent:@"sent"];
    NSMutableArray<NSDictionary *> *deliveries = [NSMutableArray array];
    for (NSString *path in JSONFilesInDirectory(directory)) {
        NSDictionary *receipt = ReadJSONObject(path);
        if (![receipt[@"status"] isEqual:@"delivered"]) continue;
        NSDictionary *from = [receipt[@"from"] isKindOfClass:NSDictionary.class] ? receipt[@"from"] : nil;
        NSDictionary *to = [receipt[@"to"] isKindOfClass:NSDictionary.class] ? receipt[@"to"] : nil;
        if (!from || !to || [from[@"system"] boolValue]) continue;
        id stamp = receipt[@"updatedAt"] ?: receipt[@"createdAt"];
        if (![stamp isKindOfClass:NSNumber.class]) continue;
        NSTimeInterval at = [stamp doubleValue] / 1000.0;
        if (at < since) continue;
        NSString *fromName = BridgeSafeString(from[@"name"], 40);
        NSString *toName = BridgeSafeString(to[@"name"], 40);
        NSString *toSession = BridgeSafeString(to[@"session"], 128);
        if (fromName.length == 0 || toName.length == 0 || toSession.length == 0) continue;
        // 只取元数据：receipt[@"body"] 不进入返回值。
        [deliveries addObject:@{
            @"id": BridgeSafeString(receipt[@"id"], 64),
            @"from": fromName,
            @"to": toName,
            @"toSession": toSession,
            @"at": @(at)
        }];
    }
    [deliveries sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [right[@"at"] compare:left[@"at"]];
    }];
    if (deliveries.count > limit) return [deliveries subarrayWithRange:NSMakeRange(0, limit)];
    return deliveries;
}

NSDictionary<NSString *, NSNumber *> *CCBridgePendingCounts(void) {
    NSString *inbox = [CCBridgeStateDirectory() stringByAppendingPathComponent:@"inbox"];
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:inbox error:nil]) {
        NSString *session = BridgeSafeString(name, 128);
        if (session.length == 0 || ![session isEqualToString:name]) continue;
        NSUInteger count = JSONFilesInDirectory([inbox stringByAppendingPathComponent:name]).count;
        if (count > 0) counts[session] = @(count);
    }
    return counts;
}
