#import "CCPetsCleanup.h"
#import "CCPetsPaths.h"
#import <sys/file.h>
#import <fcntl.h>
#import <signal.h>
#import <unistd.h>
#import <errno.h>

static const NSTimeInterval RuntimeStateTTL = 7 * 24 * 60 * 60;
static NSString *const PreferencesDomain = @"com.universewang.cc-pets";

static NSString *RuntimeLockPath(void) {
    NSString *name = [NSString stringWithFormat:@"cc-pets-%u.lock", getuid()];
    return [PetStateDirectory() stringByAppendingPathComponent:name];
}

static NSString *ClientStateDirectory(void) {
    NSString *name = [NSString stringWithFormat:@"cc-pets-%u-clients", getuid()];
    return [PetStateDirectory() stringByAppendingPathComponent:name];
}

static BOOL RemoveIfPresent(NSString *path) {
    if (path.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:path]) return NO;
    return [NSFileManager.defaultManager removeItemAtPath:path error:nil];
}

// Token 摘要缓存按数据源目录分文件（<provider>-token-cache-<hash>.plist、
// <provider>-monthly-usage-<hash>.plist），同一台机器可以有多份 CODEX_HOME / 配置目录，
// 份数和 hash 都不固定，因此按名字标记枚举，而不是拼具体路径。
// 落盘走临时文件替换，中途崩溃会留下同名的 .tmp，一并清掉。
static NSUInteger RemoveTokenCaches(NSString *supportDirectory) {
    NSArray<NSString *> *entries =
        [NSFileManager.defaultManager contentsOfDirectoryAtPath:supportDirectory error:nil];
    NSUInteger removed = 0;
    for (NSString *entry in entries) {
        if ([entry rangeOfString:@"-token-cache-"].location == NSNotFound &&
            [entry rangeOfString:@"-monthly-usage-"].location == NSNotFound) continue;
        if (RemoveIfPresent([supportDirectory stringByAppendingPathComponent:entry])) removed += 1;
    }
    return removed;
}

// statusline 写者不依赖桌宠进程存在，所以 RuntimeIsActive() 不能证明额度文件无人使用。
// 清理额度缓存前必须拿到同一把锁；锁文件本身刻意长期保留，持锁时 unlink 仍会让后来者
// 创建新 inode，导致新旧两把锁同时存在、互斥失效。
static BOOL RemoveClaudeUsageIfUnlocked(void) {
    // 没有额度缓存就别碰锁：O_CREAT 会凭空造出一个锁文件，而它此后永不删除，
    // 等于清理反而留下了残留。
    if (![NSFileManager.defaultManager fileExistsAtPath:ClaudeUsagePath()]) return NO;
    int descriptor = open(ClaudeUsageLockPath().fileSystemRepresentation,
        O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR);
    if (descriptor < 0) return NO;
    if (flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
        // 静默跳过会让"共移除 N 项"看起来一切正常，用户不会知道额度缓存还在。
        fputs("额度缓存正在被 Claude status line 写入，已跳过；稍后可重试。\n", stderr);
        close(descriptor);
        return NO;
    }
    BOOL removed = RemoveIfPresent(ClaudeUsagePath());
    flock(descriptor, LOCK_UN);
    close(descriptor);
    return removed;
}

static BOOL RuntimeIsActive(void) {
    NSString *lockPath = RuntimeLockPath();
    if (![NSFileManager.defaultManager fileExistsAtPath:lockPath]) return NO;
    int descriptor = open(lockPath.fileSystemRepresentation, O_RDWR | O_CLOEXEC);
    if (descriptor < 0) return YES;
    BOOL active = flock(descriptor, LOCK_EX | LOCK_NB) != 0;
    if (!active) flock(descriptor, LOCK_UN);
    close(descriptor);
    return active;
}

static void RemoveExpiredFile(NSString *path, NSTimeInterval cutoff) {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    NSDate *modified = attributes[NSFileModificationDate];
    if (modified && modified.timeIntervalSince1970 < cutoff) RemoveIfPresent(path);
}

static void RemoveDeadClientRecords(void) {
    NSString *directory = ClientStateDirectory();
    NSArray<NSString *> *entries =
        [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil] ?: @[];
    for (NSString *entry in entries) {
        pid_t pid = (pid_t)entry.intValue;
        BOOL alive = pid > 1 && (kill(pid, 0) == 0 || errno == EPERM);
        if (!alive) RemoveIfPresent([directory stringByAppendingPathComponent:entry]);
    }
    if ([NSFileManager.defaultManager
            contentsOfDirectoryAtPath:directory error:nil].count == 0) {
        RemoveIfPresent(directory);
    }
}

