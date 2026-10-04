#import "CCPetsVersion.h"
#import <signal.h>
#import <unistd.h>
#import <errno.h>

static NSArray<NSNumber *> *StableVersionComponents(NSString *version) {
    if (![version isKindOfClass:NSString.class]) return nil;
    NSArray<NSString *> *parts = [version componentsSeparatedByString:@"."];
    if (parts.count != 3) return nil;
    NSCharacterSet *nonDigits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet;
    NSMutableArray<NSNumber *> *components = [NSMutableArray arrayWithCapacity:3];
    for (NSString *part in parts) {
        if (part.length == 0 || part.length > 9 ||
            (part.length > 1 && [part hasPrefix:@"0"]) ||
            [part rangeOfCharacterFromSet:nonDigits].location != NSNotFound) return nil;
        [components addObject:@(part.longLongValue)];
    }
    return components;
}

NSComparisonResult CompareStableVersions(NSString *left, NSString *right, BOOL *valid) {
    NSArray<NSNumber *> *leftParts = StableVersionComponents(left);
    NSArray<NSNumber *> *rightParts = StableVersionComponents(right);
    if (!leftParts || !rightParts) {
        if (valid) *valid = NO;
        return NSOrderedSame;
    }
    if (valid) *valid = YES;
    for (NSUInteger index = 0; index < 3; index++) {
        long long leftValue = leftParts[index].longLongValue;
        long long rightValue = rightParts[index].longLongValue;
        if (leftValue < rightValue) return NSOrderedAscending;
        if (leftValue > rightValue) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

int RestartAfterPID(pid_t pid, NSString *appPath, BOOL managed) {
    for (NSUInteger attempt = 0; attempt < 300; attempt++) {
        if (pid <= 1 || (kill(pid, 0) != 0 && errno == ESRCH)) break;
        usleep(100000);
    }
    if (pid > 1 && (kill(pid, 0) == 0 || errno == EPERM)) {
        fprintf(stderr, "等待旧版 CC Pets 退出超时。\n");
        return EXIT_FAILURE;
    }

    NSString *openPath = NSProcessInfo.processInfo.environment[@"CC_PETS_OPEN_PATH"];
    if (openPath.length == 0) openPath = @"/usr/bin/open";
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:openPath];
    NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObjects:@"-g", appPath, nil];
    if (managed) [arguments addObjectsFromArray:@[@"--args", @"--managed"]];
    task.arguments = arguments;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        fprintf(stderr, "无法重新启动 CC Pets: %s\n", error.localizedDescription.UTF8String);
        return EXIT_FAILURE;
    }
    [task waitUntilExit];
    return task.terminationStatus == EXIT_SUCCESS ? EXIT_SUCCESS : EXIT_FAILURE;
}

// 刚发布的版本存在 packument 传播与本机 npm 缓存的竞态：registry 的 /latest 已经报出
// 新版本，而同一时刻 `npm install cc-pets@<新版本>` 解析到的包元数据可能还是旧的，
// 直接报 ETARGET。这类失败重试一次通常就好，不该当成"装不上"弹错误框。
// 网络类错误同理。真正的失败（EACCES、ENOSPC、脚本报错等）不在此列，必须如实上报。
BOOL UpdateFailureIsTransient(NSString *log) {
    if (log.length == 0) return NO;
    static NSArray<NSString *> *markers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        markers = @[@"ETARGET", @"ENOTFOUND", @"EAI_AGAIN", @"ETIMEDOUT", @"ECONNRESET",
                    @"ERR_SOCKET_TIMEOUT", @"ECONNREFUSED", @"ERR_SSL", @"429", @"503"];
    });
    for (NSString *marker in markers) {
        if ([log rangeOfString:marker options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static NSString *StripReleaseNoteMarkdown(NSString *text) {
    static NSRegularExpression *link, *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        image = [NSRegularExpression regularExpressionWithPattern:@"!\\[[^\\]]*\\]\\([^)]*\\)"
            options:0 error:nil];
        link = [NSRegularExpression regularExpressionWithPattern:@"\\[([^\\]]*)\\]\\([^)]*\\)"
            options:0 error:nil];
    });
    NSMutableString *result = [text mutableCopy];
    [image replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:@""];
    [link replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:@"$1"];
    for (NSString *marker in @[@"**", @"__", @"`"]) {
        [result replaceOccurrencesOfString:marker withString:@"" options:0
            range:NSMakeRange(0, result.length)];
    }
    return [result stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

NSArray<NSString *> *ReleaseNoteHighlights(NSString *body, NSUInteger limit, NSUInteger maxLength,
    BOOL *truncated) {
    if (truncated) *truncated = NO;
    if (![body isKindOfClass:NSString.class] || body.length == 0 || limit == 0) return @[];
    NSArray<NSString *> *lines = [[body stringByReplacingOccurrencesOfString:@"\r" withString:@""]
        componentsSeparatedByString:@"\n"];

    // 有「简体中文」段就只取这一段：从它的标题开始，到下一个同级或更高级标题为止。
    NSRange section = NSMakeRange(0, lines.count);
    for (NSUInteger index = 0; index < lines.count; index++) {
        NSString *line = [lines[index] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (![line hasPrefix:@"#"]) continue;
        NSUInteger level = 0;
        while (level < line.length && [line characterAtIndex:level] == '#') level++;
        NSString *title = [[line substringFromIndex:level]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (![title isEqualToString:@"简体中文"] && ![title isEqualToString:@"中文"]) continue;
        NSUInteger end = lines.count;
        for (NSUInteger next = index + 1; next < lines.count; next++) {
            NSString *candidate = lines[next];
            if (![candidate hasPrefix:@"#"]) continue;
            NSUInteger nextLevel = 0;
            while (nextLevel < candidate.length && [candidate characterAtIndex:nextLevel] == '#') nextLevel++;
            if (nextLevel <= level) { end = next; break; }
        }
        section = NSMakeRange(index + 1, end - index - 1);
        break;
    }

    static NSRegularExpression *bullet;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 只认顶层列表项（行首不缩进），嵌套的子项是补充说明，挤不进三条要点。
        bullet = [NSRegularExpression regularExpressionWithPattern:@"^(?:[-*+]|\\d+[.)])\\s+(.+)$"
            options:0 error:nil];
    });
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    BOOL inFence = NO;
    for (NSUInteger index = section.location; index < NSMaxRange(section); index++) {
        NSString *line = lines[index];
        if ([[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] hasPrefix:@"```"]) {
            inFence = !inFence;
            continue;
        }
        if (inFence) continue;
        NSTextCheckingResult *match = [bullet firstMatchInString:line options:0
            range:NSMakeRange(0, line.length)];
        if (!match) continue;
        NSString *text = StripReleaseNoteMarkdown([line substringWithRange:[match rangeAtIndex:1]]);
        if (text.length == 0) continue;
        if (items.count == limit) {
            if (truncated) *truncated = YES;
            break;
        }
        if (maxLength > 0 && text.length > maxLength) {
            NSRange keep = [text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, maxLength)];
            text = [[text substringWithRange:keep] stringByAppendingString:@"…"];
        }
        [items addObject:text];
    }
    return items;
}
