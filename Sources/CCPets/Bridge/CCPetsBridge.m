#import "CCPetsBridge.h"
#import "CCPetsBridgeStore.h"
#import "CCPetsPaths.h"
#import <unistd.h>

NSString *const BridgeBadgeEnabledKey = @"CCPetsBridgeBadgeEnabled";
NSString *const BridgeNotificationKey = @"CCPetsBridgeNotification";

// 一次最多读这么多文件。回执保留 48 小时，正常使用远到不了这个量；
// 真到了说明有东西在刷消息，宁可少显示几条也不让桌宠主线程卡在读盘上。
static const NSUInteger BridgeFileScanLimit = 500;

NSString *CCBridgeStateDirectory(void) {
    NSString *name = [NSString stringWithFormat:@"cc-bridge-%u", getuid()];
    return [PetStateDirectory() stringByAppendingPathComponent:name];
}

// $HOME 可被覆盖（测试与命令行子命令都依赖这一点），没有时才退回账户的 home。
NSString *CCBridgeHomeDirectory(void) {
    NSString *home = NSProcessInfo.processInfo.environment[@"CC_PETS_HOME"];
    if (home.length == 0) {
        NSString *userHome = NSProcessInfo.processInfo.environment[@"HOME"];
        if (userHome.length == 0) userHome = NSHomeDirectory();
        home = [userHome stringByAppendingPathComponent:@".cc-pets"];
    }
    return home.stringByStandardizingPath;
}

BOOL CCBridgeEnabled(void) {
    return [NSFileManager.defaultManager fileExistsAtPath:
        [CCBridgeHomeDirectory() stringByAppendingPathComponent:@"bridge-enabled"]];
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

// 回执每次状态变化都是"临时文件 + rename"，修改时间就是最后一次更新的时间，比 ID（创建时间）更准：
// 排了很久的消息也可能刚刚送达。比 since 早的文件里不可能有新送达，不用打开；
// 其余的按新到旧取，文件数超过上限时丢掉的才是最旧的。
static NSArray<NSString *> *ReceiptFilesUpdatedSince(NSString *directory, NSTimeInterval since) {
    NSArray<NSURL *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:directory]
        includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:0 error:nil];
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    for (NSURL *entry in entries) {
        if (![entry.lastPathComponent hasSuffix:@".json"]) continue;
        NSDate *modified = nil;
        [entry getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
        if (modified.timeIntervalSince1970 < since) continue;
        [candidates addObject:@{@"path": entry.path, @"modified": modified}];
    }
    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [right[@"modified"] compare:left[@"modified"]];
    }];
    if (candidates.count > BridgeFileScanLimit) {
        [candidates removeObjectsInRange:NSMakeRange(BridgeFileScanLimit, candidates.count - BridgeFileScanLimit)];
    }
    return [candidates valueForKey:@"path"];
}

static NSDictionary *ReadJSONObject(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length == 0) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

// 只有 JSON 里明确写着 false 才算关；0、缺省、其他类型都按开处理。
static BOOL IsJSONFalse(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() && ![value boolValue];
}

NSDictionary *CCBridgeNormalizeOptions(NSDictionary *raw) {
    if (![raw isKindOfClass:NSDictionary.class]) raw = nil;
    return @{
        @"codexApprove": KnownTools(raw[@"codexApprove"]),
        @"claudeAllow": KnownTools(raw[@"claudeAllow"]),
        // 必须是 @YES / @NO（CFBoolean）：写回开关文件时要落成 JSON 的 true / false，而不是 1 / 0。
        @"wake": IsJSONFalse(raw[@"wake"]) ? @NO : @YES,
        @"editGuard": IsJSONFalse(raw[@"editGuard"]) ? @NO : @YES
    };
}

NSDictionary *CCBridgeReadSavedOptions(void) {
    return ReadJSONObject([CCBridgeHomeDirectory() stringByAppendingPathComponent:@"bridge-enabled"]) ?: @{};
}

