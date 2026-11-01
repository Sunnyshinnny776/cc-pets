#import "CCPetsLaunchPreflight.h"
#import "CCPetsCLISupport.h"
#import "CCPetsL10n.h"
#import "CCPetsPreferences.h"
#import <netdb.h>

static int BlockLaunch(NSString *provider, NSString *reason) {
    CCPetsPrintLine(stderr, CCPetsInterpolate(
        L(@"CC Pets blocked {provider}: {reason}"), @{@"provider": provider, @"reason": reason}));
    CCPetsPrintLine(stderr, L(@"Connect Shadowrocket and check its node / DNS settings, then retry. You can turn off this check in Main menu → Settings → Launch Protection."));
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

static BOOL HostResolves(NSString *host) {
    // getaddrinfo 走 macOS 系统解析器（包括 VPN 分流 DNS）；限制等待，避免 DNS 故障卡住终端。
    dispatch_group_t group = dispatch_group_create();
    __block BOOL resolved = NO;
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        struct addrinfo hints = {0};
        hints.ai_socktype = SOCK_STREAM;
        hints.ai_family = AF_UNSPEC;
        struct addrinfo *addresses = NULL;
        int result = getaddrinfo(host.UTF8String, "443", &hints, &addresses);
        resolved = result == 0 && addresses != NULL;
        if (addresses) freeaddrinfo(addresses);
    });
    if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC)) != 0) return NO;
    return resolved;
}

int CCPetsLaunchPreflight(NSString *provider) {
    if (![@[@"claude", @"codex"] containsObject:provider]) {
        CCPetsPrintLine(stderr, L(@"Launch check expects claude or codex."));
        return 2;
    }
    if (!CCPetsPrefBool(CCPetsShadowrocketLaunchCheckKey)) return 0;
    NSString *name = [provider isEqualToString:@"claude"] ? @"Claude" : @"Codex";
    CCPetsPrintLine(stderr, L(@"CC Pets: checking Shadowrocket Proxy Status ..."));
    NSString *reason = nil;
    if (!ShadowrocketConnected(&reason)) return BlockLaunch(name, reason);

    NSArray<NSString *> *hosts = [provider isEqualToString:@"claude"]
        ? @[@"api.anthropic.com"] : @[@"api.openai.com", @"chatgpt.com"];
    for (NSString *host in hosts) {
        if (!HostResolves(host)) {
            return BlockLaunch(name, CCPetsInterpolate(L(@"DNS lookup failed or timed out for {host}."), @{@"host": host}));
        }
        NSString *output = nil;
        // -q 必须是首个参数，禁止 ~/.curlrc 注入额外 URL、认证或关闭证书校验。
        // 不携带 CLI token，不跟随重定向；沿用终端的代理环境变量。
        int status = CCPetsRun(@"/usr/bin/curl", @[@"-q", @"--silent", @"--head",
            @"--output", @"/dev/null", @"--write-out", @"%{http_code}",
            @"--connect-timeout", @"4", @"--max-time", @"8", @"--proto", @"=https",
            [NSString stringWithFormat:@"https://%@/", host]], nil, nil, 9, &output, NULL);
        NSInteger httpStatus = output.integerValue;
        // 未认证探测的 401 / 403 / 404 / 429 不能说明代理坏了；只判断 TLS + HTTP 可达性。
        if (status != 0 || httpStatus < 200 || httpStatus >= 500) {
            NSString *detail;
            if (status == 5 || status == 6) detail = L(@"The proxy or service hostname could not be resolved.");
            else if (status == 28 || status == CCPetsRunTimedOut) detail = L(@"The HTTPS connection timed out.");
            else if (status == 35 || status == 60) detail = L(@"TLS negotiation or certificate verification failed.");
            else if (status == 0 && httpStatus >= 500) detail = L(@"The service or proxy returned a server error.");
            else detail = L(@"Unable to establish an HTTPS connection.");
            return BlockLaunch(name, CCPetsInterpolate(L(@"{host}: {detail}"), @{@"host": host, @"detail": detail}));
        }
    }
    // 探测期间用户可能断开 VPN，不沿用之前的状态。
    if (!ShadowrocketConnected(&reason)) return BlockLaunch(name, reason);
    return 0;
}
