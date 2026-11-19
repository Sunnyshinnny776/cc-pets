#import "QuotaDashboardView+Private.h"
#import "CCPetsPreferences.h"
#import "CCPetsProfiles.h"

static NSString *const SummaryCarousel = @"summary";

const CGFloat QuotaLogicalWidth = 760;
const CGFloat QuotaLogicalHeight = 590;
const CGFloat QuotaScale = 0.58;

CGFloat QuotaLogicalHeightForProviderCount(NSUInteger count) {
    if (count == 0) return QuotaHeaderHeight + QuotaEmptyNoticeHeight + 16;
    CGFloat cardHeight = QuotaBaseCardHeight + QuotaReclaimedFooterHeight / count;
    return QuotaHeaderHeight + QuotaSummaryHeight +
        count * (QuotaBlockGap + cardHeight) + QuotaBottomPadding;
}


// 各家图标的透明边距不同。加载时按不透明主体裁切，再放进相同的留白画布，
// 避免每次重绘扫描像素，也避免 ICNS 的阴影影响视觉尺寸。
static NSImage *NormalizedAgentIcon(NSImage *image) {
    const size_t side = 256;
    CGImageRef source = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!source) return image;
    unsigned char *pixels = calloc(side * side, 4);
    if (!pixels) return image;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, side, side, 8, side * 4,
        colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) { free(pixels); return image; }
    CGFloat width = CGImageGetWidth(source), height = CGImageGetHeight(source);
    CGFloat scale = MIN(side / width, side / height);
    CGContextDrawImage(context, CGRectMake((side - width * scale) / 2,
        (side - height * scale) / 2, width * scale, height * scale), source);
    size_t minX = side, minY = side, maxX = 0, maxY = 0;
    for (size_t y = 0; y < side; y++) {
        for (size_t x = 0; x < side; x++) {
            if (pixels[(y * side + x) * 4 + 3] < 128) continue;
            minX = MIN(minX, x); minY = MIN(minY, y);
            maxX = MAX(maxX, x); maxY = MAX(maxY, y);
        }
    }
    CGImageRef raster = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    free(pixels);
    if (!raster || minX == side) {
        if (raster) CGImageRelease(raster);
        return image;
    }
    CGImageRef cropped = CGImageCreateWithImageInRect(raster,
        CGRectMake(minX, minY, maxX - minX + 1, maxY - minY + 1));
    CGImageRelease(raster);
    if (!cropped) return image;
    NSSize size = NSMakeSize(CGImageGetWidth(cropped), CGImageGetHeight(cropped));
    NSImage *content = [[NSImage alloc] initWithCGImage:cropped size:size];
    CGImageRelease(cropped);
    return [NSImage imageWithSize:NSMakeSize(side, side) flipped:NO drawingHandler:^BOOL(NSRect bounds) {
        NSRect available = NSInsetRect(bounds, 16, 16);
        CGFloat fit = MIN(NSWidth(available) / size.width, NSHeight(available) / size.height);
        NSRect target = NSMakeRect(NSMidX(bounds) - size.width * fit / 2,
            NSMidY(bounds) - size.height * fit / 2, size.width * fit, size.height * fit);
        [NSGraphicsContext saveGraphicsState];
        CGFloat radius = MIN(NSWidth(target), NSHeight(target)) * 18 / 70;
        [[NSBezierPath bezierPathWithRoundedRect:target xRadius:radius yRadius:radius] addClip];
        [content drawInRect:target fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
            fraction:1 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
        [NSGraphicsContext restoreGraphicsState];
        return YES;
    }];
}

NSImage *OfficialAppIcon(NSString *bundleIdentifier, NSString *resourceName) {
    NSURL *appURL = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:bundleIdentifier];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    if (appURL) {
        NSBundle *bundle = [NSBundle bundleWithURL:appURL];
        NSString *resourcePath = [bundle pathForResource:resourceName.stringByDeletingPathExtension
            ofType:resourceName.pathExtension];
        if (resourcePath.length > 0) [paths addObject:resourcePath];
    }
    NSString *applicationName = [bundleIdentifier containsString:@"anthropic"] ? @"Claude.app" : @"ChatGPT.app";
    if ([bundleIdentifier isEqualToString:@"com.google.antigravity"]) applicationName = @"Antigravity.app";
    [paths addObject:[@"/Applications" stringByAppendingPathComponent:
        [applicationName stringByAppendingPathComponent:[@"Contents/Resources" stringByAppendingPathComponent:resourceName]]]];
    [paths addObject:[[NSHomeDirectory() stringByAppendingPathComponent:@"Applications"] stringByAppendingPathComponent:
        [applicationName stringByAppendingPathComponent:[@"Contents/Resources" stringByAppendingPathComponent:resourceName]]]];
    for (NSString *path in paths) {
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
        if (image) return NormalizedAgentIcon(image);
    }
    if (appURL && [NSFileManager.defaultManager fileExistsAtPath:appURL.path]) {
        NSImage *image = [NSWorkspace.sharedWorkspace iconForFile:appURL.path];
        if (image) return NormalizedAgentIcon(image);
    }
    // 没装官方桌面端（例如只装 CLI）时，从发布包读取备用图标。
    NSString *fallback = @{
        @"com.anthropic.claudefordesktop": @"claude.png",
        @"com.openai.codex": @"codex.icns",
        @"com.google.antigravity": @"antigravity.icns"
    }[bundleIdentifier];
    if (!fallback) return nil;
    NSArray<NSString *> *directories = @[
        NSBundle.mainBundle.resourcePath ?: @"",
        NSBundle.mainBundle.executablePath.stringByDeletingLastPathComponent ?: @""
    ];
    for (NSString *directory in directories) {
        if (directory.length == 0) continue;
        NSString *path = [[directory stringByAppendingPathComponent:@"AgentIcons"]
            stringByAppendingPathComponent:fallback];
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
        if (image) return NormalizedAgentIcon(image);
    }
    return nil;
}


