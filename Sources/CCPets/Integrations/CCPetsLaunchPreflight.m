#import "CCPetsLaunchPreflight.h"
#import "CCPetsCLISupport.h"
#import "CCPetsL10n.h"
#import "CCPetsPreferences.h"
#import <arpa/inet.h>

static int BlockLaunch(NSString *provider, NSString *reason) {
    CCPetsPrintLine(stderr, CCPetsInterpolate(
        L(@"CC Pets blocked {provider}: {reason}"), @{@"provider": provider, @"reason": reason}));
    CCPetsPrintLine(stderr, L(@"Connect Shadowrocket and select an exit outside mainland China / Hong Kong, then check routing and DNS settings. You can turn off this check in Main menu → Settings → Launch Protection."));
    return 1;
}

static BOOL ShadowrocketConnected(NSString **reason) {
    NSString *output = nil;
    // 只匹配 VPN provider ID；用户改过服务名称仍能识别，其他 VPN 不会被误认。
    int status = CCPetsRun(@"/usr/sbin/scutil", @[@"--nc", @"list"], nil, nil, 3, &output, NULL);
    if (status != 0) {
        *reason = L(@"Unable to read the system VPN status.");
        return NO;
    }
    NSRegularExpression *providerPattern = [NSRegularExpression regularExpressionWithPattern:
        @"\\[VPN:com\\.liguangming\\.Shadowrocket\\]\\s*$" options:0 error:nil];
    NSRegularExpression *connectedPattern = [NSRegularExpression regularExpressionWithPattern:
        @"^\\*\\s+\\(Connected\\)\\s+" options:0 error:nil];
    BOOL found = NO;
    for (NSString *line in [output componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSRange range = NSMakeRange(0, line.length);
        if (![providerPattern firstMatchInString:line options:0 range:range]) continue;
        found = YES;
        if ([connectedPattern firstMatchInString:line options:0 range:range]) return YES;
    }
    *reason = found ? L(@"Shadowrocket is not connected. Opening the app alone is not enough.")
                    : L(@"No Shadowrocket VPN configuration was found.");
    return NO;
}

static NSDictionary *ReadJSONObject(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSString *NonemptyString(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 ? value : nil;
}

// 仅支持明确的单行 TOML 字符串。未支持的路由写法必须报错，不能猜测官方出口。
static NSDictionary *CodexRouting(NSString *home, NSString **reason) {
    NSString *path = [home stringByAppendingPathComponent:@"config.toml"];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return @{};
    NSString *config = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!config) { *reason = L(@"Unable to read the CLI network configuration."); return nil; }
    NSMutableDictionary *routing = [NSMutableDictionary dictionary];
    __block NSString *section = @"";
    __block NSString *multilineDelimiter = nil;
    __block BOOL valid = YES;
    NSRegularExpression *table = [NSRegularExpression regularExpressionWithPattern:
        @"^\\[([A-Za-z0-9_.-]+)\\]\\s*(?:#.*)?$" options:0 error:nil];
    NSRegularExpression *assignment = [NSRegularExpression regularExpressionWithPattern:
        @"^([A-Za-z0-9_.-]+)\\s*=\\s*(\"(?:[^\"\\\\]|\\\\.)*\"|'[^']*')\\s*(?:#.*)?$" options:0 error:nil];
    NSRegularExpression *routeKey = [NSRegularExpression regularExpressionWithPattern:
        @"(?:^|[^A-Za-z0-9_])(model_provider|model_providers|profile|profiles|base_url|chatgpt_base_url)(?:[^A-Za-z0-9_]|$)"
        options:0 error:nil];
    [config enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (multilineDelimiter) {
            if ([trimmed containsString:multilineDelimiter]) multilineDelimiter = nil;
            return;
        }
        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"]) return;
        for (NSString *delimiter in @[@"\"\"\"", @"'''"]) {
            NSRange start = [trimmed rangeOfString:delimiter];
            if (start.location == NSNotFound) continue;
            NSString *key = [[trimmed componentsSeparatedByString:@"="] firstObject];
            if ([routeKey firstMatchInString:key options:0 range:NSMakeRange(0, key.length)]) valid = NO;
            if (![[trimmed substringFromIndex:NSMaxRange(start)] containsString:delimiter]) multilineDelimiter = delimiter;
            return;
        }
        if ([trimmed hasPrefix:@"["]) {
            NSTextCheckingResult *match = [table firstMatchInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)];
            // 引号表名、内联表和多行值不在本探测器的 TOML 子集内。
            if (!match && [routeKey firstMatchInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)]) valid = NO;
            section = match ? [trimmed substringWithRange:[match rangeAtIndex:1]] : @"<other>";
            return;
        }
        NSString *key = [[trimmed componentsSeparatedByString:@"="] firstObject];
        if ([section isEqualToString:@"model_providers"] || [section isEqualToString:@"profiles"]) { valid = NO; return; }
        if (![routeKey firstMatchInString:key options:0 range:NSMakeRange(0, key.length)]) return;
        if (section.length > 0 && ![section hasPrefix:@"profiles."] && ![section hasPrefix:@"model_providers."]) return;
        NSTextCheckingResult *match = [assignment firstMatchInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)];
        if (!match) { valid = NO; return; }
        key = [trimmed substringWithRange:[match rangeAtIndex:1]];
        NSString *literal = [trimmed substringWithRange:[match rangeAtIndex:2]];
        NSString *value = [literal hasPrefix:@"'"] ? [literal substringWithRange:NSMakeRange(1, literal.length - 2)] :
            [NSJSONSerialization JSONObjectWithData:[literal dataUsingEncoding:NSUTF8StringEncoding]
                options:NSJSONReadingFragmentsAllowed error:nil];
        NSString *fullKey = section.length > 0 ? [section stringByAppendingFormat:@".%@", key] : key;
        if (!NonemptyString(value) || routing[fullKey]) { valid = NO; return; }
        routing[fullKey] = value;
    }];
    if (!valid || multilineDelimiter) { *reason = L(@"Unable to determine the CLI endpoint from its network configuration."); return nil; }
    return routing;
}

