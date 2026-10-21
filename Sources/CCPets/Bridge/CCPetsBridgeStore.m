#import "CCPetsL10n.h"
#import "CCPetsBridgeStore.h"
#import "CCPetsBridge.h"
#import "CCPetsCLISupport.h"
#import "CCPetsJSON.h"
#import <CommonCrypto/CommonDigest.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <signal.h>
#import <unistd.h>
#import <errno.h>

#define LF(localized, values) CCPetsInterpolate(localized, values)

const NSUInteger CCBridgeMessageBodyLimit = 16 * 1024;
const long long CCBridgeMessageTTL = 24LL * 60 * 60 * 1000;
// 同一对会话 10 分钟内来回超过这个数，基本可以断定是两个 Agent 在互相自动回复。
static const long long PairLimitWindow = 10LL * 60 * 1000;
const NSUInteger CCBridgePairLimitCount = 20;
static const NSUInteger SenderLimitCount = 40;
// 没有 pid 的会话记录退回到活动窗口判断在线，与桌宠"没有 pid 文件就看最近事件"的思路一致。
static const long long StaleWithoutPid = 6LL * 60 * 60 * 1000;

static long long NumberValue(id value) {
    return [value isKindOfClass:NSNumber.class] ? [value longLongValue] : 0;
}

static NSString *StringValue(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSString *RandomHex(NSUInteger bytes) {
    uint8_t buffer[16];
    bytes = MIN(bytes, sizeof buffer);
    arc4random_buf(buffer, bytes);
    NSMutableString *hex = [NSMutableString string];
    for (NSUInteger index = 0; index < bytes; index++) [hex appendFormat:@"%02x", buffer[index]];
    return hex;
}

NSString *CCBridgeSHA1Hex(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
#pragma clang diagnostic pop
    NSMutableString *hex = [NSMutableString string];
    for (int index = 0; index < CC_SHA1_DIGEST_LENGTH; index++) [hex appendFormat:@"%02x", digest[index]];
    return hex;
}

#pragma mark - 开关与选项

static NSString *EnabledFlagPath(void) {
    return [CCBridgeHomeDirectory() stringByAppendingPathComponent:@"bridge-enabled"];
}

static void EnsureHomeDirectory(void) {
    [NSFileManager.defaultManager createDirectoryAtPath:CCBridgeHomeDirectory() withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:nil];
}

BOOL CCBridgeMigrateLegacyFlag(void) {
    NSString *legacy = [CCBridgeHomeDirectory() stringByAppendingPathComponent:@"bus-enabled"];
    if (![NSFileManager.defaultManager fileExistsAtPath:legacy]) return NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:EnabledFlagPath()]) {
        unlink(legacy.fileSystemRepresentation);
    } else {
        rename(legacy.fileSystemRepresentation, EnabledFlagPath().fileSystemRepresentation);
    }
    return YES;
}

void CCBridgeSetEnabled(BOOL enabled, NSDictionary *options) {
    if (!enabled) {
        unlink(EnabledFlagPath().fileSystemRepresentation);
        return;
    }
    EnsureHomeDirectory();
    NSDictionary *normalized = CCBridgeNormalizeOptions(options);
    CCPetsJSONObject *document = [CCPetsJSONObject new];
    for (NSString *key in @[@"codexApprove", @"claudeAllow", @"wake", @"editGuard"]) document[key] = normalized[key];
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    document[@"enabledAt"] = [formatter stringFromDate:NSDate.date];
    CCPetsWriteFileAtomically(EnabledFlagPath(), [CCPetsJSONStringify(document) stringByAppendingString:@"\n"], 0600, NULL);
}

void CCBridgeWriteCLILocator(void) {
    EnsureHomeDirectory();
    CCPetsJSONObject *document = [CCPetsJSONObject new];
    document[@"schemaVersion"] = @2;
    document[@"binary"] = CCPetsExecutablePath();
    document[@"path"] = CCPetsEnvironmentValue(@"PATH") ?: @"";
    CCPetsWriteFileAtomically([CCBridgeHomeDirectory() stringByAppendingPathComponent:@"bridge-cli.json"],
        [CCPetsJSONStringify(document) stringByAppendingString:@"\n"], 0600, NULL);
}

static NSArray<NSString *> *AllTools(void) {
    NSMutableArray<NSString *> *tools = [NSMutableArray array];
    for (NSString *group in CCBridgeToolGroupNames()) [tools addObjectsFromArray:CCBridgeToolGroup(group)];
    return tools;
}

