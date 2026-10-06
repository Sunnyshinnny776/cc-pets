#import "CCPetsPhrases.h"
#import "CCPetsL10n.h"

NSString *const PetPhraseTagDone = @"done";
NSString *const PetPhraseTagFail = @"fail";
NSString *const PetPhraseTagQuotaLow = @"quota_low";
NSString *const PetPhraseTagLateNight = @"late_night";
NSString *const PetPhraseTagLongSession = @"long_session";
NSString *const PetPhraseTagWake = @"wake";
NSString *const PetPhraseTagIdle = @"idle";
NSString *const PetPhraseTagClickHeart = @"click_heart";
NSString *const PetPhraseTagClickAnnoyed = @"click_annoyed";

NSString *const PetPhraseTagStateStarting = @"state_starting";
NSString *const PetPhraseTagStateIdle = @"state_idle";
NSString *const PetPhraseTagStateThinking = @"state_thinking";
NSString *const PetPhraseTagStateAutoReview = @"state_auto_review";
NSString *const PetPhraseTagStateApproval = @"state_approval";
NSString *const PetPhraseTagStateSubagent = @"state_subagent";
NSString *const PetPhraseTagStateTool = @"state_tool";
NSString *const PetPhraseTagStateToolBash = @"state_tool_bash";
NSString *const PetPhraseTagStateToolEdit = @"state_tool_edit";
NSString *const PetPhraseTagStateToolRead = @"state_tool_read";
NSString *const PetPhraseTagStateToolDone = @"state_tool_done";
NSString *const PetPhraseTagStateToolFailed = @"state_tool_failed";
NSString *const PetPhraseTagStateCompleted = @"state_completed";
NSString *const PetPhraseTagStateFailed = @"state_failed";
NSString *const PetPhraseTagStateNotification = @"state_notification";

const NSUInteger PetPhraseMaxLength = 30;
const NSUInteger PetPhraseMaxLatinLength = 40;

// 气泡最宽 300pt、13pt 字号：汉字一个顶一个字宽，30 个刚好；英文字母大约半个字宽，
// 同样宽度能放 40 个上下。按"有没有中日韩字符"二选一，不做逐字加权——加权之后用户
// 没法对着报错数出自己超了多少。
NSUInteger PetPhraseMaxLengthForText(NSString *text) {
    static NSCharacterSet *wide;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *set = [NSMutableCharacterSet new];
        [set addCharactersInRange:NSMakeRange(0x1100, 0x0100)];  // 谚文字母
        [set addCharactersInRange:NSMakeRange(0x2E80, 0xA4D0 - 0x2E80)]; // 中日韩部首到彝文
        [set addCharactersInRange:NSMakeRange(0xAC00, 0xD7A4 - 0xAC00)]; // 谚文音节
        [set addCharactersInRange:NSMakeRange(0xF900, 0x0200)];  // 兼容汉字
        [set addCharactersInRange:NSMakeRange(0xFF00, 0x0061)];  // 全角 ASCII
        wide = set;
    });
    return [text rangeOfCharacterFromSet:wide].location == NSNotFound
        ? PetPhraseMaxLatinLength : PetPhraseMaxLength;
}
// 最近说过的这么多条不再重复。模板库不大，靠这个把主观重复感压下去。
static const NSUInteger PetPhraseRecentMemory = 12;

NSArray<NSString *> *PetPhraseSlotNames(void) {
    static NSArray<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[@"quota5h", @"resetTime", @"toolName", @"sessionMin", @"failCount", @"hour"];
    });
    return names;
}

NSString *PetPhrasesFilePath(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"CC_PETS_PHRASES_FILE"];
    if (override.length > 0) return override.stringByStandardizingPath;
    return [NSHomeDirectory() stringByAppendingPathComponent:@".cc-pets/speech.txt"];
}

NSString *PetPhrasesPetDirectory(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"CC_PETS_PHRASES_PET_DIR"];
    if (override.length > 0) return override.stringByStandardizingPath;
    return [NSHomeDirectory() stringByAppendingPathComponent:@".cc-pets/speech"];
}

// 文件名安全化。斜杠和冒号会让路径跑到别处去，控制字符在 Finder 里根本看不见，
// 前导点会把文件藏起来——用户看不见的文件等于不存在，他会以为自己写的没保存上。
static NSString *PetPhrasesSafeFileComponent(NSString *name) {
    NSMutableString *safe = [NSMutableString string];
    for (NSUInteger index = 0; index < name.length; index++) {
        unichar character = [name characterAtIndex:index];
        if (character == '/' || character == ':' || character == '\\' || character < 0x20) {
            [safe appendString:@"_"];
            continue;
        }
        [safe appendFormat:@"%C", character];
    }
    // "." 和 ".." 是目录本身，拼出来的路径会指向 speech 目录而不是文件。
    if ([safe isEqualToString:@"."] || [safe isEqualToString:@".."]) return @"_";
    if ([safe hasPrefix:@"."]) [safe replaceCharactersInRange:NSMakeRange(0, 1) withString:@"_"];
    // 素材名理论上可以任意长，而文件名有 255 字节上限。中文一个字三字节，截到 60 个字符
    // 稳稳落在限内；截断带来的重名概率不值得再挂个哈希后缀去防。
    if (safe.length > 60) return [safe substringToIndex:60];
    return safe;
}

