#import "CCPetsBridgeTitleRelay.h"
#import "CCPetsBridgeTerminalTitle.h"
#import "CCPetsCLISupport.h"
#import "CCPetsTerminalFocus.h"
#import <errno.h>
#import <fcntl.h>
#import <poll.h>
#import <signal.h>
#import <sys/ioctl.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <termios.h>
#import <unistd.h>
#import <util.h>

static const NSUInteger RelayBufferLimit = 64 * 1024;
static const NSUInteger RelayTitleLimit = 4096;

typedef NS_ENUM(NSUInteger, RelayOutputState) {
    RelayPlain, RelayEscape, RelayCSI, RelayEscapeIntermediate, RelayOSCCode, RelayOSCSeparator, RelayTitle,
    RelayTitleEscape, RelayControlString, RelayControlEscape
};

@interface CCPetsTerminalTitleOutput : NSObject
@property RelayOutputState state;
@property BOOL oscString;
@property NSUInteger utf8Remaining;
@property NSMutableData *frame;
@property NSData *lastTitle;
@property(copy) NSString *nickname;
- (void)appendBytes:(const uint8_t *)bytes length:(NSUInteger)length to:(NSMutableData *)output;
- (void)refreshNickname:(NSString *)nickname output:(NSMutableData *)output;
- (void)flushTo:(NSMutableData *)output;
@end

static NSUInteger RemainingUTF8Bytes(const uint8_t *bytes, NSUInteger length, NSUInteger previous) {
    NSUInteger continuation = 0;
    while (continuation < length && (bytes[length - continuation - 1] & 0xc0) == 0x80) continuation++;
    if (continuation == length) return previous > length ? previous - length : 0;
    uint8_t lead = bytes[length - continuation - 1];
    NSUInteger expected = 0;
    if (lead >= 0xc2 && lead <= 0xdf) expected = 1;
    else if (lead >= 0xe0 && lead <= 0xef) expected = 2;
    else if (lead >= 0xf0 && lead <= 0xf4) expected = 3;
    return expected > continuation ? expected - continuation : 0;
}

@implementation CCPetsTerminalTitleOutput

- (instancetype)init {
    if ((self = [super init])) _frame = [NSMutableData data];
    return self;
}

- (void)appendTitleTo:(NSMutableData *)output {
    NSData *title = self.lastTitle;
    if (!title) return;
    const uint8_t *bytes = title.bytes;
    NSUInteger terminatorLength = bytes[title.length - 1] == '\a' ? 1 : 2;
    NSUInteger baseLength = title.length - terminatorLength;
    if (!self.nickname.length || baseLength <= 4) {
        [output appendData:title];
        return;
    }
    static const char separator[] = " · ";
    [output appendBytes:bytes length:baseLength];
    [output appendBytes:separator length:sizeof(separator) - 1];
    [output appendData:[self.nickname dataUsingEncoding:NSUTF8StringEncoding]];
    [output appendBytes:bytes + baseLength length:terminatorLength];
}

- (void)refreshNickname:(NSString *)nickname output:(NSMutableData *)output {
    if (nickname == self.nickname || [nickname isEqualToString:self.nickname]) return;
    self.nickname = nickname;
    // Keep the title as emitted by the child. Never append a suffix to its empty reset sequence.
    if (self.lastTitle.length > 0) {
        const uint8_t *bytes = self.lastTitle.bytes;
        NSUInteger terminatorLength = bytes[self.lastTitle.length - 1] == '\a' ? 1 : 2;
        if (self.lastTitle.length > 4 + terminatorLength) [self appendTitleTo:output];
    }
}

- (void)flushTo:(NSMutableData *)output {
    [output appendData:self.frame];
    [self.frame setLength:0];
}

- (void)finishTitleWithByte:(uint8_t)byte output:(NSMutableData *)output {
    [self.frame appendBytes:&byte length:1];
    self.lastTitle = [self.frame copy];
    [self appendTitleTo:output];
    [self.frame setLength:0];
    self.state = RelayPlain;
}

