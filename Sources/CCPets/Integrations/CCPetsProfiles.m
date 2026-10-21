#import "CCPetsProfiles.h"
#import "CCPetsBridge.h"
#import "CCPetsBridgeSetup.h"
#import "CCPetsCLISupport.h"
#import "CCPetsIntegrations.h"
#import "CCPetsJSON.h"
#import "CCPetsL10n.h"
#import <sys/stat.h>

NSString *const CCPetsProfileProviderClaude = @"claude";
NSString *const CCPetsProfileProviderCodex = @"codex";
NSNotificationName const CCPetsProfilesDidChangeNotification = @"CCPetsProfilesDidChange";
NSString *const CCPetsProfileStateIntegrated = @"integrated";
NSString *const CCPetsProfileStateRepair = @"repair";
NSString *const CCPetsProfileStateUnavailable = @"unavailable";

static NSString *ProfilesDirectory(void) {
    return [CCPetsHomeDirectory() stringByAppendingPathComponent:@".cc-pets"];
}

NSString *CCPetsProfilesPath(void) {
    return [ProfilesDirectory() stringByAppendingPathComponent:@"agent-profiles.json"];
}

static BOOL ValidProvider(NSString *provider) {
    return [provider isEqualToString:CCPetsProfileProviderClaude] ||
        [provider isEqualToString:CCPetsProfileProviderCodex];
}

static NSString *CanonicalHome(NSString *home) {
    if (![home isKindOfClass:NSString.class] || home.length == 0) return nil;
    NSString *expanded = [home stringByExpandingTildeInPath];
    NSString *resolved = CCPetsRealPath(expanded);
    return resolved ?: CCPetsResolvePath(expanded);
}

static uint64_t StablePathHash(NSString *text) {
    uint64_t hash = 1469598103934665603ULL;
    const unsigned char *bytes = (const unsigned char *)text.UTF8String;
    for (const unsigned char *cursor = bytes; cursor && *cursor; cursor++) {
        hash ^= (uint64_t)*cursor;
        hash *= 1099511628211ULL;
    }
    return hash;
}

NSString *CCPetsProfileID(NSString *provider, NSString *home) {
    NSString *canonical = CanonicalHome(home);
    if (!ValidProvider(provider) || canonical.length == 0) return nil;
    NSString *source = [NSString stringWithFormat:@"%@:%@", provider, canonical];
    return [NSString stringWithFormat:@"%@:%016llx", provider,
        (unsigned long long)StablePathHash(source)];
}

NSString *CCPetsProfileSlug(NSString *home) {
    NSString *name = CanonicalHome(home).lastPathComponent ?: @"";
    while ([name hasPrefix:@"."]) name = [name substringFromIndex:1];
    return name.length > 0 ? name : @"profile";
}

static NSString *LegacyFriendlyDisplayName(NSString *provider, NSString *home) {
    NSString *slug = CCPetsProfileSlug(home);
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *part in [slug componentsSeparatedByCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"-_ "]]) {
        if (part.length == 0) continue;
        if ([part.lowercaseString isEqualToString:@"claude"]) [words addObject:@"Claude"];
        else if ([part.lowercaseString isEqualToString:@"codex"]) [words addObject:@"Codex"];
        else [words addObject:part.uppercaseString];
    }
    if (words.count == 0) {
        return [provider isEqualToString:CCPetsProfileProviderClaude] ? @"Claude" : @"Codex";
    }
    return [words componentsJoinedByString:@" "];
}

NSString *CCPetsProfileDefaultDisplayName(NSString *provider, NSString *home) {
    (void)provider;
    return CCPetsProfileSlug(home);
}

BOOL CCPetsProfileIsOfficialDefault(NSDictionary *profile) {
    NSString *provider = profile[@"provider"];
    NSString *leaf = [provider isEqualToString:CCPetsProfileProviderClaude] ? @".claude"
        : ([provider isEqualToString:CCPetsProfileProviderCodex] ? @".codex" : nil);
    if (!leaf) return NO;
    NSString *official = CanonicalHome([CCPetsHomeDirectory() stringByAppendingPathComponent:leaf]);
    return official.length > 0 && [CanonicalHome(profile[@"home"]) isEqualToString:official];
}