NSString *PetPhrasesKeyForPetID(NSString *petID) {
    if (petID.length == 0) return nil;
    NSString *scheme = @"";
    NSString *name = petID;
    NSRange colon = [petID rangeOfString:@":"];
    if (colon.location != NSNotFound) {
        scheme = [petID substringToIndex:colon.location];
        name = [petID substringFromIndex:colon.location + 1];
    }
    // 内置素材的 petID 是文件名，扩展名对用户没有任何意义，留着只会让 builtin-默认.webp.txt
    // 这种双扩展名看起来像出了错。
    if ([scheme isEqualToString:@"builtin"]) {
        NSString *extension = name.pathExtension.lowercaseString;
        if ([extension isEqualToString:@"webp"] || [extension isEqualToString:@"png"]) {
            name = name.stringByDeletingPathExtension;
        }
    }
    if (name.length == 0) return nil;
    NSString *safe = PetPhrasesSafeFileComponent(name);
    if (safe.length == 0) return nil;
    if (scheme.length == 0) return safe;
    return [NSString stringWithFormat:@"%@-%@", PetPhrasesSafeFileComponent(scheme), safe];
}

NSString *PetPhrasesFilePathForPetID(NSString *petID) {
    NSString *key = PetPhrasesKeyForPetID(petID);
    if (key.length == 0) return nil;
    return [PetPhrasesPetDirectory() stringByAppendingPathComponent:
        [key stringByAppendingPathExtension:@"txt"]];
}

// 当前宠物。取词层唯一的外部状态，见头文件里为什么不走参数。
static NSString *PetPhrasesCurrentPet;

void PetPhrasesSetCurrentPetID(NSString *petID) {
    PetPhrasesCurrentPet = petID.length > 0 ? [petID copy] : nil;
}

NSString *PetPhrasesCurrentPetID(void) {
    return PetPhrasesCurrentPet;
}

NSString *PetPhrasesCurrentPetFilePath(void) {
    return PetPhrasesFilePathForPetID(PetPhrasesCurrentPet);
}

// 每种界面语言一份默认词库：phrases.default.<语言>.txt（zh-Hans、en…）。找不到返回 nil。
static NSString *PetPhrasesBundledDefaultPath(NSString *language) {
    NSString *name = [@"phrases.default." stringByAppendingString:language];
    NSString *bundled = [NSBundle.mainBundle pathForResource:name ofType:@"txt"];
    if (bundled.length > 0) return bundled;
    // 直接跑 .build/release/cc-pets（没有 app bundle）时退到可执行文件旁边，
    // 否则开发期跑起来一句台词都没有，会被误当成解析出了问题。
    NSString *executable = NSBundle.mainBundle.executablePath.stringByDeletingLastPathComponent;
    NSString *path = [executable stringByAppendingPathComponent:
        [name stringByAppendingPathExtension:@"txt"]];
    return [NSFileManager.defaultManager fileExistsAtPath:path] ? path : nil;
}

// 当前语言没有默认台词（翻译只做了界面）时退回源语言那份。
NSString *PetPhrasesDefaultFilePath(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"CC_PETS_PHRASES_DEFAULT_FILE"];
    if (override.length > 0) return override.stringByStandardizingPath;
    NSString *path = PetPhrasesBundledDefaultPath(CCPetsCurrentLanguage()) ?:
        PetPhrasesBundledDefaultPath(CCPetsSourceLanguage);
    if (path.length > 0) return path;
    NSString *executable = NSBundle.mainBundle.executablePath.stringByDeletingLastPathComponent;
    return [executable stringByAppendingPathComponent:
        [NSString stringWithFormat:@"phrases.default.%@.txt", CCPetsSourceLanguage]];
}