- (void)appendBytes:(const uint8_t *)bytes length:(NSUInteger)length to:(NSMutableData *)output {
    for (NSUInteger index = 0; index < length;) {
        uint8_t byte = bytes[index++];
        switch (self.state) {
            case RelayPlain: {
                const uint8_t *start = bytes + index - 1;
                const uint8_t *escape = memchr(start, '\033', length - index + 1);
                NSUInteger run = escape ? (NSUInteger)(escape - start) : length - index + 1;
                [output appendBytes:start length:run];
                self.utf8Remaining = escape ? 0 : RemainingUTF8Bytes(start, run, self.utf8Remaining);
                if (!escape) return;
                index += run;
                [self.frame appendBytes:escape length:1];
                self.state = RelayEscape;
                break;
            }
            case RelayEscape:
                if (byte == ']') {
                    [self.frame appendBytes:&byte length:1];
                    self.state = RelayOSCCode;
                } else {
                    [self flushTo:output];
                    if (byte == '\033') {
                        [self.frame appendBytes:&byte length:1];
                    } else {
                        [output appendBytes:&byte length:1];
                        self.oscString = NO;
                        if (byte == 'P' || byte == 'X' || byte == '^' || byte == '_') self.state = RelayControlString;
                        else if (byte == '[') self.state = RelayCSI;
                        else if (byte >= 0x20 && byte <= 0x2f) self.state = RelayEscapeIntermediate;
                        else self.state = RelayPlain;
                    }
                }
                break;
            case RelayCSI:
            case RelayEscapeIntermediate: {
                uint8_t firstFinal = self.state == RelayCSI ? 0x40 : 0x30;
                if (byte == '\033') {
                    [self.frame appendBytes:&byte length:1];
                    self.state = RelayEscape;
                } else {
                    [output appendBytes:&byte length:1];
                    if ((byte >= firstFinal && byte <= 0x7e) || byte == 0x18 || byte == 0x1a) self.state = RelayPlain;
                }
                break;
            }
            case RelayOSCCode:
            case RelayOSCSeparator: {
                BOOL code = self.state == RelayOSCCode;
                if (code ? (byte == '0' || byte == '2') : byte == ';') {
                    [self.frame appendBytes:&byte length:1];
                    self.state = code ? RelayOSCSeparator : RelayTitle;
                } else {
                    [self flushTo:output];
                    [output appendBytes:&byte length:1];
                    self.oscString = YES;
                    self.state = byte == '\a' || byte == 0x18 || byte == 0x1a
                        ? RelayPlain : (byte == '\033' ? RelayControlEscape : RelayControlString);
                }
                break;
            }
            case RelayTitle:
                if (byte == '\a') {
                    [self finishTitleWithByte:byte output:output];
                } else if (byte == 0x18 || byte == 0x1a) {
                    [self flushTo:output];
                    [output appendBytes:&byte length:1];
                    self.state = RelayPlain;
                } else {
                    [self.frame appendBytes:&byte length:1];
                    self.state = byte == '\033' ? RelayTitleEscape : RelayTitle;
                    if (self.frame.length >= RelayTitleLimit) {
                        [self flushTo:output];
                        self.lastTitle = nil;
                        self.oscString = YES;
                        self.state = byte == '\033' ? RelayControlEscape : RelayControlString;
                    }
                }
                break;
            case RelayTitleEscape:
                if (byte == '\\') {
                    [self finishTitleWithByte:byte output:output];
                } else {
                    // An unexpected escape inside OSC cancels its rewrite. Reprocess it as a new escape.
                    NSUInteger prefix = self.frame.length - 1;
                    [output appendBytes:self.frame.bytes length:prefix];
                    [self.frame replaceBytesInRange:NSMakeRange(0, prefix) withBytes:NULL length:0];
                    self.lastTitle = nil;
                    self.state = RelayEscape;
                    index--;
                }
                break;
            case RelayControlString:
            case RelayControlEscape: {
                BOOL escaped = self.state == RelayControlEscape;
                [output appendBytes:&byte length:1];
                if ((escaped && byte == '\\') || (self.oscString && byte == '\a') || byte == 0x18 || byte == 0x1a) {
                    self.state = RelayPlain;
                }
                else if (byte == '\033' && (!escaped || self.oscString)) self.state = RelayControlEscape;
                else self.state = RelayControlString;
                break;
            }
        }
    }
}

@end

static const int RelaySignals[] = {SIGWINCH, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP};
static volatile sig_atomic_t RelayResize, RelayInterrupt, RelaySuspend;