@implementation QuotaDashboardView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _selectedProfileIDs = [NSMutableDictionary dictionary];
        self.accessibilityElement = YES;
        self.accessibilityRole = NSAccessibilityGroupRole;
        self.accessibilityLabel = L(@"Agent usage account cards");
        self.accessibilityHelp = L(@"Use the arrows, page dots, or horizontal swipes to switch usage pages or accounts. Use the button below the cards to show more or fewer.");
        NSTrackingArea *tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
            options:NSTrackingMouseEnteredAndExited |
                    NSTrackingActiveAlways | NSTrackingInVisibleRect
            owner:self userInfo:nil];
        [self addTrackingArea:tracking];
    }
    return self;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (void)mouseEntered:(NSEvent *)event {
    if (self.hoverChanged) self.hoverChanged(YES);
}
- (void)mouseExited:(NSEvent *)event {
    if (self.hoverChanged) self.hoverChanged(NO);
}
// 探测还未完成时保留旧版 Codex / Claude 布局。已有账号或用量的 Antigravity 也可以显示。
- (NSArray<NSString *> *)visibleProviders {
    NSMutableArray<NSString *> *visible = [NSMutableArray array];
    for (CCPetsProviderDescriptor *provider in CCPetsProviderDescriptors()) {
        BOOL detected = [self.detectedProviders containsObject:provider.name];
        if (!self.detectedProviders) {
            detected = ![provider.profileProvider isEqualToString:CCPetsProfileProviderAntigravity] ||
                [self profilesForProvider:provider.name].count > 0 || self.usageByProvider[provider.name].count > 0;
        }
        if (detected) {
            [visible addObject:provider.name];
        }
    }
    return visible;
}
- (NSArray<NSString *> *)orderedCardProviders {
    NSArray<NSString *> *available = [self visibleProviders];
    if (self.animatingCardOrder && [[NSSet setWithArray:self.animatingCardOrder] isEqualToSet:[NSSet setWithArray:available]]) {
        return self.animatingCardOrder;
    }
    NSArray<NSString *> *manual = CCPetsQuotaCardOrder();
    NSMutableDictionary<NSString *, NSNumber *> *weeklyUsed = [NSMutableDictionary dictionary];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    for (NSString *name in available) {
        CCPetsProviderDescriptor *descriptor = CCPetsProviderForName(name);
        NSDictionary *week = [self quota:[self usageForProvider:name] key:@"week"];
        NSNumber *used = [week[descriptor.usedKey] isKindOfClass:NSNumber.class] ? week[descriptor.usedKey] : nil;
        NSNumber *reset = [week[@"resets_at"] isKindOfClass:NSNumber.class] ? week[@"resets_at"] : nil;
        if (used && isfinite(used.doubleValue) && (!reset || reset.doubleValue > now)) weeklyUsed[name] = used;
    }
    return [available sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        NSUInteger leftIndex = [manual indexOfObject:CCPetsProviderForName(left).key];
        NSUInteger rightIndex = [manual indexOfObject:CCPetsProviderForName(right).key];
        if (leftIndex != rightIndex) return leftIndex < rightIndex ? NSOrderedAscending : NSOrderedDescending;
        NSNumber *leftUsed = weeklyUsed[left], *rightUsed = weeklyUsed[right];
        if (leftUsed && rightUsed) return [rightUsed compare:leftUsed];
        if (leftUsed == rightUsed) return NSOrderedSame;
        return leftUsed ? NSOrderedAscending : NSOrderedDescending;
    }];
}

- (NSArray<NSString *> *)orderedQuotaProviderKeys {
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (NSString *name in [self orderedCardProviders]) [keys addObject:CCPetsProviderForName(name).key];
    return keys;
}

- (NSArray<NSString *> *)displayedCardProviders {
    NSArray<NSString *> *providers = [self orderedCardProviders];
    if (!self.quotaCardsExpanded && providers.count > QuotaCollapsedCardCount) {
        return [providers subarrayWithRange:NSMakeRange(0, QuotaCollapsedCardCount)];
    }
    return providers;
}

- (BOOL)areQuotaCardsExpanded { return self.quotaCardsExpanded; }

- (CGFloat)logicalHeight {
    NSUInteger available = [self visibleProviders].count;
    NSUInteger shown = self.quotaCardsExpanded ? available : MIN(available, QuotaCollapsedCardCount);
    return QuotaLogicalHeightForProviderCount(shown);
}

- (void)refreshQuotaCardLayout {
    [self updateTrackingAreas];
    self.needsDisplay = YES;
}

- (NSString *)profileProviderForName:(NSString *)name {
    return CCPetsProviderForName(name).profileProvider;
}

- (NSArray<NSDictionary *> *)profilesForProvider:(NSString *)name {
    NSString *provider = [self profileProviderForName:name];
    NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
    for (NSDictionary *profile in self.profiles ?: @[]) {
        if ([profile[@"provider"] isEqualToString:provider]) [matches addObject:profile];
    }
    return matches;
}

- (NSString *)selectionDefaultsKeyForProvider:(NSString *)name {
    return [NSString stringWithFormat:@"CCPetsSelected%@ProfileID", name];
}

- (NSDictionary *)selectedProfileForProvider:(NSString *)name {
    NSArray<NSDictionary *> *profiles = [self profilesForProvider:name];
    if (profiles.count == 0) return nil;
    NSString *selected = self.selectedProfileIDs[name];
    if (selected.length == 0) {
        selected = [NSUserDefaults.standardUserDefaults stringForKey:
            [self selectionDefaultsKeyForProvider:name]];
    }
    for (NSDictionary *profile in profiles) {
        if ([profile[@"id"] isEqualToString:selected]) {
            self.selectedProfileIDs[name] = selected;
            return profile;
        }
    }
    NSDictionary *first = profiles.firstObject;
    self.selectedProfileIDs[name] = first[@"id"];
    return first;
}

