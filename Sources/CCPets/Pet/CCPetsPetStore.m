#import "CCPetsL10n.h"
#import "CCPetsPetStore.h"
#import "CCPetsCLISupport.h"
#import "CCPetsJSON.h"
#import "CCPetsPaths.h"
#import "CCPetsVersion.h"

#define LF(localized, values) CCPetsInterpolate(localized, values)

static NSString *const SidecarName = @".source.json";
static const NSTimeInterval ManifestTTL = 6 * 60 * 60;

// 一个源的完整定义就是这几项。以后接自建 registry 时在这里加一项即可，命令、目录结构和桌宠端都不用动。
// 清单是远端数据，理论上可以指向任意地址；下载前把 host 卡死，免得一次清单投毒就变成"从任意地址往本地写文件"。
static NSDictionary<NSString *, NSDictionary *> *Sources(void) {
    return @{
        @"petdex": @{
            @"label": @"PetDex",
            @"manifestUrl": @"https://petdex.dev/api/manifest",
            @"assetHosts": @[@"assets.petdex.dev"],
            @"referer": @"https://petdex.dev/",
            @"homepage": @"https://petdex.dev"
        }
    };
}

static NSString *DefaultSource(void) {
    return CCPetsEnvironmentValue(@"CC_PETS_SOURCE") ?: @"petdex";
}

// 请求素材源时自报家门：对方运维从日志里能看出流量来自 CC Pets，想联系或限流都有个明确的对象。
static NSString *UserAgent(void) {
    return [NSString stringWithFormat:@"cc-pets/%s (+https://github.com/Sunnyshinnny776/cc-pets)", CC_PETS_VERSION];
}

static NSString *Dim(NSString *text) { return [NSString stringWithFormat:@"\033[2m%@\033[0m", text]; }
static NSString *Cyan(NSString *text) { return [NSString stringWithFormat:@"\033[36m%@\033[0m", text]; }
static NSString *Green(NSString *text) { return [NSString stringWithFormat:@"\033[32m%@\033[0m", text]; }
static NSString *Red(NSString *text) { return [NSString stringWithFormat:@"\033[31m%@\033[0m", text]; }

static void Print(NSString *text) { CCPetsPrintLine(stdout, text); }
static void PrintError(NSString *text) { CCPetsPrintLine(stderr, text); }

static void Fail(NSString *message) {
    PrintError(Red(message));
    exit(1);
}

static NSString *PetsRoot(void) {
    NSString *override = CCPetsEnvironmentValue(@"CC_PETS_PETS_DIR");
    if (override) {
        if ([override hasPrefix:@"~/"]) override = [CCPetsHomeDirectory() stringByAppendingPathComponent:[override substringFromIndex:2]];
        return CCPetsResolvePath(override);
    }
    return [CCPetsHomeDirectory() stringByAppendingPathComponent:@".cc-pets/pets"];
}

// 与 CC Bridge、cc-pets clean 一致：CC_PETS_HOME 可覆盖 ~/.cc-pets。
static NSString *CachePath(NSString *sourceName) {
    NSString *home = CCPetsEnvironmentValue(@"CC_PETS_HOME") ?: [CCPetsHomeDirectory() stringByAppendingPathComponent:@".cc-pets"];
    return [[home stringByAppendingPathComponent:@"cache"] stringByAppendingPathComponent:
        [NSString stringWithFormat:@"manifest-%@.json", sourceName]];
}

// 每个源都可以单独用环境变量改清单地址，主要给测试和自建源的本地联调用。
static NSString *ManifestURLFor(NSString *sourceName) {
    return CCPetsEnvironmentValue([@"CC_PETS_MANIFEST_URL_" stringByAppendingString:sourceName.uppercaseString])
        ?: Sources()[sourceName][@"manifestUrl"];
}

static BOOL Matches(NSString *pattern, NSString *text) {
    if (![text isKindOfClass:NSString.class]) return NO;
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    return [expression firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] != nil;
}

