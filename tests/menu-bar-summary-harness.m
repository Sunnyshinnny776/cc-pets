#import <Foundation/Foundation.h>
#import "CCPetsMenuBarSummary.h"
#import "CCPetsPreferences.h"

// 菜单栏标题测试：取哪个账号的额度、什么时候变色、什么时候不顾开关也要显示数字，
// 以及显示位置偏好的规整。裸二进制的 defaults 落在以进程名命名的域里，开头结尾都清掉。

static BOOL Check(BOOL condition, NSString *label) {
    if (!condition) NSLog(@"失败：%@", label);
    return condition;
}

static NSDictionary *Plan(id five) {
    return five ? @{@"apiMode": @NO, @"fiveRemaining": five} : @{@"apiMode": @NO};
}

int main(void) {
    @autoreleasepool {
        BOOL ok = YES;

        // 没有账号、只有 API 账号、只有没数据的账号：都没有可比较的额度。
        ok &= Check(CCPetsMenuBarLowestFiveHourRemaining(@[]) == -1, @"无账号返回 -1");
        ok &= Check(CCPetsMenuBarLowestFiveHourRemaining(@[@{@"apiMode": @YES, @"fiveRemaining": @5}]) == -1,
            @"API 账号不参与");
        ok &= Check(CCPetsMenuBarLowestFiveHourRemaining(@[Plan(nil)]) == -1, @"无数据账号不参与");
        ok &= Check(CCPetsMenuBarLowestFiveHourRemaining(@[Plan(@(NAN))]) == -1, @"NaN 不参与");

        // 多账号取最低，向下取整并钳到 0–100；限流账号按 0。
        ok &= Check(CCPetsMenuBarLowestFiveHourRemaining(@[Plan(@62), Plan(@34.9), Plan(nil)]) == 34,
            @"多账号取最低并向下取整");
        ok &= Check(CCPetsMenuBarLowestFiveHourRemaining(@[Plan(@-3)]) == 0, @"负值钳到 0");
        ok &= Check(CCPetsMenuBarLowestFiveHourRemaining(@[Plan(@80), @{@"apiMode": @NO, @"state": @"limited"}]) == 0,
            @"限流账号按 0");

        // 阈值边界与低额度台词一致：20 警告，10 严重。
        ok &= Check(CCPetsMenuBarLevelForRemaining(-1) == CCPetsMenuBarLevelNormal, @"无数据不变色");
        ok &= Check(CCPetsMenuBarLevelForRemaining(21) == CCPetsMenuBarLevelNormal, @"21% 正常");
        ok &= Check(CCPetsMenuBarLevelForRemaining(20) == CCPetsMenuBarLevelWarning, @"20% 警告");
        ok &= Check(CCPetsMenuBarLevelForRemaining(11) == CCPetsMenuBarLevelWarning, @"11% 警告");
        ok &= Check(CCPetsMenuBarLevelForRemaining(10) == CCPetsMenuBarLevelCritical, @"10% 严重");
        ok &= Check(CCPetsMenuBarLevelForRemaining(0) == CCPetsMenuBarLevelCritical, @"0% 严重");

        // 开关关着时额度正常不显示数字；进了警告档照样显示。
        NSDictionary *parts = CCPetsMenuBarTitleParts(@[Plan(@62)], 0, NO);
        ok &= Check(parts[@"percent"] == nil && parts[@"approvals"] == nil, @"默认只显示图标");
        parts = CCPetsMenuBarTitleParts(@[Plan(@62)], 0, YES);
        ok &= Check([parts[@"percent"] isEqual:@"62%"], @"打开开关显示数字");
        parts = CCPetsMenuBarTitleParts(@[Plan(@19.6)], 0, NO);
        ok &= Check([parts[@"percent"] isEqual:@"19%"] &&
            [parts[@"level"] integerValue] == CCPetsMenuBarLevelWarning, @"低额度强制显示并标警告");
        parts = CCPetsMenuBarTitleParts(@[], 3, YES);
        ok &= Check(parts[@"percent"] == nil && [parts[@"approvals"] isEqual:@"3"], @"无额度仍显示审批数");

        // 账号排列：订阅在前、API 在后，组内保持原次序。
        NSDictionary *codexAPI = @{@"provider": @"Codex", @"apiMode": @YES};
        NSDictionary *codexPlan = @{@"provider": @"Codex", @"apiMode": @NO, @"profileName": @"work"};
        NSDictionary *claudePlan = @{@"provider": @"Claude", @"apiMode": @NO};
        NSDictionary *claudeAPI = @{@"provider": @"Claude", @"apiMode": @YES};
        ok &= Check([CCPetsMenuBarOrderedQuotas(@[codexAPI, codexPlan, claudeAPI, claudePlan])
            isEqualToArray:(@[codexPlan, claudePlan, codexAPI, claudeAPI])], @"订阅账号排在 API 账号前");
        ok &= Check(CCPetsMenuBarOrderedQuotas(@[]).count == 0, @"无账号返回空数组");

        // 爪印色调：归类与状态卡一致，待机和没有状态时保持原色。
        ok &= Check(CCPetsMenuBarIconToneForState(nil) == CCPetsMenuBarIconToneNone &&
            CCPetsMenuBarIconToneForState(@"") == CCPetsMenuBarIconToneNone &&
            CCPetsMenuBarIconToneForState(@"idle") == CCPetsMenuBarIconToneNone &&
            CCPetsMenuBarIconToneForState((NSString *)@1) == CCPetsMenuBarIconToneNone, @"待机保持原色");
        ok &= Check(CCPetsMenuBarIconToneForState(@"thinking") == CCPetsMenuBarIconToneWorking &&
            CCPetsMenuBarIconToneForState(@"tool") == CCPetsMenuBarIconToneWorking &&
            CCPetsMenuBarIconToneForState(@"starting") == CCPetsMenuBarIconToneWorking, @"工作中为蓝");
        ok &= Check(CCPetsMenuBarIconToneForState(@"approval") == CCPetsMenuBarIconToneAttention &&
            CCPetsMenuBarIconToneForState(@"notification") == CCPetsMenuBarIconToneAttention, @"审批为橙");
        ok &= Check(CCPetsMenuBarIconToneForState(@"completed") == CCPetsMenuBarIconToneCompleted &&
            CCPetsMenuBarIconToneForState(@"tool_completed") == CCPetsMenuBarIconToneCompleted, @"完成为绿");
        ok &= Check(CCPetsMenuBarIconToneForState(@"failed") == CCPetsMenuBarIconToneFailed &&
            CCPetsMenuBarIconToneForState(@"tool_failed") == CCPetsMenuBarIconToneFailed, @"失败为红");

        // 今日 Token 合计。
        NSDictionary *withToday = @{@"usage": @{@"tokenUsage": @{@"today": @{@"total_tokens": @1200}}}};
        ok &= Check(CCPetsMenuBarTodayTokens(@[]) == nil, @"无数据返回 nil");
        ok &= Check([CCPetsMenuBarTodayTokens(@[withToday, withToday, Plan(@5)]) isEqual:@2400], @"今日合计");

        // 显示位置：没写过、写了未知值都按仅桌宠；写入口拒绝未知值。
        NSString *domain = NSProcessInfo.processInfo.processName;
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults removePersistentDomainForName:domain];
        ok &= Check([CCPetsDisplayMode() isEqual:CCPetsDisplayModePet], @"缺省仅桌宠");
        ok &= Check(CCPetsPrefSetObject(CCPetsDisplayModeKey, CCPetsDisplayModeMenuBar) &&
            [CCPetsDisplayMode() isEqual:CCPetsDisplayModeMenuBar], @"写入仅菜单栏");
        ok &= Check(!CCPetsPrefSetObject(CCPetsDisplayModeKey, @"tray") &&
            [CCPetsDisplayMode() isEqual:CCPetsDisplayModeMenuBar], @"拒绝未知模式且不改原值");
        [defaults setObject:@"tray" forKey:CCPetsDisplayModeKey];
        ok &= Check([CCPetsDisplayMode() isEqual:CCPetsDisplayModePet], @"读到未知值按仅桌宠");
        ok &= Check(!CCPetsPrefBool(CCPetsMenuBarShowsPercentKey), @"额度数字缺省关闭");
        [defaults removePersistentDomainForName:domain];

        if (!ok) return 1;
        printf("菜单栏标题与显示位置测试通过\n");
    }
    return 0;
}
