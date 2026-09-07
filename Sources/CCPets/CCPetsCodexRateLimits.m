#import "CCPetsCodexRateLimits.h"
#import "CCPetsPaths.h"
#import "CCPetsVersion.h"

static const NSTimeInterval CodexRateLimitRequestTimeout = 20.0;
static char CodexRateLimitsQueueKey;

static NSNumber *NumberForKeys(NSDictionary *dictionary, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        id value = dictionary[key];
        if ([value isKindOfClass:NSNumber.class]) return value;
    }
    return nil;
}

static NSDictionary *QuotaFromAppServerWindow(NSDictionary *window) {
    if (![window isKindOfClass:NSDictionary.class]) return nil;
    NSNumber *used = NumberForKeys(window, @[@"usedPercent", @"used_percent"]);
    NSNumber *minutes = NumberForKeys(window, @[@"windowDurationMins", @"window_minutes"]);
    NSNumber *reset = NumberForKeys(window, @[@"resetsAt", @"resets_at"]);
    if (!used && !minutes && !reset) return nil;
    NSMutableDictionary *quota = [NSMutableDictionary dictionary];
    if (used) quota[@"used_percent"] = @(fmax(0, fmin(100, used.doubleValue)));
    if (minutes) quota[@"window_minutes"] = minutes;
    if (reset) quota[@"resets_at"] = reset;
    return quota;
}

static BOOL RateLimitReached(id value) {
    if (!value || value == NSNull.null) return NO;
    if ([value isKindOfClass:NSNumber.class]) return [value boolValue];
    if ([value isKindOfClass:NSString.class]) return ((NSString *)value).length > 0;
    return YES;
}

// App Server 以 camelCase 返回额度。按 windowDurationMins 分窗而不是假设 primary/
// secondary 的位置，这样服务端将来调整字段顺序时，5 小时和 7 天也不会被画反。
//
// 分窗结果决定了要不要写 NSNull：账号确实没有某个窗口时，用 NSNull 盖掉会话里的陈旧
// 快照是对的；但一个窗口都没认出来（服务端改了窗长、或响应里缺 windowDurationMins）
// 时再盖，就等于用一次解析失败清空本来可用的数据——那比不读实时额度还糟。所以两个窗口
// 全没命中时只回传受限状态，让会话快照继续兜底。
static NSDictionary *LiveUsageFromRateLimitBucket(NSDictionary *bucket) {
    if (![bucket isKindOfClass:NSDictionary.class]) return nil;
    NSString *limitID = [bucket[@"limitId"] isKindOfClass:NSString.class]
        ? bucket[@"limitId"] : nil;
    if (limitID.length > 0 && ![limitID hasPrefix:@"codex"]) return nil;

    NSDictionary *fiveHour = nil;
    NSDictionary *week = nil;
    for (id value in @[bucket[@"primary"] ?: NSNull.null,
                         bucket[@"secondary"] ?: NSNull.null]) {
        NSDictionary *quota = QuotaFromAppServerWindow(value);
        NSInteger minutes = [quota[@"window_minutes"] integerValue];
        if (minutes == 300) fiveHour = quota;
        else if (minutes == 10080) week = quota;
    }

    BOOL exhausted = RateLimitReached(bucket[@"rateLimitReachedType"]);
    if (!fiveHour && !week && !exhausted) return nil;

    NSNumber *sampledAt = @(NSDate.date.timeIntervalSince1970);
    NSMutableDictionary *usage = [@{@"sampledAt": sampledAt} mutableCopy];
    if (fiveHour || week) {
        usage[@"fiveHour"] = fiveHour ?: NSNull.null;
        usage[@"week"] = week ?: NSNull.null;
    }
    if (exhausted) {
        // 服务端已分类为额度受限时，不能让一次成功请求留下的百分比继续显示为可用。
        usage[@"exhaustedAt"] = sampledAt;
    }
    return usage;
}