static NSDictionary *EmptyDocument(void) {
    return @{@"schemaVersion": @1, @"profiles": @[]};
}

static NSDictionary *ReadDocument(void) {
    NSData *data = [NSData dataWithContentsOfFile:CCPetsProfilesPath()];
    NSDictionary *document = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![document isKindOfClass:NSDictionary.class] || [document[@"schemaVersion"] integerValue] != 1 ||
        ![document[@"profiles"] isKindOfClass:NSArray.class]) return EmptyDocument();
    return document;
}

static BOOL WriteProfiles(NSArray<NSDictionary *> *profiles, NSString **errorMessage) {
    [NSFileManager.defaultManager createDirectoryAtPath:ProfilesDirectory()
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil];
    NSDictionary *document = @{@"schemaVersion": @1, @"profiles": profiles ?: @[]};
    NSData *data = [NSJSONSerialization dataWithJSONObject:document
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes error:nil];
    if (!data) {
        if (errorMessage) *errorMessage = @"Unable to encode agent profile registry.";
        return NO;
    }
    NSString *text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        stringByAppendingString:@"\n"];
    return CCPetsWriteFileAtomically(CCPetsProfilesPath(), text, 0600, errorMessage);
}

NSArray<NSDictionary *> *CCPetsProfiles(void) {
    NSMutableArray<NSDictionary *> *valid = [NSMutableArray array];
    for (id entry in ReadDocument()[@"profiles"]) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *profileID = entry[@"id"], *provider = entry[@"provider"], *home = entry[@"home"];
        if (![profileID isKindOfClass:NSString.class] || !ValidProvider(provider) ||
            ![home isKindOfClass:NSString.class] || home.length == 0) continue;
        NSMutableDictionary *profile = [entry mutableCopy];
        NSString *rawName = CCPetsProfileDefaultDisplayName(provider, home);
        NSString *storedName = [entry[@"displayName"] isKindOfClass:NSString.class]
            ? entry[@"displayName"] : nil;
        NSNumber *customName = [entry[@"customName"] isKindOfClass:NSNumber.class]
            ? entry[@"customName"] : nil;
        // 早期手动添加流程把自动生成的文件夹名也误记成了“自定义”。两者完全相同
        // 时恢复为自动名称，重新定位 Home 后才能自然跟随新的文件夹名。
        if ([customName boolValue] && [storedName isEqualToString:rawName]) customName = @NO;
        if (!customName) {
            NSString *legacyName = LegacyFriendlyDisplayName(provider, home);
            BOOL wasCustomized = storedName.length > 0 &&
                ![storedName isEqualToString:legacyName] && ![storedName isEqualToString:rawName];
            customName = @(wasCustomized);
        }
        profile[@"customName"] = customName;
        if (![customName boolValue]) profile[@"displayName"] = rawName;
        else if (storedName.length == 0) profile[@"displayName"] = rawName;
        profile[@"slug"] = CCPetsProfileSlug(home);
        [valid addObject:profile];
    }
    return valid;
}

NSArray<NSDictionary *> *CCPetsProfilesForProvider(NSString *provider) {
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *profile, NSDictionary *bindings) {
        return [profile[@"provider"] isEqualToString:provider];
    }];
    return [CCPetsProfiles() filteredArrayUsingPredicate:predicate];
}

NSDictionary *CCPetsProfileWithID(NSString *profileID) {
    for (NSDictionary *profile in CCPetsProfiles()) {
        if ([profile[@"id"] isEqualToString:profileID]) return profile;
    }
    return nil;
}

NSDictionary *CCPetsProfileForHome(NSString *provider, NSString *home) {
    NSString *canonical = CanonicalHome(home);
    for (NSDictionary *profile in CCPetsProfiles()) {
        if ([profile[@"provider"] isEqualToString:provider] &&
            [profile[@"home"] isEqualToString:canonical]) return profile;
    }
    return nil;
}

