#import <Cocoa/Cocoa.h>
#import "QuotaDashboardView.h"

// 卡片的在线徽章一度是按"有没有额度数据"判定的。额度会一直缓存着，所以哪怕客户端
// 早就退出、甚至单独打开 App 从没跑过 Agent，两张卡片也永远显示在线。这里锁住
// 正确语义：在线只取决于该 provider 还有没有活着的客户端。
static BOOL Check(NSString *label, NSSet<NSString *> *providers, BOOL unlabeled,
    BOOL expectedCodex, BOOL expectedClaude) {
    QuotaDashboardView *view = [[QuotaDashboardView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
    // 两家都给满额度数据：有数据但没有客户端时必须判离线。
    view.usageByProvider = @{
        @"Codex": @{@"fiveHour": @{@"used_percent": @34},
            @"tokenUsage": @{@"week": @{@"total_tokens": @1000}}},
        @"Claude": @{@"fiveHour": @{@"used_percentage": @23},
            @"tokenUsage": @{@"week": @{@"total_tokens": @1000}}}
    };
    view.liveProviders = providers;
    view.hasUnlabeledClient = unlabeled;
    BOOL codex = [view isProviderOnline:@"Codex"];
    BOOL claude = [view isProviderOnline:@"Claude"];
    if (codex != expectedCodex || claude != expectedClaude) {
        NSLog(@"%@: Codex=%d(期望 %d) Claude=%d(期望 %d)", label, codex, expectedCodex,
            claude, expectedClaude);
        return NO;
    }
    return YES;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        BOOL ok = YES;
        ok &= Check(@"无任何客户端", [NSSet set], NO, NO, NO);
        ok &= Check(@"仅 Codex 存活", [NSSet setWithObject:@"Codex"], NO, YES, NO);
        ok &= Check(@"仅 Claude 存活", [NSSet setWithObject:@"Claude"], NO, NO, YES);
        ok &= Check(@"两家都存活", ([NSSet setWithArray:@[@"Codex", @"Claude"]]), NO, YES, YES);
        // 老版本包装脚本写出的 pid 文件没有 provider 名，无法归属，保守地都算在线。
        ok &= Check(@"存在身份不明的客户端", [NSSet set], YES, YES, YES);
        if (!ok) return EXIT_FAILURE;
        puts("额度卡片在线状态按存活客户端判定测试通过");
    }
    return EXIT_SUCCESS;
}