static NSDictionary *LiveUsageFromRateLimitResponse(NSDictionary *result) {
    if (![result isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *byLimitID = [result[@"rateLimitsByLimitId"] isKindOfClass:NSDictionary.class]
        ? result[@"rateLimitsByLimitId"] : nil;
    NSDictionary *fallback = [result[@"rateLimits"] isKindOfClass:NSDictionary.class]
        ? result[@"rateLimits"] : nil;
    NSDictionary *codex = [byLimitID[@"codex"] isKindOfClass:NSDictionary.class]
        ? byLimitID[@"codex"] : nil;
    // 单桶视图由当前 Codex 客户端选择，是最接近终端 /status 的口径；多桶对象只在
    // 服务端未给单桶视图时才作为兼容兜底。
    return LiveUsageFromRateLimitBucket(fallback ?: codex);
}

static BOOL IsCCPetsCodexWrapper(NSString *path) {
    NSString *resolved = path.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    if ([resolved.lastPathComponent isEqualToString:@"codex-with-pet"]) return YES;
    NSString *shims = [[NSHomeDirectory() stringByAppendingPathComponent:@".cc-pets/shims"]
        stringByStandardizingPath];
    return [resolved hasPrefix:[shims stringByAppendingString:@"/"]];
}

static BOOL IsUsableCodexExecutable(NSString *path) {
    return path.length > 0 && [NSFileManager.defaultManager isExecutableFileAtPath:path] &&
        !IsCCPetsCodexWrapper(path);
}

static NSString *CodexAppServerExecutablePath(void) {
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    for (NSString *key in @[@"CC_PETS_CODEX_BIN", @"CODEX_REAL_BIN"]) {
        id value = environment[key];
        NSString *path = [value isKindOfClass:NSString.class]
            ? [value stringByStandardizingPath] : nil;
        if (IsUsableCodexExecutable(path)) return path;
    }

    NSMutableOrderedSet<NSString *> *directories = [NSMutableOrderedSet orderedSet];
    for (NSString *path in [environment[@"PATH"] componentsSeparatedByString:@":"]) {
        if (path.length > 0) [directories addObject:path.stringByStandardizingPath];
    }
    for (NSString *path in @[
        [NSHomeDirectory() stringByAppendingPathComponent:@".local/bin"],
        [NSHomeDirectory() stringByAppendingPathComponent:@".npm-global/bin"],
        [NSHomeDirectory() stringByAppendingPathComponent:@".npm/bin"],
        @"/opt/homebrew/bin", @"/usr/local/bin", @"/usr/bin", @"/bin"
    ]) [directories addObject:path.stringByStandardizingPath];

    // Finder 拉起的 App 通常没有终端里的 nvm PATH。补上已安装 Node 版本的 bin 目录，
    // 同时仍跳过 CC Pets 自己的 codex shim，避免 app-server 反过来再启动桌宠。
    NSString *nvmVersions = [NSHomeDirectory() stringByAppendingPathComponent:@".nvm/versions/node"];
    NSArray<NSString *> *versions = [[NSFileManager.defaultManager
        contentsOfDirectoryAtPath:nvmVersions error:nil]
        sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
            return [right compare:left options:NSNumericSearch];
        }];
    for (NSString *version in versions) {
        [directories addObject:[[nvmVersions stringByAppendingPathComponent:version]
            stringByAppendingPathComponent:@"bin"]];
    }

    for (NSString *directory in directories) {
        NSString *candidate = [directory stringByAppendingPathComponent:@"codex"];
        if (IsUsableCodexExecutable(candidate)) return candidate;
    }
    return nil;
}

static NSDictionary<NSString *, NSString *> *CodexAppServerEnvironment(NSString *executablePath) {
    NSMutableDictionary<NSString *, NSString *> *environment =
        [NSProcessInfo.processInfo.environment mutableCopy];
    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];
    if (executablePath.stringByDeletingLastPathComponent.length > 0) {
        [paths addObject:executablePath.stringByDeletingLastPathComponent];
    }
    for (NSString *path in [environment[@"PATH"] componentsSeparatedByString:@":"]) {
        if (path.length == 0 || IsCCPetsCodexWrapper([path stringByAppendingPathComponent:@"codex"])) continue;
        [paths addObject:path];
    }
    environment[@"PATH"] = [paths.array componentsJoinedByString:@":"];
    // 与会话扫描使用同一份配置目录，避免备用 CODEX_HOME 下的账号被错读成默认账号。
    environment[@"CODEX_HOME"] = DefaultCodexHomeDirectory();
    return environment;
}