NSDictionary *CCPetsRegisterProfile(NSString *provider, NSString *home,
    NSString *displayName, NSString *existingID, NSString **errorMessage) {
    if (!ValidProvider(provider)) {
        if (errorMessage) *errorMessage = @"Provider must be claude or codex.";
        return nil;
    }
    NSString *canonical = CanonicalHome(home);
    BOOL isDirectory = NO;
    if (canonical.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:canonical isDirectory:&isDirectory] || !isDirectory) {
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Profile Home is not a directory: %@", home ?: @""];
        return nil;
    }
    NSString *profileID = existingID.length > 0 ? existingID : CCPetsProfileID(provider, canonical);
    NSString *slug = CCPetsProfileSlug(canonical);
    NSString *name = [displayName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL customName = name.length > 0;
    if (!customName) name = CCPetsProfileDefaultDisplayName(provider, canonical);
    NSMutableArray<NSDictionary *> *profiles = [CCPetsProfiles() mutableCopy];
    NSUInteger replacement = NSNotFound;
    for (NSUInteger index = 0; index < profiles.count; index++) {
        NSDictionary *candidate = profiles[index];
        if (existingID.length > 0 && ![candidate[@"id"] isEqualToString:existingID] &&
            [candidate[@"provider"] isEqualToString:provider] &&
            [candidate[@"home"] isEqualToString:canonical]) {
            if (errorMessage) *errorMessage = @"That Agent Home is already registered.";
            return nil;
        }
        if ([candidate[@"id"] isEqualToString:profileID] ||
            ([candidate[@"provider"] isEqualToString:provider] && [candidate[@"home"] isEqualToString:canonical])) {
            replacement = index;
            break;
        }
    }
    NSNumber *addedAt = replacement == NSNotFound ? @(NSDate.date.timeIntervalSince1970) : profiles[replacement][@"addedAt"];
    NSMutableDictionary *profile = [@{
        @"id": profileID,
        @"provider": provider,
        @"home": canonical,
        @"slug": slug,
        @"displayName": name,
        @"customName": @(customName),
        @"bridgePolicy": @"followGlobal",
        @"addedAt": addedAt ?: @(NSDate.date.timeIntervalSince1970)
    } mutableCopy];
    if (replacement != NSNotFound && [profiles[replacement][@"needsRepair"] boolValue]) {
        profile[@"needsRepair"] = @YES;
    }
    if (replacement == NSNotFound) [profiles addObject:profile]; else profiles[replacement] = profile;
    if (!WriteProfiles(profiles, errorMessage)) return nil;
    return profile;
}

BOOL CCPetsForgetProfile(NSString *profileID, NSString **errorMessage) {
    NSMutableArray<NSDictionary *> *profiles = [CCPetsProfiles() mutableCopy];
    NSIndexSet *matches = [profiles indexesOfObjectsPassingTest:^BOOL(NSDictionary *profile, NSUInteger index, BOOL *stop) {
        return [profile[@"id"] isEqualToString:profileID];
    }];
    if (matches.count == 0) return YES;
    [profiles removeObjectsAtIndexes:matches];
    return WriteProfiles(profiles, errorMessage);
}

BOOL CCPetsSetProfileNeedsRepair(NSString *profileID, BOOL needsRepair, NSString **errorMessage) {
    NSMutableArray<NSDictionary *> *profiles = [CCPetsProfiles() mutableCopy];
    BOOL found = NO;
    for (NSUInteger index = 0; index < profiles.count; index++) {
        if (![profiles[index][@"id"] isEqualToString:profileID]) continue;
        NSMutableDictionary *updated = [profiles[index] mutableCopy];
        if (needsRepair) updated[@"needsRepair"] = @YES;
        else [updated removeObjectForKey:@"needsRepair"];
        profiles[index] = updated;
        found = YES;
        break;
    }
    return !found || WriteProfiles(profiles, errorMessage);
}

static BOOL FileContainsMarker(NSString *path, NSString *marker) {
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return text.length > 0 && [text containsString:marker];
}

