// agent 事件流读取与客户端存活检测。
#import "CCPetsAppDelegate+Private.h"

// 客户端是否真的还在跑。只问 kill(pid, 0) 不够：关掉终端窗口只是销毁 pty，claude /
// codex（Node 进程）不一定跟着 SIGHUP 退出，会变成脱离控制终端的孤儿继续活着。那样
// pid 一直存在，会话就永久挂在"在线"上，最近会话列表里那条也永远不消失。
// 所以再看两件事：进程是否还有控制终端；以及它是不是仍然是 pid 文件里记的那个 TTY
// （pty 会被新开的窗口复用，光看"有 tty"挡不住换了主人的情况）。
// recordedTTY 为空是 1.0.2 及更早的老客户端，只能退回"有控制终端"这一条。
static BOOL ClientProcessAlive(pid_t pid, NSString *recordedTTY) {
    if (pid <= 1) return NO;
    struct kinfo_proc info;
    size_t length = sizeof(info);
    int name[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    if (sysctl(name, 4, &info, &length, NULL, 0) != 0 || length == 0) return NO;
    if (info.kp_proc.p_stat == SZOMB) return NO;
    dev_t device = info.kp_eproc.e_tdev;
    if (device == NODEV) return NO;
    if (recordedTTY.length == 0) return YES;
    const char *current = devname(device, S_IFCHR);
    if (!current) return NO;
    return [recordedTTY isEqualToString:@(current).lastPathComponent];
}

@implementation AppDelegate (AgentEvents)
- (void)prepareAgentEventReader {
    NSString *path = AgentEventPath();
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    if (self.agentEventReaderInitialized) {
        if (size < self.agentEventOffset) {
            self.agentEventOffset = 0;
            [self.agentEventPartialLine setLength:0];
        }
        [self readNewAgentEvents];
        return;
    }
    self.agentEventReaderInitialized = YES;
    self.agentEventOffset = size;
    if (size > 0) {
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
        unsigned long long start = size > 65536 ? size - 65536 : 0;
        [handle seekToFileOffset:start];
        NSData *recent = [handle readDataToEndOfFile];
        [handle closeFile];
        [self processAgentEventData:recent ignoreFirstPartial:start > 0 recentOnly:YES];
    }
}
- (void)consumeAgentEventData:(NSData *)data {
    if (data.length == 0) return;
    [self.agentEventPartialLine appendData:data];
    const uint8_t *bytes = self.agentEventPartialLine.bytes;
    NSUInteger lineStart = 0;
    for (NSUInteger index = 0; index < self.agentEventPartialLine.length; index++) {
        if (bytes[index] != '\n') continue;
        NSData *lineData = [self.agentEventPartialLine subdataWithRange:NSMakeRange(lineStart, index - lineStart)];
        [self processAgentEventData:lineData ignoreFirstPartial:NO recentOnly:NO];
        lineStart = index + 1;
    }
    if (lineStart > 0) {
        NSData *remainder = [self.agentEventPartialLine subdataWithRange:
            NSMakeRange(lineStart, self.agentEventPartialLine.length - lineStart)];
        self.agentEventPartialLine = [remainder mutableCopy];
    }
    if (self.agentEventPartialLine.length > 1024 * 1024) [self.agentEventPartialLine setLength:0];
}
- (void)processAgentEventData:(NSData *)data ignoreFirstPartial:(BOOL)ignoreFirstPartial recentOnly:(BOOL)recentOnly {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) return;
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSTimeInterval cutoff = [NSDate.date timeIntervalSince1970] - 5;
    for (NSUInteger index = 0; index < lines.count; index++) {
        if (ignoreFirstPartial && index == 0) continue;
        NSData *lineData = [lines[index] dataUsingEncoding:NSUTF8StringEncoding];
        if (lineData.length == 0) continue;
        NSDictionary *record = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
        if (![record isKindOfClass:NSDictionary.class]) continue;
        if (recentOnly && [record[@"timestamp"] doubleValue] < cutoff) continue;
        [self trackAgentSessionRecord:record];
        NSString *event = record[@"event"];
        NSString *state = [record[@"state"] isKindOfClass:NSString.class] ? record[@"state"] : @"";
        if ([event isKindOfClass:NSString.class]) {
            if (!self.pendingApprovalRecords) {
                self.pendingApprovalRecords = [NSMutableDictionary dictionary];
            }
            [self prunePendingApprovalRecords];
            NSString *approvalKey = [self approvalKeyForRecord:record];
            BOOL manualApproval = [state isEqualToString:@"approval"];
            if (manualApproval) {
                self.pendingApprovalRecords[approvalKey] = record;
            } else {
                [self.pendingApprovalRecords removeObjectForKey:approvalKey];
            }
            [self prunePendingApprovalRecords];
            // 多会话下不能让一个未处理的审批全局挡住其他 Agent 的所有 Hook。每条事件
            // 都正常驱动气泡和动画；仍在等待的审批保留在多会话记录中供用户回跳。
            [self displayAgentRecord:record notify:YES];
        }
    }
    [self refreshApprovalBadge];
}
- (void)readNewAgentEvents {
    NSString *path = AgentEventPath();
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    if (size < self.agentEventOffset) self.agentEventOffset = 0;
    if (size == self.agentEventOffset) return;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return;
    unsigned long long start = self.agentEventOffset;
    [handle seekToFileOffset:start];
    NSData *data = [handle readDataToEndOfFile];
    [handle closeFile];
    self.agentEventOffset = start + data.length;
    [self consumeAgentEventData:data];
}
- (void)startAgentEventReader {
    if (self.agentEventSource) return;
    NSString *path = AgentEventPath();
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil];
    int creator = open(path.fileSystemRepresentation, O_CREAT | O_WRONLY | O_CLOEXEC, S_IRUSR | S_IWUSR);
    if (creator >= 0) close(creator);
    int descriptor = open(path.fileSystemRepresentation, O_EVTONLY | O_CLOEXEC);
    if (descriptor < 0) return;
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, descriptor,
        DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_DELETE |
        DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE,
        dispatch_get_main_queue());
    if (!source) {
        close(descriptor);
        return;
    }
    self.agentEventSource = source;
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_source_t currentSource = strongSelf.agentEventSource;
        if (!currentSource) return;
        unsigned long flags = dispatch_source_get_data(currentSource);
        [strongSelf readNewAgentEvents];
        if (flags & (DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE)) {
            strongSelf.agentEventSource = nil;
            dispatch_source_cancel(currentSource);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                dispatch_get_main_queue(), ^{ [weakSelf startAgentEventReader]; });
        }
    });
    dispatch_source_set_cancel_handler(source, ^{ close(descriptor); });
    dispatch_resume(source);
    [self prepareAgentEventReader];
}
- (void)ensureAgentEventReader:(id)sender {
    if (!self.agentEventSource) [self startAgentEventReader];
}
- (void)refreshClientLifecycle:(id)sender {
    [self considerIdleSpeech];
    [self prunePendingApprovalRecords];
    NSString *clientName = [NSString stringWithFormat:@"cc-pets-%u-clients", getuid()];
    NSString *clientDirectory = [PetStateDirectory() stringByAppendingPathComponent:clientName];
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:clientDirectory error:nil] ?: @[];
    NSInteger liveClients = 0;
    NSMutableSet<NSString *> *providers = [NSMutableSet set];
    NSMutableSet<NSString *> *sessionKeys = [NSMutableSet set];
    BOOL unlabeled = NO;
    for (NSString *entry in entries) {
        pid_t pid = (pid_t)entry.intValue;
        NSString *path = [clientDirectory stringByAppendingPathComponent:entry];
        // 包装脚本会把 provider 名写进 pid 文件第一行、TTY 写进第二行。1.0.2 及更早
        // 的版本只 touch 出空文件，升级后仍在运行的老客户端读出来是空的：这类当作
        // “身份不明”，只要还有一个就不清场，避免把仍然活着的会话误判成已退出。
        NSString *contents = [NSString stringWithContentsOfFile:path
            encoding:NSUTF8StringEncoding error:nil] ?: @"";
        NSArray<NSString *> *lines = [contents componentsSeparatedByCharactersInSet:
            NSCharacterSet.newlineCharacterSet];
        NSString *label = [lines.firstObject
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *tty = lines.count > 1 ? [lines[1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
        if (!ClientProcessAlive(pid, tty)) {
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            continue;
        }
        liveClients += 1;
        if (label.length > 0 && label.length <= 32) [providers addObject:label];
        else unlabeled = YES;
        NSString *sessionKey = [self onlineAgentSessionKeyForProvider:label tty:tty];
        if (sessionKey.length > 0) [sessionKeys addObject:sessionKey];
    }
    // 包装脚本启动的客户端有精确的退出信号：pid 文件被回收。这一段不该被为"直接跑
    // claude / codex"准备的 60 秒活跃度宽限盖住，否则退出后还要挂满一分钟才转离线。
    // 因此某一家的 pid 文件一旦从有变无，立刻丢掉它的活跃度记录；从来没有过 pid 文件
    // 的（直接启动）不受影响，继续走宽限。
    NSSet<NSString *> *previousProviders = self.liveClientProviders;
    self.liveClientCount = liveClients;
    self.liveClientProviders = providers;
    self.liveAgentSessionKeys = sessionKeys;
    self.hasUnlabeledClient = unlabeled;
    [self pruneOfflineAgentSessionRecords];
    for (NSString *provider in previousProviders) {
        if (![providers containsObject:provider]) {
            [self.providerActivityAt removeObjectForKey:provider];
        }
    }
    [self updateQuotaLiveState];
    [self refreshDetectedProviders];
    [self hideAgentStatusIfClientGone];
    [self checkStalledAgentSessions];
    [self refreshApprovalBadge];
    // 启动模式在应用生命周期内保持不变。手动启动的桌宠即使后来检测到
    // Codex/Claude 客户端，也不应被转成 CLI 托管模式并随客户端退出。
    if (liveClients == 0 && self.managedByCLI) [NSApp terminate:nil];
}
@end
