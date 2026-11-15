#import <Foundation/Foundation.h>
#import "CCPetsEvents.h"

// 状态机的两个坑，都来自"事件顺序不等于语义顺序"：
//
// 1. Stop 之后还会飘来 SubagentStop / PostToolUse（实测 Stop 后 4 秒）。它们和
//    UserPromptSubmit 一样都归一成 thinking，只看 state 分不出来——必须按事件名拦，
//    否则"任务已完成"会被打回"正在思考"，看起来像任务又活了。
// 2. 拦得太宽也不行：新一轮真实动作（用户提问、工具调用、需要关注）必须能解除终态。

static BOOL IsTrailingEvent(NSString *event) {
    return [event isEqualToString:@"SubagentStop"] || [event isEqualToString:@"PostToolUse"] ||
        [event isEqualToString:@"TaskCompleted"];
}

static BOOL CheckNormalized(NSString *event, BOOL failed, NSString *expected) {
    NSString *actual = NormalizedStateForEvent(event, failed);
    if ([actual isEqualToString:expected]) return YES;
    NSLog(@"%@ 应归一成 %@，实际 %@", event, expected, actual);
    return NO;
}

int main(void) {
    @autoreleasepool {
        BOOL ok = YES;
        ok &= CheckNormalized(@"Stop", NO, @"completed");
        ok &= CheckNormalized(@"StopFailure", NO, @"failed");
        ok &= CheckNormalized(@"SessionStart", NO, @"starting");
        ok &= CheckNormalized(@"UserPromptSubmit", NO, @"thinking");
        ok &= CheckNormalized(@"SubagentStop", NO, @"thinking");
        ok &= CheckNormalized(@"PostToolUse", NO, @"thinking");

        // 尾巴事件和"新一轮真实动作"归一后的 state 完全一样，这正是必须按事件名区分的原因。
        if (![NormalizedStateForEvent(@"SubagentStop", NO)
                isEqualToString:NormalizedStateForEvent(@"UserPromptSubmit", NO)]) {
            NSLog(@"前提失效：尾巴事件与新一轮动作的 state 已能区分，拦截逻辑需要重新审视");
            ok = NO;
        }
        for (NSString *event in @[@"SubagentStop", @"PostToolUse", @"TaskCompleted"]) {
            if (!IsTrailingEvent(event)) {
                NSLog(@"%@ 应被认定为终态之后的尾巴事件", event);
                ok = NO;
            }
        }
        for (NSString *event in @[@"UserPromptSubmit", @"PreToolUse", @"PermissionRequest",
                                  @"Notification", @"SessionStart"]) {
            if (IsTrailingEvent(event)) {
                NSLog(@"%@ 是新一轮真实动作，必须能解除终态", event);
                ok = NO;
            }
        }

        // 同一个终端先后跑过两个账号：在线 key 必须区分账号，否则已退出账号的记录会借着
        // 另一个账号的 pid 文件一直算在线，会话页多出一行"正在启动"。
        NSString *defaultKey = OnlineAgentSessionKey(@"Claude", @"claude:default", @"/dev/ttys003");
        NSString *otherKey = OnlineAgentSessionKey(@"Claude", @"claude:other", @"ttys003");
        if ([defaultKey isEqualToString:otherKey]) {
            NSLog(@"同一 tty 上不同账号的在线 key 不应相同: %@", defaultKey);
            ok = NO;
        }
        // pid 文件写的是 ttys003，事件里可能是 /dev/ttys003，两边必须对得上。
        if (![OnlineAgentSessionKey(@"Claude", @"claude:other", @"/dev/ttys003") isEqualToString:otherKey]) {
            NSLog(@"tty 写法不同导致在线 key 对不上");
            ok = NO;
        }
        if (OnlineAgentSessionKey(@"Claude", @"claude:other", nil) != nil ||
            OnlineAgentSessionKey(@"Claude", @"claude:other", @42) != nil) {
            NSLog(@"没有 tty 的记录不应生成在线 key");
            ok = NO;
        }

        // 会话页的"正在启动"超过宽限就按待机展示，和状态气泡一致。
        NSTimeInterval now = 1000;
        if (![SessionDisplayState(@"starting", now - 1, now) isEqualToString:@"starting"] ||
            ![SessionDisplayState(@"starting", now - 14 * 60, now) isEqualToString:@"idle"] ||
            ![SessionDisplayState(@"thinking", now - 14 * 60, now) isEqualToString:@"thinking"]) {
            NSLog(@"会话页启动态降级为待机的判定不对");
            ok = NO;
        }
        // 状态卡的会话标签：Bridge 短名优先，其次目录名；都没有就留空，由标题退回 provider。
        if (![StatusSessionLabel(@"cc-pets.crab", @"/Users/me/other") isEqualToString:@"cc-pets.crab"] ||
            ![StatusSessionLabel(@"", @"/Users/me/cc-pets") isEqualToString:@"cc-pets"] ||
            ![StatusSessionLabel(nil, @"/Users/me/我的 项目/") isEqualToString:@"我的 项目"] ||
            StatusSessionLabel(nil, nil).length != 0 || StatusSessionLabel(@"", @"/").length != 0) {
            NSLog(@"会话标签的取值优先级不对");
            ok = NO;
        }
        // 过长时截掉中间、保留动物后缀：同目录的多个会话只有后缀不同。
        NSString *longLabel = StatusSessionLabel(@"my-very-long-project-name.raccoon", nil);
        NSString *plainLabel = StatusSessionLabel(nil, @"/tmp/a-directory-name-without-any-dots");
        NSString *wideLabel = StatusSessionLabel(nil, @"/tmp/项目项目项目项目项目项目项目项目项目项目项目项目");
        if (![longLabel isEqualToString:@"my-very-lon….raccoon"] || longLabel.length != 20 ||
            ![plainLabel isEqualToString:@"a-directory-name-wi…"] || wideLabel.length != 20) {
            NSLog(@"会话标签截断不对: %@ / %@ / %@", longLabel, plainLabel, wideLabel);
            ok = NO;
        }
        // 工作目录可以带中文和空格，但必须是绝对路径且不含控制字符。
        if (![SanitizedWorkingDirectory(@" /Users/me/我的 项目 ") isEqualToString:@"/Users/me/我的 项目"] ||
            SanitizedWorkingDirectory(@"relative/path").length != 0 ||
            SanitizedWorkingDirectory(@"/tmp/a\nb").length != 0 || SanitizedWorkingDirectory(@42).length != 0) {
            NSLog(@"工作目录清洗不对");
            ok = NO;
        }
        if (!ok) return EXIT_FAILURE;
        puts("Agent 状态归一与终态尾巴事件判定测试通过");
    }
    return EXIT_SUCCESS;
}