NSDictionary *CCPetsProfileStatus(NSDictionary *profile) {
    NSString *provider = profile[@"provider"], *home = profile[@"home"];
    BOOL available = CCPetsDirectoryExists(home);
    if (!available) return @{@"state": CCPetsProfileStateUnavailable, @"available": @NO,
        @"petHooks": @NO, @"bridge": @NO};
    NSString *config = [home stringByAppendingPathComponent:
        [provider isEqualToString:CCPetsProfileProviderClaude] ? @"settings.json" : @"hooks.json"];
    NSString *petMarker = [provider isEqualToString:CCPetsProfileProviderClaude]
        ? CCPetsClaudeHookMarker : CCPetsCodexHookMarker;
    NSString *configText = [NSString stringWithContentsOfFile:config
        encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSString *profileID = [profile[@"id"] isKindOfClass:NSString.class] ? profile[@"id"] : @"";
    BOOL petHooks = [configText containsString:petMarker] &&
        (profileID.length == 0 || [configText containsString:profileID]);
    BOOL bridge = [configText containsString:CCBridgeHookMarker] &&
        (profileID.length == 0 || [configText containsString:profileID]);
    BOOL bridgeExpected = CCBridgeEnabled();
    BOOL healthy = petHooks && (!bridgeExpected || bridge) && ![profile[@"needsRepair"] boolValue];
    return @{@"state": healthy ? CCPetsProfileStateIntegrated : CCPetsProfileStateRepair,
        @"available": @YES, @"petHooks": @(petHooks), @"bridge": @(bridge)};
}

NSString *CCPetsProfileStateTitle(NSString *state) {
    if ([state isEqualToString:CCPetsProfileStateIntegrated]) return L(@"Integrated");
    if ([state isEqualToString:CCPetsProfileStateUnavailable]) return L(@"Home unavailable");
    return L(@"Needs repair");
}

BOOL CCPetsMigrateManagedDefaultProfiles(NSString **errorMessage) {
    NSArray<NSDictionary *> *candidates = @[
        @{@"provider": CCPetsProfileProviderClaude,
          @"home": [CCPetsHomeDirectory() stringByAppendingPathComponent:@".claude"],
          @"file": @"settings.json", @"marker": CCPetsClaudeHookMarker},
        @{@"provider": CCPetsProfileProviderCodex,
          @"home": [CCPetsHomeDirectory() stringByAppendingPathComponent:@".codex"],
          @"file": @"hooks.json", @"marker": CCPetsCodexHookMarker}
    ];
    for (NSDictionary *candidate in candidates) {
        NSString *home = candidate[@"home"];
        NSString *file = [home stringByAppendingPathComponent:candidate[@"file"]];
        if (!FileContainsMarker(file, candidate[@"marker"])) continue;
        if (CCPetsProfileForHome(candidate[@"provider"], home)) continue;
        if (!CCPetsRegisterProfile(candidate[@"provider"], home, nil, nil, errorMessage)) return NO;
    }
    return YES;
}

BOOL CCPetsEnsureOfficialDefaultProfiles(NSString **errorMessage) {
    NSArray<NSDictionary *> *candidates = @[
        @{ @"provider": CCPetsProfileProviderClaude,
           @"home": [CCPetsHomeDirectory() stringByAppendingPathComponent:@".claude"] },
        @{ @"provider": CCPetsProfileProviderCodex,
           @"home": [CCPetsHomeDirectory() stringByAppendingPathComponent:@".codex"] }
    ];
    for (NSDictionary *candidate in candidates) {
        NSString *provider = candidate[@"provider"];
        NSString *home = candidate[@"home"];
        if (CCPetsProfileForHome(provider, home)) continue;
        BOOL isDirectory = NO;
        BOOL homeExists = [NSFileManager.defaultManager fileExistsAtPath:home isDirectory:&isDirectory] && isDirectory;
        BOOL cliInstalled = [provider isEqualToString:CCPetsProfileProviderClaude]
            ? CCPetsClaudeCLIInstalled() : CCPetsCodexCLIInstalled();
        // 官方 Home 是唯一允许自动发现的目录：已有目录直接登记；CLI 已安装但首次尚未
        // 生成目录时创建它。其他任何相似目录都只能由用户从菜单手动添加。
        if (!homeExists && !cliInstalled) continue;
        NSError *directoryError = nil;
        if (!homeExists && ![NSFileManager.defaultManager createDirectoryAtPath:home
                withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
            if (errorMessage) *errorMessage = directoryError.localizedDescription;
            return NO;
        }
        if (!CCPetsRegisterProfile(provider, home, nil, nil, errorMessage)) return NO;
    }
    return YES;
}

static NSString *ValueAfter(NSArray<NSString *> *arguments, NSString *flag) {
    NSUInteger index = [arguments indexOfObject:flag];
    return index != NSNotFound && index + 1 < arguments.count ? arguments[index + 1] : nil;
}

static int AdaptProfile(NSDictionary *profile) {
    NSString *provider = profile[@"provider"], *home = profile[@"home"];
    CCPetsPrintLine(stdout, @"stage=hooks");
    int status = [provider isEqualToString:CCPetsProfileProviderClaude]
        ? InstallClaudeHooksAtHome(CCPetsExecutablePath(), home)
        : InstallCodexHooksAtHome(CCPetsExecutablePath(), home);
    if (status != 0) {
        CCPetsSetProfileNeedsRepair(profile[@"id"], YES, NULL);
        return status;
    }
    if (CCBridgeEnabled()) {
        CCPetsPrintLine(stdout, @"stage=bridge");
        NSArray<NSString *> *report = nil;
        @try {
            report = CCBridgeInstallForProfile(profile, CCBridgeOptions(), YES);
        } @catch (NSException *exception) {
            CCPetsSetProfileNeedsRepair(profile[@"id"], YES, NULL);
            @throw;
        }
        BOOL bridgeFailed = NO;
        for (NSString *line in report) {
            CCPetsPrintLine([line hasPrefix:@"ERROR: "] ? stderr : stdout, line);
            if ([line hasPrefix:@"ERROR: "]) bridgeFailed = YES;
        }
        if (bridgeFailed) {
            CCPetsSetProfileNeedsRepair(profile[@"id"], YES, NULL);
            return 1;
        }
    }
    CCPetsPrintLine(stdout, @"stage=verify");
    CCPetsSetProfileNeedsRepair(profile[@"id"], NO, NULL);
    return 0;
}

int CCPetsProfileCommandMain(NSArray<NSString *> *arguments) {
    @try {
        NSString *command = arguments.firstObject;
        if ([command isEqualToString:@"list"]) {
            NSData *json = [NSJSONSerialization dataWithJSONObject:CCPetsProfiles()
                options:NSJSONWritingPrettyPrinted | NSJSONWritingWithoutEscapingSlashes error:nil];
            fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout);
            return 0;
        }
        if ([command isEqualToString:@"resolve"]) {
            NSDictionary *profile = CCPetsProfileForHome(ValueAfter(arguments, @"--provider"),
                ValueAfter(arguments, @"--home"));
            if (!profile) return 1;
            NSString *field = ValueAfter(arguments, @"--field");
            CCPetsPrintLine(stdout, [field isEqualToString:@"name"]
                ? (profile[@"displayName"] ?: profile[@"slug"] ?: @"") : profile[@"id"]);
            return 0;
        }
        if ([command isEqualToString:@"migrate"]) {
            NSString *error = nil;
            if (!CCPetsMigrateManagedDefaultProfiles(&error)) {
                CCPetsPrintLine(stderr, error); return 1;
            }
            return 0;
        }
        if ([command isEqualToString:@"ensure-defaults"]) {
            NSString *error = nil;
            if (!CCPetsEnsureOfficialDefaultProfiles(&error)) {
                CCPetsPrintLine(stderr, error); return 1;
            }
            return 0;
        }
        if ([command isEqualToString:@"add"]) {
            NSString *provider = ValueAfter(arguments, @"--provider");
            NSString *home = ValueAfter(arguments, @"--home");
            NSString *name = ValueAfter(arguments, @"--name");
            NSString *error = nil;
            NSDictionary *profile = CCPetsRegisterProfile(provider, home, name, nil, &error);
            if (!profile) { CCPetsPrintLine(stderr, error); return 1; }
            CCPetsPrintLine(stdout, @"stage=registered");
            return AdaptProfile(profile);
        }
        if ([command isEqualToString:@"repair"]) {
            NSDictionary *profile = CCPetsProfileWithID(ValueAfter(arguments, @"--id"));
            if (!profile) { CCPetsPrintLine(stderr, @"Profile not found."); return 1; }
            return AdaptProfile(profile);
        }
        if ([command isEqualToString:@"repair-all"]) {
            BOOL failed = NO;
            for (NSDictionary *profile in CCPetsProfiles()) {
                CCPetsPrintLine(stdout, [NSString stringWithFormat:@"profile=%@", profile[@"displayName"]]);
                if (AdaptProfile(profile) != 0) failed = YES;
            }
            return failed ? 1 : 0;
        }
        if ([command isEqualToString:@"update"]) {
            NSString *profileID = ValueAfter(arguments, @"--id");
            NSDictionary *oldProfile = CCPetsProfileWithID(profileID);
            if (!oldProfile) { CCPetsPrintLine(stderr, @"Profile not found."); return 1; }
            NSString *home = ValueAfter(arguments, @"--home") ?: oldProfile[@"home"];
            NSString *requestedName = ValueAfter(arguments, @"--name");
            NSString *name = requestedName ?: ([oldProfile[@"customName"] boolValue]
                ? oldProfile[@"displayName"] : nil);
            NSString *error = nil;
            NSDictionary *profile = CCPetsRegisterProfile(oldProfile[@"provider"], home,
                name, profileID, &error);
            if (!profile) { CCPetsPrintLine(stderr, error); return 1; }
            CCPetsPrintLine(stdout, @"stage=registered");
            int status = AdaptProfile(profile);
            if (status != 0) return status;
            if (![oldProfile[@"home"] isEqualToString:profile[@"home"]]) {
                for (NSString *line in CCBridgeUninstallForProfile(oldProfile, CCBridgeShouldTouchMCP())) {
                    CCPetsPrintLine(stdout, line);
                }
                status = [oldProfile[@"provider"] isEqualToString:CCPetsProfileProviderClaude]
                    ? UninstallClaudeHooksAtHome(oldProfile[@"home"])
                    : UninstallCodexHooksAtHome(oldProfile[@"home"]);
            }
            return status;
        }
        if ([command isEqualToString:@"remove"]) {
            NSString *profileID = ValueAfter(arguments, @"--id");
            NSDictionary *profile = CCPetsProfileWithID(profileID);
            if (!profile) { CCPetsPrintLine(stderr, @"Profile not found."); return 1; }
            BOOL bridgeFailed = NO;
            for (NSString *line in CCBridgeUninstallForProfile(profile, CCBridgeShouldTouchMCP())) {
                CCPetsPrintLine([line hasPrefix:@"ERROR: "] ? stderr : stdout, line);
                if ([line hasPrefix:@"ERROR: "]) bridgeFailed = YES;
            }
            int status = [profile[@"provider"] isEqualToString:CCPetsProfileProviderClaude]
                ? UninstallClaudeHooksAtHome(profile[@"home"])
                : UninstallCodexHooksAtHome(profile[@"home"]);
            if (status != 0) return status;
            if (bridgeFailed) {
                CCPetsSetProfileNeedsRepair(profileID, YES, NULL);
                return 1;
            }
            NSString *error = nil;
            if (!CCPetsForgetProfile(profileID, &error)) {
                CCPetsPrintLine(stderr, error); return 1;
            }
            return 0;
        }
        if ([command isEqualToString:@"forget"]) {
            NSString *error = nil;
            if (!CCPetsForgetProfile(ValueAfter(arguments, @"--id"), &error)) {
                CCPetsPrintLine(stderr, error); return 1;
            }
            return 0;
        }
        CCPetsPrintLine(stderr, @"Usage: cc-pets profile list|resolve|migrate|ensure-defaults|add|update|repair|repair-all|remove");
        return 2;
    } @catch (NSException *exception) {
        CCPetsPrintLine(stderr, exception.reason ?: exception.name);
        return 1;
    }
}