NSArray<NSString *> *CCBridgeParseToolList(NSString *text, NSString *flag, NSString **error) {
    NSMutableOrderedSet<NSString *> *tools = [NSMutableOrderedSet orderedSet];
    NSMutableArray<NSString *> *unknown = [NSMutableArray array];
    NSArray<NSString *> *all = AllTools();
    for (NSString *raw in [text ?: @"" componentsSeparatedByString:@","]) {
        NSString *item = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (item.length == 0) continue;
        if ([CCBridgeToolGroupNames() containsObject:item]) [tools addObjectsFromArray:CCBridgeToolGroup(item)];
        else if ([all containsObject:item]) [tools addObject:item];
        else [unknown addObject:item];
    }
    if (unknown.count > 0) {
        if (error) {
            *error = LF(L(@"{flag} only accepts groups {TOOL_GROUPS} or tools {ALL_TOOLS}, got: {unknown}"), (@{
                @"flag": flag, @"TOOL_GROUPS": [CCBridgeToolGroupNames() componentsJoinedByString:@", "],
                @"ALL_TOOLS": [all componentsJoinedByString:@", "], @"unknown": [unknown componentsJoinedByString:@", "]}));
        }
        return nil;
    }
    NSMutableArray<NSString *> *ordered = [NSMutableArray array];
    for (NSString *tool in all) {
        if ([tools containsObject:tool]) [ordered addObject:tool];
    }
    return ordered;
}

NSNumber *CCBridgeParseSwitch(NSString *text, NSString *flag, NSString **error) {
    NSString *value = [text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    if ([@[@"on", @"true", @"1", @"yes"] containsObject:value]) return @YES;
    if ([@[@"off", @"false", @"0", @"no"] containsObject:value]) return @NO;
    if (error) *error = LF(L(@"{flag} only accepts on / off, got: {text}"), (@{@"flag": flag, @"text": text ?: @""}));
    return nil;
}

NSDictionary *CCBridgeMergeOptionFlags(NSDictionary *base, NSDictionary<NSString *, NSString *> *flags, NSString **error) {
    NSMutableDictionary *next = [CCBridgeNormalizeOptions(base) mutableCopy];
    if (flags[@"approve"]) {
        NSArray *tools = CCBridgeParseToolList(flags[@"approve"], @"--approve", error);
        if (!tools) return nil;
        next[@"codexApprove"] = tools;
        next[@"claudeAllow"] = tools;
    }
    if (flags[@"codexApprove"]) {
        NSArray *tools = CCBridgeParseToolList(flags[@"codexApprove"], @"--codex-approve", error);
        if (!tools) return nil;
        next[@"codexApprove"] = tools;
    }
    if (flags[@"claudeAllow"]) {
        NSArray *tools = CCBridgeParseToolList(flags[@"claudeAllow"], @"--claude-allow", error);
        if (!tools) return nil;
        next[@"claudeAllow"] = tools;
    }
    if (flags[@"wake"]) {
        NSNumber *value = CCBridgeParseSwitch(flags[@"wake"], @"--wake", error);
        if (!value) return nil;
        next[@"wake"] = value;
    }
    if (flags[@"editGuard"]) {
        NSNumber *value = CCBridgeParseSwitch(flags[@"editGuard"], @"--edit-guard", error);
        if (!value) return nil;
        next[@"editGuard"] = value;
    }
    return next;
}

NSArray<NSString *> *CCBridgeDescribeOptions(NSDictionary *options) {
    NSArray *codex = options[@"codexApprove"];
    NSArray *claude = options[@"claudeAllow"];
    return @[
        LF(L(@"Codex auto-approve: {codexApprove}"), (@{@"codexApprove": codex.count > 0 ? [codex componentsJoinedByString:@", "] : L(@"none")})),
        LF(L(@"Claude allow without asking: {claudeAllow}"), (@{@"claudeAllow": claude.count > 0 ? [claude componentsJoinedByString:@", "] : L(@"none")})),
        LF(L(@"Wake idle sessions: {wake}"), (@{@"wake": [options[@"wake"] boolValue] ? L(@"on") : L(@"off")})),
        LF(L(@"Pause edits on reserved files: {editGuard}"), (@{@"editGuard": [options[@"editGuard"] boolValue] ? L(@"on") : L(@"off")}))
    ];
}

#pragma mark - 目录与文件

// 目录一律 0700：信箱里是消息正文，同机其他用户不能读，也不能往里塞"任务"。
// 已存在的目录也要校正权限并确认归属，防止有人提前在共享 /tmp 里抢建同名目录。
static NSString *EnsureDirectory(NSString *directory) {
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:nil];
    struct stat info;
    if (lstat(directory.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode)) {
        [NSException raise:@"CCBridgeDirectory"
            format:@"%@", LF(L(@"{directory} isn't a regular directory"), @{@"directory": directory})];
    }
    if (info.st_uid != getuid()) {
        [NSException raise:@"CCBridgeDirectory"
            format:@"%@", LF(L(@"{directory} isn't owned by the current user"), @{@"directory": directory})];
    }
    if ((info.st_mode & 077) != 0) chmod(directory.fileSystemRepresentation, 0700);
    return directory;
}

NSString *CCBridgeSubdirectory(NSArray<NSString *> *parts) {
    NSString *root = EnsureDirectory(CCBridgeStateDirectory());
    if (parts.count == 0) return root;
    return EnsureDirectory([root stringByAppendingPathComponent:[NSString pathWithComponents:parts]]);
}