BOOL PetPhrasesAdoptLanguageDefaults(void) {
    // 测试指定了默认词库时只有那一份，没有"另一种语言"可比。
    if (NSProcessInfo.processInfo.environment[@"CC_PETS_PHRASES_DEFAULT_FILE"].length > 0) return NO;
    NSString *path = PetPhrasesFilePath();
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSString *currentPath = PetPhrasesDefaultFilePath();
    NSString *currentText = [NSString stringWithContentsOfFile:currentPath
        encoding:NSUTF8StringEncoding error:nil];
    if (text.length == 0 || currentText.length == 0 || [text isEqualToString:currentText]) return NO;
    for (NSString *language in CCPetsSupportedLanguages()) {
        NSString *otherPath = PetPhrasesBundledDefaultPath(language);
        if (otherPath.length == 0 || [otherPath isEqualToString:currentPath]) continue;
        NSString *otherText = [NSString stringWithContentsOfFile:otherPath
            encoding:NSUTF8StringEncoding error:nil];
        if (![text isEqualToString:otherText]) continue;
        return [currentText writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    return NO;
}

BOOL PetPhrasesEnsureFileExists(void) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *path = PetPhrasesFilePath();
    if ([manager fileExistsAtPath:path]) return YES;
    NSString *defaultText = [NSString stringWithContentsOfFile:PetPhrasesDefaultFilePath()
        encoding:NSUTF8StringEncoding error:nil];
    if (defaultText.length == 0) return NO;
    [manager createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil];
    return [defaultText writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// 标签清单。顺序就是默认模板里的顺序，校验提示按这个顺序报，
// 用户对着文件从上往下找得到。
NSArray<NSString *> *PetPhraseStateTags(void) {
    static NSArray<NSString *> *tags;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tags = @[PetPhraseTagStateStarting, PetPhraseTagStateIdle, PetPhraseTagStateThinking,
            PetPhraseTagStateTool, PetPhraseTagStateToolBash, PetPhraseTagStateToolEdit,
            PetPhraseTagStateToolRead, PetPhraseTagStateToolDone, PetPhraseTagStateToolFailed,
            PetPhraseTagStateSubagent, PetPhraseTagStateApproval, PetPhraseTagStateAutoReview,
            PetPhraseTagStateCompleted, PetPhraseTagStateFailed, PetPhraseTagStateNotification];
    });
    return tags;
}

NSArray<NSString *> *PetPhraseAllTags(void) {
    static NSArray<NSString *> *tags;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *all = [@[PetPhraseTagIdle, PetPhraseTagDone, PetPhraseTagFail,
            PetPhraseTagWake, PetPhraseTagLateNight, PetPhraseTagLongSession,
            PetPhraseTagQuotaLow] mutableCopy];
        [all addObjectsFromArray:PetPhraseStateTags()];
        // 互动标签最初就是追加到升级用户文件末尾的；稳定顺序必须与磁盘迁移结果一致，
        // 否则删除标签后的“原位恢复”会跨过全部 state_ 小节，插到错误位置。
        [all addObjectsFromArray:@[PetPhraseTagClickHeart, PetPhraseTagClickAnnoyed]];
        tags = all;
    });
    return tags;
}

NSString *PetPhraseTagDescription(NSString *tag) {
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            PetPhraseTagIdle: L(@"idle"), PetPhraseTagDone: L(@"Task done"),
            PetPhraseTagFail: L(@"repeated failures"), PetPhraseTagWake: L(@"back after a long break"),
            PetPhraseTagLateNight: L(@"working late at night"), PetPhraseTagLongSession: L(@"long session"),
            PetPhraseTagQuotaLow: L(@"quota running low"),
            PetPhraseTagClickHeart: L(@"happy after a few clicks"),
            PetPhraseTagClickAnnoyed: L(@"annoyed after too many clicks"),
            PetPhraseTagStateStarting: L(@"Starting"), PetPhraseTagStateIdle: L(@"Idle"),
            PetPhraseTagStateThinking: L(@"Thinking"), PetPhraseTagStateTool: L(@"using a tool"),
            PetPhraseTagStateToolBash: L(@"Running a command"), PetPhraseTagStateToolEdit: L(@"Editing files"),
            PetPhraseTagStateToolRead: L(@"Looking things up"), PetPhraseTagStateToolDone: L(@"step done"),
            PetPhraseTagStateToolFailed: L(@"Tool failed"), PetPhraseTagStateSubagent: L(@"Subagent working"),
            PetPhraseTagStateApproval: L(@"Awaiting approval"), PetPhraseTagStateAutoReview: L(@"Auto-reviewing"),
            PetPhraseTagStateCompleted: L(@"Task completed"), PetPhraseTagStateFailed: L(@"Task failed"),
            PetPhraseTagStateNotification: L(@"Needs attention"),
        };
    });
    return map[tag] ?: tag;
}

// 去掉行尾注释。
//
// 必须支持行尾注释，否则模板里 "[state_subagent]  # 子 Agent 工作中" 这样的小节名
// 会因为结尾不是 ] 而不被识别，它下面的台词全部无处安放被丢掉——整个文件静默失效，
// 用户取消注释后什么都不会发生，连报错都没有。
//
// 只在 # 前面是空白（或位于行首）时才截断：这样台词里写 "进度#1" 之类不会被误伤。
static NSString *PetLineWithoutTrailingComment(NSString *line) {
    if ([line hasPrefix:@"#"]) return @"";
    NSRange search = NSMakeRange(0, line.length);
    while (search.length > 0) {
        NSRange hash = [line rangeOfString:@"#" options:0 range:search];
        if (hash.location == NSNotFound) break;
        unichar previous = [line characterAtIndex:hash.location - 1];
        if (previous == ' ' || previous == '\t') {
            return [[line substringToIndex:hash.location] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceCharacterSet];
        }
        NSUInteger next = hash.location + 1;
        search = NSMakeRange(next, line.length - next);
    }
    return line;
}