static NSString *TraceURL(NSString *baseURL, NSString **reason) {
    NSURLComponents *url = [NSURLComponents componentsWithString:baseURL];
    if (![url.scheme.lowercaseString isEqualToString:@"https"] || !url.host.length || url.user || url.password) {
        *reason = L(@"The exit check requires an HTTPS endpoint without embedded credentials.");
        return nil;
    }
    url.path = @"/cdn-cgi/trace";
    url.query = nil;
    url.fragment = nil;
    return url.string;
}

static NSArray<NSString *> *ProbeURLs(NSString *provider, NSMutableDictionary *environment, NSString *selectedProfile, NSString **reason) {
    if ([provider isEqualToString:@"claude"]) {
        // 读取网络相关 env，不执行 apiKeyHelper，也不把账号凭据放进探测请求。
        NSString *path = [CCPetsClaudeHome() stringByAppendingPathComponent:@"settings.json"];
        NSDictionary *settings = ReadJSONObject(path);
        if (!settings && [NSFileManager.defaultManager fileExistsAtPath:path]) {
            *reason = L(@"Unable to read the CLI network configuration."); return nil;
        }
        NSDictionary *env = [settings[@"env"] isKindOfClass:NSDictionary.class] ? settings[@"env"] : @{};
        for (NSString *key in @[@"ANTHROPIC_BASE_URL", @"HTTPS_PROXY", @"https_proxy", @"HTTP_PROXY", @"http_proxy",
                @"NO_PROXY", @"no_proxy", @"CLAUDE_CODE_USE_BEDROCK", @"CLAUDE_CODE_USE_VERTEX", @"CLAUDE_CODE_USE_FOUNDRY"]) {
            if ([env[key] isKindOfClass:NSString.class]) environment[key] = env[key];
        }
        for (NSString *key in @[@"CLAUDE_CODE_USE_BEDROCK", @"CLAUDE_CODE_USE_VERTEX", @"CLAUDE_CODE_USE_FOUNDRY"]) {
            if ([environment[key] isEqualToString:@"1"]) {
                *reason = L(@"Exit checks for this cloud provider are not supported. No official-domain fallback was used."); return nil;
            }
        }
        // curl 与 Claude 对代理变量的优先级不同，明确指定 Claude 的 HTTPS 代理。
        NSString *proxy = NonemptyString(environment[@"https_proxy"]) ?: NonemptyString(environment[@"HTTPS_PROXY"]) ?:
            NonemptyString(environment[@"http_proxy"]) ?: NonemptyString(environment[@"HTTP_PROXY"]);
        [environment removeObjectForKey:@"ALL_PROXY"];
        [environment removeObjectForKey:@"all_proxy"];
        if (proxy) { environment[@"https_proxy"] = proxy; environment[@"HTTPS_PROXY"] = proxy; }
        NSString *url = TraceURL(NonemptyString(environment[@"ANTHROPIC_BASE_URL"]) ?: @"https://api.anthropic.com", reason);
        return url ? @[url] : nil;
    }

    NSDictionary *routing = CodexRouting(CCPetsCodexHome(), reason);
    if (!routing) return nil;
    NSString *profile = selectedProfile ?: routing[@"profile"];
    if (profile) {
        NSString *prefix = [NSString stringWithFormat:@"profiles.%@.", profile];
        NSMutableDictionary *effective = [routing mutableCopy];
        for (NSString *key in routing) {
            if ([key hasPrefix:prefix]) effective[[key substringFromIndex:prefix.length]] = routing[key];
        }
        routing = effective;
    }
    NSString *modelProvider = routing[@"model_provider"] ?: @"openai";
    NSString *baseURL = routing[[NSString stringWithFormat:@"model_providers.%@.base_url", modelProvider]];
    if (!baseURL && [modelProvider isEqualToString:@"openai"]) baseURL = NonemptyString(environment[@"OPENAI_BASE_URL"]);
    if (baseURL) {
        NSString *url = TraceURL(baseURL, reason);
        return url ? @[url] : nil;
    }
    if (![modelProvider isEqualToString:@"openai"]) {
        *reason = L(@"Unable to determine the CLI endpoint from its network configuration."); return nil;
    }
    NSString *chatGPTBase = routing[@"chatgpt_base_url"] ?: @"https://chatgpt.com";
    NSDictionary *auth = ReadJSONObject([CCPetsCodexHome() stringByAppendingPathComponent:@"auth.json"]);
    NSString *mode = NonemptyString(auth[@"auth_mode"]);
    BOOL api = [mode isEqualToString:@"apikey"];
    BOOL chatGPT = [@[@"chatgpt", @"chatgptAuthTokens"] containsObject:mode ?: @""];
    if (!mode) {
        BOOL key = NonemptyString(auth[@"OPENAI_API_KEY"]) != nil;
        NSDictionary *tokens = [auth[@"tokens"] isKindOfClass:NSDictionary.class] ? auth[@"tokens"] : nil;
        BOOL token = NonemptyString(tokens[@"access_token"]) != nil;
        api = key && !token;
        chatGPT = token && !key;
    }
    if (mode && !api && !chatGPT) {
        *reason = L(@"Unable to determine the CLI endpoint from its network configuration."); return nil;
    }
    NSString *chatGPTURL = TraceURL(chatGPTBase, reason);
    if (!chatGPTURL) return nil;
    if (api) return @[@"https://api.openai.com/cdn-cgi/trace"];
    if (chatGPT) return @[chatGPTURL];
    // 未登录或凭据位于 Keychain 时不猜模式；两个候选出口都必须通过。
    CCPetsPrintLine(stderr, L(@"Codex login mode is unknown; checking both ChatGPT and OpenAI API exits."));
    return @[chatGPTURL, @"https://api.openai.com/cdn-cgi/trace"];
}