// slug 直接用作目录名，而它来自远端清单，必须自己校验，不能指望上游。
static BOOL IsSafeSlug(id slug) {
    return Matches(@"\\A[A-Za-z0-9][A-Za-z0-9._-]*\\z", slug) && ![slug containsString:@".."];
}

// 本地名由用户通过 --as 指定，可以用中文等 Unicode 字母。路径分隔符、空白和控制字符不在允许集内；
// 首字符必须是字母或数字，避免生成隐藏目录。
static BOOL IsSafeLocalName(id name) {
    return Matches(@"\\A[\\p{L}\\p{N}][\\p{L}\\p{N}\\p{M}._-]*\\z", name) && ![name containsString:@".."];
}

// "petdex:boba" -> @{source: petdex, slug: boba}；不带前缀就用默认源。
static NSDictionary *ParseSpec(NSString *spec) {
    NSRange separator = [spec rangeOfString:@":"];
    if (separator.location == NSNotFound) return @{@"source": DefaultSource(), @"slug": spec};
    NSString *source = [spec substringToIndex:separator.location];
    if (!Sources()[source]) {
        Fail(LF(L(@"Unknown pet source \"{source}\". Available sources: {SOURCES}"),
            (@{@"source": source, @"SOURCES": [Sources().allKeys componentsJoinedByString:@", "]})));
    }
    return @{@"source": source, @"slug": [spec substringFromIndex:NSMaxRange(separator)]};
}

#pragma mark - 网络

// 同步请求：命令行一次只做一件事，没必要把调用方改成异步。返回数据，失败时 data 为 nil 并给出 HTTP 状态或错误。
static NSData *Fetch(NSURL *url, NSDictionary<NSString *, NSString *> *headers, NSInteger *status, NSString **error) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        [request setValue:value forHTTPHeaderField:key];
    }];
    request.timeoutInterval = 60;
    __block NSData *result = nil;
    __block NSInteger code = 0;
    __block NSString *failure = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
        if (taskError) {
            failure = taskError.localizedDescription;
        } else {
            code = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 200;
            result = data;
        }
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (status) *status = code;
    if (error) *error = failure;
    return failure ? nil : result;
}

static NSArray<NSDictionary *> *FetchManifest(NSString *sourceName, BOOL refresh) {
    NSString *cache = CachePath(sourceName);
    NSString *label = Sources()[sourceName][@"label"];
    if (!refresh) {
        NSDate *modified = [NSFileManager.defaultManager attributesOfItemAtPath:cache error:nil].fileModificationDate;
        if (modified && -modified.timeIntervalSinceNow < ManifestTTL) {
            NSData *data = [NSData dataWithContentsOfFile:cache];
            id cached = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if ([cached isKindOfClass:NSDictionary.class] && [cached[@"pets"] isKindOfClass:NSArray.class]) return cached[@"pets"];
        }
    }
    NSURL *url = [NSURL URLWithString:ManifestURLFor(sourceName)];
    NSInteger status = 0;
    NSString *error = nil;
    NSData *data = url ? Fetch(url, @{@"User-Agent": UserAgent()}, &status, &error) : nil;
    if (!data && !url) error = ManifestURLFor(sourceName);
    if (error || status < 200 || status >= 300) {
        Fail(LF(L(@"Failed to fetch the {label} pet list: HTTP {status}"), (@{@"label": label, @"status": error ?: @(status)})));
    }
    id body = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![body isKindOfClass:NSDictionary.class] || ![body[@"pets"] isKindOfClass:NSArray.class]) {
        Fail(LF(L(@"The {label} pet list has an unexpected format"), @{@"label": label}));
    }
    [NSFileManager.defaultManager createDirectoryAtPath:cache.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [data writeToFile:cache atomically:YES];
    NSMutableArray<NSDictionary *> *pets = [NSMutableArray array];
    for (id pet in body[@"pets"]) {
        if ([pet isKindOfClass:NSDictionary.class]) [pets addObject:pet];
    }
    return pets;
}

