#import "CCPetsPreferences.h"
#import "CCPetsPetSize.h"
#import <math.h>

NSNotificationName const CCPetsPreferencesDidChangeNotification = @"CCPetsPreferencesDidChange";
NSString *const CCPetsPreferencesChangedKeyKey = @"key";

NSString *const PetSpeechEnabledKey = @"CCPetsSpeechEnabled";
NSString *const PetInteractionEnabledKey = @"CCPetsInteractionEnabled";
NSString *const PetInteractionHeartThresholdKey = @"CCPetsInteractionHeartThreshold";
NSString *const PetInteractionAnnoyedThresholdKey = @"CCPetsInteractionAnnoyedThreshold";
NSString *const PetInteractionIntervalKey = @"CCPetsInteractionInterval";

// 没有注册默认值、缺省又是开启的键。碎碎念从第一版起就是"读不到就算开"，
// 改成 registerDefaults 的话 CLI 子命令（没走 applicationDidFinishLaunching）会读成关。
static BOOL DefaultsToEnabled(NSString *key) {
    return [key isEqualToString:PetSpeechEnabledKey];
}

BOOL CCPetsPrefBool(NSString *key) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    if (value == nil) return DefaultsToEnabled(key);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

void CCPetsPrefPostChange(NSString *key) {
    if (key.length == 0) return;
    [NSNotificationCenter.defaultCenter
        postNotificationName:CCPetsPreferencesDidChangeNotification object:nil
        userInfo:@{CCPetsPreferencesChangedKeyKey: key}];
}

void CCPetsPrefSetBool(NSString *key, BOOL value) {
    if (key.length == 0) return;
    BOOL changed = CCPetsPrefBool(key) != value;
    [NSUserDefaults.standardUserDefaults setBool:value forKey:key];
    if (changed) CCPetsPrefPostChange(key);
}

static NSNumber *ClampedNumber(id value, double minimum, double maximum) {
    if (![value isKindOfClass:NSNumber.class]) return nil;
    double number = [value doubleValue];
    if (!isfinite(number)) return nil;
    return @(MAX(minimum, MIN(maximum, number)));
}

// 下限与右键菜单原先各 setter 里的钳制逐条对应，改这里等于改菜单行为。
id CCPetsPrefNormalizedValue(NSString *key, id value) {
    if (value == nil) return nil;
    if ([key isEqualToString:CCPetsPetScaleKey]) {
        NSNumber *scale = ClampedNumber(value, CCPetsPetMinimumScale, CCPetsPetMaximumScale);
        // 滑动条连续拖动会给出 0.8734 这种值，按百分比取整，免得 defaults 里存一串小数。
        return scale ? @(round(scale.doubleValue * 100) / 100) : nil;
    }
    if ([key isEqualToString:PetInteractionHeartThresholdKey]) {
        NSNumber *count = ClampedNumber(value, 2, INT_MAX);
        return count ? @(count.integerValue) : nil;
    }
    if ([key isEqualToString:PetInteractionAnnoyedThresholdKey]) {
        // 生气必须在比心之后，否则连点永远到不了比心那一档。
        NSInteger heart = MAX((NSInteger)2, [NSUserDefaults.standardUserDefaults
            integerForKey:PetInteractionHeartThresholdKey]);
        NSNumber *count = ClampedNumber(value, heart + 1, INT_MAX);
        return count ? @(count.integerValue) : nil;
    }
    if ([key isEqualToString:PetInteractionIntervalKey]) return ClampedNumber(value, 0.4, 3.0);
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) return value;
    return nil;
}

BOOL CCPetsPrefSetObject(NSString *key, id value) {
    if (key.length == 0) return NO;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id previous = [defaults objectForKey:key];
    if (value == nil) {
        [defaults removeObjectForKey:key];
        if (previous != nil) CCPetsPrefPostChange(key);
        return YES;
    }
    id normalized = CCPetsPrefNormalizedValue(key, value);
    if (!normalized) return NO;
    [defaults setObject:normalized forKey:key];
    if (![previous isEqual:normalized]) CCPetsPrefPostChange(key);
    return YES;
}