NSString *CCBridgeSafeSessionId(id value) {
    NSString *text = StringValue(value);
    if (text.length == 0 || text.length > 128) return nil;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    if ([text rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
    if ([text stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"."]].length == 0) return nil;
    return text;
}

// 先写同目录临时文件再 rename：读取端永远看不到写了一半的 JSON。
void CCBridgeWriteJSON(NSString *file, id value) {
    NSString *temporary = [NSString stringWithFormat:@"%@.%d.%@.tmp", file, getpid(), RandomHex(4)];
    NSData *data = [[CCPetsJSONStringify(value) stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    int descriptor = open(temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (descriptor < 0) {
        [NSException raise:@"CCBridgeWrite" format:@"%@: %s", file, strerror(errno)];
    }
    BOOL written = write(descriptor, data.bytes, data.length) == (ssize_t)data.length;
    close(descriptor);
    if (!written || rename(temporary.fileSystemRepresentation, file.fileSystemRepresentation) != 0) {
        unlink(temporary.fileSystemRepresentation);
        [NSException raise:@"CCBridgeWrite" format:@"%@: %s", file, strerror(errno)];
    }
}

id CCBridgeReadJSON(NSString *file) {
    NSData *data = [NSData dataWithContentsOfFile:file];
    if (data.length == 0) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
}

static NSArray<NSString *> *ListJSON(NSString *directory) {
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *name in entries) {
        if ([name hasSuffix:@".json"]) [names addObject:name];
    }
    return [names sortedArrayUsingSelector:@selector(compare:)];
}

#pragma mark - 会话注册表

NSString *CCBridgeSessionRef(NSString *sessionId) {
    return [CCBridgeSHA1Hex(sessionId) substringToIndex:6];
}

static NSString *SessionFile(NSString *sessionId) {
    return [CCBridgeSubdirectory(@[@"sessions"]) stringByAppendingPathComponent:[sessionId stringByAppendingString:@".json"]];
}

NSDictionary *CCBridgeReadSession(id sessionId) {
    NSString *safe = CCBridgeSafeSessionId(sessionId);
    if (!safe) return nil;
    id record = CCBridgeReadJSON(SessionFile(safe));
    return [record isKindOfClass:NSDictionary.class] ? record : nil;
}

NSArray<NSDictionary *> *CCBridgeListSessions(void) {
    NSString *directory = CCBridgeSubdirectory(@[@"sessions"]);
    NSMutableArray<NSDictionary *> *sessions = [NSMutableArray array];
    for (NSString *name in ListJSON(directory)) {
        id record = CCBridgeReadJSON([directory stringByAppendingPathComponent:name]);
        if ([record isKindOfClass:NSDictionary.class]) [sessions addObject:record];
    }
    return sessions;
}

void CCBridgeRemoveSession(id sessionId) {
    NSString *safe = CCBridgeSafeSessionId(sessionId);
    if (safe) unlink(SessionFile(safe).fileSystemRepresentation);
}

// 小写，连续的非 [a-z0-9] 合并成 -，截到 limit 后去掉首尾的 -；结果可能为空。
static NSString *NameSlug(NSString *text, NSUInteger limit) {
    NSString *base = text.lowercaseString ?: @"";
    NSRegularExpression *separators = [NSRegularExpression regularExpressionWithPattern:@"[^a-z0-9]+" options:0 error:nil];
    NSString *slug = [separators stringByReplacingMatchesInString:base options:0 range:NSMakeRange(0, base.length) withTemplate:@"-"];
    NSCharacterSet *dash = [NSCharacterSet characterSetWithCharactersInString:@"-"];
    slug = [slug stringByTrimmingCharactersInSet:dash];
    if (slug.length > limit) slug = [[slug substringToIndex:limit] stringByTrimmingCharactersInSet:dash];
    return slug;
}

// 默认名字末尾的动物词：都是 7 个字母以内、好认好打的萌系动物，避开贬义词和编程语言 / 工具名。
static NSArray<NSString *> *NameAnimals(void) {
    static NSArray<NSString *> *animals;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        animals = @[
            @"otter", @"panda", @"quokka", @"corgi", @"koala", @"capy", @"puffin", @"lemur", @"alpaca", @"wombat",
            @"bunny", @"kitten", @"puppy", @"hamster", @"fox", @"owl", @"seal", @"penguin", @"duck", @"llama",
            @"sloth", @"fennec", @"bear", @"cub", @"lamb", @"fawn", @"deer", @"dolphin", @"beluga", @"orca",
            @"narwhal", @"walrus", @"manatee", @"turtle", @"frog", @"gecko", @"chick", @"robin", @"finch", @"wren",
            @"sparrow", @"toucan", @"parrot", @"macaw", @"dove", @"swan", @"owlet", @"goose", @"koi", @"bee",
            @"ladybug", @"raccoon", @"ferret", @"badger", @"beaver", @"marmot", @"meerkat", @"mouse", @"gerbil", @"pony",
            @"foal", @"piglet", @"calf", @"giraffe", @"zebra", @"hippo", @"rhino", @"tapir", @"okapi", @"lynx",
            @"tiger", @"cheetah", @"lion", @"husky", @"shiba", @"beagle", @"pug", @"poodle", @"collie", @"dingo",
            @"newt", @"tadpole", @"octopus", @"squid", @"crab", @"snail", @"peacock", @"emu", @"quail", @"magpie",
            @"kea", @"heron", @"stork", @"ibis", @"numbat", @"bilby", @"possum", @"dugong", @"yak", @"bison",
        ];
    });
    return animals;
}

static NSDictionary *NameTakenBy(NSString *name, NSString *sessionId, NSArray<NSDictionary *> *liveSessions) {
    for (NSDictionary *entry in liveSessions) {
        if (![entry[@"session"] isEqual:sessionId] && [entry[@"name"] isEqual:name]) return entry;
    }
    return nil;
}

// 名字是给 Agent 和人看的地址：<账号名>.<项目目录名>.<动物>，例如 claude-x.my-app.otter。段内用 -，段间用 .，
// 账号名和项目名本身带 - 时也分得清边界。
// 账号名取多账号里的显示名（默认账号就是 claude / codex），取不到时退回 provider，这样多个账号开在同一项目里
// 也一眼能分清。动物从 session id 的哈希位置开始找同前缀下第一个没被在线会话占用的，同一会话结果稳定；
// 词库全被占用才追加序号。总长度控制在 40 以内：账号名最多 12 个字符，项目名用剩下的。
// ref 由 session id 派生，永不变化，用于重名时消歧。
static NSString *AllocateName(NSString *provider, NSString *profileName, NSString *cwd, NSString *sessionId,
    NSArray<NSDictionary *> *liveSessions) {
    NSString *account = NameSlug(profileName, 12);
    if (account.length == 0) account = NameSlug(provider, 12);
    if (account.length == 0) account = @"agent";
    NSArray<NSString *> *animals = NameAnimals();
    // 动物词最多 7 个字母，再给兜底序号留 2 位。
    NSString *project = NameSlug(cwd.lastPathComponent, 40 - account.length - 9 - 2);
    if (project.length == 0) project = @"session";
    NSString *prefix = [NSString stringWithFormat:@"%@.%@", account, project];
    unsigned long long hash = strtoull([CCBridgeSHA1Hex(sessionId) substringToIndex:8].UTF8String, NULL, 16);
    for (NSUInteger offset = 0; offset < animals.count; offset++) {
        NSString *candidate = [NSString stringWithFormat:@"%@.%@", prefix, animals[(hash + offset) % animals.count]];
        if (!NameTakenBy(candidate, sessionId, liveSessions)) return candidate;
    }
    NSString *animal = animals[hash % animals.count];
    for (NSUInteger index = 2; ; index++) {
        NSString *candidate = [NSString stringWithFormat:@"%@.%@%lu", prefix, animal, (unsigned long)index];
        if (!NameTakenBy(candidate, sessionId, liveSessions)) return candidate;
    }
}

// 启动时指定的名字被占用就追加序号（frontend → frontend-2），不让会话因此注册失败。
static NSString *AllocateCustomName(NSString *name, NSString *sessionId, NSArray<NSDictionary *> *liveSessions) {
    if (!NameTakenBy(name, sessionId, liveSessions)) return name;
    for (NSUInteger index = 2; ; index++) {
        NSString *candidate = [NSString stringWithFormat:@"%@-%lu", name, (unsigned long)index];
        if (candidate.length > 40) candidate = [candidate substringToIndex:40];
        if (!NameTakenBy(candidate, sessionId, liveSessions)) return candidate;
    }
}

// 自定义名字只允许小写字母、数字和 . _ -，首字符必须是字母或数字，最长 40 个字符——名字会出现在
// 消息头和 Agent 的工具参数里，不能带空格、方括号（与 "名字 [ref]" 语法冲突）或控制字符。
NSString *CCBridgeNormalizeSessionName(id value) {
    NSString *text = [value isKindOfClass:NSString.class] ? value : ([value isKindOfClass:NSNumber.class] ? [value stringValue] : @"");
    NSString *name = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"\\A[a-z0-9][a-z0-9._-]{0,39}\\z" options:0 error:nil];
    return [pattern firstMatchInString:name options:0 range:NSMakeRange(0, name.length)] ? name : nil;
}