static NSData *Download(id urlValue, NSDictionary *source, NSString **error) {
    NSString *text = [urlValue isKindOfClass:NSString.class] ? urlValue : @"";
    NSURL *url = [NSURL URLWithString:text];
    if (!url || !url.scheme) {
        *error = LF(L(@"Invalid pet URL: {url}"), @{@"url": text});
        return nil;
    }
    if (![url.scheme isEqualToString:@"https"] || ![source[@"assetHosts"] containsObject:url.host ?: @""]) {
        *error = LF(L(@"Untrusted pet source: {url}"), @{@"url": url.host.length > 0 ? url.host : text});
        return nil;
    }
    NSInteger status = 0;
    NSString *failure = nil;
    NSData *data = Fetch(url, @{@"Referer": source[@"referer"], @"User-Agent": UserAgent()}, &status, &failure);
    if (!data || status < 200 || status >= 300) {
        *error = LF(L(@"Download failed {pathname} -> HTTP {status}"), (@{@"pathname": url.path ?: @"", @"status": failure ?: @(status)}));
        return nil;
    }
    return data;
}

#pragma mark - 本地素材

static NSDictionary *ReadSidecar(NSString *directory) {
    NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:SidecarName]];
    id raw = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [raw isKindOfClass:NSDictionary.class] && [raw[@"source"] isKindOfClass:NSString.class] ? raw : nil;
}

// 已经存在的目录不能闷声覆盖：可能是另一个源的同名素材，也可能是用户自己手放的图。
static NSString *InstallBlocker(NSString *directory, NSString *sourceName, NSString *localName) {
    if (![NSFileManager.defaultManager fileExistsAtPath:directory]) return nil;
    NSDictionary *sidecar = ReadSidecar(directory);
    if ([sidecar[@"source"] isEqual:sourceName]) return nil;
    NSString *owner = sidecar ? LF(L(@"came from {source}"), @{@"source": sidecar[@"source"]})
        : L(@"wasn't installed by cc-pets pet (no source record)");
    return [LF(L(@"{localName} already exists and {owner}. Install it under another name: "), (@{@"localName": localName, @"owner": owner}))
        stringByAppendingFormat:@"cc-pets pet add %@:%@ --as %@-%@", sourceName, localName, localName, sourceName];
}

static NSString *InstallPet(NSDictionary *pet, NSString *sourceName, NSString *localName, NSString **error) {
    NSDictionary *source = Sources()[sourceName];
    if (!IsSafeSlug(pet[@"slug"])) {
        *error = LF(L(@"Invalid pet name: {slug}"), @{@"slug": [pet[@"slug"] description] ?: @""});
        return nil;
    }
    NSString *directory = [PetsRoot() stringByAppendingPathComponent:localName];
    NSString *blocker = InstallBlocker(directory, sourceName, localName);
    if (blocker) {
        *error = blocker;
        return nil;
    }
    NSData *meta = Download(pet[@"petJsonUrl"], source, error);
    if (!meta) return nil;
    NSData *sprite = Download(pet[@"spritesheetUrl"], source, error);
    if (!sprite) return nil;
    NSString *extension = [[NSURL URLWithString:pet[@"spritesheetUrl"]].path hasSuffix:@".png"] ? @"png" : @"webp";
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    // 同一只宠物换过格式时，旧的 spritesheet 会留下来抢加载顺序，先清掉。
    for (NSString *stale in @[@"spritesheet.webp", @"spritesheet.png"]) {
        if (![stale isEqualToString:[@"spritesheet." stringByAppendingString:extension]]) {
            [NSFileManager.defaultManager removeItemAtPath:[directory stringByAppendingPathComponent:stale] error:nil];
        }
    }
    // pet.json 原样落盘，不掺自己的字段——保持上游原始内容，以后比对和更新才干净。
    [meta writeToFile:[directory stringByAppendingPathComponent:@"pet.json"] atomically:YES];
    [sprite writeToFile:[directory stringByAppendingPathComponent:[@"spritesheet." stringByAppendingString:extension]] atomically:YES];
    CCPetsJSONObject *sidecar = [CCPetsJSONObject new];
    sidecar[@"source"] = sourceName;
    sidecar[@"slug"] = pet[@"slug"];
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    sidecar[@"installedAt"] = [formatter stringFromDate:NSDate.date];
    [[CCPetsJSONStringify(sidecar) stringByAppendingString:@"\n"] writeToFile:[directory stringByAppendingPathComponent:SidecarName]
        atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return directory;
}

static NSArray<NSDictionary *> *InstalledPets(void) {
    NSString *root = PetsRoot();
    NSMutableArray<NSDictionary *> *pets = [NSMutableArray array];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]) {
        if ([name hasPrefix:@"."]) continue;
        if (!CCPetsDirectoryExists([root stringByAppendingPathComponent:name])) continue;
        NSDictionary *sidecar = ReadSidecar([root stringByAppendingPathComponent:name]);
        [pets addObject:@{@"name": name, @"source": sidecar[@"source"] ?: NSNull.null,
            @"slug": [sidecar[@"slug"] isKindOfClass:NSString.class] ? sidecar[@"slug"] : NSNull.null}];
    }
    [pets sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCompare:b[@"name"]];
    }];
    return pets;
}

