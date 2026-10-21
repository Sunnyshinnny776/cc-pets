#import "CCPetsL10n.h"
#import <Cocoa/Cocoa.h>
#import "CCPetsAppDelegate.h"
#import "CCPetsEvents.h"
#import "CCPetsPaths.h"
#import "CCPetsPhrases.h"
#import "CCPetsPreviews.h"
#import "CCPetsQuotaHistory.h"
#import "CCPetsUsage.h"
#import "CCPetsVersion.h"
#import "CCPetsCleanup.h"
#import "CCPetsIntegrations.h"
#import "CCPetsBridgeCLI.h"
#import "CCPetsDoctor.h"
#import "CCPetsOpenCommand.h"
#import "CCPetsPetStore.h"
#import "CCPetsCLISupport.h"
#import "CCPetsTerminalFocus.h"
#import "CCPetsProfiles.h"
#import <sys/file.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // 下面这些都是命令行入口，输出语言跟终端走；真正启动桌宠前再切回 App 的语言规则。
        CCPetsUseCommandLineLanguage(YES);
        if (argc > 1 && (strcmp(argv[1], "doctor") == 0 || strcmp(argv[1], "paths") == 0)) {
            NSMutableArray<NSString *> *arguments = [NSMutableArray array];
            for (int index = 1; index < argc; index++) [arguments addObject:@(argv[index])];
            return CCPetsDoctorMain(arguments);
        }
        if (argc > 1 && strcmp(argv[1], "open") == 0) {
            NSMutableArray<NSString *> *arguments = [NSMutableArray array];
            for (int index = 2; index < argc; index++) [arguments addObject:@(argv[index])];
            return CCPetsOpenMain(arguments);
        }
        if (argc > 1 && strcmp(argv[1], "pet") == 0) {
            NSMutableArray<NSString *> *arguments = [NSMutableArray array];
            for (int index = 2; index < argc; index++) [arguments addObject:@(argv[index])];
            return CCPetsPetStoreMain(arguments);
        }
        if (argc > 1 && strcmp(argv[1], "profile") == 0) {
            NSMutableArray<NSString *> *arguments = [NSMutableArray array];
            for (int index = 2; index < argc; index++) [arguments addObject:@(argv[index])];
            return CCPetsProfileCommandMain(arguments);
        }
        if (argc > 1 && strcmp(argv[1], "--configure-updater") == 0) return ConfigureUpdater();
        // zsh 脚本的文案（scripts/i18n.zsh）：--localize <英文原文> [name=value …]，与 App 共用一张表。
        if (argc > 2 && strcmp(argv[1], "--localize") == 0) {
            NSMutableDictionary<NSString *, NSString *> *values = [NSMutableDictionary dictionary];
            for (int index = 3; index < argc; index++) {
                NSString *pair = @(argv[index]);
                NSRange equals = [pair rangeOfString:@"="];
                if (equals.location == NSNotFound) values[pair] = @"";
                else values[[pair substringToIndex:equals.location]] = [pair substringFromIndex:NSMaxRange(equals)];
            }
            puts(CCPetsInterpolate(CCPetsLocalized(@(argv[2])), values).UTF8String);
            return EXIT_SUCCESS;
        }
        if (argc > 1 && strcmp(argv[1], "bridge") == 0) {
            NSMutableArray<NSString *> *arguments = [NSMutableArray array];
            for (int index = 2; index < argc; index++) [arguments addObject:@(argv[index])];
            return CCBridgeCommandMain(arguments);
        }
        if (argc > 1 && (strcmp(argv[1], "--version") == 0 ||
                         strcmp(argv[1], "-version") == 0 ||
                         strcmp(argv[1], "-v") == 0)) {
            printf("cc-pets %s\n", CC_PETS_VERSION);
            return EXIT_SUCCESS;
        }
        if (argc > 3 && strcmp(argv[1], "--compare-versions") == 0) {
            BOOL valid = NO;
            NSComparisonResult comparison = CompareStableVersions(
                [NSString stringWithUTF8String:argv[2]],
                [NSString stringWithUTF8String:argv[3]],
                &valid);
            if (!valid) return 2;
            printf("%ld\n", (long)comparison);
            return EXIT_SUCCESS;
        }
        if (argc > 3 && strcmp(argv[1], "--restart-after-pid") == 0) {
            pid_t pid = (pid_t)strtol(argv[2], NULL, 10);
            NSString *appPath = [NSString stringWithUTF8String:argv[3]];
            BOOL managed = argc > 4 && strcmp(argv[4], "--managed") == 0;
            return RestartAfterPID(pid, appPath, managed);
        }
        if (argc > 1 && strcmp(argv[1], "--hook") == 0) return RecordHookEvent();
        if (argc > 1 && strcmp(argv[1], "--frontmost-bundle-id") == 0) {
            puts(FrontmostApplicationBundleIdentifier().UTF8String);
            return EXIT_SUCCESS;
        }
        if (argc > 1 && (strcmp(argv[1], "--provider-event") == 0 ||
                         strcmp(argv[1], "provider-event") == 0)) return RecordProviderEvent();
        if (argc > 1 && strcmp(argv[1], "--claude-usage") == 0) return RecordClaudeUsage();
        if (argc > 1 && strcmp(argv[1], "--codex-launch") == 0) return RegisterCodexLaunch();
        // 安装器调用：--install-claude-hooks / --install-codex-hooks <包目录>/.build/release/cc-pets。
        if (argc > 1 && strcmp(argv[1], "--install-claude-hooks") == 0) {
            return InstallClaudeHooks(argc > 2 ? @(argv[2]) : nil);
        }
        if (argc > 1 && strcmp(argv[1], "--install-codex-hooks") == 0) {
            return InstallCodexHooks(argc > 2 ? @(argv[2]) : nil);
        }
        // --uninstall-integrations [--prepare-install] [<shellRC>]
        if (argc > 1 && strcmp(argv[1], "--uninstall-integrations") == 0) {
            BOOL preparing = argc > 2 && strcmp(argv[2], "--prepare-install") == 0;
            int index = preparing ? 3 : 2;
            return UninstallIntegrations(preparing, argc > index ? @(argv[index]) : nil);
        }
        if (argc > 1 && strcmp(argv[1], "--clean") == 0) return CleanCCPetsData(NO);
        if (argc > 1 && strcmp(argv[1], "--purge-data") == 0) return CleanCCPetsData(YES);
        if (argc > 1 && strcmp(argv[1], "--paths") == 0) {
            NSMutableDictionary *paths = [CCPetsDataPaths() mutableCopy];
            paths[@"phrases"] = PetPhrasesFilePath();
            paths[@"petPhrases"] = PetPhrasesPetDirectory();
            NSData *json = [NSJSONSerialization dataWithJSONObject:paths
                options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes
                error:nil];
            if (!json) return EXIT_FAILURE;
            fwrite(json.bytes, 1, json.length, stdout);
            fputc('\n', stdout);
            return EXIT_SUCCESS;
        }
        if (argc > 1 && strcmp(argv[1], "--history") == 0) {
            NSData *json = [NSJSONSerialization dataWithJSONObject:QuotaHistoryDocument()
                options:NSJSONWritingPrettyPrinted error:nil];
            if (!json) return EXIT_FAILURE;
            fwrite(json.bytes, 1, json.length, stdout);
            fputc('\n', stdout);
            return EXIT_SUCCESS;
        }
        if (argc > 2 && strcmp(argv[1], "--render-dashboard") == 0) {
            return RenderQuotaDashboard([NSString stringWithUTF8String:argv[2]]);
        }
        if (argc > 2 && strcmp(argv[1], "--render-status") == 0) {
            return RenderAgentStatusCard([NSString stringWithUTF8String:argv[2]]);
        }
        if (argc > 2 && strcmp(argv[1], "--render-switches") == 0) {
            return RenderMenuSwitches([NSString stringWithUTF8String:argv[2]]);
        }
        // --render-pet <out.png> <sheet.webp> [rowCount]：逐格渲染 PetView 的等价校验基准。
        if (argc > 3 && strcmp(argv[1], "--render-pet") == 0) {
            NSInteger rowCount = argc > 4 ? atoi(argv[4]) : 9;
            return RenderPetSheet([NSString stringWithUTF8String:argv[2]],
                [NSString stringWithUTF8String:argv[3]], rowCount);
        }
        if (argc > 1 && strcmp(argv[1], "--status") == 0) {
            NSDictionary *usage = LatestUsage();
            if (!usage) {
                puts("Codex usage unavailable");
                return EXIT_FAILURE;
            }
            NSDictionary *fiveHour = (id)usage[@"fiveHour"] == NSNull.null ? nil : usage[@"fiveHour"];
            NSDictionary *week = (id)usage[@"week"] == NSNull.null ? nil : usage[@"week"];
            printf("five_hour=%s week=%s\n",
                fiveHour ? [[[fiveHour[@"used_percent"] stringValue] stringByAppendingString:@"%"] UTF8String] : "--",
                week ? [[[week[@"used_percent"] stringValue] stringByAppendingString:@"%"] UTF8String] : "--");
            return EXIT_SUCCESS;
        }

        // 走到这里就要启动桌宠了。拼错的 `--xxx` 原先会被当成"启动"：桌宠已在运行时静默退出，
        // 否则在前台拉起一个桌宠占住终端，两种都让人看不出哪里错了。只拦双横线参数：
        // 单横线的 -psn_* / -NS* / -Apple* 是系统和 Xcode 启动 App 时自己加的。
        for (int index = 1; index < argc; index++) {
            if (strncmp(argv[index], "--", 2) != 0) continue;
            static const char *launchFlags[] = {"--managed", "--standalone", "--preview-dashboard", "--open-window"};
            BOOL known = NO;
            for (size_t flag = 0; flag < sizeof(launchFlags) / sizeof(launchFlags[0]); flag++) {
                if (strcmp(argv[index], launchFlags[flag]) == 0) known = YES;
            }
            if (known) continue;
            fprintf(stderr, "%s\n", [NSString stringWithFormat:L(@"Unknown argument: %@\nRun cc-pets --help for usage."),
                @(argv[index])].UTF8String);
            return 2;
        }

        CCPetsUseCommandLineLanguage(NO);
        NSString *lockName = [NSString stringWithFormat:@"cc-pets-%u.lock", getuid()];
        NSString *lockPath = [PetStateDirectory() stringByAppendingPathComponent:lockName];
        int lock = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR);
        if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0) return EXIT_SUCCESS;
        PruneStaleRuntimeState();

        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        // --open-window [page]：page 省略时开上次看的页面。
        for (int index = 1; index < argc; index++) {
            if (strcmp(argv[index], "--open-window") != 0) continue;
            BOOL hasPage = index + 1 < argc && argv[index + 1][0] != '-';
            delegate.launchWindowPage = hasPage ? @(argv[index + 1]) : @"";
        }
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
        (void)lock;
    }
    return EXIT_SUCCESS;
}
