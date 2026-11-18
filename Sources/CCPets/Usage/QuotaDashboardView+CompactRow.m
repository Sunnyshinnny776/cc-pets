#import "QuotaDashboardView+Private.h"

@implementation QuotaDashboardView (CompactRow)
- (void)drawCompactRowForProvider:(NSString *)name usage:(NSDictionary *)normalized rect:(NSRect)rect {
    CGFloat x = NSMinX(rect), mid = NSMidY(rect), right = NSMaxX(rect);
    NSRect row = NSMakeRect(x, mid - 22, NSWidth(rect), 44);
    NSColor *color = [self colorForProvider:name];
    NSBezierPath *background = [NSBezierPath bezierPathWithRoundedRect:row xRadius:10 yRadius:10];
    if (self.usesLiquidGlass) [self fillLiquidScrim:background];
    else [self fillRoundedRect:row radius:10 color:[NSColor colorWithWhite:1 alpha:0.075]];

    NSRect icon = NSMakeRect(x + 10, mid - 14, 28, 28);
    NSString *displayName = [self displayNameForProvider:name];
    NSImage *logo = self.logoByProvider[name];
    if (logo) {
        [NSGraphicsContext saveGraphicsState];
        [[NSBezierPath bezierPathWithRoundedRect:icon xRadius:7 yRadius:7] addClip];
        [logo drawInRect:icon fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        [NSGraphicsContext restoreGraphicsState];
    } else {
        [self fillRoundedRect:icon radius:7 color:color];
        NSString *initial = displayName.length
            ? [displayName substringWithRange:[displayName rangeOfComposedCharacterSequenceAtIndex:0]] : @"";
        [initial drawInRect:NSInsetRect(icon, 1, 4) withAttributes:
            [self centeredTextAttributesWithSize:15 color:NSColor.whiteColor weight:NSFontWeightBold]];
    }
    [self drawText:displayName inRect:NSMakeRect(x + 48, mid - 10, 116, 20)
        size:15 weight:NSFontWeightSemibold color:self.primaryColor dotColor:nil];
    NSDictionary *state = [self accountStateForProvider:name profile:[self selectedProfileForProvider:name] normalized:normalized];
    NSColor *statusColor = [self statusColorForState:state];
    NSString *status = [state[@"status"] stringByReplacingOccurrencesOfString:@"● " withString:@""];
    if (!self.usesLiquidGlass) {
        CGFloat width = [status sizeWithAttributes:[self textAttributesWithSize:12 color:statusColor
            weight:NSFontWeightMedium]].width + 24;
        [self fillRoundedRect:NSMakeRect(x + 168, mid - 10, width, 20)
            radius:10 color:[statusColor colorWithAlphaComponent:0.13]];
    }
    [statusColor setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x + 174, mid - 3, 6, 6)] fill];
    [self drawText:status inRect:NSMakeRect(x + 185, mid - 9, 126, 18)
        size:12 weight:NSFontWeightMedium color:statusColor dotColor:nil];

    NSDictionary *tokens = normalized[@"tokens"];
    NSString *today = [self formattedTokenCount:[self quota:tokens key:@"today"]];
    [self drawText:[NSString stringWithFormat:L(@"Today %@"), today] inRect:NSMakeRect(x + 316, mid - 9, 134, 18)
        size:13 weight:NSFontWeightMedium color:self.secondaryColor dotColor:nil];

    NSString *billing = normalized[@"billing"];
    NSRect metric = NSMakeRect(x + 456, mid - 9, right - (x + 456) - 32, 18);
    if ([billing isEqualToString:@"subscription"]) {
        NSDictionary *tightest = nil;
        for (NSDictionary *window in normalized[@"windows"]) {
            NSNumber *used = window[@"used"];
            if (used && (!tightest || used.doubleValue > [tightest[@"used"] doubleValue])) tightest = window;
        }
        if (tightest) {
            double remaining = 100 - [tightest[@"used"] doubleValue];
            [self drawText:L(tightest[@"titleKey"]) inRect:NSMakeRect(NSMinX(metric), mid - 9, 96, 18)
                size:12 weight:NSFontWeightMedium color:self.secondaryColor dotColor:nil];
            NSRect bar = NSMakeRect(NSMinX(metric) + 102, mid - 3, 48, 6);
            [self fillRoundedRect:bar radius:3 color:[color colorWithAlphaComponent:0.2]];
            bar.size.width *= remaining / 100;
            if (bar.size.width > 0) [self fillRoundedRect:bar radius:3 color:color];
            metric.origin.x += 156;
            metric.size.width -= 156;
            [self drawText:[NSString stringWithFormat:@"%.0f%%", remaining] inRect:metric
                size:13 weight:NSFontWeightSemibold color:self.primaryColor dotColor:nil];
        } else {
            [self drawText:@"--" inRect:metric size:13 weight:NSFontWeightMedium color:self.secondaryColor dotColor:nil];
        }
    } else {
        NSString *text = L(@"No quota data");
        NSString *month = [self formattedTokenCount:[self quota:tokens key:@"month"]];
        if ([billing isEqualToString:@"api"]) text = [NSString stringWithFormat:L(@"API · This month %@"), month];
        if ([billing isEqualToString:@"credits"]) text = [NSString stringWithFormat:L(@"Credits · This month %@"), month];
        [self drawText:text inRect:metric size:13 weight:NSFontWeightMedium color:self.primaryColor dotColor:nil];
    }
    [self drawText:@"›" inRect:NSMakeRect(right - 21, mid - 12, 14, 24)
        size:18 weight:NSFontWeightMedium color:self.secondaryColor dotColor:nil];
}
@end
