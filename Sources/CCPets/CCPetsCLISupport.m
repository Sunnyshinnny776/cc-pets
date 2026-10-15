#import "CCPetsCLISupport.h"
#import "CCPetsJSON.h"
#import <mach-o/dyld.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <fcntl.h>
#import <poll.h>
#import <signal.h>
#import <spawn.h>
#import <unistd.h>
#import <errno.h>

extern char **environ;

const int CCPetsRunLaunchFailed = -1;
const int CCPetsRunTimedOut = -2;

void CCPetsPrintLine(FILE *stream, NSString *text) {
    fprintf(stream, "%s\n", text.UTF8String);
}

NSString *CCPetsEnvironmentValue(NSString *name) {
    NSString *value = NSProcessInfo.processInfo.environment[name];
    return value.length > 0 ? value : nil;
}

NSString *CCPetsHomeDirectory(void) {
    return CCPetsEnvironmentValue(@"HOME") ?: NSHomeDirectory();
}

NSString *CCPetsResolvePath(NSString *path) {
    if (![path hasPrefix:@"/"]) {
        path = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingFormat:@"/%@", path];
    }
    NSMutableArray<NSString *> *components = [NSMutableArray array];
    for (NSString *component in [path componentsSeparatedByString:@"/"]) {
        if (component.length == 0 || [component isEqualToString:@"."]) continue;
        if ([component isEqualToString:@".."]) {
            if (components.count > 0) [components removeLastObject];
            continue;
        }
        [components addObject:component];
    }
    return [@"/" stringByAppendingString:[components componentsJoinedByString:@"/"]];
}

NSString *CCPetsRealPath(NSString *path) {
    char resolved[PATH_MAX];
    if (!realpath(path.fileSystemRepresentation, resolved)) return nil;
    return [NSString stringWithUTF8String:resolved];
}

NSString *CCPetsShellQuote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

BOOL CCPetsDirectoryExists(NSString *path) {
    BOOL isDirectory = NO;
    return path.length > 0 && [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory;
}

NSString *CCPetsTildePath(NSString *path) {
    NSString *home = CCPetsHomeDirectory();
    if (![path isKindOfClass:NSString.class]) return path;
    if ([path isEqualToString:home]) return @"~";
    if ([path hasPrefix:[home stringByAppendingString:@"/"]]) {
        return [@"~" stringByAppendingString:[path substringFromIndex:home.length]];
    }
    return path;
}

NSString *CCPetsExecutablePath(void) {
    uint32_t size = PATH_MAX;
    char buffer[PATH_MAX];
    if (_NSGetExecutablePath(buffer, &size) != 0) return NSProcessInfo.processInfo.arguments.firstObject;
    return CCPetsResolvePath([NSString stringWithUTF8String:buffer]);
}

long long CCPetsMilliseconds(void) {
    return (long long)(NSDate.date.timeIntervalSince1970 * 1000.0);
}

NSString *CCPetsInterpolate(NSString *text, NSDictionary<NSString *, id> *values) {
    if (values.count == 0) return text;
    static NSRegularExpression *placeholder;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        placeholder = [NSRegularExpression regularExpressionWithPattern:@"\\{([A-Za-z][A-Za-z0-9_]*)\\}" options:0 error:nil];
    });
    NSMutableString *result = [NSMutableString string];
    __block NSUInteger cursor = 0;
    [placeholder enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length)
        usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
        id value = values[[text substringWithRange:[match rangeAtIndex:1]]];
        if (!value) return;
        [result appendString:[text substringWithRange:NSMakeRange(cursor, match.range.location - cursor)]];
        [result appendString:[value description]];
        cursor = NSMaxRange(match.range);
    }];
    [result appendString:[text substringFromIndex:cursor]];
    return result;
}

#pragma mark - 外部 CLI

NSString *CCPetsClaudeHome(void) {
    return CCPetsEnvironmentValue(@"CLAUDE_CONFIG_DIR") ?: [CCPetsHomeDirectory() stringByAppendingPathComponent:@".claude"];
}

NSString *CCPetsCodexHome(void) {
    return CCPetsEnvironmentValue(@"CODEX_HOME") ?: [CCPetsHomeDirectory() stringByAppendingPathComponent:@".codex"];
}