- (NSDictionary *)usageForProvider:(NSString *)name {
    NSDictionary *profile = [self selectedProfileForProvider:name];
    if (profile) return self.profileUsages[profile[@"id"]] ?: @{};
    return self.usageByProvider[name] ?: @{};
}

- (NSDictionary *)summedTokenBucket:(NSArray<NSDictionary *> *)buckets {
    NSMutableDictionary<NSString *, NSNumber *> *sum = [NSMutableDictionary dictionary];
    for (NSDictionary *bucket in buckets) {
        if (![bucket isKindOfClass:NSDictionary.class]) continue;
        [bucket enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
            if ([value isKindOfClass:NSNumber.class]) {
                sum[key] = @([sum[key] doubleValue] + [value doubleValue]);
            }
        }];
    }
    return sum;
}

- (NSDictionary *)summaryUsageForProvider:(NSString *)name {
    NSArray<NSDictionary *> *profiles = [self profilesForProvider:name];
    if (profiles.count == 0) return [self usageForProvider:name];
    NSMutableArray<NSDictionary *> *today = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *recentWeek = [NSMutableArray array];
    for (NSDictionary *profile in profiles) {
        NSDictionary *usage = self.profileUsages[profile[@"id"]];
        NSDictionary *tokenUsage = [usage[@"tokenUsage"] isKindOfClass:NSDictionary.class]
            ? usage[@"tokenUsage"] : nil;
        if ([tokenUsage[@"today"] isKindOfClass:NSDictionary.class]) [today addObject:tokenUsage[@"today"]];
        if ([tokenUsage[@"recentWeek"] isKindOfClass:NSDictionary.class]) [recentWeek addObject:tokenUsage[@"recentWeek"]];
    }
    return @{@"tokenUsage": @{
        @"today": [self summedTokenBucket:today],
        @"recentWeek": [self summedTokenBucket:recentWeek]
    }};
}

- (NSDictionary *)summaryUsageForAntigravityApp {
    NSArray<NSDictionary *> *profiles = [self profilesForProvider:@"Antigravity"];
    // App 的本机记录仅归属默认 Gemini Home，没有第二份账号额度或自定义 CLI Home 的份额。
    for (NSDictionary *profile in profiles) {
        NSDictionary *tokens = [self quota:self.profileUsages[profile[@"id"]] key:@"appTokenUsage"];
        if (tokens) return @{@"tokenUsage": tokens};
    }
    NSDictionary *tokens = [self quota:self.usageByProvider[@"Antigravity"] key:@"appTokenUsage"];
    return tokens ? @{@"tokenUsage": tokens} : @{};
}

- (NSString *)displayNameForProvider:(NSString *)name {
    NSDictionary *profile = [self selectedProfileForProvider:name];
    NSString *displayName = [profile[@"displayName"] isKindOfClass:NSString.class]
        ? profile[@"displayName"] : nil;
    return displayName.length > 0 ? displayName : name.lowercaseString;
}

- (NSUInteger)selectedIndexForProvider:(NSString *)name {
    NSArray<NSDictionary *> *profiles = [self profilesForProvider:name];
    NSString *selected = [self selectedProfileForProvider:name][@"id"];
    NSUInteger index = [profiles indexOfObjectPassingTest:^BOOL(NSDictionary *profile, NSUInteger index, BOOL *stop) {
        return [profile[@"id"] isEqualToString:selected];
    }];
    return index == NSNotFound ? 0 : index;
}

- (void)moveProfileForProvider:(NSString *)name direction:(NSInteger)direction {
    NSArray<NSDictionary *> *profiles = [self profilesForProvider:name];
    if (profiles.count < 2 || direction == 0) return;
    NSInteger index = (NSInteger)[self selectedIndexForProvider:name];
    NSInteger count = (NSInteger)profiles.count;
    NSInteger next = (index + (direction > 0 ? 1 : -1) + count) % count;
    [self selectProfileIndex:(NSUInteger)next forProvider:name direction:direction];
}

- (void)selectProfileIndex:(NSUInteger)index forProvider:(NSString *)name direction:(NSInteger)direction {
    NSArray<NSDictionary *> *profiles = [self profilesForProvider:name];
    if (index >= profiles.count || index == [self selectedIndexForProvider:name]) return;
    NSString *profileID = profiles[index][@"id"];
    // Keep the card in place through the account animation. Reapply quota order when it completes.
    self.animatingCardOrder = [self orderedCardProviders];
    self.animatingCarouselProvider = name;
    self.carouselAnimationDirection = direction > 0 ? 1 : -1;
    self.carouselAnimationStartedAt = NSDate.date.timeIntervalSince1970;
    self.selectedProfileIDs[name] = profileID;
    [NSUserDefaults.standardUserDefaults setObject:profileID
        forKey:[self selectionDefaultsKeyForProvider:name]];
    self.activeCarouselProvider = name;
    self.needsDisplay = YES;
    [self advanceCarouselAnimation];
}

- (void)advanceCarouselAnimation {
    if (self.animatingCarouselProvider.length == 0) return;
    self.needsDisplay = YES;
    if (NSDate.date.timeIntervalSince1970 - self.carouselAnimationStartedAt >= 0.20) {
        self.animatingCarouselProvider = nil;
        self.animatingCardOrder = nil;
        [self refreshQuotaCardLayout];
        return;
    }
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(advanceCarouselAnimation) object:nil];
    [self performSelector:@selector(advanceCarouselAnimation) withObject:nil afterDelay:1.0 / 60.0];
}