NSDictionary *CCBridgeUpsertSession(NSString *sessionId, NSString *provider, NSNumber *pid, NSString *cwd,
    NSString *tty, NSString *status, NSString *preferredName, NSString *profileID,
    NSString *profileName, NSArray<NSDictionary *> *liveSessions) {
    NSString *safe = CCBridgeSafeSessionId(sessionId);
    if (!safe) return nil;
    long long now = CCPetsMilliseconds();
    NSMutableDictionary *record = [CCBridgeReadSession(safe) mutableCopy];
    if (!record) {
        record = [@{@"session": safe, @"ref": CCBridgeSessionRef(safe), @"startedAt": @(now)} mutableCopy];
        if (provider) record[@"provider"] = provider;
    }
    if (provider) record[@"provider"] = provider;
    if (pid && pid.intValue > 1) record[@"pid"] = pid;
    if (cwd.length > 0) record[@"cwd"] = cwd;
    if (tty.length > 0) record[@"tty"] = tty;
    if (profileID.length > 0) record[@"profileId"] = profileID;
    if (profileName.length > 0) record[@"profileName"] = profileName;
    if (!StringValue(record[@"name"])) {
        NSString *custom = CCBridgeNormalizeSessionName(preferredName);
        record[@"name"] = custom ? AllocateCustomName(custom, safe, liveSessions ?: @[])
            : AllocateName(StringValue(record[@"provider"]) ?: @"", StringValue(record[@"profileName"]),
                StringValue(record[@"cwd"]), safe, liveSessions ?: @[]);
    }
    if (status) record[@"status"] = status;
    record[@"updatedAt"] = @(now);
    CCBridgeWriteJSON(SessionFile(safe), record);
    return record;
}