#pragma mark - 命令

static NSArray<NSString *> *Positional(NSArray<NSString *> *arguments, NSInteger skipIndex) {
    NSMutableArray<NSString *> *values = [NSMutableArray array];
    [arguments enumerateObjectsUsingBlock:^(NSString *value, NSUInteger index, BOOL *stop) {
        if (![value hasPrefix:@"--"] && (NSInteger)index != skipIndex) [values addObject:value];
    }];
    return values;
}

static int CommandAdd(NSArray<NSString *> *arguments) {
    BOOL refresh = [arguments containsObject:@"--refresh"];
    NSUInteger asIndex = [arguments indexOfObject:@"--as"];
    NSString *alias = asIndex != NSNotFound && asIndex + 1 < arguments.count ? arguments[asIndex + 1] : nil;
    if (asIndex != NSNotFound && (!alias || [alias hasPrefix:@"--"])) Fail(L(@"--as needs a name after it."));
    if (alias && !IsSafeLocalName(alias)) Fail(LF(L(@"Invalid --as name: {alias}"), @{@"alias": alias}));
    NSOrderedSet<NSString *> *specs = [NSOrderedSet orderedSetWithArray:Positional(arguments, asIndex == NSNotFound ? -1 : (NSInteger)asIndex + 1)];
    if (specs.count == 0) {
        Fail(LF(L(@"Usage: {cyan}"), @{@"cyan": Cyan(L(@"cc-pets pet add [source:]<name> [name...] [--as <local-name>]"))}));
    }
    if (alias && specs.count > 1) Fail(L(@"--as can only rename one pet at a time."));

    // 按源分组，同一个源只拉一次清单。
    NSMutableArray<NSString *> *sourceOrder = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *bySource = [NSMutableDictionary dictionary];
    for (NSString *spec in specs) {
        NSDictionary *item = ParseSpec(spec);
        if (!bySource[item[@"source"]]) {
            bySource[item[@"source"]] = [NSMutableArray array];
            [sourceOrder addObject:item[@"source"]];
        }
        [bySource[item[@"source"]] addObject:item[@"slug"]];
    }
    NSUInteger failed = 0, installed = 0;
    for (NSString *sourceName in sourceOrder) {
        NSMutableDictionary<NSString *, NSDictionary *> *index = [NSMutableDictionary dictionary];
        for (NSDictionary *pet in FetchManifest(sourceName, refresh)) {
            if ([pet[@"slug"] isKindOfClass:NSString.class]) index[pet[@"slug"]] = pet;
        }
        for (NSString *slug in bySource[sourceName]) {
            NSDictionary *pet = index[slug];
            if (!pet) {
                failed++;
                PrintError(LF(L(@"{red} {sourceName}:{slug}: not in the pet list"), (@{@"red": Red(@"×"), @"sourceName": sourceName, @"slug": slug})));
                continue;
            }
            NSString *localName = alias ?: slug;
            NSString *error = nil;
            NSString *directory = InstallPet(pet, sourceName, localName, &error);
            if (!directory) {
                failed++;
                PrintError([NSString stringWithFormat:@"%@ %@:%@: %@", Red(@"×"), sourceName, slug, error]);
                continue;
            }
            installed++;
            NSString *renamed = [localName isEqualToString:slug] ? @"" : Dim([NSString stringWithFormat:@" (%@:%@)", sourceName, slug]);
            Print([NSString stringWithFormat:@"%@ %@%@ %@", Green(@"✓"), localName, renamed, Dim([@"→ " stringByAppendingString:directory])]);
        }
    }
    if (installed > 0) {
        Print(Dim(LF(L(@"Pets directory: {petsRoot}"), @{@"petsRoot": PetsRoot()})));
        Print(Dim(L(@"Click “Rescan” in the pet menu or restart the pet to see new pets.")));
    }
    return failed > 0 ? 1 : 0;
}

