#import "CCPetsPaths.h"

NSString *PetStateDirectory(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"CC_PETS_STATE_DIR"];
    if (override.length > 0) return override.stringByStandardizingPath;
    return NSTemporaryDirectory();
}

NSString *AgentEventPath(void) {
    NSString *name = [NSString stringWithFormat:@"cc-pets-%u-agent-events.ndjson", getuid()];
    return [PetStateDirectory() stringByAppendingPathComponent:name];
}

// 桌宠只认这一个配置目录。刻意不用 CLAUDE_CONFIG_DIR：那是会话级的，桌宠作为常驻进程
// 会把拉起它的那个客户端的值一直带着。真的把配置目录搬过家的人可以设 CC_PETS_CLAUDE_
// CONFIG_DIR——正常使用下没有任何东西会设它，所以不存在被意外继承的问题。
NSString *DefaultClaudeConfigDirectory(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"CC_PETS_CLAUDE_CONFIG_DIR"];
    if (override.length > 0) return override.stringByStandardizingPath;
    return [NSHomeDirectory() stringByAppendingPathComponent:@".claude"];
}

// 记录端（statusline / hook）跑在 CLI 会话里，CLAUDE_CONFIG_DIR 指向那一次会话真正
// 使用的配置目录。桌宠端不能用它：桌宠是被某个客户端 open 起来的常驻进程，会把当时的
// 环境变量一直带着，等于永久绑定到"第一个拉起它的账号"。
NSString *CurrentClaudeConfigDirectory(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"CLAUDE_CONFIG_DIR"];
    if (override.length > 0) return override.stringByStandardizingPath;
    return DefaultClaudeConfigDirectory();
}

// 与 DefaultClaudeConfigDirectory 同一个理由：桌宠是被某个客户端 open 起来的常驻进程，
// 会把当时的 CODEX_HOME 一直带着，等于永久绑定到"第一个拉起它的那份 Codex 配置"。
// 记录端（--provider-event 之类跑在 Codex 会话里的入口）照常用 CODEX_HOME，那是会话级的。
NSString *DefaultCodexHomeDirectory(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"CC_PETS_CODEX_HOME"];
    if (override.length > 0) return override.stringByStandardizingPath;
    return [NSHomeDirectory() stringByAppendingPathComponent:@".codex"];
}

// 额度是按账号的。一台机器上可以有多个配置目录（例如 ~/.claude 和 ~/.claude-nw），
// 各自是不同账号、不同额度周期。共用一个文件的话两边的 statusline 会互相覆盖，
// 面板就会把 A 账号的剩余百分比配上 B 账号的用量。因此按配置目录分文件。
static uint64_t StablePathHash(NSString *path) {
    uint64_t hash = 1469598103934665603ULL;
    const unsigned char *bytes = (const unsigned char *)path.UTF8String;
    for (const unsigned char *cursor = bytes; cursor && *cursor; cursor++) {
        hash ^= (uint64_t)*cursor;
        hash *= 1099511628211ULL;
    }
    return hash;
}

NSString *ClaudeUsagePathForConfigDirectory(NSString *configDirectory) {
    NSString *suffix = @"";
    NSString *resolved = configDirectory.stringByStandardizingPath;
    if (resolved.length > 0 &&
        ![resolved isEqualToString:DefaultClaudeConfigDirectory().stringByStandardizingPath]) {
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyz0123456789-"];
        NSMutableString *name = [NSMutableString string];
        for (NSString *unit in @[resolved.lastPathComponent.lowercaseString]) {
            for (NSUInteger index = 0; index < unit.length && name.length < 24; index++) {
                unichar character = [unit characterAtIndex:index];
                if ([allowed characterIsMember:character]) [name appendFormat:@"%C", character];
            }
        }
        NSString *label = name.length > 0 ? name : @"alt";
        // 末级目录名只用于可读性；完整规范化路径的稳定哈希才负责区分账号目录。
        // 否则 /Users/a/.claude-work 与 /Volumes/team/.claude-work 会落到同一个缓存文件。
        suffix = [NSString stringWithFormat:@"-%@-%016llx", label,
            (unsigned long long)StablePathHash(resolved)];
    }
    NSString *name = [NSString stringWithFormat:@"cc-pets-%u-claude-usage%@.json",
        getuid(), suffix];
    return [PetStateDirectory() stringByAppendingPathComponent:name];
}

NSString *ClaudeUsagePath(void) {
    return ClaudeUsagePathForConfigDirectory(CurrentClaudeConfigDirectory());
}

