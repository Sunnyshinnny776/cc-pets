#import "QuotaDashboardView+Private.h"

@implementation QuotaDashboardView (Rendering)
- (void)drawProvider:(NSString *)name displayName:(NSString *)displayName
    usage:(NSDictionary *)usage usedKey:(NSString *)usedKey color:(NSColor *)color
    cardRect:(NSRect)card profileCount:(NSUInteger)profileCount selectedIndex:(NSUInteger)selectedIndex {
    NSColor *primary = self.primaryColor;
    NSColor *secondary = self.secondaryColor;
    NSDictionary *five = [self quota:usage key:@"fiveHour"];
    NSDictionary *week = [self quota:usage key:@"week"];
    NSDictionary *fiveTokens = [self tokenTotals:usage key:@"fiveHour"];
    NSDictionary *weekTokens = [self tokenTotals:usage key:@"week"];
    NSDictionary *monthTokens = [self tokenTotals:usage key:@"month"];
    // 同比两侧都只数到最后一个完整自然日（见 CalendarMonthWindows），因此不能拿含今天的
    // monthTokens 去比不含同日的上月——那样每天都会凭空多出小半天的增量。
    NSDictionary *monthComparable = [self tokenTotals:usage key:@"monthComparable"];
    NSDictionary *previousMonthTokens = [self tokenTotals:usage key:@"previousMonthToDate"];
    NSDictionary *tokenUsage = [usage[@"tokenUsage"] isKindOfClass:NSDictionary.class]
        ? usage[@"tokenUsage"] : nil;
    NSArray<NSDictionary *> *monthDaily = [tokenUsage[@"monthDaily"] isKindOfClass:NSArray.class]
        ? tokenUsage[@"monthDaily"] : @[];
    NSDictionary *profile = [self selectedProfileForProvider:name];
    NSDictionary *state = [self accountStateForProvider:name profile:profile usage:usage];
    BOOL apiMode = [state[@"apiMode"] boolValue];
    NSNumber *fiveUsed = [self usedForQuota:five usedKey:usedKey];
    NSNumber *weekUsed = [self usedForQuota:week usedKey:usedKey];
    // usage_limit_exceeded 只能说明某次请求被额度限制，不能说明耗尽的是 5 小时还是
    // 7 天窗口；切到 credits 后请求还能继续成功，但 rate_limits 可能一直为空。因此把它
    // 作为独立的“额度受限”状态，不再拿一个无窗口归属的事件覆盖两个官方百分比。
    BOOL exhausted = [usage[@"exhaustedAt"] isKindOfClass:NSNumber.class];
    BOOL hasData = [state[@"hasData"] boolValue];
    BOOL online = [state[@"online"] boolValue];

    NSBezierPath *cardPath = [NSBezierPath bezierPathWithRoundedRect:card xRadius:18 yRadius:18];
    // 经典主题的浅色渐变放到玻璃上会变成磨砂；原生玻璃下改垫一层深色衬底托住文字。
    if (self.usesLiquidGlass) {
        [self fillLiquidScrim:cardPath];
    } else {
        NSGradient *cardGlass = [[NSGradient alloc]
            initWithStartingColor:[NSColor colorWithWhite:1 alpha:0.085]
            endingColor:[color colorWithAlphaComponent:0.025]];
        [cardGlass drawInBezierPath:cardPath angle:-25];
    }
    [[NSColor colorWithWhite:1 alpha:self.usesLiquidGlass ? 0.10 : 0.18] setStroke];
    cardPath.lineWidth = 1;
    [cardPath stroke];

    // 账号列加宽，三个数据区略微收紧；Home 名称比 Provider 名更长。
    NSArray<NSNumber *> *separators = @[@(NSMinX(card) + 220), @(NSMinX(card) + 390),
        @(NSMinX(card) + 560)];
    [[NSColor colorWithWhite:1 alpha:0.10] setStroke];
    for (NSNumber *value in separators) {
        [NSBezierPath strokeLineFromPoint:NSMakePoint(value.doubleValue, NSMinY(card) + 14)
            toPoint:NSMakePoint(value.doubleValue, NSMaxY(card) - 14)];
    }

    // 卡片增高后保持原有内容组垂直居中，新增空间均匀落在上下两侧。
    CGFloat contentOffset = (NSHeight(card) - QuotaBaseCardHeight) / 2;
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *contentTransform = [NSAffineTransform transform];
    [contentTransform translateXBy:0 yBy:contentOffset];
    [contentTransform concat];
    card.size.height = QuotaBaseCardHeight;

    NSRect icon = NSMakeRect(NSMinX(card) + 12, NSMinY(card) + 41, 70, 70);
    NSImage *logo = [name isEqualToString:@"Codex"] ? self.codexLogo : self.claudeLogo;
    if (logo) {
        [NSGraphicsContext saveGraphicsState];
        [[NSBezierPath bezierPathWithRoundedRect:icon xRadius:18 yRadius:18] addClip];
        [logo drawInRect:icon fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0
            respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
        [NSGraphicsContext restoreGraphicsState];
    } else {
        [self fillRoundedRect:icon radius:18 color:[color colorWithAlphaComponent:0.7]];
        [name drawInRect:NSInsetRect(icon, 5, 23)
            withAttributes:[self centeredTextAttributesWithSize:13 color:NSColor.whiteColor weight:NSFontWeightBold]];
    }
    CGFloat nameWidth = 118;
    CGFloat nameSize = 22;
    while (nameSize > 14 && [displayName sizeWithAttributes:
            [self textAttributesWithSize:nameSize color:primary weight:NSFontWeightBold]].width > nameWidth) {
        nameSize -= 1;
    }
    NSMutableDictionary *nameAttributes = [[self textAttributesWithSize:nameSize color:primary
        weight:NSFontWeightBold] mutableCopy];
    NSMutableParagraphStyle *nameStyle = [NSMutableParagraphStyle new];
    nameStyle.lineBreakMode = NSLineBreakByTruncatingMiddle;
    nameAttributes[NSParagraphStyleAttributeName] = nameStyle;
    [displayName drawInRect:NSMakeRect(NSMinX(card) + 94, NSMinY(card) + 84, nameWidth, 30)
        withAttributes:nameAttributes];
    // 四态：额度被拒 → 额度受限（百分比仍是上次官方快照）；没有任何额度数据 → 等待数据；
    // 有数据但客户端已退出 → 离线；两者都有 → 在线。
    NSString *statusText = state[@"status"];
    NSColor *statusColor = (!apiMode && exhausted) ? NSColor.systemOrangeColor
        : (online && hasData ? NSColor.systemGreenColor : secondary);
    if (self.usesLiquidGlass) {
        // 原生玻璃下不画彩色底标签，状态色交给字前的圆点；文字里自带的"●"去掉，免得两个点。
        NSString *plain = [statusText stringByReplacingOccurrencesOfString:@"● " withString:@""];
        [self drawText:plain inRect:NSMakeRect(NSMinX(card) + 96, NSMinY(card) + 57, 120, 20)
            size:11 weight:NSFontWeightMedium color:statusColor dotColor:statusColor];
    } else {
        NSDictionary *statusAttributes = [self textAttributesWithSize:11 color:statusColor
            weight:NSFontWeightMedium];
        CGFloat statusWidth = ceil([statusText sizeWithAttributes:statusAttributes].width) + 18;
        NSRect status = NSMakeRect(NSMinX(card) + 94, NSMinY(card) + 55, statusWidth, 24);
        [self fillRoundedRect:status radius:12 color:[statusColor colorWithAlphaComponent:0.13]];
        [statusText drawInRect:NSInsetRect(status, 9, 4) withAttributes:statusAttributes];
    }
    if (profileCount > 1) {
        // 箭头画在卡片两侧 20pt 的留白里：描边 chevron 比"‹ ›"字形更大更清楚，用次要色压低存在感。
        [NSGraphicsContext saveGraphicsState];
        [[NSShadow new] set];
        [[secondary colorWithAlphaComponent:0.75] setStroke];
        for (NSNumber *side in @[@-1, @1]) {
            CGFloat tipX = side.doubleValue < 0 ? NSMinX(card) - 15 : NSMaxX(card) + 15;
            CGFloat tailX = tipX - side.doubleValue * 9;
            NSBezierPath *chevron = [NSBezierPath bezierPath];
            [chevron moveToPoint:NSMakePoint(tailX, NSMidY(card) + 13)];
            [chevron lineToPoint:NSMakePoint(tipX, NSMidY(card))];
            [chevron lineToPoint:NSMakePoint(tailX, NSMidY(card) - 13)];
            chevron.lineWidth = 3;
            chevron.lineCapStyle = NSLineCapStyleRound;
            chevron.lineJoinStyle = NSLineJoinStyleRound;
            [chevron stroke];
        }
        [NSGraphicsContext restoreGraphicsState];
        CGFloat dotsWidth = (profileCount - 1) * QuotaCarouselDotGap + QuotaCarouselDotDiameter;
        CGFloat dotsX = NSMinX(card) + 155 - dotsWidth / 2;
        for (NSUInteger index = 0; index < profileCount; index++) {
            NSRect dot = NSMakeRect(dotsX + index * QuotaCarouselDotGap, NSMinY(card) + 34,
                QuotaCarouselDotDiameter, QuotaCarouselDotDiameter);
            // 只标当前面板：选中用 Provider 主色，其余一律置灰。
            NSColor *dotColor = index == selectedIndex ? color : [secondary colorWithAlphaComponent:0.35];
            [dotColor setFill];
            [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
        }
    }

    if (apiMode) {
        CGFloat callX = NSMinX(card) + 244;
        CGFloat tokenX = NSMinX(card) + 414;
        [L(@"Calls this month") drawInRect:NSMakeRect(callX, NSMinY(card) + 114, 130, 20)
            withAttributes:[self textAttributesWithSize:13 color:secondary weight:NSFontWeightRegular]];
        [L(@"Tokens this month") drawInRect:NSMakeRect(tokenX, NSMinY(card) + 114, 130, 20)
            withAttributes:[self textAttributesWithSize:13 color:secondary weight:NSFontWeightRegular]];

        NSString *requests = [NSString stringWithFormat:L(@"%@ calls"),
            [self formattedRequestCount:monthTokens ?: @{}]];
        [requests drawInRect:NSMakeRect(callX, NSMinY(card) + 75, 142, 34)
            withAttributes:[self textAttributesWithSize:24 color:primary weight:NSFontWeightBold]];
        // 曲线铺满整个自然月，月末那些还没到的日子不能算进"已过天数"，否则日均会被稀释。
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        NSUInteger recordedDays = 0;
        for (NSDictionary *day in monthDaily) {
            if ([day[@"timestamp"] doubleValue] <= now) recordedDays += 1;
        }
        NSUInteger elapsedDays = MAX((NSUInteger)1, recordedDays);
        NSNumber *requestCount = [monthTokens[@"request_count"] isKindOfClass:NSNumber.class]
            ? monthTokens[@"request_count"] : nil;
        NSString *average = requestCount
            ? [NSString stringWithFormat:L(@"%@/day avg"),
                [NSNumberFormatter localizedStringFromNumber:
                    @(llround(requestCount.doubleValue / elapsedDays))
                    numberStyle:NSNumberFormatterDecimalStyle]]
            : L(@"--/day avg");
        [average drawInRect:NSMakeRect(callX, NSMinY(card) + 48, 142, 20)
            withAttributes:[self textAttributesWithSize:12 color:secondary weight:NSFontWeightRegular]];

        // 这里不再重复"本月消耗"的合计：输入与输出各自的量级才是按量计费时要看的东西，
        // 合计随时可以由这两个数得到，而它原先占掉了最显眼的一行。
        NSArray<NSDictionary *> *splits = @[
            @{@"label": L(@"Input"), @"value": [self formattedTokenSplit:monthTokens ?: @{}
                wantsOutput:NO], @"y": @(NSMinY(card) + 76)},
            @{@"label": L(@"Output"), @"value": [self formattedTokenSplit:monthTokens ?: @{}
                wantsOutput:YES], @"y": @(NSMinY(card) + 48)}
        ];
        for (NSDictionary *split in splits) {
            CGFloat y = [split[@"y"] doubleValue];
            [split[@"label"] drawInRect:NSMakeRect(tokenX, y + 4, 28, 16)
                withAttributes:[self textAttributesWithSize:11 color:secondary
                    weight:NSFontWeightRegular]];
            [split[@"value"] drawInRect:NSMakeRect(tokenX + 32, y, 110, 26)
                withAttributes:[self textAttributesWithSize:18 color:primary
                    weight:NSFontWeightBold]];
        }

        NSDictionary *requestComparison = [self comparisonForCurrent:
            [monthComparable[@"request_count"] doubleValue]
            previous:[previousMonthTokens[@"request_count"] doubleValue] color:color];
        [self drawText:requestComparison[@"text"] inRect:NSMakeRect(callX, NSMinY(card) + 22, 142, 18)
            size:11 weight:NSFontWeightMedium color:requestComparison[@"color"]
            dotColor:requestComparison[@"color"]];
        NSDictionary *tokenComparison = [self comparisonForCurrent:
            [monthComparable[@"total_tokens"] doubleValue]
            previous:[previousMonthTokens[@"total_tokens"] doubleValue] color:color];
        [self drawText:tokenComparison[@"text"] inRect:NSMakeRect(tokenX, NSMinY(card) + 22, 142, 18)
            size:11 weight:NSFontWeightMedium color:tokenComparison[@"color"]
            dotColor:tokenComparison[@"color"]];

        CGFloat trendX = NSMinX(card) + 574;
        // 今日用量和记录天数各占一行，峰值放进悬浮提示。
        [self drawText:L(@"Month") inRect:NSMakeRect(trendX, NSMinY(card) + 114, 145, 20)
            size:13 weight:NSFontWeightRegular color:secondary dotColor:nil];
        NSRect curveRect = NSMakeRect(trendX, NSMinY(card) + 66, 135, 34);
        [self drawMonthlyTokenCurve:monthDaily inRect:curveRect color:color];
        NSDictionary *todayTotals = nil;
        for (NSDictionary *day in monthDaily) {
            if ([day[@"timestamp"] doubleValue] > now) break;
            NSDictionary *totals = [day[@"totals"] isKindOfClass:NSDictionary.class]
                ? day[@"totals"] : nil;
            todayTotals = totals;
        }
        NSString *todayText = todayTotals
            ? [NSString stringWithFormat:L(@"Today %@"),
                [self formattedTokenValue:[todayTotals[@"total_tokens"] doubleValue]]] : L(@"Today --");
        [self drawText:todayText inRect:NSMakeRect(trendX, NSMinY(card) + 44, 145, 18)
            size:11 weight:NSFontWeightRegular color:secondary dotColor:nil];
        // 记录天数与左侧两列的月同比脚注保持相同基线和字号。
        NSString *recordedText = [NSString stringWithFormat:L(@"%lu / %lu days recorded"),
            (unsigned long)recordedDays, (unsigned long)monthDaily.count];
        [self drawText:recordedText inRect:NSMakeRect(trendX, NSMinY(card) + 22, 145, 18)
            size:11 weight:NSFontWeightMedium color:color dotColor:nil];
        [NSGraphicsContext restoreGraphicsState];
        return;
    }

    // 层级：官方剩余额度是订阅限额的权威值，占主位；本机 Token 是参考量，降一级并用
    // 强调色区分；重置时间最小。反过来会让最抢眼的数字恰好是最不该照着做决定的那个。
    NSArray<NSDictionary *> *windows = @[
        @{@"x": @(NSMinX(card) + 244), @"title": L(@"5h window"), @"quota": five ?: @{},
          @"tokens": fiveTokens ?: @{}, @"used": fiveUsed ?: NSNull.null,
          @"showDate": @NO, @"rolling": L(@"Waiting for refresh")},
        @{@"x": @(NSMinX(card) + 414), @"title": L(@"7d window"), @"quota": week ?: @{},
          @"tokens": weekTokens ?: @{}, @"used": weekUsed ?: NSNull.null,
          @"showDate": @YES, @"rolling": L(@"Waiting for refresh")}
    ];
    for (NSDictionary *window in windows) {
        CGFloat x = [window[@"x"] doubleValue];
        [window[@"title"] drawInRect:NSMakeRect(x, NSMinY(card) + 114, 130, 20)
            withAttributes:[self textAttributesWithSize:13 color:secondary weight:NSFontWeightRegular]];
        NSNumber *used = [window[@"used"] isKindOfClass:NSNumber.class] ? window[@"used"] : nil;
        double remaining = used ? 100.0 - used.doubleValue : 0;
        NSString *official = used ? [NSString stringWithFormat:@"%.0f%%", remaining] : @"--";
        // 百分比是"剩余"、Token 是"已用"，方向相反。后缀直接贴在数字右侧、
        // 前缀写进 Token 行，否则两个数字并排看会被当成同一口径。
        NSDictionary *valueAttributes = [self textAttributesWithSize:25
            color:exhausted ? NSColor.systemOrangeColor : primary
            weight:NSFontWeightBold];
        CGFloat valueWidth = ceil([official sizeWithAttributes:valueAttributes].width);
        [official drawInRect:NSMakeRect(x, NSMinY(card) + 74, valueWidth + 4, 34)
            withAttributes:valueAttributes];
        // 没有数字可标时不给口径标签："-- 剩余"看起来像一个真实的 0 值，而实际上是
        // 官方快照待刷新。下方的状态文字会说明它为何不可用。
        NSString *valueLabel = !used ? @"" : (exhausted ? L(@"Snapshot") : L(@"Left"));
        if (valueLabel.length > 0) {
            [valueLabel drawInRect:NSMakeRect(x + valueWidth + 7, NSMinY(card) + 78, 60, 20)
                withAttributes:[self textAttributesWithSize:12 color:secondary
                    weight:NSFontWeightRegular]];
        }
        // 官方窗口拿不到时（账号没有这个窗口、或响应里没带），Token 走的是本机滚动窗口。
        // 说清楚这一行的口径，比留一个 `--` 让人以为是渲染坏了要好。
        NSString *resetValue = [self resetText:window[@"quota"]
            showDate:[window[@"showDate"] boolValue]];
        NSString *reset = [resetValue isEqualToString:@"--"]
            ? window[@"rolling"] : [NSString stringWithFormat:L(@"Reset %@"), resetValue];
        [self drawText:reset inRect:NSMakeRect(x, NSMinY(card) + 46, 160, 18)
            size:11 weight:NSFontWeightRegular color:secondary dotColor:nil];
        // 两个主题统一使用紧凑文案；脚注里已说明 Token 即本机统计的已用量。
        NSString *tokenText = [NSString stringWithFormat:L(@"Used %@"),
            [self formattedTokenCount:window[@"tokens"]]];
        [self drawText:tokenText inRect:NSMakeRect(x, NSMinY(card) + 22, 142, 22) size:14
            weight:NSFontWeightSemibold color:color dotColor:color];
    }

    CGFloat trendX = NSMinX(card) + 574;
    // 与 API 卡同一套骨架：标题行带 pill、中间曲线、脚注和左边两列齐平。
    [L(@"Trend") drawInRect:NSMakeRect(trendX, NSMinY(card) + 114, 60, 20)
        withAttributes:[self textAttributesWithSize:13 color:secondary weight:NSFontWeightRegular]];
    NSString *profileID = [self selectedProfileForProvider:name][@"id"];
    NSArray<NSDictionary *> *history = profileID.length > 0 ? (self.profileHistories[profileID] ?: @[])
        : ([name isEqualToString:@"Codex"] ? self.codexHistory : self.claudeHistory);
    NSNumber *currentUsed = weekUsed;
    NSArray<NSDictionary *> *points = [self curvePointsFromHistory:history currentUsed:currentUsed];
    // 趋势这一列算的是 7 天窗口（currentUsed 取 weekUsed）。而 exhaustedAt 来自
    // rateLimitReachedType，没有窗口归属，实际撞墙的通常是 5 小时窗口——拿它一票否决
    // 整列，会出现左边 7 天窗口好好显示着 45% 剩余、右边却说"等待官方额度刷新"的自相
    // 矛盾。所以只有 7 天窗口自己确实没有百分比时才退回"待刷新"。
    BOOL weekUnknown = exhausted && currentUsed == nil;
    NSDictionary *pace = weekUnknown
        ? @{ @"label": L(@"Stale"), @"tip": L(@"Awaiting refresh"),
             @"color": NSColor.systemOrangeColor }
        : [self paceStatusForQuota:week currentUsed:currentUsed color:color];
    NSColor *paceColor = pace[@"color"];
    // 档位讲的是 7 天趋势，脚注讲的是此刻为什么发不出请求：受限但 7 天窗口尚有余量时
    // 两者都要说清，所以脚注单独取色，不跟着档位走。
    NSString *paceTip = pace[@"tip"];
    NSColor *tipColor = paceColor;
    if (exhausted && !weekUnknown) {
        paceTip = L(@"Limited until reset");
        tipColor = NSColor.systemOrangeColor;
    }
    if (self.usesLiquidGlass) {
        [self drawText:pace[@"label"] inRect:NSMakeRect(trendX + 62, NSMinY(card) + 114, 96, 20)
            size:11 weight:NSFontWeightSemibold color:paceColor dotColor:paceColor];
    } else {
        NSDictionary *pillAttributes = [self textAttributesWithSize:11 color:paceColor
            weight:NSFontWeightSemibold];
        // 档位标签跟在标题后面。宽度仍按文字算：四个档位不一样长，最宽的"数据不足"到
        // trendX + 131，列宽 145 放得下。
        CGFloat pillWidth = ceil([pace[@"label"] sizeWithAttributes:pillAttributes].width) + 18;
        NSRect pill = NSMakeRect(trendX + 59, NSMinY(card) + 113, pillWidth, 22);
        [self fillRoundedRect:pill radius:11 color:[paceColor colorWithAlphaComponent:0.14]];
        [pace[@"label"] drawInRect:NSInsetRect(pill, 9, 3) withAttributes:pillAttributes];
    }

    NSRect curveRect = NSMakeRect(trendX, NSMinY(card) + 62, 135, 38);
    [self drawUsageCurve:points inRect:curveRect color:color];
    double peak = 0;
    for (NSDictionary *point in points) peak = fmax(peak, [point[@"used"] doubleValue]);
    NSString *peakText = points.count > 0
        ? [NSString stringWithFormat:L(@"Max %.0f%%"), peak] : L(@"Max --");
    NSString *currentText = currentUsed
        ? [NSString stringWithFormat:L(@"Now %.0f%%"), currentUsed.doubleValue] : L(@"Now --");
    [peakText drawInRect:NSMakeRect(trendX, NSMinY(card) + 42 - 2 / QuotaScale, 72, 16)
        withAttributes:[self textAttributesWithSize:10 color:secondary weight:NSFontWeightRegular]];
    [currentText drawInRect:NSMakeRect(trendX + 66, NSMinY(card) + 42 - 2 / QuotaScale, 69, 16)
        withAttributes:[self rightAlignedTextAttributesWithSize:10 color:secondary
            weight:NSFontWeightRegular]];
    // 与左边两列的"已用 Token"同一条基线（+22），也和 API 卡的脚注行对齐。
    [self drawTip:paceTip inRect:NSMakeRect(trendX, NSMinY(card) + 22 - 2 / QuotaScale,
        145, 18) color:tipColor];
    [NSGraphicsContext restoreGraphicsState];
}
- (void)drawRect:(NSRect)dirtyRect {
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *scale = [NSAffineTransform transform];
    [scale scaleBy:QuotaScale];
    [scale concat];
    NSArray<NSString *> *visibleProviders = [self visibleProviders];
    const CGFloat height = [self logicalHeight];
    NSRect logicalBounds = NSMakeRect(0, 0, QuotaLogicalWidth, height);
    NSRect outer = NSInsetRect(logicalBounds, 1, 1);
    NSBezierPath *background = [NSBezierPath bezierPathWithRoundedRect:outer xRadius:24 yRadius:24];
    // 原生玻璃按 13pt 圆角裁切整个面板；底色也铺满到同一圆角，否则玻璃边缘和
    // 底色之间会露出一圈细缝。
    if (self.usesLiquidGlass) {
        CGFloat radius = 13 / QuotaScale;
        background = [NSBezierPath bezierPathWithRoundedRect:logicalBounds
            xRadius:radius yRadius:radius];
    }
    // 原生玻璃不铺底色：任何一层深色都会把 Clear 玻璃压回磨砂感。
    if (!self.usesLiquidGlass) {
        NSGradient *gradient = [[NSGradient alloc]
            initWithStartingColor:[NSColor colorWithRed:0.025 green:0.055 blue:0.095 alpha:0.88]
            endingColor:[NSColor colorWithRed:0.07 green:0.12 blue:0.19 alpha:0.80]];
        [gradient drawInBezierPath:background angle:-20];
    }

    // 原生玻璃自己绘制高光和边缘，不叠加经典主题的模拟反光。
    if (!self.usesLiquidGlass) {
        [NSGraphicsContext saveGraphicsState];
        [background addClip];
        NSGradient *topGlow = [[NSGradient alloc]
            initWithStartingColor:[NSColor colorWithWhite:1 alpha:0.34]
            endingColor:[NSColor colorWithWhite:1 alpha:0.0]];
        // 两处光晕原本是按 H=590 定的绝对点。面板会变矮，改成跟着高度走：顶部光源始终悬在
        // 面板上沿之外，冷色光晕落在内容区中段。
        NSPoint topGlowCenter = NSMakePoint(700, height + 60);
        [topGlow drawFromCenter:topGlowCenter radius:0
            toCenter:topGlowCenter radius:250 options:0];
        NSGradient *cyanGlow = [[NSGradient alloc]
            initWithStartingColor:[NSColor colorWithRed:0.18 green:0.72 blue:1 alpha:0.11]
            endingColor:[NSColor colorWithRed:0.18 green:0.88 blue:1 alpha:0.0]];
        NSPoint cyanGlowCenter = NSMakePoint(660, height * 0.42);
        [cyanGlow drawFromCenter:cyanGlowCenter radius:0
            toCenter:cyanGlowCenter radius:260 options:0];
        [NSGraphicsContext restoreGraphicsState];

        [[NSColor colorWithWhite:1 alpha:0.34] setStroke];
        background.lineWidth = 1.5;
        [background stroke];
        NSBezierPath *innerGlassBorder = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(outer, 2, 2)
            xRadius:22 yRadius:22];
        [[NSColor colorWithRed:0.58 green:0.82 blue:1 alpha:0.22] setStroke];
        innerGlassBorder.lineWidth = 0.8;
        [innerGlassBorder stroke];
    }
    // 玻璃底下可能是任意亮度的壁纸，除了玻璃背后的压暗层，再给白字加一层很淡的投影托底。
    if (self.usesLiquidGlass) {
        NSShadow *legibility = [NSShadow new];
        legibility.shadowColor = [NSColor colorWithWhite:0 alpha:0.4];
        legibility.shadowBlurRadius = 2;
        legibility.shadowOffset = NSMakeSize(0, -0.5);
        [legibility set];
    }
    NSColor *primary = self.primaryColor;
    NSColor *secondary = self.secondaryColor;
    NSColor *cyan = self.accentColor;
    NSColor *agentColor = self.agentStatusColor;
    [@"Agent Usage" drawInRect:NSMakeRect(28, height - 65, 260, 42)
        withAttributes:[self textAttributesWithSize:30 color:primary weight:NSFontWeightBold]];
    NSDictionary *liveStatusAttributes = [self textAttributesWithSize:14 color:secondary
        weight:NSFontWeightRegular];
    NSString *liveStatusText = L(@"Live status");
    [liveStatusText drawInRect:NSMakeRect(30, height - 94, 142, 22)
        withAttributes:liveStatusAttributes];
    CGFloat agentIndicatorX = 30 + [liveStatusText sizeWithAttributes:liveStatusAttributes].width + 12;
    [agentColor setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(agentIndicatorX, height - 88, 9, 9)] fill];
    NSString *agentText = self.activeAgentCount > 0
        ? [NSString stringWithFormat:self.activeAgentCount != 1 ? L(@"%ld Agents online")
            : L(@"%ld Agent online"), (long)self.activeAgentCount]
        : L(@"No Agents online");
    [agentText drawInRect:NSMakeRect(agentIndicatorX + 16, height - 95, 160, 22)
        withAttributes:[self textAttributesWithSize:14 color:agentColor weight:NSFontWeightMedium]];
    [self drawSystemMetricsEndingAtX:QuotaLogicalWidth - 28 y:height - 95];

    // 用量由定时器自动刷新，面板不再提供手动刷新按钮；右上角只留上次刷新的时间，
    // 与下一行的系统指标右边对齐。放回汇总条里会挤掉一整格 Provider 数据。
    [[NSString stringWithFormat:L(@"Updated %@"), [self refreshAgeText]]
        drawInRect:NSMakeRect(QuotaLogicalWidth - 28 - 200, height - 45, 200, 18)
        withAttributes:[self rightAlignedTextAttributesWithSize:11 color:secondary
            weight:NSFontWeightRegular]];

    if (visibleProviders.count > 0) {
        [self drawSummaryForProviders:visibleProviders primary:primary secondary:secondary
            accent:cyan];
    }
    NSDictionary *cardSpecs = @{
        @"Codex": @{@"usage": [self usageForProvider:@"Codex"], @"usedKey": @"used_percent",
                    @"color": cyan},
        @"Claude": @{@"usage": [self usageForProvider:@"Claude"], @"usedKey": @"used_percentage",
                     @"color": self.claudeColor}
    };
    // 卡片从汇总条下方依次向下排；原脚注空间按可见卡片数平分。这里的分段账必须和
    // QuotaLogicalHeightForProviderCount 完全一致，否则面板会多出或少掉一段空白。
    CGFloat cardTop = height - QuotaHeaderHeight - QuotaSummaryHeight;
    CGFloat cardHeight = QuotaCardHeightForProviderCount(visibleProviders.count);
    for (NSString *name in visibleProviders) {
        NSDictionary *spec = cardSpecs[name];
        cardTop -= QuotaBlockGap;
        NSArray<NSDictionary *> *profiles = [self profilesForProvider:name];
        NSRect cardRect = NSMakeRect(20, cardTop - cardHeight,
            QuotaLogicalWidth - 40, cardHeight);
        BOOL animating = [self.animatingCarouselProvider isEqualToString:name];
        if (animating) {
            NSTimeInterval elapsed = NSDate.date.timeIntervalSince1970 - self.carouselAnimationStartedAt;
            CGFloat progress = fmax(0, fmin(1, elapsed / 0.20));
            CGFloat eased = 1 - pow(1 - progress, 3);
            [NSGraphicsContext saveGraphicsState];
            [[NSBezierPath bezierPathWithRect:NSInsetRect(cardRect, -20, 0)] addClip];
            CGContextSetAlpha(NSGraphicsContext.currentContext.CGContext, 0.45 + 0.55 * eased);
            NSAffineTransform *transform = [NSAffineTransform transform];
            [transform translateXBy:self.carouselAnimationDirection * (1 - eased) * 48 yBy:0];
            [transform concat];
        }
        [self drawProvider:name displayName:[self displayNameForProvider:name]
            usage:spec[@"usage"] usedKey:spec[@"usedKey"] color:spec[@"color"]
            cardRect:cardRect
            profileCount:profiles.count selectedIndex:[self selectedIndexForProvider:name]];
        if (animating) [NSGraphicsContext restoreGraphicsState];
        cardTop -= cardHeight;
    }
    if (visibleProviders.count == 0) {
        // 官方 Home 自动发现；自定义 Home 必须由用户明确选择，不能扫描接管。
        CGFloat noticeTop = height - QuotaHeaderHeight;
        [L(@"No Agent accounts detected") drawInRect:NSMakeRect(28, noticeTop - 30, 460, 26)
            withAttributes:[self textAttributesWithSize:17 color:primary weight:NSFontWeightMedium]];
        [L(@"Official Homes appear automatically")
            drawInRect:NSMakeRect(28, noticeTop - 52, 560, 20)
            withAttributes:[self textAttributesWithSize:12 color:secondary weight:NSFontWeightRegular]];
        [L(@"Add custom Homes from Multi-Account in the Main menu")
            drawInRect:NSMakeRect(28, noticeTop - 72, 560, 18)
            withAttributes:[self textAttributesWithSize:11
                color:[NSColor colorWithWhite:0.52 alpha:1] weight:NSFontWeightRegular]];
    }
    [NSGraphicsContext restoreGraphicsState];
}