static int CommandSearch(NSArray<NSString *> *arguments) {
    BOOL refresh = [arguments containsObject:@"--refresh"];
    NSArray<NSString *> *positional = Positional(arguments, -1);
    // 关键词本身也可以带源前缀：`cc-pets pet search petdex:otter`。
    NSDictionary *scoped = positional.count > 0 && [positional[0] containsString:@":"] ? ParseSpec(positional[0])
        : @{@"source": DefaultSource(), @"slug": [positional componentsJoinedByString:@" "]};
    NSString *sourceName = scoped[@"source"];
    NSMutableArray<NSString *> *words = [NSMutableArray arrayWithObject:scoped[@"slug"]];
    if (positional.count > 1) [words addObjectsFromArray:[positional subarrayWithRange:NSMakeRange(1, positional.count - 1)]];
    NSString *keyword = [[words componentsJoinedByString:@" "]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    NSArray<NSDictionary *> *pets = FetchManifest(sourceName, refresh);
    NSMutableArray<NSDictionary *> *matched = [NSMutableArray array];
    for (NSDictionary *pet in pets) {
        NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@", pet[@"slug"] ?: @"",
            [pet[@"displayName"] isKindOfClass:NSString.class] ? pet[@"displayName"] : @"",
            [pet[@"submittedBy"] isKindOfClass:NSString.class] ? pet[@"submittedBy"] : @""].lowercaseString;
        if (keyword.length == 0 || [haystack containsString:keyword]) [matched addObject:pet];
    }
    if (matched.count == 0) {
        Fail(LF(L(@"No pets on {label} match \"{keyword}\"."), (@{@"label": Sources()[sourceName][@"label"], @"keyword": keyword})));
    }
    NSArray<NSDictionary *> *shown = matched.count > 60 ? [matched subarrayWithRange:NSMakeRange(0, 60)] : matched;
    for (NSDictionary *pet in shown) {
        NSString *author = [pet[@"submittedBy"] isKindOfClass:NSString.class] && [pet[@"submittedBy"] length] > 0
            ? Dim([@" by " stringByAppendingString:pet[@"submittedBy"]]) : @"";
        NSString *display = [pet[@"displayName"] isKindOfClass:NSString.class] ? pet[@"displayName"] : @"";
        Print([NSString stringWithFormat:@"  %@  %@%@", Cyan([pet[@"slug"] description]), display, author]);
    }
    if (matched.count > shown.count) {
        Print(Dim(LF(L(@"  … {length} results, showing the first {shown}."), (@{@"length": @(matched.count), @"shown": @(shown.count)}))));
    }
    Print(Dim(LF(L(@"Install one: cc-pets pet add {sourceName}:{slug}"), (@{@"sourceName": sourceName, @"slug": [shown[0][@"slug"] description]}))));
    return 0;
}