NSDictionary *CCBridgeRenameSession(NSString *sessionId, NSString *requestedName, NSArray<NSDictionary *> *liveSessions) {
    NSMutableDictionary *record = [CCBridgeReadSession(sessionId) mutableCopy];
    if (!record) return @{@"error": L(@"This session isn't registered yet.")};
    NSString *name = CCBridgeNormalizeSessionName(requestedName);
    if (!name) {
        return @{@"error": L(@"Names may only contain lowercase letters, digits and . _ -, must start with a letter or digit, and be at most 40 characters.")};
    }
    NSDictionary *holder = NameTakenBy(name, record[@"session"], liveSessions);
    if (holder) {
        return @{@"error": LF(L(@"The name {name} is taken by {holder} [{ref}]; pick another."),
            (@{@"name": name, @"holder": holder[@"name"] ?: @"", @"ref": holder[@"ref"] ?: @""}))};
    }
    NSString *previous = StringValue(record[@"name"]) ?: @"";
    record[@"name"] = name;
    record[@"updatedAt"] = @(CCPetsMilliseconds());
    CCBridgeWriteJSON(SessionFile(record[@"session"]), record);
    return @{@"session": record, @"previous": previous};
}

#pragma mark - 消息

NSString *CCBridgeNewMessageId(void) {
    unsigned long long now = (unsigned long long)CCPetsMilliseconds();
    static const char digits[] = "0123456789abcdefghijklmnopqrstuvwxyz";
    char buffer[32];
    int length = 0;
    do {
        buffer[length++] = digits[now % 36];
        now /= 36;
    } while (now > 0);
    NSMutableString *base36 = [NSMutableString string];
    while (length > 0) [base36 appendFormat:@"%c", buffer[--length]];
    return [NSString stringWithFormat:@"m%@%@", base36, RandomHex(5)];
}

static NSString *ReceiptFile(NSString *messageId) {
    return [CCBridgeSubdirectory(@[@"sent"]) stringByAppendingPathComponent:[messageId stringByAppendingString:@".json"]];
}