// 用户词库：~/.cc-pets/speech.txt
//
//   # 井号开头是注释
//   [fail]
//   又挂了？我陪你看看。
//   [done]
//   收工！
//
// 逐行解析，容错到底：不认识的小节名跳过、空行跳过、超长的丢掉，
// 单行有问题绝不影响其他行。这是选纯文本而不是 JSON 的全部理由。
//
// 文件即全部：没有 merge、没有 replace。删掉一节就是那个情境不吭声。
//
// 解析和校验共用这一个函数：校验器要报"第几行为什么被丢了"，如果它自己再写一套
// 判断，两边迟早会漂移——用户看到"校验通过"而桌宠照样不说话，是最糟的一种 bug。
// 所以这里把每一次丢弃都通过 onDrop 回调抛出去，校验器只负责把它们变成人话。
static void FlushOrphans(void (^onDrop)(NSInteger line, NSString *reason),
    NSInteger *start, NSInteger *count) {
    if (*count == 0) return;
    if (onDrop) {
        onDrop(*start, *count == 1 ? L(@"This line isn't under any [tag] and won't be used") :
            [NSString stringWithFormat:L(@"%ld lines here aren't under any [tag] and won't be used"),
                (long)*count]);
    }
    *count = 0;
}

static NSDictionary<NSString *, NSArray<NSString *> *> *ParsePhrasesText(NSString *text,
    void (^onDrop)(NSInteger line, NSString *reason)) {
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *groups =
        [NSMutableDictionary dictionary];
    NSString *current = nil;
    // 小节名拼错时，它下面的台词全都无处安放。但那不是"每一行都错了"——
    // 错的只有小节名那一行。逐行报的话，一个拼错的小节能刷出十几条一模一样的提示，
    // 真正该改的那一行反而被淹掉。所以只报小节头，底下的行安静吞掉。
    BOOL insideUnknownSection = NO;
    // 连续的"无处安放"的句子只报一条。删掉一个小节头，它下面那一串台词会全部变成
    // 散句——逐行报的话，一个错误能刷出十几条提示，把真正该看的那条错误挤下去。
    NSInteger orphanStart = 0, orphanCount = 0;
    NSArray<NSString *> *rawLines = [text componentsSeparatedByCharactersInSet:
        NSCharacterSet.newlineCharacterSet];
    NSSet<NSString *> *known = [NSSet setWithArray:PetPhraseAllTags()];
    for (NSUInteger index = 0; index < rawLines.count; index++) {
        NSInteger lineNumber = (NSInteger)index + 1;
        NSString *line = [rawLines[index] stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceCharacterSet];
        line = PetLineWithoutTrailingComment(line);
        if (line.length == 0) continue;
        if ([line hasPrefix:@"["] && [line hasSuffix:@"]"]) {
            FlushOrphans(onDrop, &orphanStart, &orphanCount);
            NSString *tag = [line substringWithRange:NSMakeRange(1, line.length - 2)];
            tag = [tag stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (![known containsObject:tag]) {
                current = nil;
                insideUnknownSection = YES;
                if (onDrop) onDrop(lineNumber,
                    [NSString stringWithFormat:L(@"There's no [%@] tag; the lines below won't be used"), tag]);
                continue;
            }
            insideUnknownSection = NO;
            current = tag;
            if (!groups[current]) groups[current] = [NSMutableArray array];
            continue;
        }
        // 还没进任何小节的散句无处安放，直接跳过，不猜用户想放哪。
        if (current.length == 0) {
            if (!insideUnknownSection) {
                if (orphanCount == 0) orphanStart = lineNumber;
                orphanCount++;
            }
            continue;
        }
        NSUInteger maxLength = PetPhraseMaxLengthForText(line);
        if (line.length > maxLength) {
            if (onDrop) onDrop(lineNumber, [NSString stringWithFormat:
                L(@"This line has %lu characters, over the %lu limit"), (unsigned long)line.length,
                (unsigned long)maxLength]);
            continue;
        }
        [groups[current] addObject:line];
    }
    FlushOrphans(onDrop, &orphanStart, &orphanCount);
    return groups;
}

BOOL PetPhrasesEnsureInteractionSections(void) {
    NSString *path = PetPhrasesFilePath();
    NSString *text = [NSString stringWithContentsOfFile:path
        encoding:NSUTF8StringEncoding error:nil];
    NSString *defaultText = [NSString stringWithContentsOfFile:PetPhrasesDefaultFilePath()
        encoding:NSUTF8StringEncoding error:nil];
    if (text.length == 0 || defaultText.length == 0) return NO;

    NSDictionary<NSString *, NSArray<NSString *> *> *existing = ParsePhrasesText(text, nil);
    NSDictionary<NSString *, NSArray<NSString *> *> *defaults = ParsePhrasesText(defaultText, nil);
    NSArray<NSString *> *interactionTags =
        @[PetPhraseTagClickHeart, PetPhraseTagClickAnnoyed];
    NSMutableString *updated = [text mutableCopy];
    NSMutableString *addition = [NSMutableString string];
    for (NSString *tag in interactionTags) {
        // 字典里存在空数组也表示用户已经拥有并可能主动清空了这个小节，不能覆盖。
        if (existing[tag] != nil) continue;
        NSArray<NSString *> *lines = defaults[tag];
        if (lines.count == 0) continue;
        [addition appendFormat:@"\n\n[%@]  # %@\n", tag, PetPhraseTagDescription(tag)];
        [addition appendString:[lines componentsJoinedByString:@"\n"]];
    }
    if (addition.length == 0) return YES;
    while ([updated hasSuffix:@"\n"]) [updated deleteCharactersInRange:
        NSMakeRange(updated.length - 1, 1)];
    [updated appendString:addition];
    [updated appendString:@"\n"];
    return [updated writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// 一个缓存槽：只存 path / stamp / groups 三样。用可变字典而不是结构体，
// 纯粹是为了让 ARC 全程管住这几个对象——结构体里存对象要么写 __unsafe_unretained
// 再自己找地方续命，要么加 __strong 让结构体不能当静态变量用，两条路都比这难读。
//
// 路径也参与失效判断：切换宠物时专属词库换的是路径而不是内容，只比 mtime 的话会一直
// 拿着上一只宠物的台词——两只宠物的文件 mtime 恰好相同并不罕见（同一次编辑里先后存的）。
//
// 从磁盘读。mtime 没变就直接用上次的结果——取句子本来就低频，这点开销可以忽略，
// 换来的是用户改完保存立刻生效，不用重启桌宠。
static NSDictionary<NSString *, NSArray<NSString *> *> *LoadPhrasesAtPath(NSString *path,
    NSMutableDictionary *slot) {
    if (path.length == 0) return nil;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    NSDate *stamp = attributes[NSFileModificationDate];
    if (stamp && slot[@"stamp"] && [stamp isEqualToDate:slot[@"stamp"]] &&
        [path isEqualToString:slot[@"path"]]) {
        return slot[@"groups"];
    }
    [slot removeAllObjects];
    slot[@"path"] = path;
    if (!stamp) return nil;
    slot[@"stamp"] = stamp;

    NSString *text = [NSString stringWithContentsOfFile:path
        encoding:NSUTF8StringEncoding error:nil];
    if (text.length == 0) return nil;
    NSDictionary *groups = ParsePhrasesText(text, nil);
    slot[@"groups"] = groups;
    return groups;
}

static NSDictionary<NSString *, NSArray<NSString *> *> *LoadUserPhrases(void) {
    static NSMutableDictionary *slot;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ slot = [NSMutableDictionary dictionary]; });
    return LoadPhrasesAtPath(PetPhrasesFilePath(), slot);
}

// 当前宠物的专属词库。没设过宠物、或这只宠物没有专属文件时返回 nil——
// 两种情况的结果都是"全部走通用"，调用方不需要区分。
static NSDictionary<NSString *, NSArray<NSString *> *> *LoadPetPhrases(void) {
    static NSMutableDictionary *slot;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ slot = [NSMutableDictionary dictionary]; });
    return LoadPhrasesAtPath(PetPhrasesCurrentPetFilePath(), slot);
}