NSDictionary *CCBridgeOptions(void) {
    return CCBridgeNormalizeOptions(CCBridgeEnabled() ? CCBridgeReadSavedOptions() : nil);
}

NSDictionary<NSString *, NSString *> *CCBridgeCLILocator(void) {
    NSDictionary *raw = ReadJSONObject([CCBridgeHomeDirectory() stringByAppendingPathComponent:@"bridge-cli.json"]);
    NSString *binary = [raw[@"binary"] isKindOfClass:NSString.class] ? [raw[@"binary"] stringByStandardizingPath] : nil;
    if (!binary.isAbsolutePath || ![NSFileManager.defaultManager isExecutableFileAtPath:binary]) return nil;
    NSString *path = [raw[@"path"] isKindOfClass:NSString.class] ? raw[@"path"] : @"";
    return @{@"binary": binary, @"path": path};
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

NSDictionary<NSString *, NSDictionary *> *CCBridgeSessions(void) {
    NSString *directory = [CCBridgeStateDirectory() stringByAppendingPathComponent:@"sessions"];
    NSMutableDictionary<NSString *, NSDictionary *> *sessions = [NSMutableDictionary dictionary];
    for (NSString *path in JSONFilesInDirectory(directory)) {
        NSDictionary *record = ReadJSONObject(path);
        NSString *session = BridgeSafeString(record[@"session"], 128);
        NSString *name = BridgeSafeString(record[@"name"], 40);
        // 与 CLI 用同一条规则，否则菜单里的在线会话和 list_agents 对不上。
        if (session.length == 0 || name.length == 0 || !CCBridgeSessionLive(record)) continue;
        NSMutableDictionary *entry = [@{
            @"name": name,
            @"ref": BridgeSafeString(record[@"ref"], 6),
            @"provider": BridgeSafeString(record[@"provider"], 16)
        } mutableCopy];
        NSString *nameSource = [record[@"nameSource"] isKindOfClass:NSString.class] ? record[@"nameSource"] : nil;
        if ([nameSource isEqualToString:@"generated"] || [nameSource isEqualToString:@"custom"]) {
            entry[@"nameSource"] = nameSource;
        }
        NSString *profileID = BridgeSafeString(record[@"profileId"], 128);
        if (profileID.length > 0) entry[@"profileId"] = profileID;
        NSString *tty = BridgeSafeString(record[@"tty"], 32);
        if (tty.length > 0) entry[@"tty"] = tty;
        sessions[session] = entry;
    }
    return sessions;
}

NSArray<NSDictionary *> *CCBridgeRecentDeliveries(NSTimeInterval since, NSUInteger limit) {
    NSString *directory = [CCBridgeStateDirectory() stringByAppendingPathComponent:@"sent"];
    NSMutableArray<NSDictionary *> *deliveries = [NSMutableArray array];
    for (NSString *path in ReceiptFilesUpdatedSince(directory, since)) {
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
            @"fromIdentity": @{@"name": fromName, @"nameSource": BridgeSafeString(from[@"nameSource"], 16)},
            @"toIdentity": @{@"name": toName, @"nameSource": BridgeSafeString(to[@"nameSource"], 16)},
            @"toSession": toSession,
            @"fromSession": BridgeSafeString(from[@"session"], 128),
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
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (NSString *kind in @[@"inbox", @"claimed"]) {
        NSString *directory = [CCBridgeStateDirectory() stringByAppendingPathComponent:kind];
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil]) {
            NSString *session = BridgeSafeString(name, 128);
            if (session.length == 0 || ![session isEqualToString:name]) continue;
            NSUInteger count = JSONFilesInDirectory([directory stringByAppendingPathComponent:name]).count;
            if (count > 0) counts[session] = @([counts[session] unsignedIntegerValue] + count);
        }
    }
    return counts;
}