static int CommandList(void) {
    NSArray<NSDictionary *> *pets = InstalledPets();
    if (pets.count == 0) {
        Print(Dim(LF(L(@"No pets in {petsRoot} yet."), @{@"petsRoot": PetsRoot()})));
        Print(Dim(L(@"Try: cc-pets pet add boba")));
        return 0;
    }
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *groups = [NSMutableDictionary dictionary];
    for (NSDictionary *pet in pets) {
        NSString *key = pet[@"source"] == NSNull.null ? @"" : pet[@"source"];
        if (!groups[key]) groups[key] = [NSMutableArray array];
        [groups[key] addObject:pet];
    }
    // 有来源记录的源按名字排在前面，手放的素材垫底。
    NSArray<NSString *> *keys = [groups.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        if (a.length == 0) return NSOrderedDescending;
        if (b.length == 0) return NSOrderedAscending;
        return [a localizedCompare:b];
    }];
    // 不能 add、只会出现在已装素材里的来源。桌宠的"导入 Codex 素材"开关会写 source: "codex"。
    NSDictionary<NSString *, NSString *> *localLabels = @{@"codex": L(@"Codex (imported)")};
    for (NSString *key in keys) {
        NSString *label = key.length == 0 ? L(@"Local pets (no source record)") : (Sources()[key][@"label"] ?: localLabels[key] ?: key);
        Print([@"  " stringByAppendingString:label]);
        for (NSDictionary *pet in groups[key]) {
            // 目录名和上游 slug 不一致时（--as 改过名）把原名标出来。
            NSString *slug = pet[@"slug"] == NSNull.null ? nil : pet[@"slug"];
            NSString *origin = slug && ![slug isEqualToString:pet[@"name"]] ? Dim([NSString stringWithFormat:@" (%@:%@)", key, slug]) : @"";
            Print([NSString stringWithFormat:@"    %@%@", Cyan(pet[@"name"]), origin]);
        }
    }
    Print(Dim(LF(L(@"{length} in total, in {petsRoot}"), (@{@"length": @(pets.count), @"petsRoot": PetsRoot()}))));
    return 0;
}

static int CommandRemove(NSArray<NSString *> *arguments) {
    NSArray<NSString *> *names = Positional(arguments, -1);
    if (names.count == 0) Fail(LF(L(@"Usage: {cyan}"), @{@"cyan": Cyan(L(@"cc-pets pet remove <name> [name...]"))}));
    NSUInteger removed = 0;
    for (NSString *name in names) {
        if (!IsSafeLocalName(name)) {
            PrintError(LF(L(@"{red} {name}: invalid name"), (@{@"red": Red(@"×"), @"name": name})));
            continue;
        }
        NSString *directory = [PetsRoot() stringByAppendingPathComponent:name];
        if (![NSFileManager.defaultManager fileExistsAtPath:directory]) {
            PrintError(LF(L(@"{red} {name}: not installed"), (@{@"red": Red(@"×"), @"name": name})));
            continue;
        }
        NSDictionary *sidecar = ReadSidecar(directory);
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
        removed++;
        Print(LF(L(@"{green} Removed {name}{source}"), (@{@"green": Green(@"✓"), @"name": name,
            @"source": sidecar ? Dim(LF(L(@" (from {source})"), @{@"source": sidecar[@"source"]})) : @""})));
    }
    return removed < names.count ? 1 : 0;
}