// 模板本身是数据，不是格式串。**绝不能把它交给 stringWithFormat:**——
// 用户词库里一个 %@ 就会让桌宠当场崩溃。这里只做白名单内的字面量替换。
static NSString *FillSlots(NSString *template, NSDictionary<NSString *, NSString *> *slots) {
    NSMutableString *result = [template mutableCopy];
    for (NSString *name in PetPhraseSlotNames()) {
        NSString *token = [NSString stringWithFormat:@"{%@}", name];
        if ([result rangeOfString:token].location == NSNotFound) continue;
        NSString *value = slots[name];
        // 该填的槽位没给值：整条作废。宁可不说，也不能吐出 "额度只剩 {quota5h} 了"。
        if (value.length == 0) return nil;
        [result replaceOccurrencesOfString:token withString:value
            options:NSLiteralSearch range:NSMakeRange(0, result.length)];
    }
    return result;
}

// 候选就是文件里那一节，没有别的来源。
//
// 两层：这只宠物的专属词库里**有这一节**就整节接管，通用词库那节一句都不参与；
// 没有这一节才落到通用。判据是 entries != nil 而不是 count > 0——专属文件里写了
// 标签却不写台词，是用户在明确表达"这只宠物在这个情境闭嘴"，那时必须返回空，
// 落回通用的话这个表达就没有任何写法能实现了。
static NSArray<NSString *> *CandidatesForTag(NSString *tag) {
    NSArray *entries = LoadPetPhrases()[tag];
    if (entries == nil) entries = LoadUserPhrases()[tag];
    if (![entries isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (id entry in (NSArray *)entries) {
        // 解析时已逐行校验过，这里再挡一道，防止将来换了来源出岔子。
        if (![entry isKindOfClass:NSString.class]) continue;
        NSString *text = entry;
        if (text.length == 0 || text.length > PetPhraseMaxLengthForText(text)) continue;
        [result addObject:text];
    }
    return result;
}

// 从候选里挑一条填好槽位的。抽出来是为了让"试说一句"能对着还没保存的文本走同一条路。
static NSString *PickFromCandidates(NSArray<NSString *> *candidates,
    NSDictionary<NSString *, NSString *> *slots, BOOL rememberRecent) {
    if (candidates.count == 0) return nil;

    // 最近说过的先排除。全被排除掉时（词条太少）就放开限制，总比不说话强。
    static NSMutableArray<NSString *> *recent;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ recent = [NSMutableArray array]; });

    NSMutableArray<NSString *> *pool = [NSMutableArray array];
    for (NSString *text in candidates) {
        if (!rememberRecent || ![recent containsObject:text]) [pool addObject:text];
    }
    if (pool.count == 0) [pool addObjectsFromArray:candidates];

    // 槽位填不上的条目要跳过，所以随机打乱后依次试，而不是一把梭。
    NSMutableArray<NSString *> *shuffled = [pool mutableCopy];
    for (NSUInteger index = shuffled.count; index > 1; index--) {
        NSUInteger swap = arc4random_uniform((uint32_t)index);
        [shuffled exchangeObjectAtIndex:index - 1 withObjectAtIndex:swap];
    }
    for (NSString *template in shuffled) {
        NSString *text = FillSlots(template, slots);
        if (text.length == 0) continue;
        if (rememberRecent) {
            [recent addObject:template];
            while (recent.count > PetPhraseRecentMemory) [recent removeObjectAtIndex:0];
        }
        return text;
    }
    return nil;
}