- (NSRect)logicalCardRectForProvider:(NSString *)target {
    CGFloat cardTop = [self logicalHeight] - QuotaHeaderHeight - QuotaSummaryHeight;
    NSArray<NSString *> *providers = [self displayedCardProviders];
    CGFloat cardHeight = QuotaCardHeightForProviderCount(providers.count);
    for (NSString *name in providers) {
        cardTop -= QuotaBlockGap;
        NSRect card = NSMakeRect(20, cardTop - cardHeight,
            QuotaLogicalWidth - 40, cardHeight);
        if ([name isEqualToString:target]) return card;
        cardTop -= cardHeight;
    }
    return NSZeroRect;
}

- (NSRect)logicalTrendRectForProvider:(NSString *)provider {
    NSRect card = [self logicalCardRectForProvider:provider];
    CGFloat contentOffset = (NSHeight(card) - QuotaBaseCardHeight) / 2;
    return NSMakeRect(NSMinX(card) + 574, NSMinY(card) + contentOffset + 22, 145, 112);
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    [self removeAllToolTips];
    for (NSString *provider in [self displayedCardProviders]) {
        NSRect rect = [self logicalTrendRectForProvider:provider];
        rect.origin.x *= QuotaScale;
        rect.origin.y *= QuotaScale;
        rect.size.width *= QuotaScale;
        rect.size.height *= QuotaScale;
        [self addToolTipRect:rect owner:self userData:NULL];
    }
}

- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag
    point:(NSPoint)point userData:(void *)data {
    // 在显示时读取当前账号，轮播或刷新数据后不会留下上一账号的统计。
    if (self.animatingCarouselProvider.length > 0) return nil;
    NSPoint logicalPoint = NSMakePoint(point.x / QuotaScale, point.y / QuotaScale);
    for (NSString *provider in [self displayedCardProviders]) {
        if (!NSPointInRect(logicalPoint, [self logicalTrendRectForProvider:provider])) continue;
        NSDictionary *usage = [self usageForProvider:provider];
        NSDictionary *normalized = [self normalizedUsageForProvider:provider
            profile:[self selectedProfileForProvider:provider] usage:usage];
        if ([normalized[@"billing"] isEqualToString:@"subscription"]) return nil;
        NSDictionary *tokenUsage = normalized[@"tokens"];
        NSArray<NSDictionary *> *days = [tokenUsage[@"monthDaily"] isKindOfClass:NSArray.class]
            ? tokenUsage[@"monthDaily"] : @[];
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        NSUInteger recordedDays = 0;
        double peak = 0;
        for (NSDictionary *day in days) {
            if ([day[@"timestamp"] doubleValue] > now) continue;
            NSDictionary *totals = [day[@"totals"] isKindOfClass:NSDictionary.class]
                ? day[@"totals"] : nil;
            peak = fmax(peak, [totals[@"total_tokens"] doubleValue]);
            recordedDays += 1;
        }
        NSString *peakText = recordedDays > 0
            ? [NSString stringWithFormat:L(@"Peak %@"), [self formattedTokenValue:peak]] : L(@"Peak --");
        NSString *recordedText = [NSString stringWithFormat:L(@"%lu / %lu days recorded"),
            (unsigned long)recordedDays, (unsigned long)days.count];
        return [NSString stringWithFormat:@"%@\n%@\n%@", L(@"Daily tokens"), peakText, recordedText];
    }
    return nil;
}

- (NSPoint)logicalPointForEvent:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    return NSMakePoint(point.x / QuotaScale, point.y / QuotaScale);
}

- (NSString *)carouselAtPoint:(NSPoint)point {
    if ([self summaryPageCount] > 1) {
        NSRect summary = [self logicalSummaryRect];
        summary.origin.x = 0;
        summary.size.width = QuotaLogicalWidth;
        if (NSPointInRect(point, summary)) return SummaryCarousel;
    }
    for (NSString *name in [self displayedCardProviders]) {
        NSRect hit = [self logicalCardRectForProvider:name];
        hit.origin.x = 0;
        hit.size.width = QuotaLogicalWidth;
        if (NSPointInRect(point, hit)) return name;
    }
    return nil;
}

- (NSUInteger)pageCountForCarousel:(NSString *)target {
    return [target isEqualToString:SummaryCarousel] ? [self summaryPageCount] : [self profilesForProvider:target].count;
}

- (void)moveCarousel:(NSString *)target direction:(NSInteger)direction {
    if (![target isEqualToString:SummaryCarousel]) {
        [self moveProfileForProvider:target direction:direction];
        return;
    }
    NSInteger count = (NSInteger)[self summaryPageCount];
    if (count < 2 || direction == 0) return;
    self.selectedSummaryPage = (NSUInteger)(((NSInteger)[self summaryPageIndex] + (direction > 0 ? 1 : -1) + count) % count);
    self.needsDisplay = YES;
}

- (NSRect)previousArrowHitRectForCard:(NSRect)card {
    return NSMakeRect(0, NSMidY(card) - 34, NSMinX(card) + 32, 68);
}

- (NSRect)nextArrowHitRectForCard:(NSRect)card {
    return NSMakeRect(NSMaxX(card) - 32, NSMidY(card) - 34,
        QuotaLogicalWidth - NSMaxX(card) + 32, 68);
}