NSString *CCPetsShimDirectory(void) {
    return CCPetsResolvePath(CCPetsEnvironmentValue(@"CC_PETS_SHIM_DIR") ?:
        [CCPetsHomeDirectory() stringByAppendingPathComponent:@".cc-pets/shims"]);
}

NSString *CCPetsFindRealExecutable(NSString *name, NSString *realBinVariable) {
    NSString *forced = realBinVariable ? CCPetsEnvironmentValue(realBinVariable) : nil;
    if (forced) return forced;
    NSString *shim = CCPetsShimDirectory();
    for (NSString *entry in [CCPetsEnvironmentValue(@"PATH") ?: @"" componentsSeparatedByString:@":"]) {
        if (entry.length == 0) continue;
        NSString *resolvedEntry = CCPetsRealPath(entry) ?: CCPetsResolvePath(entry);
        if ([resolvedEntry isEqualToString:shim]) continue;
        NSString *candidate = [entry stringByAppendingPathComponent:name];
        struct stat info;
        if (stat(candidate.fileSystemRepresentation, &info) != 0) continue;
        if (!S_ISREG(info.st_mode) || (info.st_mode & 0111) == 0) continue;
        // 复制而非软链安装时 shim 可能不在 CC_PETS_SHIM_DIR 里，按包装器的名字再兜一层。
        NSString *real = CCPetsRealPath(candidate);
        if (!real) continue;
        if ([real.stringByDeletingLastPathComponent isEqualToString:shim]) continue;
        if ([real.lastPathComponent hasSuffix:@"-with-pet"]) continue;
        return candidate;
    }
    return nil;
}

static BOOL CLIForced(NSString *realBinVariable) {
    return [CCPetsEnvironmentValue(@"CC_PETS_ASSUME_CLI") isEqualToString:@"1"] ||
        CCPetsEnvironmentValue(realBinVariable) != nil;
}

BOOL CCPetsClaudeCLIInstalled(void) {
    return CLIForced(@"CLAUDE_REAL_BIN") || CCPetsDirectoryExists(CCPetsClaudeHome()) ||
        CCPetsFindRealExecutable(@"claude", nil) != nil;
}

BOOL CCPetsCodexCLIInstalled(void) {
    return CLIForced(@"CODEX_REAL_BIN") || CCPetsDirectoryExists(CCPetsCodexHome()) ||
        CCPetsFindRealExecutable(@"codex", nil) != nil;
}

#pragma mark - 文件

BOOL CCPetsWriteFileAtomically(NSString *path, NSString *text, mode_t mode, NSString **errorMessage) {
    NSString *temporaryPath = [NSString stringWithFormat:@"%@.%d.cc-pets.tmp", path, getpid()];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    int descriptor = open(temporaryPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode);
    BOOL written = descriptor >= 0;
    const uint8_t *bytes = data.bytes;
    NSUInteger offset = 0;
    while (written && offset < data.length) {
        ssize_t count = write(descriptor, bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) written = NO;
        else offset += (NSUInteger)count;
    }
    int failure = written ? 0 : errno;
    if (descriptor >= 0) close(descriptor);
    if (written && rename(temporaryPath.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
        failure = errno;
        written = NO;
    }
    if (!written) {
        unlink(temporaryPath.fileSystemRepresentation);
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"%@: %s", path, strerror(failure)];
        return NO;
    }
    chmod(path.fileSystemRepresentation, mode);
    return YES;
}

id CCPetsReadConfig(NSString *path, NSString **errorMessage) {
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&readError];
    if (!data) {
        if (errorMessage) *errorMessage = readError.localizedDescription;
        return nil;
    }
    id parsed = CCPetsJSONParse(data, errorMessage);
    if (!parsed) return nil;
    return [parsed isKindOfClass:CCPetsJSONObject.class] ? parsed : NSNull.null;
}

#pragma mark - 子进程

static char **CStringArray(NSArray<NSString *> *strings) {
    char **array = calloc(strings.count + 1, sizeof(char *));
    for (NSUInteger index = 0; index < strings.count; index++) array[index] = strdup(strings[index].UTF8String);
    return array;
}