static int CommandSource(void) {
    for (NSString *name in [Sources().allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *source = Sources()[name];
        NSString *marker = [name isEqualToString:DefaultSource()] ? Green(L(@" (default)")) : @"";
        Print([NSString stringWithFormat:@"  %@%@  %@ %@", Cyan(name), marker, source[@"label"], Dim(source[@"homepage"])]);
    }
    Print(Dim(L(@"Change the default source with CC_PETS_SOURCE, or prefix a name with `source:`.")));
    return 0;
}

static int CommandDir(void) {
    [NSFileManager.defaultManager createDirectoryAtPath:PetsRoot() withIntermediateDirectories:YES attributes:nil error:nil];
    Print(PetsRoot());
    return 0;
}

static void Usage(void) {
    Print([@[
        @"",
        LF(L(@"  {cyan} — install pets into cc-pets' own directory"), @{@"cyan": Cyan(@"cc-pets pet")}),
        @"",
        LF(L(@"    {cyan} [source:]<name>...     download pets to {petsRoot}"), (@{@"cyan": Cyan(@"add"), @"petsRoot": Dim(PetsRoot())})),
        LF(L(@"    {cyan} [source:][keyword]  search pets (no keyword lists all)"), @{@"cyan": Cyan(@"search")}),
        LF(L(@"    {cyan}                       list installed pets, grouped by source"), @{@"cyan": Cyan(@"list")}),
        LF(L(@"    {cyan} <name>...           remove installed pets"), @{@"cyan": Cyan(@"remove")}),
        LF(L(@"    {cyan}                     list available sources"), @{@"cyan": Cyan(@"source")}),
        LF(L(@"    {cyan}                        print the pets directory"), @{@"cyan": Cyan(@"dir")}),
        @"",
        [@"  " stringByAppendingString:Dim([NSString stringWithFormat:@"%@%@%@",
            L(@"Names can have a source prefix (petdex:boba); otherwise the default source is used: "), DefaultSource(), L(@".")])],
        [@"  " stringByAppendingString:Dim(L(@"--as <local-name> installs under another directory name (any language) to avoid name clashes."))],
        [@"  " stringByAppendingString:Dim(L(@"--refresh forces a refresh of the pet list cache (cached for 6 hours by default)."))],
        [@"  " stringByAppendingString:Dim(L(@"CC_PETS_PETS_DIR changes the pets directory; CC_PETS_SOURCE changes the default source."))],
        @"",
        [NSString stringWithFormat:@"  %@ cc-pets pet search otter", Dim(@"$")],
        [NSString stringWithFormat:@"  %@ cc-pets pet add boba", Dim(@"$")],
        [NSString stringWithFormat:@"  %@ cc-pets pet add petdex:boba --as boba-petdex", Dim(@"$")],
        LF(L(@"  {dim} cc-pets pet add boba --as bubble-tea"), @{@"dim": Dim(@"$")}),
        @""
    ] componentsJoinedByString:@"\n"]);
}

int CCPetsPetStoreMain(NSArray<NSString *> *argv) {
    NSString *command = argv.firstObject;
    NSArray<NSString *> *arguments = argv.count > 1 ? [argv subarrayWithRange:NSMakeRange(1, argv.count - 1)] : @[];
    if (!Sources()[DefaultSource()]) {
        Fail(LF(L(@"CC_PETS_SOURCE points to an unknown source \"{DEFAULT_SOURCE}\". Available sources: {SOURCES}"),
            (@{@"DEFAULT_SOURCE": DefaultSource(), @"SOURCES": [Sources().allKeys componentsJoinedByString:@", "]})));
    }
    if ([@[@"add", @"install"] containsObject:command ?: @""]) return CommandAdd(arguments);
    if ([command isEqualToString:@"search"]) return CommandSearch(arguments);
    if ([@[@"list", @"ls"] containsObject:command ?: @""]) return CommandList();
    if ([@[@"remove", @"rm"] containsObject:command ?: @""]) return CommandRemove(arguments);
    if ([@[@"source", @"sources"] containsObject:command ?: @""]) return CommandSource();
    if ([command isEqualToString:@"dir"]) return CommandDir();
    if (!command || [@[@"help", @"--help", @"-h"] containsObject:command]) {
        Usage();
        return 0;
    }
    PrintError(Red(LF(L(@"Unknown subcommand: {command}"), @{@"command": command})));
    Usage();
    return 2;
}