static NSDictionary *ParseTrace(NSString *body, NSString *host) {
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    for (NSString *line in [body componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSRange equals = [line rangeOfString:@"="];
        if (equals.location == NSNotFound) continue;
        NSString *key = [line substringToIndex:equals.location];
        if (![@[@"ip", @"loc", @"h"] containsObject:key]) continue;
        if (fields[key]) return nil;
        fields[key] = [line substringFromIndex:NSMaxRange(equals)];
    }
    NSString *ip = fields[@"ip"], *loc = fields[@"loc"];
    struct in6_addr address;
    if (!ip || (inet_pton(AF_INET, ip.UTF8String, &address) != 1 && inet_pton(AF_INET6, ip.UTF8String, &address) != 1)) return nil;
    if (loc.length != 2 || ![NSLocale.ISOCountryCodes containsObject:loc]) return nil;
    if (![fields[@"h"] isKindOfClass:NSString.class] || ![[fields[@"h"] lowercaseString] isEqualToString:host.lowercaseString]) return nil;
    return fields;
}

static const NSTimeInterval ExitConnectTimeout = 8;
static const NSTimeInterval ExitRequestTimeout = 15;
static const NSTimeInterval ExitProcessTimeout = 16;
static const NSInteger ExitMaxAttempts = 2;

static BOOL RetryableExitFailure(int status, NSInteger httpStatus) {
    // 仅重试临时传输故障和网关错误，不重试 TLS / 证书错误、拒绝访问或无效 trace。
    if (status == 0) return httpStatus == 502 || httpStatus == 503 || httpStatus == 504;
    return status == CCPetsRunTimedOut || [@[@5, @6, @7, @18, @28, @52, @55, @56, @92] containsObject:@(status)];
}

static NSDictionary *ProbeExit(NSString *url, NSString *host, NSDictionary *environment, NSString **reason) {
    for (NSInteger attempt = 1; attempt <= ExitMaxAttempts; attempt++) {
        NSString *output = nil;
        NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
        // -q 必须是首个参数；不携带 CLI token、不跟随重定向、正常校验证书。
        // write-out 单独占最后一行，避免把 trace 正文或错误页当作诊断指标。
        // 不使用 curl --retry，确保每次尝试独立解析，不能用旧的合法响应掩盖后续失败。
        int status = CCPetsRun(@"/usr/bin/curl", @[@"-q", @"--silent", @"--globoff", @"--request", @"GET",
            @"--write-out", @"\n%{http_code}\t%{time_namelookup}\t%{time_connect}\t%{time_appconnect}\t%{time_starttransfer}\t%{time_total}",
            @"--max-filesize", @"16384",
            @"--connect-timeout", [NSString stringWithFormat:@"%.0f", ExitConnectTimeout],
            @"--max-time", [NSString stringWithFormat:@"%.0f", ExitRequestTimeout], @"--proto", @"=https", url],
            nil, environment, ExitProcessTimeout, &output, NULL);
        NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - started;
        NSRange separator = output ? [output rangeOfString:@"\n" options:NSBackwardsSearch] : NSMakeRange(NSNotFound, 0);
        NSArray<NSString *> *metrics = separator.location == NSNotFound ? @[] :
            [[output substringFromIndex:NSMaxRange(separator)] componentsSeparatedByString:@"\t"];
        BOOL hasMetrics = metrics.count == 6;
        NSInteger httpStatus = hasMetrics ? metrics[0].integerValue : 0;
        NSString *detail;
        if (status == 0 && httpStatus == 200) {
            NSDictionary *trace = ParseTrace([output substringToIndex:separator.location], host);
            if (trace) return trace;
            detail = L(@"No valid exit IP / region was returned.");
        } else if (status == CCPetsRunTimedOut) {
            detail = L(@"The exit-check process exceeded its 16s limit.");
        } else if (status == 28) {
            if (!hasMetrics) detail = L(@"The exit request timed out; connection timing is unavailable.");
            else if (metrics[3].doubleValue <= 0) detail = L(@"Connection timed out before HTTPS was ready (DNS / TCP / TLS; 8s limit).");
            else detail = L(@"HTTPS connected, but the response did not complete within the 15s request limit.");
        } else if (status == 5 || status == 6) {
            detail = L(@"The proxy or service hostname could not be resolved.");
        } else if (status == 35 || status == 60) {
            detail = L(@"TLS negotiation or certificate verification failed.");
        } else if (status == 0) {
            detail = CCPetsInterpolate(L(@"The exit-region endpoint returned HTTP {status}; the exit region could not be confirmed."),
                @{@"status": @(httpStatus)});
        } else {
            detail = L(@"The exit-region request failed; the exit region could not be confirmed.");
        }
        // 只输出数值指标，不输出代理 URL、认证信息、curl 原始错误或服务响应正文。
        NSString *diagnostics = CCPetsInterpolate(
            L(@"Attempt {attempt}/{max}; elapsed {elapsed}s; curl={code}; HTTP={http}; DNS={dns}s, TCP={tcp}s, TLS={tls}s, first byte={first}s, request={total}s (cumulative timings)."),
            @{@"attempt": @(attempt), @"max": @(ExitMaxAttempts), @"elapsed": [NSString stringWithFormat:@"%.2f", elapsed],
              @"code": @(status), @"http": @(httpStatus),
              @"dns": hasMetrics ? [NSString stringWithFormat:@"%.3f", metrics[1].doubleValue] : @"-",
              @"tcp": hasMetrics ? [NSString stringWithFormat:@"%.3f", metrics[2].doubleValue] : @"-",
              @"tls": hasMetrics ? [NSString stringWithFormat:@"%.3f", metrics[3].doubleValue] : @"-",
              @"first": hasMetrics ? [NSString stringWithFormat:@"%.3f", metrics[4].doubleValue] : @"-",
              @"total": hasMetrics ? [NSString stringWithFormat:@"%.3f", metrics[5].doubleValue] : @"-"});
        *reason = [NSString stringWithFormat:@"%@ %@", detail, diagnostics];
        if (attempt == ExitMaxAttempts || !RetryableExitFailure(status, httpStatus)) return nil;
        CCPetsPrintLine(stderr, CCPetsInterpolate(
            L(@"CC Pets: {host}: {detail} Retrying in 1s (attempt 2/2)."), @{@"host": host, @"detail": *reason}));
        [NSThread sleepForTimeInterval:1];
        if (!ShadowrocketConnected(reason)) return nil;
    }
    return nil;
}

// 不静默忽略会改变目标服务的命令行覆盖；配置 profile 可以直接参与解析。
static BOOL ResolveArguments(NSString *provider, NSArray<NSString *> *arguments, NSString **profile, NSString **directory) {
    BOOL codex = [provider isEqualToString:@"codex"];
    for (NSUInteger index = 0; index < arguments.count; index++) {
        NSString *argument = arguments[index];
        if ([argument isEqualToString:@"--"]) break;
        if (codex && ([@[@"--profile", @"-p"] containsObject:argument] || [argument hasPrefix:@"--profile="])) {
            NSString *value = [argument hasPrefix:@"--profile="] ? [argument substringFromIndex:10] :
                (++index < arguments.count ? arguments[index] : nil);
            if (!value.length) return NO;
            *profile = value;
        } else if (codex && ([@[@"--cd", @"-C"] containsObject:argument] || [argument hasPrefix:@"--cd="])) {
            NSString *value = [argument hasPrefix:@"--cd="] ? [argument substringFromIndex:5] :
                (++index < arguments.count ? arguments[index] : nil);
            if (!value.length) return NO;
            *directory = CCPetsResolvePath(value);
        } else if (codex && ([@[@"-c", @"--config", @"--oss", @"--local-provider"] containsObject:argument] ||
                [argument hasPrefix:@"--config="] || [argument hasPrefix:@"--local-provider="] ||
                [argument hasPrefix:@"-c"] || [argument hasPrefix:@"-p"] || [argument hasPrefix:@"-C"])) {
            // -c 可以覆盖任意嵌套项，不能当作默认配置放行。
            return NO;
        } else if (!codex && ([@[@"--settings", @"--setting-sources"] containsObject:argument] ||
                [argument hasPrefix:@"--settings="] || [argument hasPrefix:@"--setting-sources="])) return NO;
    }
    return YES;
}

static BOOL HasLocalNetworkOverrides(NSString *provider, NSString *directory) {
    BOOL claude = [provider isEqualToString:@"claude"];
    NSArray *networkKeys = @[@"ANTHROPIC_BASE_URL", @"HTTPS_PROXY", @"https_proxy", @"HTTP_PROXY", @"http_proxy",
        @"NO_PROXY", @"no_proxy", @"CLAUDE_CODE_USE_BEDROCK", @"CLAUDE_CODE_USE_VERTEX", @"CLAUDE_CODE_USE_FOUNDRY"];
    // 项目配置是否受信任由 CLI 判断。包装器不替 CLI 信任项目中的代理地址。
    for (NSString *parent = directory; parent.length > 0; parent = parent.stringByDeletingLastPathComponent) {
        NSString *configHome = [parent stringByAppendingPathComponent:claude ? @".claude" : @".codex"];
        NSString *userHome = claude ? CCPetsClaudeHome() : CCPetsCodexHome();
        if (![configHome.stringByResolvingSymlinksInPath isEqualToString:userHome.stringByResolvingSymlinksInPath]) {
            if (claude) {
                for (NSString *file in @[@"settings.json", @"settings.local.json"]) {
                    NSString *path = [configHome stringByAppendingPathComponent:file];
                    NSDictionary *settings = ReadJSONObject(path);
                    if (!settings && [NSFileManager.defaultManager fileExistsAtPath:path]) return YES;
                    NSDictionary *env = [settings[@"env"] isKindOfClass:NSDictionary.class] ? settings[@"env"] : nil;
                    for (NSString *key in networkKeys) if (env[key]) return YES;
                }
            } else {
                NSString *reason = nil;
                NSDictionary *routing = CodexRouting(configHome, &reason);
                if (!routing || routing.count > 0) return YES;
            }
        }
        if ([parent isEqualToString:@"/"]) break;
    }
    return NO;
}

int CCPetsLaunchPreflight(NSString *provider, NSArray<NSString *> *arguments) {
    if (![@[@"claude", @"codex"] containsObject:provider]) {
        CCPetsPrintLine(stderr, L(@"Launch check expects claude or codex."));
        return 2;
    }
    if (!CCPetsPrefBool(CCPetsShadowrocketLaunchCheckKey)) return 0;
    NSString *name = [provider isEqualToString:@"claude"] ? @"Claude" : @"Codex";
    CCPetsPrintLine(stderr, L(@"CC Pets: checking Shadowrocket and service exit regions ..."));
    NSString *reason = nil;
    if (!ShadowrocketConnected(&reason)) return BlockLaunch(name, reason);

    NSString *profile = nil, *directory = NSFileManager.defaultManager.currentDirectoryPath;
    if (!ResolveArguments(provider, arguments, &profile, &directory) || HasLocalNetworkOverrides(provider, directory)) {
        return BlockLaunch(name, L(@"CLI arguments or project network overrides cannot be verified by this exit check."));
    }
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    NSArray<NSString *> *urls = ProbeURLs(provider, environment, profile, &reason);
    if (!urls) return BlockLaunch(name, reason);
    for (NSString *url in urls) {
        NSURLComponents *components = [NSURLComponents componentsWithString:url];
        NSString *host = components.port ? [components.host stringByAppendingFormat:@":%@", components.port] : components.host;
        NSDictionary *trace = ProbeExit(url, host, environment, &reason);
        if (!trace) return BlockLaunch(name, CCPetsInterpolate(L(@"{host}: {detail}"), @{@"host": host, @"detail": reason}));
        if ([@[@"CN", @"HK"] containsObject:trace[@"loc"]]) return BlockLaunch(name, CCPetsInterpolate(
            L(@"{host}: exit {ip} ({region}) is in mainland China / Hong Kong."),
            @{@"host": host, @"ip": trace[@"ip"], @"region": trace[@"loc"]}));
        CCPetsPrintLine(stderr, CCPetsInterpolate(L(@"CC Pets: {host} exit {ip} ({region}) passed."),
            @{@"host": host, @"ip": trace[@"ip"], @"region": trace[@"loc"]}));
    }
    // 探测期间用户可能断开 VPN，不沿用之前的状态。
    if (!ShadowrocketConnected(&reason)) return BlockLaunch(name, reason);
    return 0;
}