// 今日与最近 7 天都按 Provider 分开展示。底层本来就是两套独立的自然日统计，
// 不在展示层相加，避免用户无法判断 Token 来自 Codex 还是 Claude。
// 每格内是一张 2×2 表：标题独占一行，每个 Provider 独占一行；输入/输出标签放在
// 对应数值上方。这样既能完整展示 7 天统计起期，也不会挤乱两家的数据行。
- (void)drawSummaryForProviders:(NSArray<NSString *> *)providers primary:(NSColor *)primary
    secondary:(NSColor *)secondary accent:(NSColor *)cyan {
    NSRect summary = [self logicalSummaryRect];
    NSBezierPath *summaryPath = [NSBezierPath bezierPathWithRoundedRect:summary xRadius:18 yRadius:18];
    if (self.usesLiquidGlass) {
        [self fillLiquidScrim:summaryPath];
    } else {
        [[NSColor colorWithWhite:1 alpha:0.065] setFill];
        [summaryPath fill];
    }
    [[NSColor colorWithWhite:1 alpha:self.usesLiquidGlass ? 0.10 : 0.16] setStroke];
    [summaryPath stroke];

    NSArray<NSDictionary *> *cells = @[
        @{@"icon": @"◔", @"headerSymbol": @"calendar", @"key": @"today",
          @"label": L(@"Today")},
        @{@"icon": @"◉", @"headerSymbol": @"calendar.badge.clock", @"key": @"recentWeek",
          @"label": [self recentWeekUsageLabel]}
    ];
    BOOL hasMultipleAccounts = [self profilesForProvider:@"Codex"].count > 1 ||
        [self profilesForProvider:@"Claude"].count > 1;
    NSDictionary *rowSpecs = @{
        @"Codex": @{@"usage": [self summaryUsageForProvider:@"Codex"], @"color": cyan},
        @"Claude": @{@"usage": [self summaryUsageForProvider:@"Claude"],
                     @"color": self.claudeColor}
    };
    // 两行版的槽位是写死的。只装了一家时改用居中的单行槽位，否则汇总条会空出半格，
    // 看着像数据没加载出来。
    NSArray<NSDictionary *> *slots = providers.count == 1
        ? @[@{@"iconY": @24, @"nameY": @33, @"labelY": @49, @"valueY": @28}]
        : @[@{@"iconY": @43, @"nameY": @52, @"labelY": @68, @"valueY": @47},
            @{@"iconY": @5, @"nameY": @14, @"labelY": @30, @"valueY": @9}];
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (NSUInteger index = 0; index < providers.count && index < slots.count; index++) {
        NSMutableDictionary *row = [slots[index] mutableCopy];
        [row addEntriesFromDictionary:rowSpecs[providers[index]]];
        row[@"name"] = providers[index];
        [rows addObject:row];
    }

    [[NSColor colorWithWhite:1 alpha:0.10] setStroke];
    for (NSUInteger index = 1; index < cells.count; index++) {
        CGFloat x = NSMinX([self logicalSummaryCellRectAtIndex:index]);
        [NSBezierPath strokeLineFromPoint:NSMakePoint(x, NSMinY(summary) + 16)
            toPoint:NSMakePoint(x, NSMaxY(summary) - 16)];
    }
    for (NSUInteger index = 0; index < cells.count; index++) {
        NSDictionary *cell = cells[index];
        NSString *key = cell[@"key"];
        CGFloat x = NSMinX([self logicalSummaryCellRectAtIndex:index]);
        const CGFloat inputX = x + 176;
        const CGFloat outputX = x + 276;
        NSFont *headerFont = [self fontWithSize:11 weight:NSFontWeightRegular];
        NSDictionary *headerAttributes = @{NSFontAttributeName: headerFont,
            NSForegroundColorAttributeName: [self textColor:secondary]};
        NSDictionary *titleAttributes = @{NSFontAttributeName:
            [self fontWithSize:11 weight:NSFontWeightBold],
            NSForegroundColorAttributeName: [self textColor:secondary]};
        NSImage *headerIcon = [NSImage imageWithSystemSymbolName:cell[@"headerSymbol"]
            accessibilityDescription:cell[@"label"]];
        NSImageSymbolConfiguration *headerIconConfiguration =
            [NSImageSymbolConfiguration configurationWithPointSize:11
                weight:NSFontWeightRegular];
        headerIconConfiguration = [headerIconConfiguration configurationByApplyingConfiguration:
            [NSImageSymbolConfiguration configurationWithHierarchicalColor:secondary]];
        headerIcon = [headerIcon imageWithSymbolConfiguration:headerIconConfiguration];
        NSTextAttachment *headerAttachment = [NSTextAttachment new];
        headerAttachment.image = headerIcon;
        const CGFloat headerIconSize = 13;
        headerAttachment.bounds = NSMakeRect(0,
            (headerFont.capHeight - headerIconSize) / 2.0, headerIconSize, headerIconSize);
        NSMutableAttributedString *header = [[NSMutableAttributedString alloc]
            initWithAttributedString:[NSAttributedString
                attributedStringWithAttachment:headerAttachment]];
        [header appendAttributedString:[[NSAttributedString alloc]
            initWithString:@"  " attributes:headerAttributes]];
        [header appendAttributedString:[[NSAttributedString alloc]
            initWithString:cell[@"label"] attributes:titleAttributes]];
        [header drawInRect:NSMakeRect(x + 24, NSMinY(summary) + 89,
            NSWidth([self logicalSummaryCellRectAtIndex:index]) - 48, 18)];
        if (hasMultipleAccounts) {
            [L(@"All accounts") drawInRect:NSMakeRect(x + 230, NSMinY(summary) + 89, 120, 18)
                withAttributes:[self rightAlignedTextAttributesWithSize:10 color:secondary
                    weight:NSFontWeightRegular]];
        }
        for (NSDictionary *row in rows) {
            NSDictionary *usage = row[@"usage"];
            NSColor *rowColor = row[@"color"];
            CGFloat iconY = NSMinY(summary) + [row[@"iconY"] doubleValue];
            CGFloat nameY = NSMinY(summary) + [row[@"nameY"] doubleValue];
            CGFloat labelY = NSMinY(summary) + [row[@"labelY"] doubleValue];
            if (CCPetsLanguageIsSource()) labelY += 2 / QuotaScale;
            CGFloat valueY = NSMinY(summary) + [row[@"valueY"] doubleValue];
            // 这是图标字形不是文字，原生玻璃下也保留颜色：它负责标出这一行是哪一家。
            [cell[@"icon"] drawInRect:NSMakeRect(x + 20, iconY, 42, 42)
                withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:30
                    weight:NSFontWeightRegular], NSForegroundColorAttributeName: rowColor}];
            [row[@"name"] drawInRect:NSMakeRect(x + 66, nameY, 76, 22)
                withAttributes:[self textAttributesWithSize:14 color:rowColor
                    weight:NSFontWeightMedium]];
            [L(@"Input") drawInRect:NSMakeRect(inputX, labelY, 76, 16)
                withAttributes:headerAttributes];
            [L(@"Output") drawInRect:NSMakeRect(outputX, labelY, 76, 16)
                withAttributes:headerAttributes];
            NSDictionary *valueAttributes = [self textAttributesWithSize:16 color:primary
                weight:NSFontWeightBold];
            [[self formattedTokenSplitForUsage:usage key:key wantsOutput:NO]
                drawInRect:NSMakeRect(inputX, valueY, 86, 23) withAttributes:valueAttributes];
            [[self formattedTokenSplitForUsage:usage key:key wantsOutput:YES]
                drawInRect:NSMakeRect(outputX, valueY, 76, 23) withAttributes:valueAttributes];
        }
    }

}
@end