static void HandleRelaySignal(int signalNumber) {
    if (signalNumber == SIGWINCH) RelayResize = 1;
    else if (signalNumber == SIGTSTP) RelaySuspend = 1;
    else RelayInterrupt = signalNumber;
}

static void RestoreRelaySignalActions(const struct sigaction *actions, NSUInteger count) {
    for (NSUInteger index = 0; index < count; index++) sigaction(RelaySignals[index], &actions[index], NULL);
}

static int ExecRelayChild(char **arguments) {
    execvp(arguments[0], arguments);
    int failure = errno;
    perror(arguments[0]);
    return failure == ENOENT ? 127 : 126;
}

static void RegisterRelayCodexLaunch(NSString *provider, pid_t pid, NSTimeInterval launchedAt) {
    if (![provider isEqual:@"Codex"]) return;
    @try {
        RegisterCodexLaunchForProcess(pid, NSFileManager.defaultManager.currentDirectoryPath,
            TerminalFocusTargetFromEnvironment(), launchedAt);
    } @catch (NSException *exception) {}
}

static int ExecWithoutRelay(char **arguments, NSString *provider) {
    unsetenv("CC_PETS_BRIDGE_TITLE_TOKEN");
    RegisterRelayCodexLaunch(provider, getpid(), NSDate.date.timeIntervalSince1970);
    return ExecRelayChild(arguments);
}

static void SignalRelayChild(pid_t child, int signalNumber) {
    if (kill(-child, signalNumber) != 0 && errno == ESRCH) kill(child, signalNumber);
}

static BOOL IsForegroundTerminal(void) {
    pid_t foreground = tcgetpgrp(STDIN_FILENO);
    return foreground > 0 && foreground == getpgrp();
}

static void RestoreOuterTerminal(const struct termios *settings) {
    if (IsForegroundTerminal()) tcsetattr(STDIN_FILENO, TCSANOW, settings);
}

static BOOL WriteRelayData(int descriptor, NSMutableData *data) {
    ssize_t written = write(descriptor, data.bytes, data.length);
    if (written < 0) return errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK;
    if (written > 0) [data replaceBytesInRange:NSMakeRange(0, (NSUInteger)written) withBytes:NULL length:0];
    return YES;
}

