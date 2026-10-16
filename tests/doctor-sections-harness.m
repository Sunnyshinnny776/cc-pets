#import <Foundation/Foundation.h>
#import "CCPetsDoctor.h"

// doctor 结构化结果测试。主窗口诊断页直接渲染 CCPetsDoctorSections()，不经过 CLI 文本，
// 这里守住它的形状：每节有标题和结果数组，每项的 level 只取四种之一、标题非空、fix 若有
// 必须是非空字符串；报告文本逐项包含标题与修复命令，失败判定与 ❌ 的出现一致。
//
// 由 test.sh 在 doctor_env 隔离环境里运行，不读用户真实的 Claude / Codex 配置。

static BOOL Check(BOOL condition, NSString *label) {
    if (!condition) NSLog(@"失败：%@", label);
    return condition;
}

static BOOL IsNonEmptyString(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0;
}

// 标题里提到 needle 的结果（PATH 检查会把挡在 shim 前面的目录写进标题）。
static NSDictionary *ResultMentioning(NSArray<NSDictionary *> *sections, NSString *needle) {
    for (NSDictionary *section in sections) {
        for (NSDictionary *result in section[@"results"]) {
            if ([result[@"title"] containsString:needle]) return result;
        }
    }
    return nil;
}

// shadow 模式：test.sh 把一个放了假 codex 的目录排在 shim 目录前面。终端版（CLI）应当报警告；
// App 版读的是桌宠进程的 PATH，不判对错，不能出现这条警告，只给一条提示。
static int RunShadowCheck(NSString *shadowDirectory) {
    NSString *name = shadowDirectory.lastPathComponent;
    NSDictionary *cli = ResultMentioning(CCPetsDoctorSections(), name);
    BOOL ok = Check([cli[@"level"] isEqualToString:@"warn"], @"终端版：挡在 shim 前面的目录报警告");
    ok &= Check(ResultMentioning(CCPetsDoctorSectionsForApp(), name) == nil, @"App 版：不按桌宠进程的 PATH 报警告");
    BOOL hinted = NO;
    for (NSDictionary *section in CCPetsDoctorSectionsForApp()) {
        for (NSDictionary *result in section[@"results"]) {
            if ([result[@"level"] isEqualToString:@"info"] && [result[@"title"] containsString:@"cc-pets doctor"]) hinted = YES;
        }
    }
    ok &= Check(hinted, @"App 版：提示去终端运行 cc-pets doctor");
    if (!ok) return 1;
    printf("doctor PATH 顺序检查在主窗口不误报测试通过\n");
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 2 && strcmp(argv[1], "shadow") == 0) return RunShadowCheck(@(argv[2]));
        NSArray<NSDictionary *> *sections = CCPetsDoctorSections();
        NSString *report = CCPetsDoctorReport(sections);
        NSSet<NSString *> *levels = [NSSet setWithArray:@[@"ok", @"warn", @"fail", @"info"]];
        BOOL ok = Check(sections.count >= 4, @"至少有程序、Claude Code、Codex、Shell 四节");
        NSUInteger failures = 0, warnings = 0;
        for (NSDictionary *section in sections) {
            ok &= Check(IsNonEmptyString(section[@"title"]), @"每节都有标题");
            ok &= Check([report containsString:[@"\n" stringByAppendingString:section[@"title"]]],
                @"报告里有每节的标题");
            NSArray *results = section[@"results"];
            ok &= Check([results isKindOfClass:NSArray.class] && results.count > 0,
                [NSString stringWithFormat:@"%@ 有结果数组", section[@"title"]]);
            for (NSDictionary *result in results) {
                NSString *label = [NSString stringWithFormat:@"%@ / %@", section[@"title"], result[@"title"]];
                ok &= Check([levels containsObject:result[@"level"]], [label stringByAppendingString:@" 的 level 合法"]);
                ok &= Check(IsNonEmptyString(result[@"title"]), [label stringByAppendingString:@" 标题非空"]);
                ok &= Check(result[@"fix"] == nil || IsNonEmptyString(result[@"fix"]),
                    [label stringByAppendingString:@" 的 fix 为空或非空字符串"]);
                ok &= Check([report containsString:result[@"title"]], [label stringByAppendingString:@" 出现在报告里"]);
                if (result[@"fix"]) {
                    ok &= Check([report containsString:[@"→ " stringByAppendingString:result[@"fix"]]],
                        [label stringByAppendingString:@" 的修复命令出现在报告里"]);
                }
                if ([result[@"level"] isEqualToString:@"fail"]) failures++;
                if ([result[@"level"] isEqualToString:@"warn"]) warnings++;
            }
        }
        ok &= Check(CCPetsDoctorHasFailures(sections) == (failures > 0), @"失败判定与 fail 项一致");
        ok &= Check([report containsString:@"❌"] == (failures > 0), @"报告里的 ❌ 与 fail 项一致");
        // 测试环境里 harness 不在 npm 包目录下，版本比对必然报警告，至少能覆盖一条带 fix 的项。
        ok &= Check(warnings + failures > 0, @"隔离环境下至少有一条警告或错误");
        ok &= Check(![report hasSuffix:@"\n"], @"报告不含末尾换行，由 CLI 打印时补");
        ok &= Check(![report containsString:NSHomeDirectory()], @"报告不含 home 绝对路径");
        if (!ok) return 1;
        printf("doctor 结构化结果测试通过\n");
    }
    return 0;
}
