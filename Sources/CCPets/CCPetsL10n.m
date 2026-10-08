#import "CCPetsL10n.h"

NSString *const CCPetsLanguageKey = @"CCPetsLanguage";
NSString *const CCPetsLanguageSystem = @"system";
NSString *const CCPetsSourceLanguage = @"en";
NSString *const CCPetsLanguageNameKey = @"Language Name";
NSString *const CCPetsReleaseNotesSectionKey = @"Release Notes Section";
NSNotificationName const CCPetsLanguageDidChangeNotification = @"CCPetsLanguageDidChange";

// 源语言没有表，名字和 Release 段落标题只能写在这里。
static NSString *const CCPetsSourceLanguageName = @"English";

// 放 .lproj 的目录，依次是：CC_PETS_LOCALIZATION_DIR（测试用）、app bundle、
// 可执行文件旁边（直接跑 .build/release/cc-pets 时没有 bundle）。
static NSArray<NSString *> *CCPetsLocalizationDirectories(void) {
    NSMutableArray<NSString *> *directories = [NSMutableArray array];
    NSString *override = NSProcessInfo.processInfo.environment[@"CC_PETS_LOCALIZATION_DIR"];
    if (override.length > 0) [directories addObject:override.stringByStandardizingPath];
    NSString *resources = NSBundle.mainBundle.resourcePath;
    if (resources.length > 0) [directories addObject:resources];
    NSString *executableDirectory =
        NSBundle.mainBundle.executablePath.stringByDeletingLastPathComponent;
    if (executableDirectory.length > 0) [directories addObject:executableDirectory];
    return directories;
}

static NSString *CCPetsTablePath(NSString *directory, NSString *language) {
    return [[directory stringByAppendingPathComponent:
        [language stringByAppendingPathExtension:@"lproj"]]
        stringByAppendingPathComponent:@"Localizable.strings"];
}

// 每种语言的表只读一次。表随 app 打包，运行期不会变。
static NSMutableDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *CCPetsTables;

static NSDictionary<NSString *, NSString *> *CCPetsTable(NSString *language) {
    if (language.length == 0 || [language isEqualToString:CCPetsSourceLanguage]) return nil;
    @synchronized(CCPetsLanguageKey) {
        if (!CCPetsTables) CCPetsTables = [NSMutableDictionary dictionary];
        id cached = CCPetsTables[language];
        if (cached) return cached == NSNull.null ? nil : cached;
        NSDictionary *table = nil;
        for (NSString *directory in CCPetsLocalizationDirectories()) {
            NSDictionary *candidate = [NSDictionary dictionaryWithContentsOfFile:
                CCPetsTablePath(directory, language)];
            if ([candidate isKindOfClass:NSDictionary.class]) {
                table = candidate;
                break;
            }
        }
        CCPetsTables[language] = table ?: (id)NSNull.null;
        return table;
    }
}

NSArray<NSString *> *CCPetsSupportedLanguages(void) {
    static NSArray<NSString *> *languages;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableSet<NSString *> *found = [NSMutableSet set];
        NSFileManager *manager = NSFileManager.defaultManager;
        for (NSString *directory in CCPetsLocalizationDirectories()) {
            for (NSString *entry in [manager contentsOfDirectoryAtPath:directory error:nil]) {
                if (![entry.pathExtension isEqualToString:@"lproj"]) continue;
                NSString *language = entry.stringByDeletingPathExtension;
                if ([language isEqualToString:CCPetsSourceLanguage]) continue;
                // 只有 InfoPlist.strings 的目录（如 en.lproj）不算一种界面语言。
                if ([manager fileExistsAtPath:CCPetsTablePath(directory, language)]) {
                    [found addObject:language];
                }
            }
        }
        NSArray *sorted = [found.allObjects sortedArrayUsingSelector:@selector(compare:)];
        languages = [@[CCPetsSourceLanguage] arrayByAddingObjectsFromArray:sorted];
    });
    return languages;
}

NSString *CCPetsLanguageDisplayName(NSString *language) {
    if ([language isEqualToString:CCPetsSourceLanguage]) return CCPetsSourceLanguageName;
    NSString *name = CCPetsTable(language)[CCPetsLanguageNameKey];
    return name.length > 0 ? name : language;
}

NSArray<NSString *> *CCPetsReleaseNotesSectionTitles(NSString *language) {
    if ([language isEqualToString:CCPetsSourceLanguage]) return @[CCPetsSourceLanguageName];
    NSString *titles = CCPetsTable(language)[CCPetsReleaseNotesSectionKey];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (NSString *title in [titles componentsSeparatedByString:@"|"]) {
        NSString *trimmed = [title stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceCharacterSet];
        if (trimmed.length > 0) [result addObject:trimmed];
    }
    return result;
}