static int RunRelay(char **arguments, NSString *provider, NSString *launchToken) {
    struct termios original;
    if (!launchToken.length || !isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO) ||
        !IsForegroundTerminal() || tcgetattr(STDIN_FILENO, &original) != 0) return ExecWithoutRelay(arguments, provider);

    struct stat inputStat, outputStat;
    if (fstat(STDIN_FILENO, &inputStat) != 0 || fstat(STDOUT_FILENO, &outputStat) != 0 ||
        inputStat.st_rdev != outputStat.st_rdev) return ExecWithoutRelay(arguments, provider);
    // A separately opened descriptor doesn't change O_NONBLOCK for the invoking shell or its jobs.
    const char *terminalPath = ttyname(STDOUT_FILENO);
    int outerOutput = terminalPath ? open(terminalPath, O_WRONLY | O_NOCTTY | O_CLOEXEC | O_NONBLOCK) : -1;
    if (outerOutput < 0) return ExecWithoutRelay(arguments, provider);
    // forkpty joins all three descriptors to the PTY. Keep a separate stderr redirection intact.
    BOOL relayStderr = isatty(STDERR_FILENO) && fstat(STDERR_FILENO, &outputStat) == 0 &&
        inputStat.st_rdev == outputStat.st_rdev;
    int savedStderr = relayStderr ? -1 : fcntl(STDERR_FILENO, F_DUPFD_CLOEXEC, 3);
    int launchGate[2];
    if ((!relayStderr && savedStderr < 0) || pipe(launchGate) != 0) {
        if (savedStderr >= 0) close(savedStderr);
        close(outerOutput);
        return ExecWithoutRelay(arguments, provider);
    }
    struct termios raw = original;
    cfmakeraw(&raw);
    struct winsize size = {0};
    ioctl(STDIN_FILENO, TIOCGWINSZ, &size);

    RelayResize = RelayInterrupt = RelaySuspend = 0;
    struct sigaction action = {0};
    struct sigaction previous[sizeof(RelaySignals) / sizeof(*RelaySignals)];
    action.sa_handler = HandleRelaySignal;
    sigemptyset(&action.sa_mask);
    NSUInteger actionCount = 0;
    while (actionCount < sizeof(RelaySignals) / sizeof(*RelaySignals) &&
        sigaction(RelaySignals[actionCount], &action, &previous[actionCount]) == 0) actionCount++;
    if (actionCount != sizeof(RelaySignals) / sizeof(*RelaySignals) || tcsetattr(STDIN_FILENO, TCSANOW, &raw) != 0) {
        close(launchGate[0]);
        close(launchGate[1]);
        if (savedStderr >= 0) close(savedStderr);
        close(outerOutput);
        RestoreRelaySignalActions(previous, actionCount);
        return ExecWithoutRelay(arguments, provider);
    }

    int master = -1;
    NSTimeInterval launchedAt = NSDate.date.timeIntervalSince1970;
    pid_t child = forkpty(&master, NULL, &original, &size);
    if (child == 0) {
        close(launchGate[1]);
        RestoreRelaySignalActions(previous, actionCount);
        char unused;
        while (read(launchGate[0], &unused, 1) < 0 && errno == EINTR) {}
        close(launchGate[0]);
        if (savedStderr >= 0) {
            if (dup2(savedStderr, STDERR_FILENO) < 0) _exit(126);
            close(savedStderr);
        }
        _exit(ExecRelayChild(arguments));
    }
    close(launchGate[0]);
    if (savedStderr >= 0) close(savedStderr);
    // Register the actual child PID before a shared Codex host can emit SessionStart.
    if (child > 0) RegisterRelayCodexLaunch(provider, child, launchedAt);
    close(launchGate[1]);
    if (child < 0) {
        close(outerOutput);
        RestoreOuterTerminal(&original);
        RestoreRelaySignalActions(previous, actionCount);
        return ExecWithoutRelay(arguments, provider);
    }

    BOOL exited = NO;
    int completion = 0;
    @try {
        fcntl(master, F_SETFD, FD_CLOEXEC);
        int masterFlags = fcntl(master, F_GETFL);
        if (masterFlags < 0 || fcntl(master, F_SETFL, masterFlags | O_NONBLOCK) != 0) return 1;
        CCPetsTerminalTitleOutput *parser = [CCPetsTerminalTitleOutput new];
        NSMutableData *pendingInput = [NSMutableData data];
        NSMutableData *pendingOutput = [NSMutableData data];
        BOOL masterOpen = YES;
        NSTimeInterval nicknameRefresh = 0, stopDeadline = 0, drainDeadline = 0;
        while (!exited || masterOpen || pendingOutput.length > 0) {
            @autoreleasepool {
                NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
                BOOL childStopped = NO;
                if (!exited) {
                    int status = 0;
                    if (waitpid(child, &status, WNOHANG | WUNTRACED) == child) {
                        if (WIFSTOPPED(status)) childStopped = YES;
                        else {
                            completion = status;
                            exited = YES;
                            drainDeadline = now + 0.5;
                        }
                    }
                }
                if ((RelaySuspend || childStopped) && !exited && !RelayInterrupt && !stopDeadline) {
                    RelaySuspend = 0;
                    if (!childStopped) SignalRelayChild(child, SIGSTOP);
                    RestoreOuterTerminal(&original);
                    do { raise(SIGSTOP); } while (!IsForegroundTerminal() && !RelayInterrupt);
                    if (!RelayInterrupt) {
                        tcsetattr(STDIN_FILENO, TCSANOW, &raw);
                        SignalRelayChild(child, SIGCONT);
                        RelayResize = 1;
                    }
                }
                if (RelayResize) {
                    RelayResize = 0;
                    if (masterOpen && ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0) ioctl(master, TIOCSWINSZ, &size);
                }
                if (RelayInterrupt) {
                    int signalNumber = RelayInterrupt;
                    RelayInterrupt = 0;
                    if (!exited) {
                        SignalRelayChild(child, signalNumber);
                        if (signalNumber != SIGINT || !IsForegroundTerminal()) stopDeadline = now + 2;
                    }
                }
                if (stopDeadline && now >= stopDeadline && !exited) SignalRelayChild(child, SIGKILL);
                if (masterOpen && !exited && now >= nicknameRefresh && pendingOutput.length < RelayBufferLimit &&
                    parser.state == RelayPlain && parser.utf8Remaining == 0) {
                    @try {
                        NSString *name = CCBridgeTerminalTitleName(provider, launchToken, child);
                        NSString *nickname = name.length > 0 ? CCBridgeComposeTerminalTitle(nil, name) : nil;
                        [parser refreshNickname:nickname output:pendingOutput];
                    } @catch (NSException *exception) {}
                    nicknameRefresh = now + 0.25;
                }

                BOOL readInput = !exited && masterOpen && !stopDeadline && pendingInput.length < RelayBufferLimit;
                BOOL readOutput = masterOpen && pendingOutput.length < RelayBufferLimit;
                struct pollfd descriptors[] = {
                    {.fd = readInput ? STDIN_FILENO : -1, .events = POLLIN},
                    {.fd = masterOpen ? master : -1, .events = (readOutput ? POLLIN : 0) | (pendingInput.length > 0 ? POLLOUT : 0)},
                    {.fd = pendingOutput.length > 0 ? outerOutput : -1, .events = POLLOUT}
                };
                int ready = poll(descriptors, 3, 100);
                if (ready < 0) {
                    if (errno == EINTR) continue;
                    return 1;
                }
                if (!ready && masterOpen && exited && pendingOutput.length == 0 && now >= drainDeadline) {
                    masterOpen = NO;
                    [parser flushTo:pendingOutput];
                }
                uint8_t bytes[8192];
                if (descriptors[0].revents) {
                    ssize_t length = read(STDIN_FILENO, bytes, sizeof(bytes));
                    if (length > 0) [pendingInput appendBytes:bytes length:(NSUInteger)length];
                    else if (length == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)) {
                        SignalRelayChild(child, SIGHUP);
                        stopDeadline = now + 2;
                    }
                }
                if (descriptors[1].revents & POLLOUT && pendingInput.length > 0 && !WriteRelayData(master, pendingInput)) {
                    [pendingInput setLength:0];
                }
                if (readOutput && (descriptors[1].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL))) {
                    ssize_t length = read(master, bytes, sizeof(bytes));
                    if (length > 0) {
                        [parser appendBytes:bytes length:(NSUInteger)length to:pendingOutput];
                        if (exited) drainDeadline = now + 0.5;
                    }
                    else if (length == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)) {
                        masterOpen = NO;
                        [parser flushTo:pendingOutput];
                        if (!exited && !stopDeadline) stopDeadline = now + 2;
                    }
                }
                if (descriptors[2].revents && pendingOutput.length > 0 && !WriteRelayData(outerOutput, pendingOutput)) return 1;
            }
        }
        return WIFSIGNALED(completion) ? 128 + WTERMSIG(completion) : WEXITSTATUS(completion);
    } @finally {
        RestoreOuterTerminal(&original);
        close(outerOutput);
        close(master);
        if (!exited) {
            SignalRelayChild(child, SIGKILL);
            while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
        }
        RestoreRelaySignalActions(previous, actionCount);
        @try { CCBridgeClearTerminalTitleBinding(launchToken); } @catch (NSException *exception) {}
    }
}

int CCPetsRunBridgeTitleRelay(NSArray<NSString *> *arguments) {
    if (arguments.count < 2 || ![@[@"Codex", @"Claude"] containsObject:arguments.firstObject]) return 2;
    // Build argv before forkpty; its child must not call Foundation between fork and exec.
    char **childArguments = calloc(arguments.count, sizeof(*childArguments));
    if (!childArguments) return 1;
    @try {
        for (NSUInteger index = 1; index < arguments.count; index++) {
            const char *argument = arguments[index].UTF8String;
            childArguments[index - 1] = argument ? strdup(argument) : NULL;
            if (!childArguments[index - 1]) return 1;
        }
        return RunRelay(childArguments, arguments.firstObject, CCPetsEnvironmentValue(@"CC_PETS_BRIDGE_TITLE_TOKEN"));
    } @finally {
        for (NSUInteger index = 0; index + 1 < arguments.count; index++) free(childArguments[index]);
        free(childArguments);
    }
}
