#import "CCPetsUsageMonitor.h"
#import "CCPetsUsage.h"
#import "CCPetsCodexRateLimits.h"
#import "CCPetsPaths.h"
#import <CoreServices/CoreServices.h>
#import <fcntl.h>
#import <unistd.h>

// 读取与聚合全部跑在这条串行队列上，主线程只收结果。两个 reader 都不加锁，线程安全完全
// 依赖“只有这条队列碰它们”这一条约束：FSEvents 流、Claude 的 vnode source、定时刷新、
// 手动刷新，四个入口都要派到这里，任何一个漏掉都会变成数据竞争。
//
// 改成异步的直接原因：首次聚合要把一整个月的会话解析一遍（本机实测 7 秒），同步跑在主线程上
// 会让桌宠窗口迟迟不出现、切换展示模式时整个界面卡死。
@interface CCPetsUsageMonitor ()
@property dispatch_queue_t queue;
@property CodexUsageReader *codexReader;
@property CCPetsCodexRateLimitsReader *codexRateLimitsReader;
@property ClaudeUsageReader *claudeReader;
@property(readwrite) NSDictionary *codexUsage;
@property(readwrite) NSDictionary *claudeUsage;
@property NSDictionary *codexLiveUsage;
@property NSTimeInterval codexLiveUsageUpdatedAt;
@property FSEventStreamRef codexStream;
@property dispatch_source_t claudeSource;
@property unsigned long long claudeSize;
@property NSTimeInterval claudeModifiedAt;
@property BOOL started;
- (void)publishChange;
- (void)startClaudeSource;
- (NSDictionary *)usageByApplyingLiveCodexUsage:(NSDictionary *)sessionUsage;
@end

// App Server 是服务端当前额度的权威源；会话日志只在成功响应落盘时才更新。短暂失败时
// 留出一小段缓存寿命，既不因一次网络抖动闪回旧日志，也不会把实时值永久钉在界面上。
static const NSTimeInterval CodexLiveUsageTTL = 5 * 60.0;

static void CodexEventsCallback(ConstFSEventStreamRef streamRef,
    void *clientCallBackInfo, size_t numEvents, void *eventPaths,
    const FSEventStreamEventFlags eventFlags[],
    const FSEventStreamEventId eventIds[]) {
    CCPetsUsageMonitor *monitor = (__bridge CCPetsUsageMonitor *)clientCallBackInfo;
    NSArray<NSString *> *paths = (__bridge NSArray<NSString *> *)eventPaths;
    BOOL requiresFullDiscovery = NO;
    // 一批里同一个文件可能出现多次；并发会话时则是多个不同文件。全都收下来交给 reader
    // 按额度采样时刻挑，这里不做"最后一个胜出"的判断——文件写入顺序不代表采样顺序。
    NSMutableOrderedSet<NSString *> *changedSessions = [NSMutableOrderedSet orderedSet];
    for (size_t index = 0; index < numEvents; index++) {
        FSEventStreamEventFlags flags = eventFlags[index];
        if (flags & (kFSEventStreamEventFlagMustScanSubDirs |
                     kFSEventStreamEventFlagUserDropped |
                     kFSEventStreamEventFlagKernelDropped |
                     kFSEventStreamEventFlagRootChanged)) {
            requiresFullDiscovery = YES;
            continue;
        }
        NSString *path = paths[index];
        if ([path.pathExtension.lowercaseString isEqualToString:@"jsonl"] &&
            [path.stringByResolvingSymlinksInPath hasPrefix:
                [monitor.codexReader.sessionsURL.path.stringByResolvingSymlinksInPath
                    stringByAppendingString:@"/"]]) {
            [changedSessions addObject:path];
        }
    }
    if (requiresFullDiscovery) {
        monitor.codexUsage = [monitor usageByApplyingLiveCodexUsage:
            [monitor.codexReader refreshWithFullDiscovery]];
    } else if (changedSessions.count > 0) {
        NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:changedSessions.count];
        for (NSString *path in changedSessions) [urls addObject:[NSURL fileURLWithPath:path]];
        monitor.codexUsage = [monitor usageByApplyingLiveCodexUsage:
            [monitor.codexReader refreshForSessionURLs:urls]];
    }
    if (requiresFullDiscovery || changedSessions.count > 0) [monitor publishChange];
}

@implementation CCPetsUsageMonitor
- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.universewang.cc-pets.usage",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                QOS_CLASS_UTILITY, 0));
        _codexReader = [CodexUsageReader new];
        _codexRateLimitsReader = [CCPetsCodexRateLimitsReader new];
        _claudeReader = [ClaudeUsageReader new];
        // 桌宠是唯一的常驻读取者，摘要缓存由它维护并落盘。
        _codexReader.persistsCache = YES;
        _claudeReader.persistsCache = YES;
        __weak typeof(self) weakSelf = self;
        _codexRateLimitsReader.liveUsageHandler = ^(NSDictionary *liveUsage) {
            dispatch_async(weakSelf.queue, ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf || !strongSelf.started) return;
                strongSelf.codexLiveUsage = liveUsage;
                strongSelf.codexLiveUsageUpdatedAt = NSDate.date.timeIntervalSince1970;
                strongSelf.codexUsage = [strongSelf usageByApplyingLiveCodexUsage:
                    strongSelf.codexReader.usage ?: strongSelf.codexUsage];
                [strongSelf publishChange];
            });
        };
    }
    return self;
}