@interface CCPetsCodexRateLimitsReader ()
@property dispatch_queue_t queue;
@property NSTask *task;
@property NSFileHandle *input;
@property NSFileHandle *output;
@property NSMutableData *partialOutput;
@property NSInteger nextRequestID;
@property NSInteger pendingRequestID;
@property BOOL stopped;
@end

@implementation CCPetsCodexRateLimitsReader

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.universewang.cc-pets.codex-rate-limits",
            DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, &CodexRateLimitsQueueKey, (__bridge void *)self, NULL);
        _partialOutput = [NSMutableData data];
        _nextRequestID = 2;  // 1 留给 initialize。
    }
    return self;
}

- (void)refresh {
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.queue, ^{ [weakSelf refreshOnQueue]; });
}

- (void)stop {
    void (^stopOnQueue)(void) = ^{
        self.stopped = YES;
        [self stopTaskOnQueue];
    };
    if (dispatch_get_specific(&CodexRateLimitsQueueKey) == (__bridge void *)self) {
        stopOnQueue();
    } else {
        dispatch_sync(self.queue, stopOnQueue);
    }
}

- (BOOL)sendMessageOnQueue:(NSDictionary *)message {
    if (!self.input || !message) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    if (!data) return NO;
    NSMutableData *line = [data mutableCopy];
    [line appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    @try {
        [self.input writeData:line];
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

- (BOOL)ensureTaskOnQueue {
    if (self.task.running) return YES;
    NSString *path = CodexAppServerExecutablePath();
    if (path.length == 0) return NO;

    NSTask *task = [NSTask new];
    NSPipe *inputPipe = [NSPipe pipe];
    NSPipe *outputPipe = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = @[@"app-server", @"--stdio"];
    task.environment = CodexAppServerEnvironment(path);
    task.currentDirectoryURL = [NSURL fileURLWithPath:NSHomeDirectory()];
    task.standardInput = inputPipe;
    task.standardOutput = outputPipe;
    task.standardError = [NSFileHandle fileHandleForWritingAtPath:@"/dev/null"];

    __weak typeof(self) weakSelf = self;
    // 两个回调都跑在后台线程，与 dealloc -> stop 清理回调之间存在竞态窗口。reader 已经
    // 释放时 weakSelf.queue 是 nil，而 dispatch_async 到 NULL 队列会直接崩，所以必须先
    // strongify 再判空，不能图省事写成 dispatch_async(weakSelf.queue, ...)。
    outputPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            handle.readabilityHandler = nil;
            return;
        }
        dispatch_async(strongSelf.queue, ^{
            [weakSelf consumeOutputDataOnQueue:data fromHandle:handle];
        });
    };
    task.terminationHandler = ^(NSTask *finishedTask) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(strongSelf.queue, ^{ [weakSelf taskDidTerminateOnQueue:finishedTask]; });
    };

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        outputPipe.fileHandleForReading.readabilityHandler = nil;
        return NO;
    }
    self.task = task;
    self.input = inputPipe.fileHandleForWriting;
    self.output = outputPipe.fileHandleForReading;
    [self.partialOutput setLength:0];
    NSDictionary *initialize = @{
        @"method": @"initialize", @"id": @1,
        @"params": @{ @"clientInfo": @{
            @"name": @"cc_pets", @"title": @"CC Pets", @"version": @CC_PETS_VERSION
        }}
    };
    if (![self sendMessageOnQueue:initialize] ||
        ![self sendMessageOnQueue:@{ @"method": @"initialized", @"params": @{} }]) {
        [self stopTaskOnQueue];
        return NO;
    }
    return YES;
}

- (void)refreshOnQueue {
    if (self.stopped || self.pendingRequestID != 0 || ![self ensureTaskOnQueue]) return;
    NSInteger requestID = self.nextRequestID++;
    self.pendingRequestID = requestID;
    if (![self sendMessageOnQueue:@{ @"method": @"account/rateLimits/read", @"id": @(requestID) }]) {
        self.pendingRequestID = 0;
        [self stopTaskOnQueue];
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(CodexRateLimitRequestTimeout * NSEC_PER_SEC)), self.queue, ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.pendingRequestID != requestID) return;
        strongSelf.pendingRequestID = 0;
        [strongSelf stopTaskOnQueue];
    });
}