static void FreeCStringArray(char **array) {
    if (!array) return;
    for (char **cursor = array; *cursor; cursor++) free(*cursor);
    free(array);
}

int CCPetsRun(NSString *executable, NSArray<NSString *> *arguments, NSString *directory,
    NSDictionary<NSString *, NSString *> *environment, NSTimeInterval timeout,
    NSString **output, NSString **errorOutput) {
    int outPipe[2], errPipe[2];
    if (pipe(outPipe) != 0) return CCPetsRunLaunchFailed;
    if (pipe(errPipe) != 0) {
        close(outPipe[0]);
        close(outPipe[1]);
        return CCPetsRunLaunchFailed;
    }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, outPipe[0]);
    posix_spawn_file_actions_addclose(&actions, errPipe[0]);
    if (directory) posix_spawn_file_actions_addchdir_np(&actions, directory.fileSystemRepresentation);

    char **argv = CStringArray([@[executable] arrayByAddingObjectsFromArray:arguments]);
    char **envp = NULL;
    if (environment) {
        NSMutableArray<NSString *> *pairs = [NSMutableArray array];
        [environment enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
            [pairs addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
        }];
        envp = CStringArray(pairs);
    }
    pid_t pid = 0;
    int spawned = [executable containsString:@"/"]
        ? posix_spawn(&pid, executable.fileSystemRepresentation, &actions, NULL, argv, envp ?: environ)
        : posix_spawnp(&pid, executable.UTF8String, &actions, NULL, argv, envp ?: environ);
    posix_spawn_file_actions_destroy(&actions);
    FreeCStringArray(argv);
    FreeCStringArray(envp);
    close(outPipe[1]);
    close(errPipe[1]);
    if (spawned != 0) {
        close(outPipe[0]);
        close(errPipe[0]);
        return CCPetsRunLaunchFailed;
    }

    NSMutableData *outData = [NSMutableData data];
    NSMutableData *errData = [NSMutableData data];
    struct pollfd descriptors[2] = {{outPipe[0], POLLIN, 0}, {errPipe[0], POLLIN, 0}};
    NSDate *deadline = timeout > 0 ? [NSDate dateWithTimeIntervalSinceNow:timeout] : nil;
    BOOL timedOut = NO;
    int remaining = 2;
    while (remaining > 0) {
        int wait = -1;
        if (deadline) {
            NSTimeInterval left = deadline.timeIntervalSinceNow;
            if (left <= 0) {
                timedOut = YES;
                break;
            }
            wait = (int)(left * 1000) + 1;
        }
        int ready = poll(descriptors, 2, wait);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0) break;
        for (int index = 0; index < 2; index++) {
            if (descriptors[index].fd < 0 || descriptors[index].revents == 0) continue;
            char buffer[16384];
            ssize_t count = read(descriptors[index].fd, buffer, sizeof buffer);
            if (count > 0) {
                [(index == 0 ? outData : errData) appendBytes:buffer length:(NSUInteger)count];
            } else if (count == 0 || errno != EINTR) {
                close(descriptors[index].fd);
                descriptors[index].fd = -1;
                remaining--;
            }
        }
    }
    if (timedOut) kill(pid, SIGKILL);
    for (int index = 0; index < 2; index++) {
        if (descriptors[index].fd >= 0) close(descriptors[index].fd);
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    if (output) *output = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] ?: @"";
    if (errorOutput) *errorOutput = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] ?: @"";
    if (timedOut) return CCPetsRunTimedOut;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return 128 + (WIFSIGNALED(status) ? WTERMSIG(status) : 0);
}

BOOL CCPetsSpawnDetached(NSString *executable, NSArray<NSString *> *arguments) {
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSID);
    char **argv = CStringArray([@[executable] arrayByAddingObjectsFromArray:arguments]);
    pid_t pid = 0;
    int spawned = posix_spawn(&pid, executable.fileSystemRepresentation, &actions, &attributes, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    FreeCStringArray(argv);
    // 不等待：子进程脱离会话后由 launchd 收养，父进程退出时不会留下僵尸。
    return spawned == 0;
}
