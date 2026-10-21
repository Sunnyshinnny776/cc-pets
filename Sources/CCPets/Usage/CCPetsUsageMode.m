#import "CCPetsUsageMode.h"
#import "CCPetsCLISupport.h"
#import "CCPetsJSON.h"
#import "CCPetsPaths.h"

NSNotificationName const CCPetsAuthenticationModesDidChangeNotification = @"CCPetsAuthenticationModesDidChange";
static NSMutableDictionary<NSString *, NSDictionary *> *AuthenticationModes;

static NSString *ProfileCacheKey(NSDictionary *profile) {
    return [NSString stringWithFormat:@"%@:%@", profile[@"provider"] ?: @"", profile[@"home"] ?: @""];
}

static BOOL HasString(id value) { return [value isKindOfClass:NSString.class] && [value length] > 0; }

static NSDictionary *ReadJSONObject(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

static NSString *ClaudeConfiguredMode(NSString *home) {
    id settings = CCPetsReadConfig([home stringByAppendingPathComponent:@"settings.json"], NULL);
    if (![settings isKindOfClass:CCPetsJSONObject.class]) return @"unknown";
    id env = settings[@"env"];
    if (![env isKindOfClass:CCPetsJSONObject.class]) env = nil;
    for (NSString *key in @[@"ANTHROPIC_API_KEY", @"ANTHROPIC_AUTH_TOKEN"]) {
        if (HasString(env[key])) return @"api";
    }
    for (NSString *key in @[@"CLAUDE_CODE_USE_BEDROCK", @"CLAUDE_CODE_USE_VERTEX", @"CLAUDE_CODE_USE_FOUNDRY"]) {
        id value = env[key];
        if ([value respondsToSelector:@selector(boolValue)] && [value boolValue]) return @"api";
    }
    if (HasString(settings[@"apiKeyHelper"])) return @"api";
    if (HasString(env[@"CLAUDE_CODE_OAUTH_TOKEN"])) return @"subscription";
    return @"unknown";
}

// 不能把第三方推理服务的 ChatGPT 登录身份等同于订阅计费。
// 只识别简单、明确的顶层配置；复杂 TOML 或第三方路由保持 unknown。
static BOOL CodexHasCustomProvider(NSString *home) {
    NSString *config = [NSString stringWithContentsOfFile:[home stringByAppendingPathComponent:@"config.toml"]
        encoding:NSUTF8StringEncoding error:nil];
    __block BOOL custom = NO;
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:
        @"^(?:[\"']?)(model_provider|profile)(?:[\"']?)\\s*=\\s*['\"]([^'\"]+)['\"]\\s*(?:#.*)?$"
        options:0 error:nil];
    [config enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([trimmed hasPrefix:@"["]) { *stop = YES; return; }
        if ([trimmed hasPrefix:@"#"]) return;
        NSTextCheckingResult *match = [expression firstMatchInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)];
        if (match) {
            custom = [[trimmed substringWithRange:[match rangeAtIndex:1]] isEqualToString:@"profile"] ||
                ![[trimmed substringWithRange:[match rangeAtIndex:2]] isEqualToString:@"openai"];
            *stop = YES;
        }
    }];
    return custom;
}