- (NSDictionary *)usageByApplyingLiveCodexUsage:(NSDictionary *)sessionUsage {
    if (self.codexLiveUsage && NSDate.date.timeIntervalSince1970 -
        self.codexLiveUsageUpdatedAt > CodexLiveUsageTTL) {
        self.codexLiveUsage = nil;
        self.codexLiveUsageUpdatedAt = 0;
    }
    return self.codexLiveUsage
        ? CodexUsageByApplyingLiveUsage(sessionUsage, self.codexLiveUsage)
        : sessionUsage;
}
// 回调交给主线程：下游全是 UI（面板重排、气泡定位、系统通知）。
- (void)publishChange {
    void (^handler)(NSDictionary *, NSDictionary *) = self.changeHandler;
    if (!handler) return;
    NSDictionary *codex = self.codexUsage;
    NSDictionary *claude = self.claudeUsage;
    dispatch_async(dispatch_get_main_queue(), ^{ handler(codex, claude); });
}
// changed=YES 表示额度文件确实变了（VNODE 事件），跳过 stat 比较；
// aggregate=YES 表示这是手动刷新/面板打开/兜底轮询，Token 聚合要绕过节流立即重算。
- (NSDictionary *)readClaudeUsageChanged:(BOOL)changed forcingAggregation:(BOOL)aggregate {
    NSString *path = ClaudeUsagePathForConfigDirectory(DefaultClaudeConfigDirectory());
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    NSTimeInterval modifiedAt = [attributes[NSFileModificationDate] timeIntervalSince1970];
    BOOL unchanged = size == self.claudeSize && modifiedAt == self.claudeModifiedAt;
    self.claudeSize = size;
    self.claudeModifiedAt = modifiedAt;
    if (!changed && !aggregate && unchanged && self.claudeUsage) return self.claudeUsage;
    return aggregate ? [self.claudeReader refreshWithFullAggregation] : [self.claudeReader refresh];
}
- (void)startCodexStream {
    if (self.codexStream) return;
    NSString *sessionsPath = self.codexReader.sessionsURL.path;
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:sessionsPath isDirectory:&isDirectory] ||
        !isDirectory) return;
    FSEventStreamContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
    NSArray *paths = @[sessionsPath];
    FSEventStreamCreateFlags flags =
        kFSEventStreamCreateFlagFileEvents |
        kFSEventStreamCreateFlagNoDefer |
        kFSEventStreamCreateFlagUseCFTypes;
    self.codexStream = FSEventStreamCreate(NULL, CodexEventsCallback, &context,
        (__bridge CFArrayRef)paths, kFSEventStreamEventIdSinceNow, 0.5, flags);
    if (!self.codexStream) return;
    // 回调直接落在读取队列上，省掉一次跳转，也保证 reader 只被这条队列访问。
    FSEventStreamSetDispatchQueue(self.codexStream, self.queue);
    if (!FSEventStreamStart(self.codexStream)) {
        FSEventStreamInvalidate(self.codexStream);
        FSEventStreamRelease(self.codexStream);
        self.codexStream = NULL;
    }
}
- (void)startClaudeSource {
    if (self.claudeSource || !self.started) return;
    // 只监听主账号那一份；其他配置目录写的是各自的文件。
    NSString *path = ClaudeUsagePathForConfigDirectory(DefaultClaudeConfigDirectory());
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
    }
    int descriptor = open(path.fileSystemRepresentation, O_EVTONLY | O_CLOEXEC);
    if (descriptor < 0) return;
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, descriptor,
        DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_DELETE |
        DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE, self.queue);
    if (!source) {
        close(descriptor);
        return;
    }
    self.claudeSource = source;
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_source_t current = strongSelf.claudeSource;
        if (!current) return;
        unsigned long flags = dispatch_source_get_data(current);
        strongSelf.claudeUsage = [strongSelf readClaudeUsageChanged:YES forcingAggregation:NO];
        [strongSelf publishChange];
        if (flags & (DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE)) {
            strongSelf.claudeSource = nil;
            dispatch_source_cancel(current);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                strongSelf.queue, ^{ [weakSelf startClaudeSource]; });
        }
    });
    dispatch_source_set_cancel_handler(source, ^{ close(descriptor); });
    dispatch_resume(source);
}
// 立即返回：首次聚合可能要几秒，桌宠窗口不该等它。
- (void)start {
    if (self.started) return;
    self.started = YES;
    dispatch_async(self.queue, ^{ [self refreshOnQueue]; });
}
- (void)refreshNow {
    dispatch_async(self.queue, ^{ [self refreshOnQueue]; });
}
- (void)refreshOnQueue {
    if (!self.started) return;
    // 手动刷新、面板打开和 120 秒兜底都走全量路径，Token 聚合的节流只约束 FSEvents 热路径。
    self.codexUsage = [self usageByApplyingLiveCodexUsage:
        [self.codexReader refreshWithFullDiscovery]];
    [self.codexRateLimitsReader refresh];
    self.claudeUsage = [self readClaudeUsageChanged:NO forcingAggregation:YES];
    if (!self.codexStream) [self startCodexStream];
    if (!self.claudeSource) [self startClaudeSource];
    [self publishChange];
}
// 同步收尾：退出时要保证事件源在进程消失之前真的停掉，而它们只能在读取队列上安全拆除。
- (void)stop {
    if (!self.started) return;
    self.started = NO;
    // dealloc 也会走到这里，block 里不能强引用 self——那会在析构途中把它再 retain 一次。
    __unsafe_unretained typeof(self) unsafeSelf = self;
    dispatch_sync(self.queue, ^{ [unsafeSelf teardownSources]; });
}
- (void)teardownSources {
    [self.codexRateLimitsReader stop];
    if (self.codexStream) {
        FSEventStreamStop(self.codexStream);
        FSEventStreamInvalidate(self.codexStream);
        FSEventStreamRelease(self.codexStream);
        self.codexStream = NULL;
    }
    if (self.claudeSource) {
        dispatch_source_cancel(self.claudeSource);
        self.claudeSource = nil;
    }
}
- (void)dealloc {
    [self stop];
}
@end