- (void)deliverLiveUsageOnQueue:(NSDictionary *)usage {
    if (!usage) return;
    void (^handler)(NSDictionary *) = self.liveUsageHandler;
    if (handler) handler(usage);
}

- (void)consumeMessageOnQueue:(NSDictionary *)message {
    if (![message isKindOfClass:NSDictionary.class]) return;
    NSNumber *requestID = [message[@"id"] isKindOfClass:NSNumber.class] ? message[@"id"] : nil;
    if (requestID && requestID.integerValue == self.pendingRequestID) {
        self.pendingRequestID = 0;
        NSDictionary *usage = LiveUsageFromRateLimitResponse(message[@"result"]);
        [self deliverLiveUsageOnQueue:usage];
        return;
    }
    NSString *method = [message[@"method"] isKindOfClass:NSString.class] ? message[@"method"] : nil;
    if (![method isEqualToString:@"account/rateLimits/updated"]) return;
    NSDictionary *params = [message[@"params"] isKindOfClass:NSDictionary.class]
        ? message[@"params"] : nil;
    [self deliverLiveUsageOnQueue:LiveUsageFromRateLimitBucket(params[@"rateLimits"])];
}

- (void)consumeOutputDataOnQueue:(NSData *)data fromHandle:(NSFileHandle *)handle {
    // 旧进程退出时可能还留下一次 readability 回调；不能让它把刚重连的新 stdout
    // 处理器清掉，或把上一代进程的响应套到新请求上。
    if (handle != self.output) return;
    if (data.length == 0) {
        handle.readabilityHandler = nil;
        return;
    }
    [self.partialOutput appendData:data];
    const uint8_t *bytes = self.partialOutput.bytes;
    NSUInteger lineStart = 0;
    for (NSUInteger index = 0; index < self.partialOutput.length; index++) {
        if (bytes[index] != '\n') continue;
        NSData *line = [self.partialOutput subdataWithRange:NSMakeRange(lineStart, index - lineStart)];
        NSDictionary *message = line.length > 0
            ? [NSJSONSerialization JSONObjectWithData:line options:0 error:nil] : nil;
        [self consumeMessageOnQueue:message];
        lineStart = index + 1;
    }
    if (lineStart > 0) {
        self.partialOutput = [[self.partialOutput subdataWithRange:
            NSMakeRange(lineStart, self.partialOutput.length - lineStart)] mutableCopy];
    }
    if (self.partialOutput.length > 1024 * 1024) [self.partialOutput setLength:0];
}

- (void)taskDidTerminateOnQueue:(NSTask *)task {
    if (task != self.task) return;
    self.output.readabilityHandler = nil;
    self.task = nil;
    self.input = nil;
    self.output = nil;
    self.pendingRequestID = 0;
    [self.partialOutput setLength:0];
}

- (void)stopTaskOnQueue {
    NSTask *task = self.task;
    self.output.readabilityHandler = nil;
    self.task = nil;
    self.input = nil;
    self.output = nil;
    self.pendingRequestID = 0;
    [self.partialOutput setLength:0];
    if (task.running) [task terminate];
}

- (void)dealloc {
    [self stop];
}

@end

NSDictionary *CodexUsageByApplyingLiveUsage(NSDictionary *sessionUsage,
    NSDictionary *liveUsage) {
    if (![liveUsage isKindOfClass:NSDictionary.class]) return sessionUsage;
    NSMutableDictionary *merged = [sessionUsage isKindOfClass:NSDictionary.class]
        ? [sessionUsage mutableCopy] : [NSMutableDictionary dictionary];
    for (NSString *key in @[@"fiveHour", @"week"]) {
        id quota = liveUsage[key];
        if (quota) merged[key] = quota;
    }
    merged[@"sampledAt"] = liveUsage[@"sampledAt"] ?: @(NSDate.date.timeIntervalSince1970);
    if ([liveUsage[@"exhaustedAt"] isKindOfClass:NSNumber.class]) {
        merged[@"exhaustedAt"] = liveUsage[@"exhaustedAt"];
    } else {
        [merged removeObjectForKey:@"exhaustedAt"];
    }
    return merged;
}