static NSString *ProbeAuthenticationMode(NSDictionary *profile, NSString *searchPath) {
    NSString *provider = profile[@"provider"], *home = profile[@"home"];
    if (!CCPetsDirectoryExists(home)) return @"unknown";
    BOOL claude = [provider isEqualToString:@"claude"];
    NSString *fallback = claude ? ClaudeConfiguredMode(home) : @"unknown";
    if (!claude) {
        // https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/storage.rs
        // 显式 auth_mode 优先于文件里残留的其他凭据。
        NSDictionary *auth = ReadJSONObject([home stringByAppendingPathComponent:@"auth.json"]);
        NSString *mode = HasString(auth[@"auth_mode"]) ? auth[@"auth_mode"] : nil;
        if ([@[@"apikey", @"bedrockApiKey", @"bedrockAccessKeys"] containsObject:mode ?: @""]) return @"api";
        BOOL key = HasString(auth[@"OPENAI_API_KEY"]);
        BOOL tokens = [auth[@"tokens"] isKindOfClass:NSDictionary.class] &&
            HasString(auth[@"tokens"][@"access_token"]);
        if (!mode && key && !tokens) return @"api";
        if (CodexHasCustomProvider(home)) return @"unknown";
        if ([@[@"chatgpt", @"chatgptAuthTokens"] containsObject:mode ?: @""]) return @"subscription";
        if (!mode && key != tokens) return key ? @"api" : @"subscription";
    }
    NSString *executable = CCPetsFindRealExecutableInPath(provider,
        claude ? @"CLAUDE_REAL_BIN" : @"CODEX_REAL_BIN", searchPath);
    if (!executable) return fallback;
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    // 常驻 App 不能把拉起它的第一个客户端的凭据套给其他账号。每份 Home 自己提供认证配置。
    for (NSString *key in @[@"ANTHROPIC_API_KEY", @"ANTHROPIC_AUTH_TOKEN", @"ANTHROPIC_BASE_URL",
            @"ANTHROPIC_CUSTOM_HEADERS", @"ANTHROPIC_PROFILE",
            @"CLAUDE_CODE_OAUTH_TOKEN", @"CLAUDE_CODE_USE_BEDROCK", @"CLAUDE_CODE_USE_VERTEX",
            @"CLAUDE_CODE_USE_FOUNDRY", @"OPENAI_API_KEY", @"OPENAI_BASE_URL", @"CODEX_API_KEY", @"CODEX_ACCESS_TOKEN"]) {
        [environment removeObjectForKey:key];
    }
    environment[claude ? @"CLAUDE_CONFIG_DIR" : @"CODEX_HOME"] = home;
    if (searchPath.length > 0) environment[@"PATH"] = searchPath;
    NSString *output = nil, *errors = nil;
    int status = CCPetsRun(executable, claude ? @[@"auth", @"status"] : @[@"login", @"status"],
        home, environment, 5, &output, &errors);
    if (status != 0) return fallback;
    if (claude) {
        // https://code.claude.com/docs/en/cli-reference#cli-commands
        // JSON 只取 authMethod；邮箱、订阅细节及 CLI 输出均不保留。
        NSData *data = [output dataUsingEncoding:NSUTF8StringEncoding];
        id auth = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![auth isKindOfClass:NSDictionary.class]) return fallback;
        NSString *reportedHome = auth[@"configDirectory"];
        if (HasString(reportedHome) && ![reportedHome.stringByResolvingSymlinksInPath
                isEqualToString:home.stringByResolvingSymlinksInPath]) return fallback;
        NSString *method = auth[@"authMethod"];
        if ([@[@"api_key", @"api_key_helper", @"third_party"] containsObject:method ?: @""]) return @"api";
        if ([@[@"claude.ai", @"oauth_token"] containsObject:method ?: @""]) return @"subscription";
    } else {
        // login status 支持 Keychain 存储；输出可能包含密钥片段，只在此处匹配固定认证名称。
        NSString *text = [[NSString stringWithFormat:@"%@\n%@", output ?: @"", errors ?: @""] lowercaseString];
        if ([text containsString:@"logged in using an api key"]) return @"api";
        if ([text containsString:@"logged in using chatgpt"]) return @"subscription";
    }
    return fallback;
}

void CCPetsRefreshProfileAuthenticationModes(NSArray<NSDictionary *> *profiles) {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSString *searchPath = nil;
    BOOL changed = NO;
    for (NSDictionary *profile in profiles) {
        NSString *key = ProfileCacheKey(profile);
        NSDictionary *previous;
        @synchronized(CCPetsAuthenticationModesDidChangeNotification) { previous = AuthenticationModes[key]; }
        if (previous && now - [previous[@"checkedAt"] doubleValue] < 60) continue;
        if (!searchPath) searchPath = CCPetsLoginShellPath() ?: @"";
        NSString *mode = ProbeAuthenticationMode(profile, searchPath);
        @synchronized(CCPetsAuthenticationModesDidChangeNotification) {
            if (!AuthenticationModes) AuthenticationModes = [NSMutableDictionary dictionary];
            AuthenticationModes[key] = @{@"mode": mode, @"checkedAt": @(now)};
        }
        if (![mode isEqualToString:previous[@"mode"] ?: @"unknown"]) changed = YES;
    }
    if (changed) dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:CCPetsAuthenticationModesDidChangeNotification object:nil];
    });
}

NSString *CCPetsProfileAuthenticationMode(NSDictionary *profile) {
    @synchronized(CCPetsAuthenticationModesDidChangeNotification) {
        return AuthenticationModes[ProfileCacheKey(profile)][@"mode"] ?: @"unknown";
    }
}

NSString *CCPetsUsageModePreferenceKey(NSDictionary *profile) {
    NSString *profileID = profile[@"id"];
    if (profileID.length > 0) return [@"CCPetsUsageDisplayMode." stringByAppendingString:profileID];
    return [profile[@"provider"] isEqualToString:@"codex"] ? CodexUsageDisplayModeKey : ClaudeUsageDisplayModeKey;
}

BOOL CCPetsProfileCanSwitchUsageMode(NSDictionary *profile) {
    return ![CCPetsProfileAuthenticationMode(profile) isEqualToString:@"api"];
}

BOOL CCPetsProfileShowsAPIUsage(NSDictionary *profile) {
    if (!CCPetsProfileCanSwitchUsageMode(profile)) return YES;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *mode = [defaults stringForKey:CCPetsUsageModePreferenceKey(profile)];
    if (!mode) mode = [defaults stringForKey:[profile[@"provider"] isEqualToString:@"codex"]
        ? CodexUsageDisplayModeKey : ClaudeUsageDisplayModeKey];
    return [mode isEqualToString:@"api"];
}