NSString *PetPhraseForTag(NSString *tag, NSDictionary<NSString *, NSString *> *slots) {
    if (tag.length == 0) return nil;
    return PickFromCandidates(CandidatesForTag(tag), slots, YES);
}

// 试说一句：对着编辑器里还没保存的文本取。不计入"最近说过"，
// 否则用户连点几下预览就会把正式说话的去重记忆挤空。
NSString *PetPhraseForTagInText(NSString *tag, NSString *text,
    NSDictionary<NSString *, NSString *> *slots) {
    if (tag.length == 0 || text.length == 0) return nil;
    NSArray *entries = ParsePhrasesText(text, nil)[tag];
    if (![entries isKindOfClass:NSArray.class]) return nil;
    return PickFromCandidates(entries, slots, NO);
}

@implementation PetPhraseIssue
@end

static PetPhraseIssue *MakeIssue(NSInteger line, PetPhraseIssueLevel level, NSString *message) {
    PetPhraseIssue *issue = [PetPhraseIssue new];
    issue.line = line;
    issue.level = level;
    issue.message = message;
    return issue;
}

// 保存时校验。分两级：
//   错误 —— 只有一种，state_ 小节空了。状态卡副行没地方取文案，卡片会残掉，
//           所以直接拦下不给保存。
//   提示 —— 其余全部。情绪句整节没有是合法的（就是那个情境不吭声），
//           被丢掉的行也只影响自己，说清楚就行，不挡用户。
// 小节头写成默认词库里的样子：[tag] 补空格对齐到 24 列，再跟中文说明。
static NSString *SectionHeaderLine(NSString *tag) {
    NSString *head = [NSString stringWithFormat:@"[%@]", tag];
    NSMutableString *line = [head mutableCopy];
    while (line.length < 24) [line appendString:@" "];
    [line appendFormat:@"# %@", PetPhraseTagDescription(tag)];
    return line;
}

// 这一行是不是会被解析器当成台词（既不是空行、注释，也不是小节头）。
static BOOL IsContentLine(NSString *rawLine) {
    NSString *line = PetLineWithoutTrailingComment([rawLine stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceCharacterSet]);
    if (line.length == 0) return NO;
    return !([line hasPrefix:@"["] && [line hasSuffix:@"]"]);
}

// 这一行是不是 tag 的小节头。
static BOOL IsHeaderLine(NSString *rawLine, NSString *tag) {
    NSString *line = PetLineWithoutTrailingComment([rawLine stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceCharacterSet]);
    return [line isEqualToString:[NSString stringWithFormat:@"[%@]", tag]];
}