// Token 聚合的会话摘要缓存。摘要只依赖会话文件里已经写死的内容，进程退出后仍然有效，
// 但原先只存在内存里，于是每次启动都要把整个窗口的会话重新解析一遍。落盘之后启动只需
// stat 一遍文件，只有长大了的会话才追读新增字节。
// 按数据源目录分文件：同一台机器可以有多份 CODEX_HOME / 配置目录，缓存键是绝对路径，
// 混在一个文件里只会让彼此的条目每轮被当成过期项清掉。
// 放 Application Support 而不是 PetStateDirectory()：后者默认是 NSTemporaryDirectory()，
// 系统会清理长期没被访问的文件，桌宠停开几天回来就又要重新解析一整个月。
NSString *TokenSummaryCachePath(NSString *provider, NSString *sourceDirectory) {
    NSString *resolved = sourceDirectory.stringByStandardizingPath ?: @"";
    NSString *name = [NSString stringWithFormat:@"%@-token-cache-%016llx.plist",
        provider, (unsigned long long)StablePathHash(resolved)];
    return [ApplicationSupportDirectory() stringByAppendingPathComponent:name];
}

// 已经结束的自然月，用量再也不会变。归档下来之后上个月的会话文件就一次都不用再打开，
// 稳态下的扫描范围收窄到"本月"。
NSString *MonthlyUsageArchivePath(NSString *provider, NSString *sourceDirectory) {
    NSString *resolved = sourceDirectory.stringByStandardizingPath ?: @"";
    NSString *name = [NSString stringWithFormat:@"%@-monthly-usage-%016llx.plist",
        provider, (unsigned long long)StablePathHash(resolved)];
    return [ApplicationSupportDirectory() stringByAppendingPathComponent:name];
}

NSString *ClaudeUsageLockPath(void) {
    return [ClaudeUsagePath() stringByAppendingPathExtension:@"lock"];
}

NSString *ApplicationSupportDirectory(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"CC_PETS_APPLICATION_SUPPORT_DIR"];
    if (override.length > 0) return override.stringByStandardizingPath;
    NSString *root = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [root stringByAppendingPathComponent:@"CC Pets"];
}

NSString *QuotaHistoryPath(void) {
    return [ApplicationSupportDirectory() stringByAppendingPathComponent:@"quota-history.json"];
}

// cc-pets 自己的素材目录，由 `cc-pets pet add` 写入。桌宠只扫这一个目录加包内素材。
NSString *OwnPetsDirectory(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"CC_PETS_PETS_DIR"];
    if (override.length > 0) return override.stringByStandardizingPath;
    return [NSHomeDirectory() stringByAppendingPathComponent:@".cc-pets/pets"];
}

NSString *CodexPetsDirectory(void) {
    return [DefaultCodexHomeDirectory() stringByAppendingPathComponent:@"pets"];
}

static BOOL DirectoryExistsAtPath(NSString *path) {
    BOOL isDirectory = NO;
    return path.length > 0 &&
        [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory;
}

BOOL CodexCLIDetected(void) {
    return DirectoryExistsAtPath(DefaultCodexHomeDirectory());
}

BOOL ClaudeCLIDetected(void) {
    if (DirectoryExistsAtPath(DefaultClaudeConfigDirectory())) return YES;
    // 把配置目录搬过家、又没设 CC_PETS_CLAUDE_CONFIG_DIR 的用户：statusline 写出的额度
    // 缓存同样能证明这家在用。有额度数据却不给卡片，是比多一张卡糟糕得多的失败方式。
    //
    // 但只判"文件存在"不行：CCPetsUsageMonitor 为了挂 VNODE 监听，会先把这个文件
    // 创建成 0 字节占位（见 CCPetsUsageMonitor.m 里 createFileAtPath: 那处）。那样桌宠
    // 一启动就把自己造的占位文件当成"用过 Claude"，探测永远为真——和安装器凭空创建
    // ~/.claude 是同一类自证。必须要求文件真的有内容。
    NSDictionary *attributes = [NSFileManager.defaultManager
        attributesOfItemAtPath:ClaudeUsagePath() error:nil];
    return attributes != nil && [attributes[NSFileSize] unsignedLongLongValue] > 0;
}

// 素材目录里认哪些文件算"有图"。和 CCPetsAppDelegate 的 spritePathInDirectory 保持一致，
// 但这里只做存在性判断，不需要读 pet.json 里的 spritesheetPath。
static BOOL DirectoryHasSprite(NSString *directory) {
    for (NSString *name in @[@"spritesheet.webp", @"spritesheet.png"]) {
        BOOL isDirectory = NO;
        NSString *path = [directory stringByAppendingPathComponent:name];
        if ([NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] &&
            !isDirectory) {
            return YES;
        }
    }
    return NO;
}

// 导入是"复制"而不是"关联"：复制过来之后 Codex 那边再删也不影响桌宠，桌宠也仍然只需要
// 扫一个目录。同名目录一律跳过——用户自己装的素材优先，导入不能踩掉它。
NSUInteger ImportCodexPets(void) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *source = CodexPetsDirectory();
    NSString *destination = OwnPetsDirectory();
    NSArray<NSString *> *entries = [manager contentsOfDirectoryAtPath:source error:nil];
    if (entries.count == 0) return 0;

    NSUInteger imported = 0;
    for (NSString *name in entries) {
        if ([name hasPrefix:@"."]) continue;
        BOOL isDirectory = NO;
        NSString *petDirectory = [source stringByAppendingPathComponent:name];
        if (![manager fileExistsAtPath:petDirectory isDirectory:&isDirectory] || !isDirectory) continue;
        if (!DirectoryHasSprite(petDirectory)) continue;
        NSString *target = [destination stringByAppendingPathComponent:name];
        if ([manager fileExistsAtPath:target]) continue;
        if (![manager createDirectoryAtPath:destination withIntermediateDirectories:YES
                attributes:nil error:nil]) {
            continue;
        }
        if (![manager copyItemAtPath:petDirectory toPath:target error:nil]) continue;
        // 和 `cc-pets pet add` 写的 sidecar 同一份格式，这样 `cc-pets pet list` 能把
        // 导入进来的素材单独归到 codex 一组。
        NSDictionary *sidecar = @{
            @"source": @"codex",
            @"slug": name,
            @"installedAt": [NSISO8601DateFormatter stringFromDate:NSDate.date
                timeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]
                formatOptions:NSISO8601DateFormatWithInternetDateTime]
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:sidecar
            options:NSJSONWritingPrettyPrinted error:nil];
        if (data) {
            [data writeToFile:[target stringByAppendingPathComponent:@".source.json"] atomically:YES];
        }
        imported += 1;
    }
    return imported;
}