static NSString *BuildCacheDirectory(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"CC_PETS_BUILD_CACHE_DIR"];
    if (override.length > 0) return override.stringByStandardizingPath;
    NSString *binary = NSProcessInfo.processInfo.arguments.firstObject.stringByStandardizingPath;
    NSString *release = binary.stringByDeletingLastPathComponent;
    if (![release.lastPathComponent isEqualToString:@"release"]) return nil;
    return [[release stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"clang-cache"];
}

static BOOL IsSafeSupportDirectory(NSString *path) {
    NSString *standardized = path.stringByStandardizingPath;
    NSString *expected = [[[NSHomeDirectory() stringByAppendingPathComponent:@"Library"]
        stringByAppendingPathComponent:@"Application Support"]
        stringByAppendingPathComponent:@"CC Pets"].stringByStandardizingPath;
    if ([standardized isEqualToString:expected]) return YES;
    return [standardized.lastPathComponent isEqualToString:@"CC Pets"] &&
        [standardized.stringByDeletingLastPathComponent.lastPathComponent
            isEqualToString:@"Application Support"];
}

static BOOL IsSafeBuildCacheDirectory(NSString *path) {
    NSString *standardized = path.stringByStandardizingPath;
    return [standardized.lastPathComponent isEqualToString:@"clang-cache"] &&
        [standardized.stringByDeletingLastPathComponent.lastPathComponent isEqualToString:@".build"];
}

// 刻意不按 mtime 清理额度写锁：锁文件创建后 mtime 就不再更新，7 天判据下它总是"过期"的，
// 而删掉一个正被持有的锁会让后来者 open 出新 inode，互斥直接失效。
void PruneStaleRuntimeState(void) {
    NSTimeInterval cutoff = NSDate.date.timeIntervalSince1970 - RuntimeStateTTL;
    RemoveExpiredFile(AgentEventPath(), cutoff);
    RemoveExpiredFile(ClaudeUsagePath(), cutoff);
    RemoveExpiredFile(CodexLiveUsagePath(), cutoff);
    RemoveDeadClientRecords();
}

int CleanCCPetsData(BOOL purge) {
    if (RuntimeIsActive()) {
        fputs("清理失败：CC Pets 正在运行，请先退出桌宠。\n", stderr);
        return 2;
    }
    NSString *supportDirectory = ApplicationSupportDirectory();
    NSString *buildCache = BuildCacheDirectory();
    if (!IsSafeSupportDirectory(supportDirectory)) {
        fprintf(stderr, "清理失败：应用数据目录不属于 CC Pets：%s\n",
            supportDirectory.UTF8String);
        return 3;
    }
    if (buildCache.length > 0 && !IsSafeBuildCacheDirectory(buildCache)) {
        fprintf(stderr, "清理失败：构建缓存目录不属于 CC Pets：%s\n",
            buildCache.UTF8String);
        return 3;
    }
    NSUInteger removed = 0;
    if (RemoveClaudeUsageIfUnlocked()) removed += 1;
    for (NSString *path in @[AgentEventPath(), CodexLiveUsagePath(), RuntimeLockPath(),
                             ClientStateDirectory(), buildCache ?: @""]) {
        if (RemoveIfPresent(path)) removed += 1;
    }
    // Token 摘要缓存也是纯缓存（丢了只是重新解析一遍会话文件），原先漏在清理之外，
    // 于是缓存一旦出问题，cc-pets clean 救不回来，只能让用户手动删文件。
    removed += RemoveTokenCaches(supportDirectory);
    NSString *updateLog = [supportDirectory stringByAppendingPathComponent:@"update.log"];
    if (RemoveIfPresent(updateLog)) removed += 1;
    if (purge) {
        if (RemoveIfPresent(supportDirectory)) removed += 1;
        NSString *domain = NSProcessInfo.processInfo.environment[@"CC_PETS_PREFERENCES_DOMAIN"];
        if (domain.length == 0) domain = PreferencesDomain;
        [NSUserDefaults.standardUserDefaults removePersistentDomainForName:domain];
        [NSUserDefaults.standardUserDefaults synchronize];
    }
    printf("%s完成，共移除 %lu 项。\n", purge ? "完整数据清理" : "缓存清理",
        (unsigned long)removed);
    return EXIT_SUCCESS;
}
