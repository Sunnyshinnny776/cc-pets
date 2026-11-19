#import <Foundation/Foundation.h>
#import "CCPetsVersion.h"

// 应用内更新的版本比较：本机可以是预览版，npm 的 latest 必须是正式版。
// 预览版用户要能收到同号及更高的正式版；误把预发布号发成 latest 时，正式版用户不能被推送。

static BOOL Check(NSString *installed, NSString *release, BOOL expectedValid, NSComparisonResult expected) {
    BOOL valid = YES;
    NSComparisonResult actual = CompareInstalledVersionToRelease(installed, release, &valid);
    if (valid == expectedValid && (!valid || actual == expected)) return YES;
    NSLog(@"%@ vs %@：valid=%d 结果=%ld，期望 valid=%d 结果=%ld", installed, release,
        valid, (long)actual, expectedValid, (long)expected);
    return NO;
}

int main(void) {
    @autoreleasepool {
        BOOL ok = YES;
        // 正式版之间与原先的严格比较一致。
        ok &= Check(@"2.5.0", @"2.5.1", YES, NSOrderedAscending);
        ok &= Check(@"2.5.0", @"2.5.0", YES, NSOrderedSame);
        ok &= Check(@"2.6.0", @"2.5.9", YES, NSOrderedDescending);
        // 预览版低于同号正式版，高于更低的正式版。
        ok &= Check(@"2.6.0-beta.0", @"2.6.0", YES, NSOrderedAscending);
        ok &= Check(@"2.6.0-beta.0", @"2.6.1", YES, NSOrderedAscending);
        ok &= Check(@"2.6.0-beta.0", @"2.5.0", YES, NSOrderedDescending);
        ok &= Check(@"2.6.0-rc-1.x.7", @"2.6.0", YES, NSOrderedAscending);
        // latest 是预发布号或格式非法时一律无效，不能据此升级。
        ok &= Check(@"2.5.0", @"2.6.0-beta.0", NO, NSOrderedSame);
        ok &= Check(@"2.6.0-beta.0", @"2.6.0-beta.1", NO, NSOrderedSame);
        ok &= Check(@"2.5.0", @"latest", NO, NSOrderedSame);
        // 本机预发布号也要合规：空标识符、前导零、非法字符、构建元数据都不接受。
        ok &= Check(@"2.6.0-", @"2.6.0", NO, NSOrderedSame);
        ok &= Check(@"2.6.0-beta..1", @"2.6.0", NO, NSOrderedSame);
        ok &= Check(@"2.6.0-beta.01", @"2.6.0", NO, NSOrderedSame);
        ok &= Check(@"2.6.0-beta_1", @"2.6.0", NO, NSOrderedSame);
        ok &= Check(@"2.6.0+build.1", @"2.6.0", NO, NSOrderedSame);
        ok &= Check(@"02.6.0-beta.0", @"2.6.0", NO, NSOrderedSame);
        ok &= Check(nil, @"2.6.0", NO, NSOrderedSame);
        // 严格比较保持不变：--compare-versions 和其他调用方仍不接受预发布号。
        BOOL valid = YES;
        CompareStableVersions(@"2.6.0-beta.0", @"2.6.0", &valid);
        if (valid) { NSLog(@"CompareStableVersions 不应接受预发布号"); ok = NO; }
        // valid 传 NULL 不应崩溃。
        CompareInstalledVersionToRelease(@"2.6.0-beta.0", @"2.6.0", NULL);

        if (!ok) return EXIT_FAILURE;
        puts("预览版应用内更新版本比较测试通过");
    }
    return EXIT_SUCCESS;
}