- (BOOL)selectProfileDotAtPoint:(NSPoint)point provider:(NSString *)provider card:(NSRect)card {
    NSArray<NSDictionary *> *profiles = [self profilesForProvider:provider];
    CGFloat dotsWidth = (profiles.count - 1) * QuotaCarouselDotGap + QuotaCarouselDotDiameter;
    CGFloat dotsX = NSMinX(card) + 155 - dotsWidth / 2;
    CGFloat firstCenterX = dotsX + QuotaCarouselDotDiameter / 2;
    CGFloat contentOffset = (NSHeight(card) - QuotaBaseCardHeight) / 2;
    CGFloat centerY = NSMinY(card) + contentOffset + 34 + QuotaCarouselDotDiameter / 2;
    if (fabs(point.y - centerY) > 14) return NO;
    NSInteger index = lround((point.x - firstCenterX) / QuotaCarouselDotGap);
    if (index < 0 || index >= (NSInteger)profiles.count) return NO;
    CGFloat centerX = firstCenterX + index * QuotaCarouselDotGap;
    if (fabs(point.x - centerX) > QuotaCarouselDotGap / 2) return NO;

    NSInteger oldIndex = (NSInteger)[self selectedIndexForProvider:provider];
    if (index == oldIndex) return YES;
    [self selectProfileIndex:(NSUInteger)index forProvider:provider direction:index > oldIndex ? 1 : -1];
    return YES;
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self logicalPointForEvent:event];
    if (NSPointInRect(point, [self logicalCardsDisclosureRect])) {
        self.quotaCardsExpanded = !self.quotaCardsExpanded;
        if (self.layoutChanged) self.layoutChanged();
        else [self refreshQuotaCardLayout];
        return;
    }
    NSString *target = [self carouselAtPoint:point];
    if (!target || [self pageCountForCarousel:target] < 2) {
        [super mouseDown:event];
        return;
    }
    [self.window makeFirstResponder:self];
    self.activeCarouselProvider = target;
    BOOL summary = [target isEqualToString:SummaryCarousel];
    NSRect card = summary ? NSZeroRect : [self logicalCardRectForProvider:target];
    NSRect previous = summary ? NSInsetRect([self logicalSummaryPageArrowRectForDirection:-1], -8, 0)
        : [self previousArrowHitRectForCard:card];
    NSRect next = summary ? NSInsetRect([self logicalSummaryPageArrowRectForDirection:1], -8, 0)
        : [self nextArrowHitRectForCard:card];
    if (NSPointInRect(point, previous)) {
        [self moveCarousel:target direction:-1];
        return;
    }
    if (NSPointInRect(point, next)) {
        [self moveCarousel:target direction:1];
        return;
    }
    if (summary) {
        for (NSUInteger index = 0; index < [self summaryPageCount]; index++) {
            if (!NSPointInRect(point, NSInsetRect([self logicalSummaryPageDotRectAtIndex:index], -4, -3))) continue;
            self.selectedSummaryPage = index;
            self.needsDisplay = YES;
            return;
        }
    } else if ([self selectProfileDotAtPoint:point provider:target card:card]) return;

    // 卡片其余区域允许按住左右拖动；超过阈值后每次拖动只切换一次。
    self.dragCarouselProvider = target;
    self.dragCarouselStartPoint = point;
    self.dragCarouselDidSwitch = NO;
}

- (void)mouseDragged:(NSEvent *)event {
    if (self.dragCarouselProvider.length == 0) {
        [super mouseDragged:event];
        return;
    }
    if (self.dragCarouselDidSwitch) return;
    NSPoint point = [self logicalPointForEvent:event];
    CGFloat deltaX = point.x - self.dragCarouselStartPoint.x;
    if (fabs(deltaX) < 36) return;
    self.dragCarouselDidSwitch = YES;
    [self moveCarousel:self.dragCarouselProvider direction:deltaX < 0 ? 1 : -1];
}

- (void)mouseUp:(NSEvent *)event {
    self.dragCarouselProvider = nil;
    self.dragCarouselDidSwitch = NO;
}

- (void)scrollWheel:(NSEvent *)event {
    NSString *provider = [self carouselAtPoint:[self logicalPointForEvent:event]];
    CGFloat delta = fabs(event.scrollingDeltaX) >= fabs(event.scrollingDeltaY)
        ? event.scrollingDeltaX : (event.modifierFlags & NSEventModifierFlagShift ? event.scrollingDeltaY : 0);
    if (provider && delta != 0 && [self pageCountForCarousel:provider] > 1) {
        // 惯性阶段不再继续翻页，避免一次触控板滑动跳过多个账号。
        if (event.momentumPhase != NSEventPhaseNone) return;
        BOOL phasedGesture = event.phase != NSEventPhaseNone;
        if (phasedGesture) {
            if ((event.phase & NSEventPhaseBegan) != 0 ||
                ![self.scrollCarouselProvider isEqualToString:provider]) {
                self.scrollCarouselProvider = provider;
                self.scrollCarouselAccumulator = 0;
                self.scrollCarouselDidSwitch = NO;
            }
            self.scrollCarouselAccumulator += delta;
            CGFloat threshold = event.hasPreciseScrollingDeltas ? 12 : 1;
            if (!self.scrollCarouselDidSwitch && fabs(self.scrollCarouselAccumulator) >= threshold) {
                self.scrollCarouselDidSwitch = YES;
                [self moveCarousel:provider
                    direction:self.scrollCarouselAccumulator > 0 ? 1 : -1];
            }
            if ((event.phase & (NSEventPhaseEnded | NSEventPhaseCancelled)) != 0) {
                self.scrollCarouselProvider = nil;
                self.scrollCarouselAccumulator = 0;
                self.scrollCarouselDidSwitch = NO;
            }
            return;
        }

        // 无 phase 的鼠标滚轮仍按时间去抖，每个滚轮刻度最多切换一次。
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        if (now - self.lastCarouselSwitchAt < 0.22) return;
        self.lastCarouselSwitchAt = now;
        [self moveCarousel:provider direction:delta > 0 ? 1 : -1];
        return;
    }
    [super scrollWheel:event];
}