NSString *const HistoryEnabledKey = @"CCPetsQuotaHistoryEnabled";
NSString *const NotificationCompletionKey = @"CCPetsNotifyCompletion";
NSString *const NotificationFailureKey = @"CCPetsNotifyFailure";
NSString *const NotificationApprovalKey = @"CCPetsNotifyApproval";
NSString *const NotificationStallKey = @"CCPetsNotifyStall";
NSString *const StatusBubbleExpandedKey = @"CCPetsStatusBubbleExpanded";
NSString *const StatusBubblePreferenceV2Key = @"CCPetsStatusBubblePreferenceV2";
NSString *const ImportCodexPetsKey = @"CCPetsImportCodexPets";
NSString *const SystemCPUEnabledKey = @"CCPetsSystemCPUEnabled";
NSString *const SystemTemperatureEnabledKey = @"CCPetsSystemTemperatureEnabled";
NSString *const SystemMemoryEnabledKey = @"CCPetsSystemMemoryEnabled";
NSString *const CodexUsageDisplayModeKey = @"CCPetsCodexUsageDisplayMode";
NSString *const ClaudeUsageDisplayModeKey = @"CCPetsClaudeUsageDisplayMode";
NSString *const DetectedProvidersKey = @"CCPetsDetectedProviders";
const NSTimeInterval AgentStatusInactivityInterval = 60.0;
// 客户端进程已经消失、但状态气泡还停在它最后一条事件上时，多等这么久再清场。
// 留这段宽限是因为不经包装脚本启动的客户端（直接跑 claude / codex）没有 pid
// 文件，只能靠"最近还在发事件"证明自己活着，不能一看不到 pid 文件就清掉。
const NSTimeInterval AgentStatusOrphanInterval = 10.0;
// "正在启动"只在会话拉起的一瞬间成立。超过这段还没有任何后续事件，说明会话已经就绪、
// 正在等用户输入，气泡应当落到"待机中"，否则启动态和空闲态看起来完全一样。
const NSTimeInterval AgentStartingGraceInterval = 8.0;
// 审批和思考是唯二会长时间停住不动的状态：窗口切走之后没人知道 Agent 早就停在
// 那儿了。超过这两个阈值就主动提醒一次，会话有新事件后重新武装。审批是纯粹在等
// 人，给得短；思考本来就可能跑很久，给得长，免得正常的长任务被当成卡死。
const NSTimeInterval AgentApprovalStallInterval = 120.0;
const NSTimeInterval AgentThinkingStallInterval = 300.0;
// 刚发布的版本存在 registry 传播竞态，更新失败后等这么久再自动重试一次。
const NSTimeInterval UpdateRetryDelay = 5.0;
// 额度变化由 FSEvents/VNODE 主动推送；定时器只保留为监听不可用时的 120 秒兜底。
// 打开面板和手动刷新仍会立即读取一次。
const NSTimeInterval UsageRefreshIntervalVisible = 120.0;
const NSTimeInterval UsageRefreshIntervalHidden = 120.0;
const NSTimeInterval ClientLifecycleInterval = 3.0;
// 面板上"数据刷新"是相对时间，仅在面板可见时按这个间隔重绘走字。
const NSTimeInterval QuotaClockInterval = 10.0;
const NSTimeInterval AgentEventReaderCheckInterval = 5.0;
// 精灵动画帧间隔。定时器的 tolerance 让内核可以合并唤醒。
const NSTimeInterval PetFrameInterval = 0.22;