static BOOL IsMessageId(id value) {
    NSString *text = StringValue(value);
    if (text.length == 0) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789"];
    return [text rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

NSDictionary *CCBridgeReadReceipt(id messageId) {
    if (!IsMessageId(messageId)) return nil;
    id receipt = CCBridgeReadJSON(ReceiptFile(messageId));
    return [receipt isKindOfClass:NSDictionary.class] ? receipt : nil;
}

void CCBridgeWriteReceipt(NSDictionary *message) {
    CCBridgeWriteJSON(ReceiptFile(message[@"id"]), message);
}

NSDictionary *CCBridgeUpdateReceipt(NSString *messageId, NSDictionary *patch) {
    NSMutableDictionary *next = [CCBridgeReadReceipt(messageId) mutableCopy];
    if (!next) return nil;
    [next addEntriesFromDictionary:patch];
    next[@"updatedAt"] = @(CCPetsMilliseconds());
    CCBridgeWriteReceipt(next);
    return next;
}

NSArray<NSDictionary *> *CCBridgeListReceipts(void) {
    NSString *directory = CCBridgeSubdirectory(@[@"sent"]);
    NSMutableArray<NSDictionary *> *receipts = [NSMutableArray array];
    for (NSString *name in ListJSON(directory)) {
        id receipt = CCBridgeReadJSON([directory stringByAppendingPathComponent:name]);
        if ([receipt isKindOfClass:NSDictionary.class]) [receipts addObject:receipt];
    }
    return receipts;
}

static NSString *PartySession(NSDictionary *receipt, NSString *key) {
    NSDictionary *party = [receipt[key] isKindOfClass:NSDictionary.class] ? receipt[key] : nil;
    return StringValue(party[@"session"]);
}

NSString *CCBridgeCheckSendLimits(NSString *fromSession, NSString *toSession) {
    long long now = CCPetsMilliseconds();
    NSUInteger pair = 0, sent = 0;
    for (NSDictionary *entry in CCBridgeListReceipts()) {
        if (now - NumberValue(entry[@"createdAt"]) >= PairLimitWindow) continue;
        NSString *from = PartySession(entry, @"from");
        NSString *to = PartySession(entry, @"to");
        if (([from isEqual:fromSession] && [to isEqual:toSession]) || ([from isEqual:toSession] && [to isEqual:fromSession])) pair++;
        if ([from isEqual:fromSession]) sent++;
    }
    if (pair >= CCBridgePairLimitCount) {
        return LF(L(@"These two sessions exchanged {length} messages in 10 minutes, which looks like an auto-reply loop, so sending is paused. Ask the user before continuing."),
            @{@"length": @(pair)});
    }
    if (sent >= SenderLimitCount) {
        return LF(L(@"This session sent {length} messages in 10 minutes, over the limit, so sending is paused."), @{@"length": @(sent)});
    }
    return nil;
}

void CCBridgeEnqueueInbox(NSDictionary *message) {
    NSString *target = CCBridgeSafeSessionId(PartySession(message, @"to"));
    if (!target) [NSException raise:@"CCBridgeInbox" format:@"%@", L(@"invalid target session id")];
    CCBridgeWriteJSON([CCBridgeSubdirectory(@[@"inbox", target]) stringByAppendingPathComponent:
        [message[@"id"] stringByAppendingString:@".json"]], message);
}

NSArray<NSDictionary *> *CCBridgeClaimInbox(id sessionId) {
    NSString *safe = CCBridgeSafeSessionId(sessionId);
    if (!safe) return @[];
    NSString *inbox = CCBridgeSubdirectory(@[@"inbox", safe]);
    NSString *claimed = CCBridgeSubdirectory(@[@"claimed", safe]);
    long long now = CCPetsMilliseconds();
    NSMutableArray<NSDictionary *> *messages = [NSMutableArray array];
    for (NSString *name in ListJSON(inbox)) {
        NSString *source = [inbox stringByAppendingPathComponent:name];
        NSString *destination = [claimed stringByAppendingPathComponent:name];
        if (rename(source.fileSystemRepresentation, destination.fileSystemRepresentation) != 0) continue;
        id message = CCBridgeReadJSON(destination);
        unlink(destination.fileSystemRepresentation);
        if (![message isKindOfClass:NSDictionary.class]) continue;
        if (now - NumberValue(message[@"createdAt"]) > CCBridgeMessageTTL) {
            CCBridgeUpdateReceipt(message[@"id"], @{@"status": @"expired"});
            continue;
        }
        [messages addObject:message];
    }
    return messages;
}

NSUInteger CCBridgePendingCount(id sessionId) {
    NSString *safe = CCBridgeSafeSessionId(sessionId);
    return safe ? ListJSON(CCBridgeSubdirectory(@[@"inbox", safe])).count : 0;
}

void CCBridgeAbandonInbox(id sessionId) {
    NSString *safe = CCBridgeSafeSessionId(sessionId);
    if (!safe) return;
    NSString *inbox = CCBridgeSubdirectory(@[@"inbox", safe]);
    for (NSString *name in ListJSON(inbox)) {
        NSString *file = [inbox stringByAppendingPathComponent:name];
        id message = CCBridgeReadJSON(file);
        unlink(file.fileSystemRepresentation);
        if ([message isKindOfClass:NSDictionary.class]) {
            CCBridgeUpdateReceipt(message[@"id"], @{@"status": @"undeliverable", @"reason": L(@"the target session has ended")});
        }
    }
}

// 回执保留 TTL 两倍时长，够排查问题，又不会无限增长。
void CCBridgePruneReceipts(void) {
    NSString *directory = CCBridgeSubdirectory(@[@"sent"]);
    long long now = CCPetsMilliseconds();
    for (NSString *name in ListJSON(directory)) {
        NSString *file = [directory stringByAppendingPathComponent:name];
        id receipt = CCBridgeReadJSON(file);
        if (![receipt isKindOfClass:NSDictionary.class] || now - NumberValue(receipt[@"createdAt"]) > CCBridgeMessageTTL * 2) {
            unlink(file.fileSystemRepresentation);
        }
    }
}

#pragma mark - 空闲订阅

void CCBridgeAddIdleSubscription(NSString *targetSession, NSString *subscriberSession) {
    NSString *target = CCBridgeSafeSessionId(targetSession);
    NSString *subscriber = CCBridgeSafeSessionId(subscriberSession);
    if (!target || !subscriber) return;
    CCBridgeWriteJSON([CCBridgeSubdirectory(@[@"subscriptions", target]) stringByAppendingPathComponent:
        [subscriber stringByAppendingString:@".json"]], @{@"subscriber": subscriber, @"createdAt": @(CCPetsMilliseconds())});
}

BOOL CCBridgeHasIdleSubscriptions(NSString *targetSession) {
    NSString *target = CCBridgeSafeSessionId(targetSession);
    if (!target) return NO;
    return ListJSON([[CCBridgeStateDirectory() stringByAppendingPathComponent:@"subscriptions"]
        stringByAppendingPathComponent:target]).count > 0;
}

NSArray<NSString *> *CCBridgeTakeIdleSubscriptions(NSString *targetSession) {
    NSString *target = CCBridgeSafeSessionId(targetSession);
    if (!target) return @[];
    NSString *directory = CCBridgeSubdirectory(@[@"subscriptions", target]);
    NSMutableArray<NSString *> *subscribers = [NSMutableArray array];
    for (NSString *name in ListJSON(directory)) {
        NSString *file = [directory stringByAppendingPathComponent:name];
        NSString *claimed = [file stringByAppendingString:@".taken"];
        if (rename(file.fileSystemRepresentation, claimed.fileSystemRepresentation) != 0) continue;
        id entry = CCBridgeReadJSON(claimed);
        unlink(claimed.fileSystemRepresentation);
        NSString *subscriber = [entry isKindOfClass:NSDictionary.class] ? StringValue(entry[@"subscriber"]) : nil;
        if (subscriber) [subscribers addObject:subscriber];
    }
    return subscribers;
}

#pragma mark - 锁

static pid_t LockHolder(NSString *file) {
    NSString *text = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
    return (pid_t)text.intValue;
}

NSString *CCBridgeAcquireLock(NSString *name) {
    NSString *file = [CCBridgeSubdirectory(@[@"locks"]) stringByAppendingPathComponent:[name stringByAppendingString:@".pid"]];
    for (int attempt = 0; attempt < 2; attempt++) {
        int descriptor = open(file.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (descriptor >= 0) {
            NSData *pid = [[NSString stringWithFormat:@"%d", getpid()] dataUsingEncoding:NSUTF8StringEncoding];
            write(descriptor, pid.bytes, pid.length);
            close(descriptor);
            return file;
        }
        if (errno != EEXIST) [NSException raise:@"CCBridgeLock" format:@"%@: %s", file, strerror(errno)];
        pid_t holder = LockHolder(file);
        if (holder > 0 && CCBridgeProcessAlive(holder)) return nil;
        unlink(file.fileSystemRepresentation);
    }
    return nil;
}

void CCBridgeReleaseLock(NSString *lockFile) {
    if (lockFile && LockHolder(lockFile) == getpid()) unlink(lockFile.fileSystemRepresentation);
}

#pragma mark - 进程探测

BOOL CCBridgeProcessAlive(pid_t pid) {
    if (pid <= 1) return NO;
    return kill(pid, 0) == 0 || errno == EPERM;
}

static BOOL ProcessParent(pid_t pid, pid_t *parent, dev_t *tty) {
    struct kinfo_proc info;
    size_t size = sizeof info;
    int name[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    if (sysctl(name, 4, &info, &size, NULL, 0) != 0 || size == 0) return NO;
    if (parent) *parent = info.kp_eproc.e_ppid;
    if (tty) *tty = info.kp_eproc.e_tdev;
    return YES;
}

// 与 `ps -o command=` 一致：argv 用空格连起来。读不到参数区（别的用户的进程、僵尸）时退回 ps。
NSString *CCBridgeProcessCommand(pid_t pid) {
    if (pid <= 0) return nil;
    int argumentMaximum = 0;
    size_t size = sizeof argumentMaximum;
    int maximumName[] = {CTL_KERN, KERN_ARGMAX};
    if (sysctl(maximumName, 2, &argumentMaximum, &size, NULL, 0) == 0 && argumentMaximum > 0) {
        char *buffer = malloc((size_t)argumentMaximum);
        size = (size_t)argumentMaximum;
        int name[] = {CTL_KERN, KERN_PROCARGS2, pid};
        if (buffer && sysctl(name, 3, buffer, &size, NULL, 0) == 0 && size > sizeof(int)) {
            int argc = 0;
            memcpy(&argc, buffer, sizeof argc);
            char *cursor = buffer + sizeof argc;
            char *end = buffer + size;
            while (cursor < end && *cursor) cursor++;  // 可执行文件路径
            while (cursor < end && !*cursor) cursor++;  // 对齐用的 \0
            NSMutableArray<NSString *> *arguments = [NSMutableArray array];
            for (int index = 0; index < argc && cursor < end; index++) {
                size_t length = strnlen(cursor, (size_t)(end - cursor));
                NSString *argument = [[NSString alloc] initWithBytes:cursor length:length encoding:NSUTF8StringEncoding];
                [arguments addObject:argument ?: @""];
                cursor += length + 1;
            }
            free(buffer);
            if (arguments.count > 0) return [arguments componentsJoinedByString:@" "];
        } else {
            free(buffer);
        }
    }
    NSString *output = nil;
    if (CCPetsRun(@"/bin/ps", @[@"-o", @"command=", @"-p", [NSString stringWithFormat:@"%d", pid]], nil, nil, 10, &output, NULL) != 0) {
        return nil;
    }
    NSString *command = [output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return command.length > 0 ? command : nil;
}

NSString *CCBridgeProcessTty(pid_t pid) {
    dev_t device = NODEV;
    if (pid <= 1 || !ProcessParent(pid, NULL, &device) || device == NODEV) return nil;
    char *name = devname(device, S_IFCHR);
    if (!name || name[0] == '?') return nil;
    NSString *tty = [NSString stringWithUTF8String:name];
    return [tty hasPrefix:@"tty"] ? tty : [@"tty" stringByAppendingString:tty];
}

// 只看可执行文件本身，不看参数：参数里出现 "claude" / "codex" 的进程太多了
// （比如 tmux new-session "codex …"、编辑器打开的某个路径）。
static NSArray<NSString *> *CommandTokens(NSString *command) {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *token in [command ?: @"" componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (token.length > 0) [tokens addObject:token];
    }
    return tokens;
}

static BOOL Matches(NSString *pattern, NSString *text) {
    if (text.length == 0) return NO;
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    return [expression firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] != nil;
}

BOOL CCBridgeCommandMatchesProvider(NSString *provider, NSString *command) {
    NSArray<NSString *> *tokens = CommandTokens(command);
    NSString *executable = tokens.firstObject ?: @"";
    NSString *second = tokens.count > 1 ? tokens[1] : @"";
    // Codex 的 npm 包是 node 包装器 + 原生二进制；hook 和 MCP 进程的直接祖先都是原生二进制，
    // 取离自己最近的那个，两边才能落到同一个 pid。
    if ([provider isEqualToString:@"Codex"]) {
        return [executable.lastPathComponent isEqualToString:@"codex"] || Matches(@"/codex-[a-z0-9-]+/vendor/", executable);
    }
    if ([provider isEqualToString:@"Claude"]) {
        return [executable.lastPathComponent isEqualToString:@"claude"] ||
            Matches(@"@anthropic-ai/claude-code/", executable) || Matches(@"@anthropic-ai/claude-code/", second);
    }
    return NO;
}

// 取"最近"而不是"某一种"：在 Claude 的 Bash 里再起一个 codex，里面的 MCP 进程属于那个 codex。
NSDictionary *CCBridgeFindAgentAncestor(pid_t startPid) {
    // 测试 / 诊断覆盖："Codex:1234"。测试本身常跑在某个 Claude 会话的 Bash 里，
    // 不覆盖的话会沿进程树认到那个真实会话头上。
    NSString *forced = CCPetsEnvironmentValue(@"CC_BRIDGE_AGENT");
    if (forced) {
        NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"\\A(Claude|Codex):(\\d+)\\z" options:0 error:nil];
        NSTextCheckingResult *match = [pattern firstMatchInString:forced options:0 range:NSMakeRange(0, forced.length)];
        if (match) {
            return @{@"provider": [forced substringWithRange:[match rangeAtIndex:1]],
                     @"pid": @([[forced substringWithRange:[match rangeAtIndex:2]] intValue])};
        }
    }
    pid_t pid = startPid;
    for (int depth = 0; depth < 12 && pid > 1; depth++) {
        pid_t parent = 0;
        if (!ProcessParent(pid, &parent, NULL)) return nil;
        NSString *command = CCBridgeProcessCommand(pid);
        for (NSString *provider in @[@"Claude", @"Codex"]) {
            if (CCBridgeCommandMatchesProvider(provider, command)) return @{@"provider": provider, @"pid": @(pid)};
        }
        pid = parent;
    }
    return nil;
}

BOOL CCBridgeSessionLive(NSDictionary *session) {
    if (![session isKindOfClass:NSDictionary.class] || [session[@"status"] isEqual:@"gone"]) return NO;
    id pid = session[@"pid"];
    if ([pid isKindOfClass:NSNumber.class]) {
        if (!CCBridgeProcessAlive([pid intValue])) return NO;
        NSString *command = CCBridgeProcessCommand([pid intValue]);
        return command == nil || CCBridgeCommandMatchesProvider(session[@"provider"], command);
    }
    return CCPetsMilliseconds() - NumberValue(session[@"updatedAt"]) < StaleWithoutPid;
}

// `codex queue` 是较新的 Codex 才有的子命令。旧版本把不认识的子命令当成交互式启动参数，
// `--help` 打出的是总帮助而不是报错，所以按帮助里有没有 --thread / --message 判断。
// 结果只用于提前提示：投递时 queue 失败本来就会退回信箱，探测失败一律算 unknown。
NSDictionary *CCBridgeProbeCodexQueue(NSString *executable) {
    return CCBridgeProbeCodexQueueWithEnvironment(executable, nil);
}

NSDictionary *CCBridgeProbeCodexQueueWithEnvironment(NSString *executable, NSDictionary<NSString *, NSString *> *environment) {
    if (executable.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:executable]) {
        return @{@"status": @"missing", @"executable": executable ?: NSNull.null, @"version": NSNull.null};
    }
    NSString *(^run)(NSArray<NSString *> *) = ^NSString *(NSArray<NSString *> *arguments) {
        NSString *output = nil, *errorOutput = nil;
        int status = CCPetsRun(executable, arguments, nil, environment, 10, &output, &errorOutput);
        if (status == CCPetsRunLaunchFailed || status == CCPetsRunTimedOut) return nil;
        return status == 0 ? output : [output stringByAppendingString:errorOutput];
    };
    NSString *versionOutput = [run(@[@"--version"]) ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *version = [versionOutput componentsSeparatedByString:@"\n"].firstObject;
    id versionValue = version.length > 0 ? version : NSNull.null;
    NSString *help = run(@[@"queue", @"--help"]);
    if (!help) return @{@"status": @"unknown", @"executable": executable, @"version": versionValue};
    BOOL supported = [help containsString:@"--thread"] && [help containsString:@"--message"];
    return @{@"status": supported ? @"supported" : @"unsupported", @"executable": executable, @"version": versionValue};
}
