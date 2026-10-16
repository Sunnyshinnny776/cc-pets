#import "CCPetsOpenCommand.h"
#import "CCPetsCLISupport.h"
#import "CCPetsL10n.h"
#import "CCPetsMainWindow.h"
#import "CCPetsPaths.h"
#import <sys/file.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

NSString *CCPetsOpenWindowNotificationName(void) {
    return [NSString stringWithFormat:@"com.ccpets.open-main-window.%u", getuid()];
}

// 桌宠是单实例，靠 flock 锁 cc-pets-<uid>.lock；锁被占着就是在运行。探测时拿到锁要马上放掉。
static BOOL PetIsRunning(void) {
    NSString *lockPath = [PetStateDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"cc-pets-%u.lock", getuid()]];
    int lock = open(lockPath.fileSystemRepresentation, O_RDONLY);
    // 锁文件不存在说明桌宠从没跑过；这里不创建，探测不该留下痕迹。
    if (lock < 0) return NO;
    BOOL running = flock(lock, LOCK_SH | LOCK_NB) != 0;
    close(lock);
    return running;
}

// 要启动的 App：优先 ~/Applications 里装好的那份（和 bin/cc-pets 一致），其次包目录里构建出来的。
static NSString *PetApplicationPath(void) {
    NSString *applications = CCPetsEnvironmentValue(@"CC_PETS_APPLICATIONS_DIR") ?:
        [CCPetsHomeDirectory() stringByAppendingPathComponent:@"Applications"];
    NSString *installed = [applications stringByAppendingPathComponent:@"CC Pets.app"];
    if ([NSFileManager.defaultManager fileExistsAtPath:installed]) return installed;
    NSString *executable = CCPetsExecutablePath();
    NSRange built = [executable rangeOfString:@"/.build/release/"];
    if (built.location == NSNotFound) return nil;
    NSString *app = [[executable substringToIndex:NSMaxRange(built)] stringByAppendingPathComponent:@"CC Pets.app"];
    return [NSFileManager.defaultManager fileExistsAtPath:app] ? app : nil;
}

static NSString *PageList(void) {
    return [CCPetsMainWindowPageIDs() componentsJoinedByString:L(@", ")];
}

static NSString *UsageText(void) {
    return [NSString stringWithFormat:@"%@\n\n%@", L(@"Usage: cc-pets open [page]"),
        CCPetsInterpolate(L(@"Pages: {pages}"), @{@"pages": PageList()})];
}

int CCPetsOpenMain(NSArray<NSString *> *arguments) {
    if ([arguments containsObject:@"--help"] || [arguments containsObject:@"-h"]) {
        CCPetsPrintLine(stdout, UsageText());
        return 0;
    }
    if (arguments.count > 1) {
        CCPetsPrintLine(stderr, UsageText());
        return 2;
    }
    NSString *page = arguments.firstObject ?: @"";
    if (page.length > 0 && ![CCPetsMainWindowPageIDs() containsObject:page]) {
        CCPetsPrintLine(stderr, CCPetsInterpolate(L(@"Unknown page: {page}\nPages: {pages}"),
            @{@"page": page, @"pages": PageList()}));
        return 2;
    }

    if (PetIsRunning()) {
        [NSDistributedNotificationCenter.defaultCenter postNotificationName:CCPetsOpenWindowNotificationName()
            object:nil userInfo:@{@"page": page} deliverImmediately:YES];
        // 通知是异步交给 distnoted 的，进程立刻退出可能发不出去。
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        return 0;
    }

    NSString *app = PetApplicationPath();
    if (!app) {
        CCPetsPrintLine(stderr, L(@"CC Pets.app not found. Run cc-pets install first."));
        return 1;
    }
    NSMutableArray<NSString *> *openArguments = [NSMutableArray arrayWithObjects:app, @"--args", @"--open-window", nil];
    if (page.length > 0) [openArguments addObject:page];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
    task.arguments = openArguments;
    // CLAUDE_CONFIG_DIR 是会话级的，泄漏给常驻的桌宠会让它永久只统计这个账号（bin/cc-pets 同理）。
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    [environment removeObjectForKey:@"CLAUDE_CONFIG_DIR"];
    task.environment = environment;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        CCPetsPrintLine(stderr, error.localizedDescription);
        return 1;
    }
    [task waitUntilExit];
    return task.terminationStatus;
}
