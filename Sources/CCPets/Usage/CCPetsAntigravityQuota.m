#import "CCPetsUsage+Internal.h"
#import "CCPetsCLISupport.h"
#import "CCPetsPaths.h"
#import "CCPetsUsageMode.h"
#import <math.h>

static NSDictionary *JSONObject(NSData *data) {
    id value = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSString *WindowKey(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *label = [[[value lowercaseString] componentsSeparatedByCharactersInSet:
        NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@""];
    for (NSString *term in @[@"rolling", @"quota", @"window", @"limit", @"period"]) {
        label = [label stringByReplacingOccurrencesOfString:term withString:@""];
    }
    if ([@[@"5h", @"5hour", @"5hours", @"fivehour", @"fivehours", @"300m"] containsObject:label]) return @"fiveHour";
    if ([@[@"week", @"weekly", @"1week", @"7d", @"7day", @"7days", @"sevenday", @"sevendays", @"168h"] containsObject:label]) return @"week";
    return nil;
}

// 组名（"Gemini Models"）或桶 id（"gemini-weekly"）任一带 gemini 即认定为 Gemini 组。
static BOOL IsGeminiQuotaGroup(NSString *name, NSArray *buckets) {
    if ([name rangeOfString:@"gemini" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    for (id bucket in buckets) {
        id identifier = [bucket isKindOfClass:NSDictionary.class] ? bucket[@"id"] : nil;
        if ([identifier isKindOfClass:NSString.class] &&
            [identifier rangeOfString:@"gemini" options:NSCaseInsensitiveSearch | NSAnchoredSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static NSDictionary *UsageFromAntigravityQuotaReport(NSDictionary *report) {
    if (![report[@"status"] isEqual:@"SUCCESS"]) return nil;
    NSDictionary *command = [report[@"command"] isKindOfClass:NSDictionary.class] ? report[@"command"] : nil;
    if (![command[@"name"] isEqual:@"usage"] && ![command[@"name"] isEqual:@"quota"]) return nil;
    NSDictionary *data = [command[@"data"] isKindOfClass:NSDictionary.class] ? command[@"data"] : nil;
    NSArray *groups = [data[@"groups"] isKindOfClass:NSArray.class] ? data[@"groups"] : nil;
    if (!groups) return nil;

    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSMutableDictionary *usage = [@{@"sampledAt": @(now)} mutableCopy];
    NSMutableArray *quotaGroups = [NSMutableArray array];
    for (id value in groups) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *group = value;
        NSString *name = [group[@"name"] isKindOfClass:NSString.class] ? group[@"name"] : nil;
        NSArray *buckets = [group[@"buckets"] isKindOfClass:NSArray.class] ? group[@"buckets"] : nil;
        if (!name || !buckets) continue;
        BOOL gemini = IsGeminiQuotaGroup(name, buckets);
        NSMutableArray *clean = [NSMutableArray array];
        for (id candidate in buckets) {
            if (![candidate isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *bucket = candidate;
            NSMutableDictionary *details = [NSMutableDictionary dictionary];
            for (NSString *field in @[@"id", @"name", @"description", @"window", @"reset_time"]) {
                if ([bucket[field] isKindOfClass:NSString.class]) details[field] = bucket[field];
            }
            for (NSString *field in @[@"remaining_fraction", @"remaining_amount", @"disabled"]) {
                if ([bucket[field] isKindOfClass:NSNumber.class]) details[field] = bucket[field];
            }
            [clean addObject:details];
            // 订阅额度只看 Gemini 组。Claude/GPT 等第三方模型组各自独立重置，混进来取最紧值时，
            // Gemini 周额度刷新后卡片仍停在第三方组的旧百分比，看起来像数据没更新。
            if (!gemini) continue;
            NSString *key = WindowKey(details[@"window"]) ?: WindowKey(details[@"name"]);
            NSNumber *remaining = details[@"remaining_fraction"];
            if (!key || !remaining || !isfinite(remaining.doubleValue) || [details[@"disabled"] boolValue]) continue;
            if (remaining.doubleValue < 0 || remaining.doubleValue > 1) continue;
            NSDate *reset = ISO8601Timestamp(details[@"reset_time"]);
            if (reset && reset.timeIntervalSince1970 <= now) continue;
            double used = (1.0 - remaining.doubleValue) * 100.0;
            // The overview and menu bar show the most constrained Gemini bucket in each window.
            if (usage[key] && [usage[key][@"used_percent"] doubleValue] >= used) continue;
            NSMutableDictionary *window = [@{@"used_percent": @(used), @"group": name,
                @"window_minutes": [key isEqual:@"week"] ? @10080 : @300} mutableCopy];
            if (reset) window[@"resets_at"] = @(reset.timeIntervalSince1970);
            usage[key] = window;
        }
        [quotaGroups addObject:@{@"name": name, @"buckets": clean}];
    }
    usage[@"quotaGroups"] = quotaGroups;
    return usage;
}

NSDictionary *AntigravityRateLimitsForConfigDirectory(NSString *configDirectory) {
    if (configDirectory.length == 0 || !CCPetsAntigravityQuotaReportEnabled(configDirectory)) return nil;
    NSString *onboardingPath = [configDirectory stringByAppendingPathComponent:@"antigravity-cli/cache/onboarding.json"];
    NSDictionary *onboarding = JSONObject([NSData dataWithContentsOfFile:onboardingPath]);
    if (![onboarding[@"onboardingComplete"] isEqual:@YES] &&
        ![onboarding[@"consumerOnboardingComplete"] isEqual:@YES] &&
        ![onboarding[@"enterpriseOnboardingComplete"] isEqual:@YES]) return nil;

    NSString *searchPath = CCPetsEnvironmentValue(@"PATH");
    NSString *executable = CCPetsFindRealExecutableInPath(@"agy", @"AGY_REAL_BIN", searchPath);
    if (!executable) {
        searchPath = CCPetsLoginShellPath();
        executable = CCPetsFindRealExecutableInPath(@"agy", @"AGY_REAL_BIN", searchPath);
    }
    if (!executable) return nil;
    NSMutableArray *arguments = [NSMutableArray array];
    NSString *standardRoot = [CCPetsHomeDirectory() stringByAppendingPathComponent:@".gemini"];
    if (![configDirectory.stringByStandardizingPath isEqual:standardRoot.stringByStandardizingPath]) {
        // This launcher flag was observed in agy 1.5.12. A version that doesn't recognize
        // it fails before the query; avoid falling back to the default profile's quota.
        [arguments addObject:[@"--gemini_dir=" stringByAppendingString:configDirectory]];
    }
    [arguments addObjectsFromArray:@[@"-p", @"/usage", @"--output-format", @"json"]];
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    if (searchPath.length) environment[@"PATH"] = searchPath;
    // An app launched by one Agent can inherit that session's API or gateway settings.
    for (NSString *key in environment.allKeys) {
        if ([key hasPrefix:@"AGY_LLM_GATEWAY_"] || [@[@"GEMINI_API_KEY", @"GOOGLE_GEMINI_BASE_URL",
            @"AGY_ADC_AUTH", @"GOOGLE_APPLICATION_CREDENTIALS"] containsObject:key]) [environment removeObjectForKey:key];
    }
    environment[@"AGY_CLI_DISABLE_AUTO_UPDATE"] = @"1";
    // Earlier builds can treat /usage as a normal prompt and spend inference quota.
    NSString *versionOutput = nil;
    if (CCPetsRun(executable, @[@"--version"], configDirectory, environment, 4, &versionOutput, NULL) != 0) return nil;
    NSRange versionRange = [versionOutput rangeOfString:@"[0-9]+\\.[0-9]+\\.[0-9]+" options:NSRegularExpressionSearch];
    if (versionRange.location == NSNotFound ||
        [[versionOutput substringWithRange:versionRange] compare:@"1.1.11" options:NSNumericSearch] == NSOrderedAscending) return nil;

    NSString *output = nil;
    int result = CCPetsRun(executable, arguments, configDirectory, environment, 8, &output, NULL);
    if (result != 0) return nil;
    return UsageFromAntigravityQuotaReport(JSONObject([output dataUsingEncoding:NSUTF8StringEncoding]));
}