- (void)keyDown:(NSEvent *)event {
    NSString *target = self.activeCarouselProvider;
    if (target.length > 0 && (event.keyCode == 123 || event.keyCode == 124) &&
        ([target isEqualToString:SummaryCarousel] || [[self displayedCardProviders] containsObject:target]) &&
        [self pageCountForCarousel:target] > 1) {
        [self moveCarousel:target direction:event.keyCode == 123 ? -1 : 1];
        return;
    }
    [super keyDown:event];
}
- (NSUInteger)summaryPageCount {
    NSArray<NSString *> *providers = [self visibleProviders];
    NSUInteger rowCount = providers.count + ([providers containsObject:@"Antigravity"] ? 1 : 0);
    return (rowCount + QuotaSummaryRowsPerPage - 1) / QuotaSummaryRowsPerPage;
}

- (NSUInteger)summaryPageIndex {
    NSUInteger count = [self summaryPageCount];
    return count > 0 ? MIN(self.selectedSummaryPage, count - 1) : 0;
}

- (NSRect)logicalSummaryPageArrowRectForDirection:(NSInteger)direction {
    if ([self summaryPageCount] < 2) return NSZeroRect;
    NSRect summary = [self logicalSummaryRect];
    CGFloat x = direction < 0 ? 0 : NSMaxX(summary);
    return NSMakeRect(x, NSMidY(summary) - 25, NSMinX(summary), 50);
}

- (NSRect)logicalSummaryPageDotRectAtIndex:(NSUInteger)index {
    NSUInteger count = [self summaryPageCount];
    if (count < 2 || index >= count) return NSZeroRect;
    NSRect summary = [self logicalSummaryRect];
    CGFloat width = (count - 1) * QuotaCarouselDotGap + QuotaCarouselDotDiameter;
    CGFloat x = NSMidX(summary) - width / 2 + index * QuotaCarouselDotGap;
    return NSMakeRect(x, NSMinY(summary) + 3, QuotaCarouselDotDiameter, QuotaCarouselDotDiameter);
}

- (NSRect)logicalCardsDisclosureRect {
    if ([self visibleProviders].count <= QuotaCollapsedCardCount) return NSZeroRect;
    NSRect card = [self logicalCardRectForProvider:[self displayedCardProviders].lastObject];
    CGFloat width = 128;
    return NSMakeRect(NSMidX(card) - width / 2, NSMinY(card) + 3, width, QuotaCardsDisclosureHeight);
}

