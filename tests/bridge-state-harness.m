#import <Foundation/Foundation.h>
#import "CCPetsBridge.h"

// 桌宠读取 CC Bridge 状态的只读视图：会话名、最近送达、信箱积压、开关。
// 重点守住两条：只返回元数据（正文不能出现在返回值里）；只认已送达的真实跨会话消息。

static BOOL Check(BOOL condition, NSString *message) {
    if (!condition) fprintf(stderr, "%s\n", message.UTF8String);
    return condition;
}

static void WriteJSON(NSString *directory, NSString *name, id object) {
    [NSFileManager.defaultManager createDirectoryAtPath:directory
        withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    [data writeToFile:[directory stringByAppendingPathComponent:name] atomically:YES];
}

int main(void) {
    @autoreleasepool {
        NSString *home = NSProcessInfo.processInfo.environment[@"CC_PETS_HOME"];
        if (!Check(!CCBridgeEnabled(), @"没有开关文件时应视为未开启")) return EXIT_FAILURE;
        NSDictionary *defaults = CCBridgeOptions();
        if (!Check([defaults[@"wake"] boolValue] && [defaults[@"editGuard"] boolValue] &&
                   [defaults[@"codexApprove"] count] == 0, @"未开启时选项应为默认值")) return EXIT_FAILURE;
        [NSFileManager.defaultManager createDirectoryAtPath:home
            withIntermediateDirectories:YES attributes:nil error:nil];
        [@"{\"codexApprove\":[\"send_message\",\"rm_rf\",\"list_agents\"],\"claudeAllow\":[\"set_name\"],"
          "\"wake\":false}\n" writeToFile:[home stringByAppendingPathComponent:@"bridge-enabled"]
            atomically:YES encoding:NSUTF8StringEncoding error:nil];
        if (!Check(CCBridgeEnabled(), @"有开关文件时应视为开启")) return EXIT_FAILURE;
        NSDictionary *options = CCBridgeOptions();
        if (!Check([options[@"codexApprove"] isEqual:(@[@"list_agents", @"send_message"])],
                   @"应过滤未知工具并按分组顺序排列")) return EXIT_FAILURE;
        if (!Check([options[@"claudeAllow"] isEqual:@[@"set_name"]], @"应读出 Claude 放行")) return EXIT_FAILURE;
        if (!Check(![options[@"wake"] boolValue] && [options[@"editGuard"] boolValue],
                   @"wake=false 应读出关闭，缺省的 editGuard 应为开启")) return EXIT_FAILURE;
        if (!Check([CCBridgeToolGroup(@"reserve") isEqual:(@[@"reserve_files", @"release_files"])] &&
                   CCBridgeToolGroup(@"nope").count == 0, @"分组定义")) return EXIT_FAILURE;

        // CLI 定位：路径必须存在，否则返回 nil（桌宠据此提示用户重新 cc-pets install）。
        NSString *locator = [home stringByAppendingPathComponent:@"bridge-cli.json"];
        if (!Check(CCBridgeCLILocator() == nil, @"没有定位文件时应返回 nil")) return EXIT_FAILURE;
        NSString *cli = [home stringByAppendingPathComponent:@"cli.mjs"];
        [@"" writeToFile:cli atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [[NSString stringWithFormat:@"{\"node\":\"/bin/sh\",\"cli\":\"%@\"}", cli]
            writeToFile:locator atomically:YES encoding:NSUTF8StringEncoding error:nil];
        if (!Check([CCBridgeCLILocator()[@"cli"] isEqualToString:cli], @"有效定位应返回路径")) return EXIT_FAILURE;
        [@"{\"node\":\"/nonexistent/node\",\"cli\":\"/tmp\"}" writeToFile:locator atomically:YES
            encoding:NSUTF8StringEncoding error:nil];
        if (!Check(CCBridgeCLILocator() == nil, @"node 不存在时应返回 nil")) return EXIT_FAILURE;

        NSString *root = CCBridgeStateDirectory();
        if (!Check([root.lastPathComponent hasPrefix:@"cc-bridge-"], @"状态目录名应与 bridge 端一致")) {
            return EXIT_FAILURE;
        }
        NSString *sessions = [root stringByAppendingPathComponent:@"sessions"];
        WriteJSON(sessions, @"s1.json", @{@"session": @"s1", @"name": @"web", @"ref": @"2a52f4",
            @"provider": @"Claude", @"tty": @"ttys003"});
        WriteJSON(sessions, @"s2.json", @{@"session": @"s2", @"name": @"api", @"ref": @"99f55e",
            @"provider": @"Codex"});
        // 被手改的状态文件：名字里的非法字符应被滤掉，而不是原样进菜单。
        WriteJSON(sessions, @"s3.json", @{@"session": @"s3", @"name": @"bad\nname<script>",
            @"ref": @"ffffff", @"provider": @"Claude"});
        WriteJSON(sessions, @"junk.json", @{@"name": @"no-session"});
        // 记录了 pid 但进程已退出的会话不应出现（取一个几乎不可能存在的 pid）。
        WriteJSON(sessions, @"dead.json", @{@"session": @"dead", @"name": @"gone", @"provider": @"Codex",
            @"pid": @(999999)});

        NSDictionary *bridgeSessions = CCBridgeSessions();
        if (!Check(bridgeSessions.count == 3, @"应读到 3 个有效会话")) return EXIT_FAILURE;
        if (!Check([bridgeSessions[@"s1"][@"tty"] isEqualToString:@"ttys003"], @"应带出 tty")) return EXIT_FAILURE;
        if (!Check(bridgeSessions[@"s2"][@"tty"] == nil, @"没有 tty 的会话不应伪造 tty")) return EXIT_FAILURE;
        if (!Check([bridgeSessions[@"s3"][@"name"] isEqualToString:@"badnamescript"], @"非法字符应被滤掉")) {
            return EXIT_FAILURE;
        }

        double now = NSDate.date.timeIntervalSince1970 * 1000.0;
        NSString *sent = [root stringByAppendingPathComponent:@"sent"];
        WriteJSON(sent, @"m1.json", @{@"id": @"m1", @"status": @"delivered", @"body": @"SECRET-BODY",
            @"from": @{@"session": @"s2", @"name": @"api"}, @"to": @{@"session": @"s1", @"name": @"web"},
            @"createdAt": @(now - 5000), @"updatedAt": @(now - 4000)});
        WriteJSON(sent, @"m2.json", @{@"id": @"m2", @"status": @"delivered", @"body": @"x",
            @"from": @{@"session": @"s1", @"name": @"web"}, @"to": @{@"session": @"s2", @"name": @"api"},
            @"createdAt": @(now - 2000), @"updatedAt": @(now - 1000)});
        // 系统通知（空闲通知）、未送达、过旧的都不算。
        WriteJSON(sent, @"m3.json", @{@"id": @"m3", @"status": @"delivered", @"body": @"idle",
            @"from": @{@"system": @YES}, @"to": @{@"session": @"s1", @"name": @"web"}, @"createdAt": @(now)});
        WriteJSON(sent, @"m4.json", @{@"id": @"m4", @"status": @"pending", @"body": @"x",
            @"from": @{@"session": @"s2", @"name": @"api"}, @"to": @{@"session": @"s1", @"name": @"web"},
            @"createdAt": @(now)});
        WriteJSON(sent, @"m5.json", @{@"id": @"m5", @"status": @"delivered", @"body": @"old",
            @"from": @{@"session": @"s2", @"name": @"api"}, @"to": @{@"session": @"s1", @"name": @"web"},
            @"createdAt": @(now - 3600 * 1000.0)});

        NSArray<NSDictionary *> *deliveries = CCBridgeRecentDeliveries(now / 1000.0 - 600, 10);
        if (!Check(deliveries.count == 2, [NSString stringWithFormat:@"应只有 2 条最近送达，实际 %lu",
            (unsigned long)deliveries.count])) return EXIT_FAILURE;
        if (!Check([deliveries[0][@"id"] isEqualToString:@"m2"], @"应按送达时间倒序")) return EXIT_FAILURE;
        if (!Check([deliveries[1][@"from"] isEqualToString:@"api"] &&
                   [deliveries[1][@"to"] isEqualToString:@"web"] &&
                   [deliveries[1][@"toSession"] isEqualToString:@"s1"], @"应带出发件人、收件人与收件会话")) {
            return EXIT_FAILURE;
        }
        for (NSDictionary *delivery in deliveries) {
            if (!Check(delivery[@"body"] == nil &&
                       ![delivery.description containsString:@"SECRET-BODY"], @"返回值里不能出现消息正文")) {
                return EXIT_FAILURE;
            }
        }
        if (!Check(CCBridgeRecentDeliveries(0, 1).count == 1, @"limit 应生效")) return EXIT_FAILURE;

        NSString *inbox = [root stringByAppendingPathComponent:@"inbox"];
        WriteJSON([inbox stringByAppendingPathComponent:@"s1"], @"a.json", @{@"id": @"a"});
        WriteJSON([inbox stringByAppendingPathComponent:@"s1"], @"b.json", @{@"id": @"b"});
        [NSFileManager.defaultManager createDirectoryAtPath:[inbox stringByAppendingPathComponent:@"s2"]
            withIntermediateDirectories:YES attributes:nil error:nil];
        NSDictionary<NSString *, NSNumber *> *pending = CCBridgePendingCounts();
        if (!Check(pending.count == 1 && [pending[@"s1"] integerValue] == 2, @"应只统计有积压的会话")) {
            return EXIT_FAILURE;
        }

        NSString *reservations = [root stringByAppendingPathComponent:@"reservations"];
        WriteJSON(reservations, @"r1.json", @{@"session": @"s1", @"expiresAt": @(now + 60000)});
        WriteJSON(reservations, @"r2.json", @{@"session": @"s1", @"expiresAt": @(now - 1)});
        WriteJSON(reservations, @"r3.json", @{@"session": @"offline", @"expiresAt": @(now + 60000)});
        if (!Check(CCBridgeActiveReservationCount([NSSet setWithArray:bridgeSessions.allKeys]) == 1,
                   @"只统计未过期、持有者在线的预留")) return EXIT_FAILURE;

        puts("CC Bridge 桌宠状态读取测试通过");
    }
    return EXIT_SUCCESS;
}
