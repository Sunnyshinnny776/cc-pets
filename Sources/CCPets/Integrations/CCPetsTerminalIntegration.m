#import "CCPetsTerminalIntegration.h"
#import <CoreServices/CoreServices.h>

static NSString *const GhosttyBundleID = @"com.mitchellh.ghostty";
// Ghostty 1.4 起在 AppleScript 字典里暴露 terminal 的 tty。
static NSString *const GhosttyMinimumVersion = @"1.4";

static NSString *AutomationState(NSString *bundleID, BOOL askUserIfNeeded) {
    NSAppleEventDescriptor *target = [NSAppleEventDescriptor descriptorWithBundleIdentifier:bundleID];
    OSStatus status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, askUserIfNeeded);
    switch (status) {
        case noErr: return @"granted";
        case errAEEventNotPermitted: return @"denied";
        case errAEEventWouldRequireUserConsent: return @"notDetermined";
        case procNotFound: return @"notRunning";
        default: return @"notDetermined";
    }
}

static BOOL ApplicationIsRunning(NSString *bundleID) {
    return [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID].count > 0;
}

NSArray<NSDictionary *> *CCPetsTerminalIntegrationSnapshot(void) {
    NSArray<NSArray<NSString *> *> *terminals = @[
        @[@"com.apple.Terminal", @"apple"],
        @[@"com.googlecode.iterm2", @"apple"],
        @[GhosttyBundleID, @"ghostty"],
    ];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSArray<NSString *> *terminal in terminals) {
        NSString *bundleID = terminal[0];
        NSURL *url = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:bundleID];
        if (!url) continue;
        NSBundle *bundle = [NSBundle bundleWithURL:url];
        NSString *name = [NSFileManager.defaultManager displayNameAtPath:url.path].stringByDeletingPathExtension;
        NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        if (![version isKindOfClass:NSString.class]) version = @"";
        NSString *state;
        if ([bundleID isEqualToString:GhosttyBundleID] && version.length &&
            [version compare:GhosttyMinimumVersion options:NSNumericSearch] == NSOrderedAscending) {
            state = @"unsupported";
        } else if (!ApplicationIsRunning(bundleID)) {
            state = @"notRunning";
        } else {
            state = AutomationState(bundleID, NO);
        }
        [rows addObject:@{@"name": name ?: bundleID, @"bundleID": bundleID, @"version": version,
            @"group": terminal[1], @"state": state}];
    }
    return rows;
}

void CCPetsRequestTerminalAutomation(NSString *bundleID, void (^completion)(void)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (ApplicationIsRunning(bundleID)) AutomationState(bundleID, YES);
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    });
}

void CCPetsOpenAutomationSettings(void) {
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"];
    [NSWorkspace.sharedWorkspace openURL:url];
}