- (NSRect)logicalSummaryRect {
    return NSMakeRect(20, [self logicalHeight] - QuotaHeaderHeight - QuotaSummaryHeight,
        QuotaLogicalWidth - 40, QuotaSummaryHeight + 1 / QuotaScale);
}
// 刷新时间挪去了右上角，这一版块整宽留给两个统计格，各占一半。
- (NSRect)logicalSummaryCellRectAtIndex:(NSUInteger)index {
    NSRect summary = [self logicalSummaryRect];
    CGFloat width = NSWidth(summary) / 2;
    return index < 2
        ? NSMakeRect(NSMinX(summary) + index * width, NSMinY(summary), width, NSHeight(summary))
        : NSZeroRect;
}
- (NSDictionary *)quota:(NSDictionary *)usage key:(NSString *)key {
    id value = usage[key];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
- (NSDictionary *)tokenTotals:(NSDictionary *)usage key:(NSString *)key {
    NSDictionary *tokenUsage = [usage[@"tokenUsage"] isKindOfClass:NSDictionary.class]
        ? usage[@"tokenUsage"] : nil;
    return [tokenUsage[key] isKindOfClass:NSDictionary.class] ? tokenUsage[key] : nil;
}
- (NSString *)formattedTokenValue:(double)value {
    if (value >= 1000000000) return [NSString stringWithFormat:@"%.2fB", value / 1000000000.0];
    if (value >= 1000000) return [NSString stringWithFormat:@"%.2fM", value / 1000000.0];
    if (value >= 1000) return [NSString stringWithFormat:@"%.1fK", value / 1000.0];
    return [NSString stringWithFormat:@"%.0f", value];
}
- (NSString *)formattedTokenCount:(NSDictionary *)totals {
    NSNumber *number = [totals[@"total_tokens"] isKindOfClass:NSNumber.class]
        ? totals[@"total_tokens"] : nil;
    return number ? [self formattedTokenValue:number.doubleValue] : @"--";
}
- (NSString *)formattedRequestCount:(NSDictionary *)totals {
    NSNumber *number = [totals[@"request_count"] isKindOfClass:NSNumber.class]
        ? totals[@"request_count"] : nil;
    return number ? [NSNumberFormatter localizedStringFromNumber:number
        numberStyle:NSNumberFormatterDecimalStyle] : @"--";
}
- (NSDictionary *)comparisonForCurrent:(double)current previous:(double)previous
    color:(NSColor *)color {
    if (previous <= 0) {
        return @{ @"text": current > 0 ? L(@"vs last month: new") : L(@"vs last month: flat"),
            @"color": current > 0 ? color : self.secondaryColor };
    }
    double change = (current - previous) * 100.0 / previous;
    if (fabs(change) < 0.05) {
        return @{ @"text": L(@"vs last month: flat"), @"color": self.secondaryColor };
    }
    return @{ @"text": [NSString stringWithFormat:L(@"vs last month %@%.1f%%"),
        change > 0 ? @"↑" : @"↓", fabs(change)], @"color": color };
}
// 输入取 total - output，而不是把几个 input_* 字段加起来：两家的包含关系是相反的。
// Codex 的 cached_input_tokens 是 input_tokens 的子集（实测 input+output == total），
// 相加会把缓存部分算两遍；Claude 的 input_tokens 不含缓存读写，两者是并列项，不加又会漏。
// total - output 对两家都成立，也保证"输入 + 输出"正好等于卡片上那个已用 Token。
- (NSString *)formattedTokenSplit:(NSDictionary *)totals wantsOutput:(BOOL)wantsOutput {
    NSNumber *total = [totals[@"total_tokens"] isKindOfClass:NSNumber.class]
        ? totals[@"total_tokens"] : nil;
    if (!total) return @"--";
    NSNumber *output = [totals[@"output_tokens"] isKindOfClass:NSNumber.class]
        ? totals[@"output_tokens"] : nil;
    double outputValue = output ? output.doubleValue : 0;
    return [self formattedTokenValue:
        wantsOutput ? outputValue : fmax(0, total.doubleValue - outputValue)];
}
// 5 小时窗口只显示时分，7 天窗口保留日期。resets_at 是整分对齐的，无需带秒。
- (NSString *)resetText:(NSDictionary *)quota showDate:(BOOL)showDate {
    NSNumber *reset = [quota[@"resets_at"] isKindOfClass:NSNumber.class] ? quota[@"resets_at"] : nil;
    if (!reset) return @"--";
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    formatter.timeZone = NSTimeZone.localTimeZone;
    formatter.dateFormat = showDate ? @"M/d HH:mm" : @"HH:mm";
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:reset.doubleValue]];
}
// 汇总条的最近 7 天是共享的自然日口径。优先显示聚合结果携带的真实边界；兼容旧缓存时，
// 再按同一规则（含今天在内的 7 个自然日）现场计算，避免界面暂时退回到没有起期。
- (NSString *)recentWeekUsageLabel {
    NSNumber *start = nil;
    for (CCPetsProviderDescriptor *provider in CCPetsProviderDescriptors()) {
        NSDictionary *usage = self.usageByProvider[provider.name];
        NSDictionary *tokenUsage = [usage[@"tokenUsage"] isKindOfClass:NSDictionary.class]
            ? usage[@"tokenUsage"] : nil;
        if ([tokenUsage[@"recentWeekStartsAt"] isKindOfClass:NSNumber.class]) {
            start = tokenUsage[@"recentWeekStartsAt"];
            break;
        }
    }
    if (!start) {
        NSCalendar *calendar = NSCalendar.currentCalendar;
        NSDate *midnight = [calendar startOfDayForDate:NSDate.date];
        NSDate *date = [calendar dateByAddingUnit:NSCalendarUnitDay value:-6 toDate:midnight
            options:0];
        start = @((date ?: midnight).timeIntervalSince1970);
    }
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    formatter.timeZone = NSTimeZone.localTimeZone;
    // 两个主题使用相同字号，统一采用紧凑日期，避免完整说明挤出单元格。
    formatter.dateFormat = @"M/d";
    NSString *date = [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:start.doubleValue]];
    return [NSString stringWithFormat:L(@"Last 7 days (since %@)"), date];
}
// 在线 = 这一家还有活着的客户端，和有没有额度数据无关：额度会一直缓存着，
// 拿它当在线信号会恒亮。身份不明的老客户端无法归属到某一家，保守地都算在线。
- (BOOL)isProviderOnline:(NSString *)name {
    return [self isProfileOnline:[self selectedProfileForProvider:name] provider:name];
}
- (BOOL)isProfileOnline:(NSDictionary *)profile provider:(NSString *)name {
    NSString *profileID = profile[@"id"];
    if ([self.liveUnscopedProviders containsObject:name] && [self.liveProviders containsObject:name]) {
        return YES;
    }
    // 只有同一个 Provider 已拿到精确 profileId 时才严格按账号判断。旧 Hook 或启动事件
    // 没有 profileId 时继续使用 provider 级进程信号，不能被另一家 Agent 的 ID 误伤。
    BOOL hasProfileAwareSessionForProvider = NO;
    for (NSDictionary *candidate in [self profilesForProvider:name]) {
        NSString *candidateID = candidate[@"id"];
        if (candidateID.length > 0 && [self.liveProfileIDs containsObject:candidateID]) {
            hasProfileAwareSessionForProvider = YES;
            break;
        }
    }
    if (profileID.length > 0 && hasProfileAwareSessionForProvider) {
        return [self.liveProfileIDs containsObject:profileID] || self.hasUnlabeledClient;
    }
    return [self.liveProviders containsObject:name] || self.hasUnlabeledClient;
}
- (NSDictionary *)normalizedUsageForProvider:(NSString *)name profile:(NSDictionary *)profile usage:(NSDictionary *)usage {
    BOOL api = profile ? CCPetsProfileShowsAPIUsage(profile) : [self.showsAPIUsageByProvider[name] boolValue];
    return CCPetsNormalizedUsage(CCPetsProviderForName(name), usage, api);
}
- (NSDictionary *)accountStateForProvider:(NSString *)name profile:(NSDictionary *)profile normalized:(NSDictionary *)normalized {
    BOOL api = ![normalized[@"billing"] isEqualToString:@"subscription"];
    BOOL exhausted = [normalized[@"exhausted"] boolValue];
    BOOL hasData = [normalized[@"hasData"] boolValue];
    BOOL online = [self isProfileOnline:profile provider:name];
    NSString *state = !api && exhausted ? @"limited" : (!hasData ? @"waiting" : (online ? @"online" : @"offline"));
    NSString *text = !api && exhausted ? L(@"Rate limited")
        : (!hasData ? L(@"Waiting for data") : (online ? L(@"● Online") : L(@"Offline")));
    return @{@"apiMode": @(api), @"online": @(online), @"hasData": @(hasData), @"state": state, @"status": text};
}
- (NSColor *)statusColorForState:(NSDictionary *)state {
    if ([state[@"state"] isEqualToString:@"limited"]) return NSColor.systemOrangeColor;
    if ([state[@"state"] isEqualToString:@"online"]) return NSColor.systemGreenColor;
    return self.secondaryColor;
}
- (NSDictionary *)accountSnapshotForProvider:(NSString *)name profile:(NSDictionary *)profile {
    NSString *profileID = profile[@"id"];
    NSDictionary *usage = profile ? (self.profileUsages[profileID] ?: @{}) : [self usageForProvider:name];
    NSArray *history = profile ? (self.profileHistories[profileID] ?: @[])
        : self.historyByProvider[name];
    NSDictionary *normalized = [self normalizedUsageForProvider:name profile:profile usage:usage];
    NSMutableDictionary *snapshot = [[self accountStateForProvider:name profile:profile normalized:normalized] mutableCopy];
    snapshot[@"normalized"] = normalized;
    snapshot[@"provider"] = name;
    snapshot[@"usage"] = usage ?: @{};
    snapshot[@"history"] = history ?: @[];
    if (profile) {
        snapshot[@"profile"] = profile;
        snapshot[@"profileId"] = profileID;
        snapshot[@"profileName"] = profile[@"displayName"] ?: name.lowercaseString;
    }
    return snapshot;
}
- (NSDictionary *)paceStatusForWindow:(NSDictionary *)window color:(NSColor *)providerColor {
    NSDictionary *quota = window[@"quota"];
    NSNumber *currentUsed = window[@"used"];
    if (!currentUsed) {
        return @{@"label": L(@"Not enough data"), @"tip": L(@"Waiting for data"),
                 @"color": self.secondaryColor};
    }
    NSNumber *reset = [quota[@"resets_at"] isKindOfClass:NSNumber.class]
        ? quota[@"resets_at"] : nil;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSTimeInterval windowSeconds = [window[@"minutes"] doubleValue] * 60;
    NSTimeInterval start = reset ? reset.doubleValue - windowSeconds : 0;
    NSTimeInterval elapsed = now - start;
    double projectedRemaining = NAN;
    NSTimeInterval paceObservationSeconds = windowSeconds / 7.0;
    // 满 24 小时就全额外推的话，放大倍数还有 7 倍：窗口第 25 小时，任何已用超过 14.3%
    // 的用户都会被判成"重置前用尽"。更糟的是两家的窗口起点差几个小时，就会出现一家
    // 已外推、另一家还没到门槛的断层——剩 80% 的报高风险，剩 61% 的却显示平稳。
    // 因此在 24 小时到窗口 1/3（56 小时）之间按观测时长加权，从"按当前已用"平滑过渡
    // 到"完全信任外推"，门槛处不再有跳变。
    const NSTimeInterval paceFullTrustSeconds = windowSeconds / 3.0;
    if (reset && reset.doubleValue > now && elapsed >= paceObservationSeconds) {
        double linearUsed = currentUsed.doubleValue * windowSeconds / elapsed;
        double confidence = fmin(1.0, (elapsed - paceObservationSeconds) /
            (paceFullTrustSeconds - paceObservationSeconds));
        double projectedUsed = currentUsed.doubleValue +
            (linearUsed - currentUsed.doubleValue) * confidence;
        projectedRemaining = 100.0 - projectedUsed;
    }

    // 四个档位从轻到重排成阶梯，后面的仲裁只在这上面挪档位，不再各写一套 label/tip/color。
    double remaining = 100.0 - currentUsed.doubleValue;
    NSArray<NSArray *> *ladder = @[
        @[L(@"Plenty"), CCPetsLanguageIsSource() ? @"" : L(@"Plenty of quota left"), NSColor.systemGreenColor],
        @[L(@"Steady"), CCPetsLanguageIsSource() ? @"" : L(@"Quota is holding steady"), providerColor],
        @[L(@"Watch"), L(@"Watch usage"), NSColor.systemOrangeColor],
        @[L(@"At risk"), L(@"Quota low"), NSColor.systemRedColor]
    ];
    NSUInteger baseRank = remaining >= 70 ? 0
        : (remaining >= 40 ? 1 : (remaining >= 15 ? 2 : 3));

    // 当前窗口开始满 24 小时后才按消耗节奏预测；此前 projectedRemaining 是 NAN，只看事实。
    NSInteger projectedRank = -1;
    NSString *projectedTip = nil;
    if (!isnan(projectedRemaining)) {
        if (remaining <= 5 || projectedRemaining < 0) {
            projectedRank = 3;
            projectedTip = L(@"Runs out early");
        } else if (projectedRemaining < 10) {
            projectedRank = 2;
            projectedTip = L(@"Ease off a bit");
        } else if (projectedRemaining >= 30) {
            projectedRank = 0;
            projectedTip = L(@"Plenty to spare");
        }
    }

    // 仲裁：有预测就以预测为准，但事实划两条不可逾越的线。预测是关于未来的猜测，
    // 剩余额度是此刻的事实；让猜测把事实盖掉，两个方向都会出错——
    //   剩 80% 被外推成"高风险"是虚惊，剩 10% 被外推成"需关注"是漏报，后者更危险。
    NSUInteger rank = projectedRank >= 0 ? (NSUInteger)projectedRank : baseRank;
    BOOL demotedByFact = NO;
    if (remaining < 15) rank = 3;                       // 只剩一成，再乐观的预测也压不下来
    else if (remaining < 40 && rank < 1) rank = 1;      // 不到四成就别标"充足"
    if (remaining >= 70 && rank > 2) {                  // 还有七成，再难看的预测也不报"高风险"
        rank = 2;
        demotedByFact = YES;
    }

    NSString *label = ladder[rank][0];
    NSString *tip = ladder[rank][1];
    if (demotedByFact) tip = L(@"Burning fast");
    else if (projectedRank >= 0 && rank == (NSUInteger)projectedRank) tip = projectedTip;
    return @{@"label": label, @"tip": tip, @"color": ladder[rank][2], @"level": @(rank)};
}
@end