// zh_CN.UTF-8 → zh-cn。系统给的是 BCP 47（zh-Hans-CN），环境变量里常是 POSIX 写法。
static NSString *CCPetsNormalizedTag(NSString *tag) {
    NSString *lower = [tag.lowercaseString stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
    NSRange dot = [lower rangeOfString:@"."];
    return dot.location == NSNotFound ? lower : [lower substringToIndex:dot.location];
}

static NSString *CCPetsBaseLanguage(NSString *normalizedTag) {
    return [normalizedTag componentsSeparatedByString:@"-"].firstObject;
}

static NSString *CCPetsMatchLanguage(NSString *candidate, NSArray<NSString *> *supported) {
    NSString *tag = CCPetsNormalizedTag(candidate);
    if (tag.length == 0) return nil;
    for (NSString *language in supported) {
        NSString *lower = language.lowercaseString;
        if ([tag isEqualToString:lower] || [tag hasPrefix:[lower stringByAppendingString:@"-"]]) {
            return language;
        }
    }
    NSString *base = CCPetsBaseLanguage(tag);
    for (NSString *language in supported) {
        if ([CCPetsBaseLanguage(language.lowercaseString) isEqualToString:base]) return language;
    }
    return nil;
}

NSString *CCPetsResolveLanguageAmong(NSString *preference, NSArray<NSString *> *systemLanguages,
    NSArray<NSString *> *supported) {
    NSString *explicit = [preference isEqualToString:CCPetsLanguageSystem] ? nil
        : CCPetsMatchLanguage(preference, supported);
    if (explicit) return explicit;
    for (NSString *language in systemLanguages) {
        NSString *match = CCPetsMatchLanguage(language, supported);
        if (match) return match;
    }
    return CCPetsSourceLanguage;
}

static NSString *CCPetsNormalizedPreference(NSString *preference) {
    return [CCPetsSupportedLanguages() containsObject:preference] ? preference : CCPetsLanguageSystem;
}

NSString *CCPetsLanguagePreference(void) {
    return CCPetsNormalizedPreference(
        [NSUserDefaults.standardUserDefaults stringForKey:CCPetsLanguageKey]);
}

// 当前语言在偏好和环境变量都不变时不会变，但查表在绘制路径上每帧都可能调用，
// 缓存一份，切换偏好时清掉。
static NSString *CCPetsCachedLanguage;

// 系统首选语言。偏好里选了具体语言时，桌宠会把 AppleLanguages 写进自己的 defaults 域，
// 好让系统自带的按钮、面板在下次启动后也换成同一种语言；所以这里要读全局域，
// 不能用 NSLocale.preferredLanguages（它会读到我们自己写进去的那份）。
static NSArray<NSString *> *CCPetsSystemLanguages(void) {
    NSArray *global = [[NSUserDefaults.standardUserDefaults
        persistentDomainForName:NSGlobalDomain] objectForKey:@"AppleLanguages"];
    if ([global isKindOfClass:NSArray.class] && global.count > 0) return global;
    return NSLocale.preferredLanguages;
}

NSString *CCPetsCurrentLanguage(void) {
    @synchronized(CCPetsLanguageKey) {
        if (CCPetsCachedLanguage) return CCPetsCachedLanguage;
        NSString *override = NSProcessInfo.processInfo.environment[@"CC_PETS_LANGUAGE"];
        NSString *preference = override.length > 0 ? override : CCPetsLanguagePreference();
        CCPetsCachedLanguage = CCPetsResolveLanguageAmong(preference, CCPetsSystemLanguages(),
            CCPetsSupportedLanguages());
        return CCPetsCachedLanguage;
    }
}

BOOL CCPetsLanguageIsSource(void) {
    return [CCPetsCurrentLanguage() isEqualToString:CCPetsSourceLanguage];
}

NSString *CCPetsLocalized(NSString *text) {
    if (text.length == 0) return text;
    NSString *language = CCPetsCurrentLanguage();
    if ([language isEqualToString:CCPetsSourceLanguage]) return text;
    NSString *translated = CCPetsTable(language)[text];
    return translated.length > 0 ? translated : text;
}

NSString *CCPetsLanguageFilePath(void) {
    NSString *home = NSProcessInfo.processInfo.environment[@"CC_PETS_HOME"];
    if (home.length == 0) {
        home = [NSHomeDirectory() stringByAppendingPathComponent:@".cc-pets"];
    }
    return [home.stringByStandardizingPath stringByAppendingPathComponent:@"language"];
}

void CCPetsWriteLanguageFile(void) {
    NSString *path = CCPetsLanguageFilePath();
    NSString *language = CCPetsCurrentLanguage();
    NSString *existing = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding
        error:nil];
    NSString *content = [language stringByAppendingString:@"\n"];
    if ([existing isEqualToString:content]) return;
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil];
    [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

void CCPetsSetLanguagePreference(NSString *preference) {
    NSString *normalized = CCPetsNormalizedPreference(preference);
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:normalized forKey:CCPetsLanguageKey];
    // 系统自带的部分（NSAlert 默认按钮、打开面板、编辑菜单的系统项）跟 AppleLanguages 走，
    // 只在下次启动时生效。跟随系统时删掉，回到全局设置。
    if ([normalized isEqualToString:CCPetsLanguageSystem]) {
        [defaults removeObjectForKey:@"AppleLanguages"];
    } else {
        [defaults setObject:@[normalized] forKey:@"AppleLanguages"];
    }
    @synchronized(CCPetsLanguageKey) {
        CCPetsCachedLanguage = nil;
    }
    CCPetsWriteLanguageFile();
    [NSNotificationCenter.defaultCenter
        postNotificationName:CCPetsLanguageDidChangeNotification object:nil];
}
