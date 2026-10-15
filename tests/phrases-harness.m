#import <Foundation/Foundation.h>
#import "CCPetsPhrases.h"

static NSInteger failures = 0;
static void Check(BOOL condition, NSString *what) {
    if (condition) return;
    fprintf(stderr, "断言失败: %s\n", what.UTF8String);
    failures++;
}

static void WriteUserPhrases(NSString *path, NSString *content) {
    [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    // mtime 只有秒级精度，连着写同一路径可能拿到同一个时间戳，热加载会误判成没变。
    // 测试里显式刷新时间戳，绕开这个精度问题。
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: NSDate.date}
        ofItemAtPath:path error:nil];
}

// 默认词库的全文。所有"从一份好文件出发再改坏"的用例都拿它当底。
static NSString *DefaultText(void) {
    return [NSString stringWithContentsOfFile:PetPhrasesDefaultFilePath()
        encoding:NSUTF8StringEncoding error:nil];
}

// 把某一节的台词全删掉，只留小节头。
static NSString *TextWithEmptySection(NSString *text, NSString *tag) {
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    NSString *header = [NSString stringWithFormat:@"[%@]", tag];
    BOOL inside = NO;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:header]) { inside = YES; [kept addObject:line]; continue; }
        if (inside) {
            if ([line hasPrefix:@"["]) inside = NO;
            else continue;
        }
        [kept addObject:line];
    }
    return [kept componentsJoinedByString:@"\n"];
}

static NSInteger CountIssues(NSArray<PetPhraseIssue *> *issues, PetPhraseIssueLevel level) {
    NSInteger count = 0;
    for (PetPhraseIssue *issue in issues) if (issue.level == level) count++;
    return count;
}

