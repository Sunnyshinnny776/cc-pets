#import <Foundation/Foundation.h>
#import "CCPetsL10n.h"
#import "CCPetsPhrases.h"
#import "CCPetsVersion.h"

// 多语言冒烟测试。用法：l10n-test <Resources 目录> <模式>
//   en / zh-Hans：test.sh 以对应的 CC_PETS_LANGUAGE 各跑一遍，覆盖查表、格式串、默认台词
//   added-language：CC_PETS_LOCALIZATION_DIR 指向一个临时目录，里面除了中文表还放了一张
//                   假的 ja 表，验证"新增语言只加文件"：自动发现、语言名、查表、Release 段落
// 源码里写英文原文：英文界面原样输出，其他语言查 <语言>.lproj/Localizable.strings。

static BOOL Check(BOOL condition, NSString *label) {
    if (!condition) NSLog(@"失败：%@", label);
    return condition;
}

static BOOL DefaultPhrasesValid(NSString *resources, NSString *name) {
    NSString *text = [NSString stringWithContentsOfFile:[resources stringByAppendingPathComponent:name]
        encoding:NSUTF8StringEncoding error:nil];
    if (text.length == 0) {
        NSLog(@"%@ 不存在或为空", name);
        return NO;
    }
    // 默认台词必须能原样通过校验：一句超长都会让那句静默失效。
    NSArray<PetPhraseIssue *> *issues = PetPhraseValidateText(text);
    for (PetPhraseIssue *issue in issues) NSLog(@"%@ 第 %ld 行：%@", name, (long)issue.line, issue.message);
    return issues.count == 0;
}

static BOOL CheckResolution(void) {
    BOOL ok = YES;
    NSArray *supported = @[@"en", @"ja", @"zh-Hans"];
    ok &= Check([CCPetsResolveLanguageAmong(@"en", @[@"zh-Hans-CN"], supported) isEqualToString:@"en"],
        @"显式偏好优先");
    ok &= Check([CCPetsResolveLanguageAmong(@"system", @[@"zh-Hans-CN", @"en"], supported)
        isEqualToString:@"zh-Hans"], @"跟随系统：前缀匹配");
    ok &= Check([CCPetsResolveLanguageAmong(nil, @[@"fr-FR", @"zh-Hant-TW", @"en-US"], supported)
        isEqualToString:@"zh-Hans"], @"跟随系统：只比主语言，按系统顺序");
    ok &= Check([CCPetsResolveLanguageAmong(@"ja_JP.UTF-8", @[], supported) isEqualToString:@"ja"],
        @"POSIX 写法");
    ok &= Check([CCPetsResolveLanguageAmong(nil, @[@"fr-FR", @"de-DE"], supported) isEqualToString:@"en"],
        @"都匹配不上时用源语言");
    ok &= Check([CCPetsResolveLanguageAmong(@"ja", @[@"zh-Hans"], @[@"en", @"zh-Hans"])
        isEqualToString:@"zh-Hans"], @"不支持的偏好退回跟随系统");
    return ok;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            NSLog(@"用法: l10n-test <Resources 目录> <en|zh-Hans|added-language>");
            return 2;
        }
        NSString *resources = [NSString stringWithUTF8String:argv[1]];
        NSString *mode = [NSString stringWithUTF8String:argv[2]];
        BOOL ok = CheckResolution();

        if ([mode isEqualToString:@"added-language"]) {
            ok &= Check([CCPetsSupportedLanguages() isEqualToArray:@[@"en", @"ja", @"zh-Hans"]],
                @"按 .lproj 自动发现语言");
            ok &= Check([CCPetsCurrentLanguage() isEqualToString:@"ja"], @"CC_PETS_LANGUAGE=ja_JP 匹配到 ja");
            ok &= Check([CCPetsLanguageDisplayName(@"ja") isEqualToString:@"日本語"], @"语言名来自表");
            ok &= Check([CCPetsLanguageDisplayName(@"en") isEqualToString:@"English"], @"源语言名");
            ok &= Check([L(@"Quit CC Pets") isEqualToString:@"終了"], @"新语言查表");
            ok &= Check([L(@"Help") isEqualToString:@"Help"], @"新语言漏翻时退回英文");
            BOOL truncated = NO;
            NSArray *notes = ReleaseNoteHighlightsForLanguage(
                @"## English\n- en\n## 简体中文\n- zh\n## 日本語\n- ja\n", @"ja", 3, 40, &truncated);
            ok &= Check([notes isEqualToArray:@[@"ja"]], @"Release 段落标题来自表");
        } else {
            BOOL source = [mode isEqualToString:@"en"];
            ok &= Check([CCPetsSupportedLanguages() containsObject:@"zh-Hans"], @"发现中文表");
            ok &= Check(CCPetsLanguageIsSource() == source, @"CC_PETS_LANGUAGE 生效");
            NSString *status = [NSString stringWithFormat:L(@"%1$@: %2$@ for %3$ld min."),
                @"Codex", @"X", 5L];
            if (source) {
                ok &= Check([L(@"Quit CC Pets") isEqualToString:@"Quit CC Pets"], @"英文原样输出");
                ok &= Check([status isEqualToString:@"Codex: X for 5 min."], @"带位置参数的格式串");
            } else {
                ok &= Check([L(@"Quit CC Pets") isEqualToString:@"退出桌宠"], @"中文查表");
                ok &= Check([status isEqualToString:@"Codex 已X 5 分钟。"], @"带位置参数的格式串");
                ok &= Check([CCPetsLanguageDisplayName(@"zh-Hans") isEqualToString:@"简体中文"], @"中文语言名");
            }
            ok &= Check([L(@"Text missing from the table") isEqualToString:@"Text missing from the table"],
                @"缺翻译时退回英文原文");

            // 每种语言的默认台词都要能原样通过校验。
            for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:resources error:nil]) {
                if ([name hasPrefix:@"phrases.default."] && [name hasSuffix:@".txt"]) {
                    ok &= DefaultPhrasesValid(resources, name);
                }
            }
            ok &= Check(PetPhraseMaxLengthForText(@"Done. Take a breather.") == PetPhraseMaxLatinLength,
                @"纯拉丁文字用宽松上限");
            ok &= Check(PetPhraseMaxLengthForText(@"搞定了 OK") == PetPhraseMaxLength, @"含汉字用原上限");

            BOOL truncated = NO;
            NSString *bilingual = @"## English\n\n- English item\n\n## 简体中文\n\n- 中文一\n";
            ok &= Check([ReleaseNoteHighlightsForLanguage(bilingual, @"en", 3, 40, &truncated)
                isEqualToArray:@[@"English item"]], @"英文界面只取 English 段");
            ok &= Check([ReleaseNoteHighlightsForLanguage(bilingual, @"zh-Hans", 3, 40, &truncated)
                isEqualToArray:@[@"中文一"]], @"中文界面只取简体中文段");
            ok &= Check([ReleaseNoteHighlightsForLanguage(@"- only item\n", @"en", 3, 40, &truncated)
                isEqualToArray:@[]], @"没有 English 段落时不读取全文");
        }

        if (!ok) return 1;
        NSLog(@"多语言测试通过（%@）", mode);
    }
    return 0;
}
