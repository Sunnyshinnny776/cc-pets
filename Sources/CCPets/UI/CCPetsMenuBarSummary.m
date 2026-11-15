#import "CCPetsMenuBarSummary.h"
#import <math.h>

const NSInteger CCPetsMenuBarWarningPercent = 20;
const NSInteger CCPetsMenuBarCriticalPercent = 10;

NSInteger CCPetsMenuBarLowestFiveHourRemaining(NSArray<NSDictionary *> *quotas) {
    NSInteger lowest = -1;
    for (NSDictionary *quota in quotas) {
        if (![quota isKindOfClass:NSDictionary.class] || [quota[@"apiMode"] boolValue]) continue;
        NSInteger remaining;
        if ([quota[@"state"] isEqual:@"limited"]) {
            remaining = 0;
        } else if ([quota[@"fiveRemaining"] isKindOfClass:NSNumber.class]) {
            double value = [quota[@"fiveRemaining"] doubleValue];
            if (!isfinite(value)) continue;
            // 向下取整：剩 19.6% 时显示 20% 却不变色，会让人以为阈值没生效。
            remaining = (NSInteger)floor(fmax(0, fmin(100, value)));
        } else {
            continue;
        }
        if (lowest < 0 || remaining < lowest) lowest = remaining;
    }
    return lowest;
}

CCPetsMenuBarLevel CCPetsMenuBarLevelForRemaining(NSInteger remaining) {
    if (remaining < 0) return CCPetsMenuBarLevelNormal;
    if (remaining <= CCPetsMenuBarCriticalPercent) return CCPetsMenuBarLevelCritical;
    if (remaining <= CCPetsMenuBarWarningPercent) return CCPetsMenuBarLevelWarning;
    return CCPetsMenuBarLevelNormal;
}

NSDictionary *CCPetsMenuBarTitleParts(NSArray<NSDictionary *> *quotas, NSUInteger approvals, BOOL showPercent) {
    NSInteger remaining = CCPetsMenuBarLowestFiveHourRemaining(quotas);
    CCPetsMenuBarLevel level = CCPetsMenuBarLevelForRemaining(remaining);
    NSMutableDictionary *parts = [NSMutableDictionary dictionaryWithObject:@(level) forKey:@"level"];
    if (remaining >= 0 && showPercent) {
        parts[@"percent"] = [NSString stringWithFormat:@"%ld%%", (long)remaining];
    }
    if (approvals > 0) parts[@"approvals"] = [NSString stringWithFormat:@"%lu", (unsigned long)approvals];
    return parts;
}

NSArray<NSDictionary *> *CCPetsMenuBarOrderedQuotas(NSArray<NSDictionary *> *quotas) {
    NSMutableArray<NSDictionary *> *subscription = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *api = [NSMutableArray array];
    for (NSDictionary *quota in quotas) {
        if (![quota isKindOfClass:NSDictionary.class]) continue;
        [([quota[@"apiMode"] boolValue] ? api : subscription) addObject:quota];
    }
    return [subscription arrayByAddingObjectsFromArray:api];
}

CCPetsMenuBarIconTone CCPetsMenuBarIconToneForState(NSString *state) {
    if (![state isKindOfClass:NSString.class] || state.length == 0 || [state isEqualToString:@"idle"]) {
        return CCPetsMenuBarIconToneNone;
    }
    if ([state isEqualToString:@"completed"] || [state isEqualToString:@"tool_completed"]) {
        return CCPetsMenuBarIconToneCompleted;
    }
    if ([state isEqualToString:@"failed"] || [state isEqualToString:@"tool_failed"]) {
        return CCPetsMenuBarIconToneFailed;
    }
    if ([state isEqualToString:@"approval"] || [state isEqualToString:@"notification"]) {
        return CCPetsMenuBarIconToneAttention;
    }
    return CCPetsMenuBarIconToneWorking;
}

NSString *CCPetsMenuBarApprovalSessionID(NSArray<NSDictionary *> *sessions) {
    for (NSDictionary *session in sessions) {
        if (![session isKindOfClass:NSDictionary.class] || ![session[@"state"] isEqual:@"approval"]) continue;
        NSString *sessionID = [session[@"id"] isKindOfClass:NSString.class] ? session[@"id"] : nil;
        NSString *terminal = [session[@"terminal"] isKindOfClass:NSString.class] ? session[@"terminal"] : nil;
        if (sessionID.length > 0 && terminal.length > 0) return sessionID;
    }
    return nil;
}

NSNumber *CCPetsMenuBarTodayTokens(NSArray<NSDictionary *> *quotas) {
    BOOL found = NO;
    unsigned long long total = 0;
    for (NSDictionary *quota in quotas) {
        if (![quota isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *usage = [quota[@"usage"] isKindOfClass:NSDictionary.class] ? quota[@"usage"] : nil;
        NSDictionary *tokens = [usage[@"tokenUsage"] isKindOfClass:NSDictionary.class] ? usage[@"tokenUsage"] : nil;
        NSDictionary *today = [tokens[@"today"] isKindOfClass:NSDictionary.class] ? tokens[@"today"] : nil;
        NSNumber *value = [today[@"total_tokens"] isKindOfClass:NSNumber.class] ? today[@"total_tokens"] : nil;
        if (!value || value.doubleValue < 0) continue;
        found = YES;
        total += value.unsignedLongLongValue;
    }
    return found ? @(total) : nil;
}