int main(void) {
    @autoreleasepool {
        NSString *path = NSProcessInfo.processInfo.environment[@"CC_PETS_PHRASES_FILE"];
        Check(path.length > 0, @"测试必须通过 CC_PETS_PHRASES_FILE 隔离用户词库");
        if (path.length == 0) return 1;

        NSString *defaults = DefaultText();
        Check(defaults.length > 0, @"默认词库文件必须存在且非空");
        if (defaults.length == 0) return 1;

        // ---- 默认词库本身必须是完全合格的 ----
        //
        // 它是用户看到的第一份文件，也是"恢复默认"的落点。它自己带着提示或错误的话，
        // 用户一保存就会看到一堆红字，会以为是自己改坏的。
        NSArray<PetPhraseIssue *> *shipped = PetPhraseValidateText(defaults);
        Check(shipped.count == 0, @"默认词库必须零提示零错误");
        for (PetPhraseIssue *issue in shipped) {
            fprintf(stderr, "  默认词库问题: 第 %ld 行 %s\n", (long)issue.line,
                issue.message.UTF8String);
        }
        // 每个标签都要有内容，否则该情境默认即哑。
        for (NSString *tag in PetPhraseAllTags()) {
            NSString *sample = PetPhraseForTagInText(tag, defaults, @{
                @"quota5h": @"12%", @"resetTime": @"18:30", @"toolName": @"Bash",
                @"sessionMin": @"95", @"failCount": @"3", @"hour": @"2"});
            Check(sample.length > 0, [NSString stringWithFormat:@"默认词库缺少可用台词: %@", tag]);
        }

        // ---- 文件即全部：没有内置兜底 ----
        //
        // 这是这一版最核心的语义。删掉一节就是那个情境不吭声，绝不能悄悄回落到
        // 代码里的某份词库——那正是 merge/replace 让人看不懂的根源。
        WriteUserPhrases(path, @"[idle]\n只有这一句。\n");
        Check([PetPhraseForTag(PetPhraseTagIdle, @{}) isEqualToString:@"只有这一句。"],
            @"文件里写了什么就说什么");
        Check(PetPhraseForTag(PetPhraseTagDone, @{}) == nil,
            @"文件里没有的情境必须一句都取不到，不能回落到内置词库");

        // replace 这个概念已经删掉了。老写法现在只是一句取不到小节的散句，
        // 不能再有任何特殊含义。
        WriteUserPhrases(path, @"replace\n[idle]\n只有这一句。\n");
        Check([PetPhraseForTag(PetPhraseTagIdle, @{}) isEqualToString:@"只有这一句。"],
            @"裸 replace 行不应影响解析");
        Check(PetPhraseForTag(PetPhraseTagDone, @{}) == nil, @"replace 已无特殊含义");

        // ---- 用户词条是数据，不是格式串 ----
        WriteUserPhrases(path, @"[idle]\n100%% 完成 %@ 了\n");
        Check([PetPhraseForTag(PetPhraseTagIdle, @{}) isEqualToString:@"100%% 完成 %@ 了"],
            @"用户词条里的 %% 和 %@ 必须原样输出，绝不能进 stringWithFormat:");

        // ---- 槽位 ----
        WriteUserPhrases(path, @"[idle]\n还剩 {quota5h}。\n");
        Check(PetPhraseForTag(PetPhraseTagIdle, @{}) == nil,
            @"槽位没值时整条作废，不能吐出花括号");
        Check([PetPhraseForTag(PetPhraseTagIdle, @{@"quota5h": @"9%"})
            isEqualToString:@"还剩 9%。"], @"给了值就正常填充");

        // ---- 行尾注释 ----
        //
        // 小节头带行尾注释必须能认出来。犯过一次：不认的话整个模板静默失效，
        // 用户改完什么都不会发生，连报错都没有。
        WriteUserPhrases(path, @"[idle]   # 闲着没事\n发呆。   # 这是注释\n");
        Check([PetPhraseForTag(PetPhraseTagIdle, @{}) isEqualToString:@"发呆。"],
            @"小节头和台词的行尾注释都要正确剥掉");
        // 只在 # 前是空白时才截断，台词里的 "进度#1" 不能被误伤。
        WriteUserPhrases(path, @"[idle]\n进度#1 完成\n");
        Check([PetPhraseForTag(PetPhraseTagIdle, @{}) isEqualToString:@"进度#1 完成"],
            @"紧贴文字的 # 不是注释");

        // ---- 超长与未知标签 ----
        WriteUserPhrases(path, @"[idle]\n这句特别特别特别特别特别特别特别特别长超过三十个字了真的很长啊\n短的。\n");
        Check([PetPhraseForTag(PetPhraseTagIdle, @{}) isEqualToString:@"短的。"],
            @"超长的丢掉，同节其他句子不受影响");
        WriteUserPhrases(path, @"[oops]\n乱写的。\n");
        Check(PetPhraseForTag(@"oops", @{}) == nil, @"未知标签取不到东西");

        // ---- 校验器：state_ 是硬性的，情绪句不是 ----
        //
        // 状态卡副行的正文只有这一个来源，空了卡片就残了，所以拦下不给保存。
        // 情绪句空了只是那个情境不吭声，是用户的合法选择，只提示。
        NSArray<PetPhraseIssue *> *issues =
            PetPhraseValidateText(TextWithEmptySection(defaults, PetPhraseTagStateThinking));
        Check(PetPhraseIssuesHaveError(issues), @"state_ 小节空了必须报错");
        Check(CountIssues(issues, PetPhraseIssueLevelError) == 1, @"只应为空掉的那一节报错");

        // 整节被删掉（连小节头一起）和"节还在但空了"要分开报：用户要做的动作不一样，
        // 前者得把 [state_xxx] 那行加回来，后者只要补一句台词。
        NSString *withoutSection = [defaults stringByReplacingOccurrencesOfString:
            @"[state_notification]" withString:@"# 被用户删掉了"];
        issues = PetPhraseValidateText(withoutSection);
        Check(PetPhraseIssuesHaveError(issues), @"state_ 小节头被删掉必须报错");
        Check(CountIssues(issues, PetPhraseIssueLevelError) == 1, @"只应为被删掉的那一节报错");
        BOOL saysCannotDelete = NO;
        for (PetPhraseIssue *issue in issues) {
            if (issue.level == PetPhraseIssueLevelError &&
                [issue.message containsString:@"不能删"]) saysCannotDelete = YES;
        }
        Check(saysCannotDelete, @"整节被删时要说清楚这一节不能删，而不是笼统说至少留一句");
        // 22 个标签行全都不能删，不只是 state_ 那组。
        NSString *stripped = defaults;
        for (NSString *tag in PetPhraseAllTags()) {
            stripped = [stripped stringByReplacingOccurrencesOfString:
                [NSString stringWithFormat:@"[%@]", tag] withString:@"# 删了"];
        }
        Check(CountIssues(PetPhraseValidateText(stripped), PetPhraseIssueLevelError) ==
            (NSInteger)PetPhraseAllTags().count, @"每个被删掉的标签行都要报一条错");

        issues = PetPhraseValidateText(TextWithEmptySection(defaults, PetPhraseTagIdle));
        Check(!PetPhraseIssuesHaveError(issues), @"情绪句留空不应拦保存");
        Check(CountIssues(issues, PetPhraseIssueLevelWarning) == 1, @"情绪句留空应给一条提示");

        // 标签行本身一律不能删，情绪句也不例外——留空和把那行删掉是两回事。
        // 犯过一次：删掉 [idle] 整行照样能保存，用户以为只是提示。
        NSString *withoutIdle = [defaults stringByReplacingOccurrencesOfString:
            @"[idle]" withString:@"# 被用户删掉了"];
        issues = PetPhraseValidateText(withoutIdle);
        Check(PetPhraseIssuesHaveError(issues), @"情绪句的标签行被删掉必须拦下保存");
        Check(CountIssues(issues, PetPhraseIssueLevelError) == 1, @"只应为被删掉的那一节报错");
        for (PetPhraseIssue *issue in issues) {
            if (issue.level != PetPhraseIssueLevelError) continue;
            Check([issue.message containsString:@"标签不能删"],
                @"要说清楚是标签行不能删，而不是笼统说至少留一句");
        }

        // 槽位名拼错最难自查：句子看着没毛病，运行时被整条跳过。必须报出来。
        issues = PetPhraseValidateText([defaults stringByAppendingString:
            @"\n[idle]\n还剩 {quotaLeft}。\n"]);
        Check(CountIssues(issues, PetPhraseIssueLevelWarning) == 1, @"拼错的槽位名要报提示");
        Check(!PetPhraseIssuesHaveError(issues), @"拼错槽位不拦保存");

        // 未知小节名会让它下面的台词全部无处安放，必须报出来。
        issues = PetPhraseValidateText([defaults stringByAppendingString:
            @"\n[state_typo]\n没人会说这句。\n"]);
        Check(CountIssues(issues, PetPhraseIssueLevelWarning) == 1, @"未知小节名要报提示");

        // ---- 被删掉的标签行要能补回原位 ----
        //
        // 光报错是把人卡死：编辑器里已经看不到那一行，用户既不知道少的是哪个，也不知道
        // 该写成什么样。补回来之后必须和原文一字不差，否则等于悄悄改坏了用户的文件。
        NSArray<NSString *> *restored = nil;
        NSString *trimmed = [defaults stringByTrimmingCharactersInSet:
            NSCharacterSet.newlineCharacterSet];
        for (NSString *tag in @[PetPhraseTagIdle, PetPhraseTagStateNotification,
                PetPhraseTagStateFailed, PetPhraseTagQuotaLow]) {
            NSMutableArray<NSString *> *kept = [NSMutableArray array];
            NSString *header = [NSString stringWithFormat:@"[%@]", tag];
            for (NSString *line in [trimmed componentsSeparatedByString:@"\n"]) {
                if (![line hasPrefix:header]) [kept addObject:line];
            }
            NSString *broken = [kept componentsJoinedByString:@"\n"];
            Check(PetPhraseIssuesHaveError(PetPhraseValidateText(broken)),
                [NSString stringWithFormat:@"删掉 [%@] 标签行应当拦下保存", tag]);
            NSString *fixed = PetPhraseTextWithRestoredTags(broken, &restored);
            Check(restored.count == 1 && [restored.firstObject isEqualToString:tag],
                [NSString stringWithFormat:@"应当只补回 [%@]", tag]);
            // 标签被删而台词还在时，台词会并进上一节。标签必须插回那串台词前面，
            // 插到别处的话台词就跟错了主人。
            Check([fixed isEqualToString:trimmed],
                [NSString stringWithFormat:@"补回 [%@] 之后应当和原文一字不差", tag]);
        }

        // 标签连着台词一起被删：只补标签，不能顺手把上一节的台词抢过来。
        NSMutableArray<NSString *> *quotaRemoved = [NSMutableArray array];
        BOOL inside = NO;
        for (NSString *line in [trimmed componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"[quota_low]"]) { inside = YES; continue; }
            if (inside) { if ([line hasPrefix:@"["]) inside = NO; else continue; }
            [quotaRemoved addObject:line];
        }
        NSString *fixed = PetPhraseTextWithRestoredTags(
            [quotaRemoved componentsJoinedByString:@"\n"], &restored);
        Check(restored.count == 1, @"整节被删也只补回标签");
        Check(!PetPhraseIssuesHaveError(PetPhraseValidateText(fixed)),
            @"补回标签后情绪句留空不该再拦保存");
        Check(PetPhraseForTagInText(PetPhraseTagLongSession, fixed, @{@"sessionMin": @"95"}).length > 0,
            @"补回标签不能把上一节的台词抢走");

        // 一次删好几个也要全补回来。
        NSMutableArray<NSString *> *multi = [NSMutableArray array];
        for (NSString *line in [trimmed componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"[idle]"] || [line hasPrefix:@"[state_notification]"]) continue;
            [multi addObject:line];
        }
        NSString *multiFixed = PetPhraseTextWithRestoredTags(
            [multi componentsJoinedByString:@"\n"], &restored);
        Check(restored.count == 2, @"删几个补几个");
        Check([multiFixed isEqualToString:trimmed], @"多个标签补回后也应和原文一致");

        // 文件本来就好好的，不该被动一个字。
        NSString *untouched = PetPhraseTextWithRestoredTags(trimmed, &restored);
        Check(restored.count == 0, @"完好的文件不应补任何标签");
        Check([untouched isEqualToString:trimmed], @"完好的文件不应被改动");

        // ---- 试说一句读的是没保存的文本，且不污染正式说话的去重记忆 ----
        WriteUserPhrases(path, @"[idle]\n磁盘上的。\n");
        Check([PetPhraseForTagInText(PetPhraseTagIdle, @"[idle]\n编辑器里的。\n", @{})
            isEqualToString:@"编辑器里的。"], @"试说一句必须读传进来的文本，不是磁盘");
        Check([PetPhraseForTag(PetPhraseTagIdle, @{}) isEqualToString:@"磁盘上的。"],
            @"试说一句不应改变磁盘词库的取句结果");

        // ---- 首次启动会把默认词库拷出来 ----
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        Check(PetPhraseForTag(PetPhraseTagIdle, @{}) == nil, @"没有文件时一句都取不到");
        Check(PetPhrasesEnsureFileExists(), @"应当能从默认词库拷出用户词库");
        Check([NSFileManager.defaultManager fileExistsAtPath:path], @"拷完文件必须真的存在");
        Check(PetPhraseForTag(PetPhraseTagIdle, @{}).length > 0, @"拷完就能正常取句");
        // 已存在时不覆盖：用户的改动比默认内容重要。
        WriteUserPhrases(path, @"[idle]\n我改过的。\n");
        Check(PetPhrasesEnsureFileExists(), @"已存在时也返回可用");
        Check([PetPhraseForTag(PetPhraseTagIdle, @{}) isEqualToString:@"我改过的。"],
            @"已存在的用户词库绝不能被默认词库覆盖");

        // ---- 宠物专属词库 ----
        //
        // 通用词库是所有宠物的兜底，专属词库只写想改的小节，按小节整体接管。
        NSString *petDirectory = NSProcessInfo.processInfo.environment[@"CC_PETS_PHRASES_PET_DIR"];
        Check(petDirectory.length > 0, @"测试必须隔离宠物专属词库目录");
        [NSFileManager.defaultManager createDirectoryAtPath:petDirectory
            withIntermediateDirectories:YES attributes:nil error:nil];

        // petID 转文件名：冒号要没，内置素材的扩展名要没，中文原样留着——
        // 用户得能在 Finder 里认出哪份是哪只的。
        Check([PetPhrasesKeyForPetID(@"external:团子") isEqualToString:@"external-团子"],
            @"external petID 应转成 external-<名字>");
        Check([PetPhrasesKeyForPetID(@"builtin:ByteMochi.webp") isEqualToString:@"builtin-ByteMochi"],
            @"内置素材的扩展名不该进文件名");
        Check([PetPhrasesKeyForPetID(@"builtin:ByteMochi.PNG") isEqualToString:@"builtin-ByteMochi"],
            @"扩展名判断要忽略大小写");
        // 斜杠会让路径跑出 speech 目录，前导点会把文件藏起来——两者都必须被挡住。
        Check(![PetPhrasesKeyForPetID(@"external:../../etc/passwd") containsString:@"/"],
            @"petID 里的斜杠不能进文件名");
        Check(![PetPhrasesKeyForPetID(@"external:.hidden") containsString:@"-."],
            @"前导点要换掉，否则文件在 Finder 里根本看不见");
        Check(PetPhrasesKeyForPetID(@"") == nil, @"空 petID 没有对应的词库文件");
        Check(PetPhrasesFilePathForPetID(nil) == nil, @"没有 petID 时不该给出路径");

        // 没设宠物时行为和从前完全一致：只认通用词库。
        PetPhrasesSetCurrentPetID(nil);
        WriteUserPhrases(path, @"[idle]\n通用闲话。\n[done]\n通用完工。\n");
        Check([PetPhraseForTag(PetPhraseTagIdle, @{}) isEqualToString:@"通用闲话。"],
            @"没有当前宠物时只认通用词库");

        // 设了宠物但它没有专属文件：同样全部走通用。
        PetPhrasesSetCurrentPetID(@"external:团子");
        Check([PetPhraseForTag(PetPhraseTagIdle, @{}) isEqualToString:@"通用闲话。"],
            @"没有专属文件时全部回落到通用");

        // 专属文件只写一节：写了的那节整节接管，没写的照旧走通用。
        NSString *petPath = PetPhrasesFilePathForPetID(@"external:团子");
        Check([petPath hasPrefix:petDirectory], @"专属词库必须落在隔离目录里");
        WriteUserPhrases(petPath, @"[idle]\n想吃糯米团…\n");
        Check([PetPhraseForTag(PetPhraseTagIdle, @{}) isEqualToString:@"想吃糯米团…"],
            @"专属词库里写了的小节要整节接管");
        Check([PetPhraseForTag(PetPhraseTagDone, @{}) isEqualToString:@"通用完工。"],
            @"专属词库里没写的小节要回落到通用");

        // 接管是整节的，不是按行合并：通用那节一句都不能混进来。
        WriteUserPhrases(petPath, @"[idle]\n想吃糯米团…\n兜里有点东西。\n");
        for (NSInteger attempt = 0; attempt < 20; attempt++) {
            NSString *spoken = PetPhraseForTag(PetPhraseTagIdle, @{});
            Check(![spoken isEqualToString:@"通用闲话。"],
                @"专属接管一节之后，通用的那节一句都不该出现");
        }

        // 写了标签却不写台词 = 这只宠物在这个情境闭嘴。判据是"这一节在不在"，
        // 不是"有没有内容"——否则用户没有任何写法能表达"闭嘴"。
        WriteUserPhrases(petPath, @"[idle]\n");
        Check(PetPhraseForTag(PetPhraseTagIdle, @{}) == nil,
            @"专属词库里的空小节表示闭嘴，不能回落到通用");

        // 切换宠物要立刻换一份词库。只比 mtime 的话这里会拿着上一只的台词。
        NSString *otherPath = PetPhrasesFilePathForPetID(@"external:小炭");
        WriteUserPhrases(otherPath, @"[idle]\n日之呼吸。\n");
        PetPhrasesSetCurrentPetID(@"external:小炭");
        Check([PetPhraseForTag(PetPhraseTagIdle, @{}) isEqualToString:@"日之呼吸。"],
            @"切换宠物之后必须换成它自己的词库");
        PetPhrasesSetCurrentPetID(@"external:团子");
        Check(PetPhraseForTag(PetPhraseTagIdle, @{}) == nil, @"切回去要拿回原来那份");

        // 专属词库的校验规则松：缺小节是常态（缺就回落），不该报错。
        NSArray<PetPhraseIssue *> *petIssues =
            PetPhraseValidateTextForPet(@"[idle]\n就改这一句。\n");
        Check(!PetPhraseIssuesHaveError(petIssues), @"专属词库缺小节不是错误");
        Check(petIssues.count == 0, @"只写一节的专属词库应当零提示");
        Check(!PetPhraseIssuesHaveError(PetPhraseValidateTextForPet(@"")),
            @"空的专属词库是合法的：全部回落到通用");
        // state_ 那组在专属词库里也可以整节不写。
        Check(!PetPhraseIssuesHaveError(PetPhraseValidateTextForPet(@"[state_thinking]\n嗯…\n")),
            @"专属词库里只写一个 state_ 小节不该报错");
        // 逐行的那些照样要查：超长、槽位拼错、小节名写错。
        Check(PetPhraseValidateTextForPet(@"[idle]\n还剩 {quota5j}。\n").count == 1,
            @"专属词库里的槽位拼错照样要提示");
        Check(PetPhraseValidateTextForPet(@"[oops]\n乱写的。\n").count > 0,
            @"专属词库里的未知小节名照样要提示");
        // 通用词库的规则一个字都没松。
        Check(PetPhraseIssuesHaveError(PetPhraseValidateText(@"[idle]\n就改这一句。\n")),
            @"通用词库缺小节仍然是错误");

        // 编辑器靠它判断"这一节是不是被专属接管了"，判据必须和取词一致。
        Check(PetPhraseTextContainsTag(@"[idle]\n", PetPhraseTagIdle),
            @"空小节也算写了这一节");
        Check(!PetPhraseTextContainsTag(@"[idle]\n话。\n", PetPhraseTagDone),
            @"没写的小节就是没写");

        // 编辑器的"填入默认模板"往专属页填的是整份**注释状态**的默认台词：用户看得见
        // 每一节能写什么，而注释一行都不算数，所以填完之后仍然全部回落到通用。
        // 直接填未注释的完整默认台词是错的——那样 22 节全被接管，再也不会回落。
        NSMutableString *commented = [NSMutableString string];
        for (NSString *line in [defaults componentsSeparatedByString:@"\n"]) {
            if (line.length == 0) { [commented appendString:@"\n"]; continue; }
            [commented appendFormat:[line hasPrefix:@"#"] ? @"%@\n" : @"# %@\n", line];
        }
        for (NSString *tag in PetPhraseAllTags()) {
            Check(!PetPhraseTextContainsTag(commented, tag), [NSString stringWithFormat:
                @"注释掉的默认模板不该接管任何小节: %@", tag]);
        }
        WriteUserPhrases(petPath, commented);
        PetPhrasesSetCurrentPetID(@"external:团子");
        Check([PetPhraseForTag(PetPhraseTagIdle, @{}) isEqualToString:@"通用闲话。"],
            @"填入注释模板之后必须仍然全部回落到通用");
        Check(!PetPhraseIssuesHaveError(PetPhraseValidateTextForPet(commented)),
            @"注释模板本身必须能通过专属词库的校验");
        // 去掉某一节的注释，只有那一节归专属管，其余照旧回落。
        NSString *enabled = [commented stringByReplacingOccurrencesOfString:
            @"# [idle]" withString:@"[idle]"];
        enabled = [enabled stringByReplacingOccurrencesOfString:@"# 发会儿呆。"
            withString:@"专属发呆。"];
        WriteUserPhrases(petPath, enabled);
        Check([PetPhraseForTag(PetPhraseTagIdle, @{}) isEqualToString:@"专属发呆。"],
            @"去掉注释的那一节应当归专属管");
        Check([PetPhraseForTag(PetPhraseTagDone, @{}) isEqualToString:@"通用完工。"],
            @"仍然注释着的小节照旧回落到通用");

        PetPhrasesSetCurrentPetID(nil);

        if (failures > 0) {
            fprintf(stderr, "词库测试失败 %ld 项\n", (long)failures);
            return 1;
        }
        printf("台词词库与校验器测试通过\n");
    }
    return 0;
}