// 标签名或括号被删掉一部分时，默认小节头后面的中文说明仍能唯一标识它属于哪个情境：
//   [click_hear]  # 连续点击后开心
//   click_heart]  # 连续点击后开心
//   []             # 连续点击后开心
// 这些都应在原行恢复，而不是另外插入一个正确标签、把损坏行留成未知小节。
static BOOL IsDamagedHeaderLine(NSString *rawLine, NSString *tag) {
    if (IsHeaderLine(rawLine, tag)) return NO;
    NSRange hash = [rawLine rangeOfString:@"#"];
    if (hash.location == NSNotFound) return NO;
    NSString *comment = [[rawLine substringFromIndex:hash.location + 1]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return [comment isEqualToString:PetPhraseTagDescription(tag)];
}

// 找 tag 的小节头在第几行，没有返回 -1。
static NSInteger HeaderIndex(NSArray<NSString *> *lines, NSString *tag) {
    for (NSUInteger index = 0; index < lines.count; index++) {
        if (IsHeaderLine(lines[index], tag)) return (NSInteger)index;
    }
    return -1;
}

NSString *PetPhraseTextWithRestoredTags(NSString *text,
    NSArray<NSString *> **restored) {
    NSMutableArray<NSString *> *lines = [[(text ?: @"")
        componentsSeparatedByString:@"\n"] mutableCopy];
    NSMutableArray<NSString *> *added = [NSMutableArray array];
    NSArray<NSString *> *order = PetPhraseAllTags();

    // 标签名被删空、删掉一部分或括号不完整时，只要中文情境说明还在，就能无歧义地
    // 确认原标签；直接替换原行，保证恢复位置不变。
    for (NSString *tag in order) {
        if (HeaderIndex(lines, tag) >= 0) continue;
        for (NSUInteger index = 0; index < lines.count; index++) {
            if (!IsDamagedHeaderLine(lines[index], tag)) continue;
            lines[index] = SectionHeaderLine(tag);
            [added addObject:tag];
            break;
        }
    }

    for (NSUInteger position = 0; position < order.count; position++) {
        NSString *tag = order[position];
        if (HeaderIndex(lines, tag) >= 0) continue;

        // 本节能插的范围：上一个还在的标签之后，下一个还在的标签之前。
        NSInteger lower = 0;
        BOOL hasPrevious = NO;
        for (NSInteger back = (NSInteger)position - 1; back >= 0; back--) {
            NSInteger found = HeaderIndex(lines, order[back]);
            if (found < 0) continue;
            lower = found + 1;
            hasPrevious = YES;
            break;
        }
        NSInteger upper = (NSInteger)lines.count;
        for (NSUInteger ahead = position + 1; ahead < order.count; ahead++) {
            NSInteger found = HeaderIndex(lines, order[ahead]);
            if (found < 0) continue;
            upper = found;
            break;
        }
        if (lower > upper) lower = upper;

        // 范围内按空行切成若干"台词块"。
        //
        // 标签被删而台词还在时，那串台词会并进上一节（解析器只认小节头，看不出中间
        // 断过），所以范围里会出现两块：前一块是上一节自己的，后一块才是被删标签的。
        // 标签连着台词一起被删时只剩一块，那块是上一节的，不能抢。
        NSMutableArray<NSNumber *> *blockStarts = [NSMutableArray array];
        BOOL inBlock = NO;
        for (NSInteger index = lower; index < upper; index++) {
            if (IsContentLine(lines[(NSUInteger)index])) {
                if (!inBlock) { [blockStarts addObject:@(index)]; inBlock = YES; }
            } else if (lines[(NSUInteger)index].length == 0) {
                inBlock = NO;
            }
        }
        // 没有上一节时，范围里的块本来就是本节的，第一块就是。
        NSInteger expected = hasPrevious ? 1 : 0;
        NSInteger insertAt = upper;
        if ((NSInteger)blockStarts.count > expected) {
            insertAt = blockStarts.lastObject.integerValue;
        }

        [lines insertObject:SectionHeaderLine(tag) atIndex:(NSUInteger)insertAt];
        // 整节都被删过的情况下，补回的标签会直接顶在下一个标签上面，看起来像挤在一起。
        if ((NSUInteger)insertAt + 1 < lines.count &&
            [lines[(NSUInteger)insertAt + 1] hasPrefix:@"["]) {
            [lines insertObject:@"" atIndex:(NSUInteger)insertAt + 1];
        }
        // 和上一节之间留个空行，别和别人的台词粘在一起。
        if (insertAt > 0 && lines[(NSUInteger)insertAt - 1].length > 0) {
            [lines insertObject:@"" atIndex:(NSUInteger)insertAt];
        }
        [added addObject:tag];
    }

    if (restored) *restored = added;
    return [lines componentsJoinedByString:@"\n"];
}

// forPet=YES 时只跑逐行那部分：专属词库缺小节是常态（缺就回落到通用），
// 拿通用规则去套的话，用户想改一句话得先抄一整份 22 节的文件过来。
static NSArray<PetPhraseIssue *> *ValidateText(NSString *text, BOOL forPet) {
    NSMutableArray<PetPhraseIssue *> *issues = [NSMutableArray array];
    NSDictionary *groups = ParsePhrasesText(text ?: @"", ^(NSInteger line, NSString *reason) {
        [issues addObject:MakeIssue(line, PetPhraseIssueLevelWarning, reason)];
    });

    // 槽位拼错是最难自查的一类：句子看着没问题，运行时却被整条跳过。
    // 白名单外的花括号一律报出来。
    NSSet<NSString *> *slots = [NSSet setWithArray:PetPhraseSlotNames()];
    NSRegularExpression *pattern = [NSRegularExpression
        regularExpressionWithPattern:@"\\{([^{}]*)\\}" options:0 error:nil];
    NSArray<NSString *> *lines = [(text ?: @"") componentsSeparatedByCharactersInSet:
        NSCharacterSet.newlineCharacterSet];
    for (NSUInteger index = 0; index < lines.count; index++) {
        NSString *line = PetLineWithoutTrailingComment([lines[index]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]);
        if (line.length == 0) continue;
        for (NSTextCheckingResult *match in [pattern matchesInString:line options:0
                range:NSMakeRange(0, line.length)]) {
            NSString *name = [line substringWithRange:[match rangeAtIndex:1]];
            if ([slots containsObject:name]) continue;
            [issues addObject:MakeIssue((NSInteger)index + 1, PetPhraseIssueLevelWarning,
                [NSString stringWithFormat:L(@"{%@} isn't a known placeholder; this line will never be said"), name])];
        }
    }

    // 标签行是配置项，不是内容——22 个小节头一个都不能删，删了就报错。
    //
    // 内容能不能为空才分两种：state_ 那组是状态卡副行的唯一正文来源，空了卡片就残，
    // 所以也拦下；情绪句留空是合法选择，就是那个情境不主动开口，只提示。
    //
    // "整节被删了"和"节还在但空了"分开报：用户要做的动作不一样，前者得把 [state_xxx]
    // 那一行加回来，后者只要补一句台词。报同一句话的话，文件里根本没有那行的用户
    // 会满文件去找一个不存在的小节。
    NSSet<NSString *> *stateTags = [NSSet setWithArray:PetPhraseStateTags()];
    for (NSString *tag in PetPhraseAllTags()) {
        if (forPet) break;
        NSArray *entries = groups[tag];
        if (entries == nil) {
            [issues addObject:MakeIssue(0, PetPhraseIssueLevelError, [NSString stringWithFormat:
                L(@"The [%1$@] (%2$@) line is missing. Tags can't be deleted; add it back (it can stay empty)"),
                tag, PetPhraseTagDescription(tag)])];
            continue;
        }
        if (entries.count > 0) continue;
        if ([stateTags containsObject:tag]) {
            [issues addObject:MakeIssue(0, PetPhraseIssueLevelError, [NSString stringWithFormat:
                L(@"[%1$@] (%2$@) needs at least one line"), tag, PetPhraseTagDescription(tag)])];
        } else {
            [issues addObject:MakeIssue(0, PetPhraseIssueLevelWarning, [NSString stringWithFormat:
                L(@"[%1$@] (%2$@) is empty; the pet will stay quiet here"), tag, PetPhraseTagDescription(tag)])];
        }
    }

    // 错误排前面，其次按行号；不带行号的（整节缺失）排到同级最后。
    [issues sortUsingComparator:^NSComparisonResult(PetPhraseIssue *a, PetPhraseIssue *b) {
        if (a.level != b.level) return a.level > b.level ? NSOrderedAscending : NSOrderedDescending;
        if (a.line == b.line) return NSOrderedSame;
        if (a.line == 0) return NSOrderedDescending;
        if (b.line == 0) return NSOrderedAscending;
        return a.line < b.line ? NSOrderedAscending : NSOrderedDescending;
    }];
    return issues;
}

NSArray<PetPhraseIssue *> *PetPhraseValidateText(NSString *text) {
    return ValidateText(text, NO);
}

NSArray<PetPhraseIssue *> *PetPhraseValidateTextForPet(NSString *text) {
    return ValidateText(text, YES);
}

// 判据必须和取词一致：取词看的是"这一节在不在"（ParsePhrasesText 给空小节也建了条目），
// 这里另写一套字符串匹配的话，两边迟早对不上——用户会看到编辑器说"这句来自通用"，
// 桌宠却闭着嘴。
BOOL PetPhraseTextContainsTag(NSString *text, NSString *tag) {
    if (tag.length == 0 || text.length == 0) return NO;
    return ParsePhrasesText(text, nil)[tag] != nil;
}

BOOL PetPhraseIssuesHaveError(NSArray<PetPhraseIssue *> *issues) {
    for (PetPhraseIssue *issue in issues) {
        if (issue.level == PetPhraseIssueLevelError) return YES;
    }
    return NO;
}
