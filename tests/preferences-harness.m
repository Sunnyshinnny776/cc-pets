#import <Foundation/Foundation.h>
#import "CCPetsPreferences.h"
#import "CCPetsPetSize.h"

// 设置写入口测试。右键菜单和主窗口设置页都经过 CCPetsPreferences，这里守住三件事：
// 钳制范围与菜单原先各 setter 一致、"没写过就算开"的默认值、只有值真的变了才广播。
//
// 裸二进制的 standardUserDefaults 落在以进程名命名的域里，开头和结尾都清掉，
// 不碰用户真实的 CC Pets 设置。

static BOOL Check(BOOL condition, NSString *label) {
    if (!condition) NSLog(@"失败：%@", label);
    return condition;
}

static NSUInteger ChangeCount;
static NSString *LastChangedKey;

int main(void) {
    @autoreleasepool {
        NSString *domain = NSProcessInfo.processInfo.processName;
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults removePersistentDomainForName:domain];
        id observer = [NSNotificationCenter.defaultCenter
            addObserverForName:CCPetsPreferencesDidChangeNotification object:nil queue:nil
            usingBlock:^(NSNotification *note) {
            ChangeCount++;
            LastChangedKey = note.userInfo[CCPetsPreferencesChangedKeyKey];
        }];
        BOOL ok = YES;

        // 碎碎念没写过时算开；其他布尔键没写过算关。
        ok &= Check(CCPetsPrefBool(PetSpeechEnabledKey), @"碎碎念缺省开启");
        ok &= Check(!CCPetsPrefBool(PetInteractionEnabledKey), @"未注册的布尔键缺省关闭");

        // 写成与当前一致的值不广播；真的变了才广播，并带上键名。
        ChangeCount = 0;
        CCPetsPrefSetBool(PetSpeechEnabledKey, YES);
        ok &= Check(ChangeCount == 0, @"布尔值未变不广播");
        CCPetsPrefSetBool(PetSpeechEnabledKey, NO);
        ok &= Check(ChangeCount == 1 && [LastChangedKey isEqualToString:PetSpeechEnabledKey],
            @"布尔值变化时广播一次并带键名");
        ok &= Check(!CCPetsPrefBool(PetSpeechEnabledKey), @"碎碎念可以关掉");

        // 宠物缩放：钳到 [最小, 最大]，按百分比取整；NaN 不写。
        CCPetsPrefSetObject(CCPetsPetScaleKey, @9.0);
        ok &= Check(CCPetsPetScalePreference() == CCPetsPetMaximumScale, @"缩放上限");
        CCPetsPrefSetObject(CCPetsPetScaleKey, @0.1);
        ok &= Check(CCPetsPetScalePreference() == CCPetsPetMinimumScale, @"缩放下限");
        CCPetsPrefSetObject(CCPetsPetScaleKey, @0.8734);
        ok &= Check([[defaults objectForKey:CCPetsPetScaleKey] doubleValue] == 0.87, @"缩放按百分比取整");
        ok &= Check(!CCPetsPrefSetObject(CCPetsPetScaleKey, @(NAN)), @"NaN 缩放被拒绝");
        ok &= Check([[defaults objectForKey:CCPetsPetScaleKey] doubleValue] == 0.87, @"NaN 不覆盖原值");

        // 点击互动：比心至少 2 次；生气必须比比心多；间隔 0.4–3 秒。
        CCPetsPrefSetObject(PetInteractionHeartThresholdKey, @1);
        ok &= Check([defaults integerForKey:PetInteractionHeartThresholdKey] == 2, @"比心阈值下限 2");
        CCPetsPrefSetObject(PetInteractionHeartThresholdKey, @5);
        CCPetsPrefSetObject(PetInteractionAnnoyedThresholdKey, @3);
        ok &= Check([defaults integerForKey:PetInteractionAnnoyedThresholdKey] == 6, @"生气阈值不低于比心 + 1");
        CCPetsPrefSetObject(PetInteractionAnnoyedThresholdKey, @12);
        ok &= Check([defaults integerForKey:PetInteractionAnnoyedThresholdKey] == 12, @"合法的生气阈值原样保存");
        CCPetsPrefSetObject(PetInteractionIntervalKey, @0.1);
        ok &= Check([defaults doubleForKey:PetInteractionIntervalKey] == 0.4, @"点击间隔下限");
        CCPetsPrefSetObject(PetInteractionIntervalKey, @10);
        ok &= Check([defaults doubleForKey:PetInteractionIntervalKey] == 3.0, @"点击间隔上限");

        // 字符串原样写；相同值不重复广播；nil 删除键并广播。
        ChangeCount = 0;
        CCPetsPrefSetObject(@"CCPetsPanelTheme", @"liquid");
        CCPetsPrefSetObject(@"CCPetsPanelTheme", @"liquid");
        ok &= Check(ChangeCount == 1, @"字符串相同值不重复广播");
        CCPetsPrefSetObject(@"CCPetsPanelTheme", nil);
        ok &= Check(ChangeCount == 2 && [defaults objectForKey:@"CCPetsPanelTheme"] == nil, @"nil 删除键并广播");
        ok &= Check(!CCPetsPrefSetObject(@"CCPetsPanelTheme", @[@"x"]), @"非字符串 / 数字的值被拒绝");

        [NSNotificationCenter.defaultCenter removeObserver:observer];
        [defaults removePersistentDomainForName:domain];
        if (!ok) return 1;
        printf("设置写入口测试通过\n");
    }
    return 0;
}
