#import "CCPetsWorkbenchPages.h"
#import "CCPetsDiagnosticsPage.h"
#import "CCPetsFormBuilder.h"
#import "CCPetsL10n.h"
#import "CCPetsMainWindow.h"
#import "CCPetsUIStyle.h"
#import "CCPetsUsagePage.h"
#import "CCPetsWorkbench.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static id<CCPetsWorkbenchSource> WorkbenchSource(void) {
    id delegate = NSApp.delegate;
    return [delegate respondsToSelector:@selector(workbenchSessions)] ? delegate : nil;
}

static NSDictionary *PetCardSnapshot(void) {
    id delegate = NSApp.delegate;
    return [delegate conformsToProtocol:@protocol(CCPetsPetCardSource)] ? [delegate petCardSnapshot] : nil;
}

static NSString *RelativeTime(NSTimeInterval timestamp) {
    NSTimeInterval age = fmax(0, NSDate.date.timeIntervalSince1970 - timestamp);
    if (age < 5) return L(@"just now");
    if (age < 60) return [NSString stringWithFormat:L(@"%.0fs ago"), age];
    if (age < 3600) return [NSString stringWithFormat:L(@"%.0fm ago"), floor(age / 60)];
    return [NSString stringWithFormat:L(@"%.0fh ago"), floor(age / 3600)];
}

// 控件的 target 只能是对象，用它把 action 转成 block。
@interface CCPetsWorkbenchHandler : NSObject
@property(nonatomic, copy) void (^block)(id sender);
- (void)invoke:(id)sender;
@end

@implementation CCPetsWorkbenchHandler
- (void)invoke:(id)sender {
    if (self.block) self.block(sender);
}
@end

// 带 block 的小按钮。handler 挂在按钮上（关联对象），按钮释放时一起释放。
static NSButton *ActionButton(NSString *title, BOOL prominent, void (^action)(void)) {
    NSButton *button = [NSButton buttonWithTitle:title target:nil action:nil];
    button.controlSize = NSControlSizeSmall;
    button.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:prominent ? NSFontWeightSemibold
        : NSFontWeightRegular];
    if (prominent) button.bezelColor = CCPetsAccentColor();
    CCPetsWorkbenchHandler *handler = [CCPetsWorkbenchHandler new];
    handler.block = ^(id sender) { action(); };
    button.target = handler;
    button.action = @selector(invoke:);
    static char HandlerKey;
    objc_setAssociatedObject(button, &HandlerKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [button setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [button setContentCompressionResistancePriority:NSLayoutPriorityRequired
        forOrientation:NSLayoutConstraintOrientationHorizontal];
    return button;
}

#pragma mark - 部件

// 环形进度：底轨 + 剩余量的弧，从 12 点钟方向顺时针。
@interface CCPetsRingView : NSView
@property(nonatomic) double fraction;
@property(nonatomic) NSColor *color;
@end

@implementation CCPetsRingView
- (NSSize)intrinsicContentSize {
    return NSMakeSize(44, 44);
}
- (void)drawRect:(NSRect)dirtyRect {
    NSRect box = NSInsetRect(self.bounds, 3, 3);
    NSPoint center = NSMakePoint(NSMidX(box), NSMidY(box));
    CGFloat radius = NSWidth(box) / 2;
    NSBezierPath *track = [NSBezierPath bezierPathWithOvalInRect:box];
    track.lineWidth = 5;
    [CCPetsRingTrackColor() set];
    [track stroke];
    double fraction = MIN(1, MAX(0, self.fraction));
    if (fraction <= 0) return;
    NSBezierPath *arc = [NSBezierPath bezierPath];
    [arc appendBezierPathWithArcWithCenter:center radius:radius startAngle:90 endAngle:90 - 360 * fraction clockwise:YES];
    arc.lineWidth = 5;
    arc.lineCapStyle = NSLineCapStyleRound;
    [self.color set];
    [arc stroke];
}
@end

// 概览的宠物卡：底色从卡片色淡淡过渡到强调青，宠物站在左边。
@interface CCPetsHeroCard : CCPetsCardView
@end

@interface CCPetsHeroCard ()
@property(nonatomic) CAGradientLayer *gradient;
@end

@implementation CCPetsHeroCard
- (void)updateLayer {
    [super updateLayer];
    if (!self.gradient) {
        self.gradient = [CAGradientLayer layer];
        self.gradient.startPoint = CGPointMake(0, 0.5);
        self.gradient.endPoint = CGPointMake(1, 0.5);
        [self.layer insertSublayer:self.gradient atIndex:0];
    }
    self.gradient.frame = self.layer.bounds;
    self.gradient.colors = @[(id)CCPetsSelectionColor().CGColor, (id)CCPetsCardColor().CGColor];
}
- (void)layout {
    [super layout];
    self.needsDisplay = YES;
}
@end

#pragma mark - 概览

@interface CCPetsOverviewPage ()
@property(nonatomic) CCPetsFormBuilder *form;
@end

@implementation CCPetsOverviewPage

- (void)loadView {
    self.form = [[CCPetsFormBuilder alloc] initWithTitle:L(@"Overview") subtitle:[self dateText]];
    self.view = self.form.view;
    for (NSNotificationName name in @[CCPetsPetCardDidChangeNotification, CCPetsUsageStoreDidChangeNotification,
                                      CCPetsDiagnosticsDidChangeNotification]) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(dataDidChange:) name:name object:nil];
    }
    [self render];
    [CCPetsUsageStore loadIfStale];
    [CCPetsDiagnosticsStore refreshIfStale];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (NSString *)dateText {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:CCPetsCurrentLanguage()];
    [formatter setLocalizedDateFormatFromTemplate:@"EEEEMMMMd"];
    return [formatter stringFromDate:NSDate.date];
}

// 名片通知一条 Agent 事件会来好几次，合并到下一轮 runloop 只重排一次。
- (void)dataDidChange:(NSNotification *)notification {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(render) object:nil];
    [self performSelector:@selector(render) withObject:nil afterDelay:0];
}

- (void)render {
    [self.form removeAllContent];
    [self.form addView:[self heroCard]];
    NSView *notice = [self diagnosticsNotice];
    if (notice) [self.form addView:notice];
    NSView *quotas = [self quotaCards];
    if (quotas) [self.form addView:quotas];
}

#pragma mark 宠物卡

// 今天的用量：取 90 天数据的最后一天（就是今天），两家相加。
- (NSArray<NSArray<NSString *> *> *)todayStats {
    NSDictionary *results = CCPetsUsageStore.results;
    if (!results) {
        NSString *waiting = L(@"Reading…");
        return @[@[L(@"Total today"), @"–", waiting],
                 @[L(@"Input"), @"–", @""],
                 @[L(@"Output"), @"–", @""],
                 @[L(@"Cached Input"), @"–", @""],
                 @[L(@"Requests"), @"–", @""]];
    }
    NSMutableArray<NSDictionary *> *days = [NSMutableArray array];
    NSMutableSet<NSString *> *models = [NSMutableSet set];
    for (NSString *provider in results) {
        NSDictionary *today = [results[provider][@"daily"] lastObject];
        [days addObject:CCPetsUsageDayTotals(today)];
        for (NSString *model in today[@"models"]) {
            if ([today[@"models"][model][@"requests"] unsignedLongLongValue] > 0) {
                [models addObject:[provider stringByAppendingString:model]];
            }
        }
    }
    return CCPetsUsageMetricItems(L(@"Total today"), CCPetsUsageSum(days), models.count);
}

static const CGFloat HeroExtraPadding = 15;

- (NSView *)heroCard {
    NSDictionary *snapshot = PetCardSnapshot();
    NSString *state = snapshot[@"state"] ?: @"idle";
    CCPetsHeroCard *card = [CCPetsHeroCard new];

    CCPetsSpriteView *sprite = [[CCPetsSpriteView alloc] initWithFrame:NSZeroRect];
    [sprite setSheet:snapshot[@"sheet"] rowCount:[snapshot[@"rowCount"] integerValue] ?: 9];
    sprite.state = state;
    // 脚下一团淡影，宠物不会像贴在卡片上。
    CCPetsColorDot *floor = [[CCPetsColorDot alloc] initWithColor:CCPetsHoverColor() diameter:8];
    [floor removeConstraints:floor.constraints];
    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObjects:floor, sprite, nil];

    // 宠物此刻在说的那句（状态卡副行），没有 Agent 在跑时不显示。
    NSString *line = snapshot[@"detail"];
    NSView *bubble = nil;
    if (line.length > 0) {
        NSTextField *text = CCPetsLabel(line, 11, NSFontWeightMedium, CCPetsCardColor());
        CCPetsCardView *pill = [CCPetsCardView new];
        pill.cornerRadius = 9;
        pill.fillColor = CCPetsInkColor();
        text.translatesAutoresizingMaskIntoConstraints = NO;
        [pill addSubview:text];
        [NSLayoutConstraint activateConstraints:@[
            [text.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:10],
            [text.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-10],
            [text.topAnchor constraintEqualToAnchor:pill.topAnchor constant:4],
            [text.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-4],
            [pill.widthAnchor constraintLessThanOrEqualToConstant:220],
        ]];
        bubble = pill;
        [views addObject:pill];
    }

    NSTextField *name = CCPetsLabel(snapshot[@"name"] ?: @"CC Pets", 17, NSFontWeightBold, CCPetsInkColor());
    CCPetsChipView *chip = [[CCPetsChipView alloc] initWithText:snapshot[@"status"] ?: L(@"Idle")
        kind:CCPetsStatusKindForAgentState(state)];
    NSStackView *nameLine = [NSStackView stackViewWithViews:@[name, chip]];
    nameLine.spacing = 8;
    nameLine.alignment = NSLayoutAttributeCenterY;
    NSView *statRow = CCPetsMetricRow([self todayStats]);
    NSStackView *side = [NSStackView stackViewWithViews:@[nameLine, statRow]];
    side.orientation = NSUserInterfaceLayoutOrientationVertical;
    side.alignment = NSLayoutAttributeLeading;
    // 数字这一排和名字之间 22pt；整组居中点同时下移一半，名字不动，只有数字往下 8pt。
    side.spacing = 22;
    [views addObject:side];

    for (NSView *view in views) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:view];
    }
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        // 素材格子是 140×150，按同样比例放大一些当主角。
        [sprite.widthAnchor constraintEqualToConstant:122],
        [sprite.heightAnchor constraintEqualToConstant:131],
        [sprite.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:32],
        // 卡片上下各留 15pt 余量（比内容高 30pt），宠物和数字在卡片里居中，不显得挤。
        [sprite.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18 - HeroExtraPadding],
        [floor.centerXAnchor constraintEqualToAnchor:sprite.centerXAnchor],
        [floor.centerYAnchor constraintEqualToAnchor:sprite.bottomAnchor constant:-2],
        [floor.widthAnchor constraintEqualToConstant:84],
        [floor.heightAnchor constraintEqualToConstant:10],
        [side.leadingAnchor constraintEqualToAnchor:sprite.trailingAnchor constant:32],
        [side.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-24],
        [statRow.widthAnchor constraintEqualToAnchor:side.widthAnchor],
        [side.centerYAnchor constraintEqualToAnchor:card.centerYAnchor constant:4],
    ]];
    if (bubble) {
        [constraints addObjectsFromArray:@[
            [bubble.topAnchor constraintEqualToAnchor:card.topAnchor constant:16 + HeroExtraPadding],
            [bubble.centerXAnchor constraintEqualToAnchor:sprite.centerXAnchor constant:10],
            [bubble.leadingAnchor constraintGreaterThanOrEqualToAnchor:card.leadingAnchor constant:12],
            [sprite.topAnchor constraintEqualToAnchor:bubble.bottomAnchor constant:4],
        ]];
    } else {
        [constraints addObject:[sprite.topAnchor constraintEqualToAnchor:card.topAnchor constant:22 + HeroExtraPadding]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
    return card;
}

#pragma mark 诊断提醒

- (NSView *)diagnosticsNotice {
    NSUInteger count = CCPetsDiagnosticsStore.issueCount;
    if (count == 0) return nil;
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (NSDictionary *section in CCPetsDiagnosticsStore.sections) {
        for (NSDictionary *result in section[@"results"]) {
            if ([result[@"level"] isEqualToString:@"warn"] || [result[@"level"] isEqualToString:@"fail"]) {
                [titles addObject:result[@"title"]];
            }
        }
    }
    CCPetsCardView *card = [CCPetsCardView new];
    card.stripeColor = CCPetsStatusColor(CCPetsStatusWarn);
    NSTextField *title = CCPetsLabel(count == 1 ? L(@"Diagnostics found 1 item to fix")
        : [NSString stringWithFormat:L(@"Diagnostics found %lu items to fix"), (unsigned long)count],
        13, NSFontWeightSemibold, CCPetsInkColor());
    NSTextField *detail = CCPetsLabel([[titles subarrayWithRange:NSMakeRange(0, MIN(2, titles.count))]
        componentsJoinedByString:L(@"; ")], 11, NSFontWeightRegular, CCPetsSecondaryInkColor());
    [detail setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
        forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSButton *open = ActionButton(L(@"View"), NO, ^{
        [CCPetsMainWindowController presentPage:CCPetsMainWindowPageDiagnostics];
    });
    for (NSView *view in @[title, detail, open]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:10],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:open.leadingAnchor constant:-12],
        [detail.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [detail.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
        [detail.trailingAnchor constraintLessThanOrEqualToAnchor:open.leadingAnchor constant:-12],
        [detail.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-10],
        [open.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [open.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
    ]];
    return card;
}

#pragma mark 额度

- (NSString *)resetText:(NSNumber *)reset {
    if (!reset) return L(@"Waiting for data");
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:reset.doubleValue];
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:CCPetsCurrentLanguage()];
    // 一天之内只写钟点，再远就带上星期几。
    [formatter setLocalizedDateFormatFromTemplate:reset.doubleValue - NSDate.date.timeIntervalSince1970 < 86400
        ? @"HH:mm" : @"EEEHH:mm"];
    return [NSString stringWithFormat:L(@"Resets %@"), [formatter stringFromDate:date]];
}

- (NSView *)ringWithRemaining:(NSNumber *)remaining title:(NSString *)title reset:(NSNumber *)reset {
    CCPetsRingView *ring = [CCPetsRingView new];
    double value = remaining.doubleValue;
    ring.fraction = remaining ? value / 100 : 0;
    // 剩两成以下换提醒色，和面板里"需关注"的门槛同一个意思。
    ring.color = remaining && value < 20 ? CCPetsStatusColor(CCPetsStatusWarn) : CCPetsAccentColor();
    ring.translatesAutoresizingMaskIntoConstraints = NO;
    [ring.widthAnchor constraintEqualToConstant:44].active = YES;
    [ring.heightAnchor constraintEqualToConstant:44].active = YES;
    NSTextField *percent = CCPetsNumberLabel(remaining ? [NSString stringWithFormat:@"%.0f%%", value] : @"–",
        17, NSFontWeightBold, CCPetsInkColor());
    NSTextField *label = CCPetsLabel(title, 11, NSFontWeightRegular, CCPetsSecondaryInkColor());
    NSTextField *resetLabel = CCPetsLabel([self resetText:reset], 11, NSFontWeightRegular, CCPetsTertiaryInkColor());
    NSStackView *texts = [NSStackView stackViewWithViews:@[percent, label, resetLabel]];
    texts.orientation = NSUserInterfaceLayoutOrientationVertical;
    texts.alignment = NSLayoutAttributeLeading;
    texts.spacing = 0;
    NSStackView *block = [NSStackView stackViewWithViews:@[ring, texts]];
    block.spacing = 10;
    block.alignment = NSLayoutAttributeCenterY;
    return block;
}

- (NSView *)quotaCards {
    NSArray<NSDictionary *> *quotas = [WorkbenchSource() workbenchQuotas];
    if (quotas.count == 0) return nil;
    NSMutableArray<NSView *> *cards = [NSMutableArray array];
    for (NSDictionary *quota in quotas) {
        CCPetsCardView *card = [CCPetsCardView new];
        CCPetsColorDot *dot = [[CCPetsColorDot alloc] initWithColor:CCPetsProviderColor(quota[@"provider"]) diameter:8];
        dot.layer.cornerRadius = 2;
        NSString *quotaName = [quota[@"profileName"] isKindOfClass:NSString.class]
            ? quota[@"profileName"] : quota[@"provider"];
        NSTextField *name = CCPetsLabel(quotaName, 13, NSFontWeightSemibold, CCPetsInkColor());
        NSStackView *title = [NSStackView stackViewWithViews:@[dot, name]];
        title.spacing = 7;
        title.alignment = NSLayoutAttributeCenterY;
        NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObject:title];
        CCPetsChipView *pace = nil;
        if ([quota[@"pace"] length] > 0 && quota[@"paceLevel"]) {
            NSInteger level = [quota[@"paceLevel"] integerValue];
            CCPetsStatusKind kind = level >= 3 ? CCPetsStatusError : (level == 2 ? CCPetsStatusWarn
                : (level == 0 ? CCPetsStatusOK : CCPetsStatusIdle));
            pace = [[CCPetsChipView alloc] initWithText:quota[@"pace"] kind:kind];
            pace.hidesDot = YES;
            [views addObject:pace];
        }
        NSView *five = [self ringWithRemaining:quota[@"fiveRemaining"] title:L(@"5-hour left") reset:quota[@"fiveReset"]];
        NSView *week = [self ringWithRemaining:quota[@"weekRemaining"] title:L(@"Weekly left") reset:quota[@"weekReset"]];
        NSStackView *rings = [NSStackView stackViewWithViews:@[five, week]];
        rings.distribution = NSStackViewDistributionFillEqually;
        rings.alignment = NSLayoutAttributeCenterY;
        rings.spacing = 12;
        [views addObject:rings];
        for (NSView *view in views) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [card addSubview:view];
        }
        NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
            [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
            [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
            [rings.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
            [rings.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
            [rings.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
            [rings.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
        ]];
        if (pace) {
            [constraints addObjectsFromArray:@[
                [pace.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
                [pace.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
            ]];
        }
        [NSLayoutConstraint activateConstraints:constraints];
        [cards addObject:card];
    }
    // 只有一家时也占半行，卡片宽度和两家时一样，不会被拉成一长条。
    if (cards.count == 1) [cards addObject:[NSView new]];
    NSStackView *row = [NSStackView stackViewWithViews:cards];
    row.distribution = NSStackViewDistributionFillEqually;
    row.alignment = NSLayoutAttributeTop;
    row.spacing = 12;
    return row;
}

@end

#pragma mark - 会话

// 会话表的列宽：状态胶囊、最近活动、按钮固定，会话名和当前在做平分剩下的。
static const CGFloat SessionStateWidth = 92, SessionTimeWidth = 72, SessionActionWidth = 82;

@interface CCPetsSessionsPage ()
@property(nonatomic) CCPetsFormBuilder *form;
@property(nonatomic) NSTimer *timer;
// 上一次渲染用的数据和相对时间。走表时没变就不重排，免得按钮在鼠标底下被换掉。
@property(nonatomic) NSArray *renderedState;
@end

@implementation CCPetsSessionsPage

- (void)loadView {
    self.form = [[CCPetsFormBuilder alloc] initWithTitle:L(@"Sessions") subtitle:@""];
    self.view = self.form.view;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(dataDidChange:)
        name:CCPetsPetCardDidChangeNotification object:nil];
    [self render];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    [WorkbenchSource() markWorkbenchMessagesSeen];
    [self.timer invalidate];
    // 最近活动的"几分钟前"和 Bridge 消息要走表才会更新；会话状态本身有通知，不靠它。
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *timer) {
        CCPetsSessionsPage *page = weakSelf;
        if (!page.view.window.isVisible || page.view.window.isMiniaturized) return;
        [page render];
    }];
    self.timer.tolerance = 1;
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [self.timer invalidate];
    self.timer = nil;
}

- (void)dealloc {
    [_timer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)dataDidChange:(NSNotification *)notification {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(render) object:nil];
    [self performSelector:@selector(render) withObject:nil afterDelay:0];
}

- (void)render {
    id<CCPetsWorkbenchSource> source = WorkbenchSource();
    NSArray<NSDictionary *> *sessions = [source workbenchSessions] ?: @[];
    NSDictionary *messages = [source workbenchMessages] ?: @{};
    NSArray *deliveries = messages[@"deliveries"] ?: @[];
    NSArray *pending = messages[@"pending"] ?: @[];
    NSMutableArray<NSString *> *times = [NSMutableArray array];
    for (NSDictionary *session in sessions) [times addObject:RelativeTime([session[@"updatedAt"] doubleValue])];
    NSArray *state = @[sessions, messages, times];
    if ([state isEqual:self.renderedState]) return;
    self.renderedState = state;
    NSUInteger waiting = 0;
    for (NSDictionary *entry in pending) waiting += [entry[@"count"] unsignedIntegerValue];
    NSMutableArray<NSString *> *summary = [NSMutableArray arrayWithObject:sessions.count == 1
        ? L(@"1 session online") : [NSString stringWithFormat:L(@"%ld sessions online"), (long)sessions.count]];
    if ([messages[@"enabled"] boolValue]) {
        [summary addObject:[NSString stringWithFormat:L(@"%lu CC Bridge messages recently"), (unsigned long)deliveries.count]];
    }
    self.form.subtitleLabel.stringValue = [summary componentsJoinedByString:@" · "];

    NSPoint scroll = self.form.scrollView.contentView.bounds.origin;
    [self.form removeAllContent];
    [self.form addView:[self sessionsTable:sessions]];
    [self.form addGroupTitle:@"CC Bridge" note:waiting > 0 ? [NSString stringWithFormat:L(@"%lu waiting in an inbox"),
        (unsigned long)waiting] : nil info:L(@"Only message exchanges are displayed")];
    [self.form addView:[self messagesCard:messages]];
    // 定时重排不要把用户滚到一半的位置弹回顶部。
    [self.form.scrollView.documentView layoutSubtreeIfNeeded];
    [self.form.scrollView.contentView scrollToPoint:scroll];
    [self.form.scrollView reflectScrolledClipView:self.form.scrollView.contentView];
}

#pragma mark 会话表

- (NSView *)cardWithRows:(NSArray<NSView *> *)rows {
    NSStackView *stack = [NSStackView stackViewWithViews:@[]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *row in rows) {
        if (stack.arrangedSubviews.count > 0) {
            NSView *rule = [CCPetsFormBuilder separator];
            [stack addArrangedSubview:rule];
            [rule.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
        }
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [stack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    }
    CCPetsCardView *card = [CCPetsCardView new];
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];
    return card;
}

// 五列：状态、会话、当前在做、最近活动、操作。cells 里 nil 的位置用空视图占位。
- (NSView *)sessionRowWithCells:(NSArray<NSView *> *)cells height:(CGFloat)height {
    NSView *row = [NSView new];
    for (NSView *cell in cells) {
        cell.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:cell];
        [cell.centerYAnchor constraintEqualToAnchor:row.centerYAnchor].active = YES;
    }
    NSView *state = cells[0], *name = cells[1], *doing = cells[2], *time = cells[3], *action = cells[4];
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:height],
        [state.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [name.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14 + SessionStateWidth + 12],
        [doing.leadingAnchor constraintEqualToAnchor:name.trailingAnchor constant:12],
        [doing.widthAnchor constraintEqualToAnchor:name.widthAnchor multiplier:1.15],
        [time.leadingAnchor constraintEqualToAnchor:doing.trailingAnchor constant:12],
        [time.widthAnchor constraintEqualToConstant:SessionTimeWidth],
        [action.leadingAnchor constraintEqualToAnchor:time.trailingAnchor constant:12],
        [action.widthAnchor constraintEqualToConstant:SessionActionWidth],
        [action.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
    ]];
    [state.trailingAnchor constraintLessThanOrEqualToAnchor:name.leadingAnchor constant:-8].active = YES;
    return row;
}

- (NSView *)sessionsTable:(NSArray<NSDictionary *> *)sessions {
    NSMutableArray<NSView *> *headerCells = [NSMutableArray array];
    for (NSString *title in @[L(@"Status"), L(@"Session"), L(@"Doing"), L(@"Last Active"), @""]) {
        NSTextField *label = CCPetsLabel(title, 11, NSFontWeightSemibold, CCPetsTertiaryInkColor());
        [headerCells addObject:label];
    }
    ((NSTextField *)headerCells[3]).alignment = NSTextAlignmentRight;
    NSMutableArray<NSView *> *rows = [NSMutableArray arrayWithObject:[self sessionRowWithCells:headerCells height:30]];
    if (sessions.count == 0) {
        NSTextField *empty = CCPetsLabel(L(@"No sessions online."), 12, NSFontWeightRegular, CCPetsTertiaryInkColor());
        NSView *row = [NSView new];
        empty.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:empty];
        [NSLayoutConstraint activateConstraints:@[
            [empty.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
            [empty.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [row.heightAnchor constraintEqualToConstant:52],
        ]];
        [rows addObject:row];
    }
    for (NSDictionary *session in sessions) {
        NSString *state = session[@"state"];
        BOOL approval = [state isEqualToString:@"approval"];
        CCPetsChipView *chip = [[CCPetsChipView alloc] initWithText:session[@"status"]
            kind:CCPetsStatusKindForAgentState(state)];
        [chip.widthAnchor constraintLessThanOrEqualToConstant:SessionStateWidth].active = YES;

        NSString *title = [session[@"name"] length] > 0 ? session[@"name"] : session[@"provider"];
        NSTextField *name = CCPetsLabel(title, 13, NSFontWeightSemibold, CCPetsInkColor());
        NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:session[@"provider"]];
        if ([session[@"terminal"] length] > 0) [parts addObject:session[@"terminal"]];
        NSUInteger mail = [session[@"pendingMessages"] unsignedIntegerValue];
        if (mail > 0) [parts addObject:[NSString stringWithFormat:L(@"%lu waiting"), (unsigned long)mail]];
        NSTextField *detail = CCPetsLabel([parts componentsJoinedByString:@" · "], 11, NSFontWeightRegular,
            CCPetsTertiaryInkColor());
        NSStackView *nameCell = [NSStackView stackViewWithViews:@[name, detail]];
        nameCell.orientation = NSUserInterfaceLayoutOrientationVertical;
        nameCell.alignment = NSLayoutAttributeLeading;
        nameCell.spacing = 1;
        for (NSView *view in @[name, detail, nameCell]) {
            [view setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                forOrientation:NSLayoutConstraintOrientationHorizontal];
        }

        NSString *tool = session[@"tool"];
        NSTextField *doing = CCPetsLabel(tool.length > 0 ? tool : @"–", 12, NSFontWeightRegular,
            tool.length > 0 ? CCPetsInkColor() : CCPetsTertiaryInkColor());
        if (tool.length > 0) doing.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
        [doing setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
            forOrientation:NSLayoutConstraintOrientationHorizontal];

        NSTextField *time = CCPetsNumberLabel(RelativeTime([session[@"updatedAt"] doubleValue]), 12,
            NSFontWeightRegular, approval ? CCPetsStatusColor(CCPetsStatusWarn) : CCPetsSecondaryInkColor());
        time.alignment = NSTextAlignmentRight;

        NSString *sessionID = session[@"id"];
        NSButton *jump = ActionButton(L(@"Go to Terminal"), approval, ^{
            [WorkbenchSource() focusWorkbenchSessionWithID:sessionID];
        });
        NSView *actionCell = [NSView new];
        jump.translatesAutoresizingMaskIntoConstraints = NO;
        [actionCell addSubview:jump];
        [NSLayoutConstraint activateConstraints:@[
            [jump.trailingAnchor constraintEqualToAnchor:actionCell.trailingAnchor],
            [jump.centerYAnchor constraintEqualToAnchor:actionCell.centerYAnchor],
            [actionCell.heightAnchor constraintEqualToAnchor:jump.heightAnchor],
        ]];
        [rows addObject:[self sessionRowWithCells:@[chip, nameCell, doing, time, actionCell] height:50]];
    }
    return [self cardWithRows:rows];
}

#pragma mark 消息

- (NSView *)messageRowWithLeading:(NSView *)leading title:(NSView *)title detail:(NSView *)detail
    trailing:(NSArray<NSView *> *)trailing {
    NSView *row = [NSView new];
    NSStackView *right = [NSStackView stackViewWithViews:trailing];
    right.spacing = 8;
    right.alignment = NSLayoutAttributeCenterY;
    [right setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [right setContentCompressionResistancePriority:NSLayoutPriorityRequired
        forOrientation:NSLayoutConstraintOrientationHorizontal];
    for (NSView *view in @[leading, title, detail, right]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:view];
        [view.centerYAnchor constraintEqualToAnchor:row.centerYAnchor].active = YES;
    }
    [title setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [detail setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
        forOrientation:NSLayoutConstraintOrientationHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:40],
        [leading.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [leading.widthAnchor constraintEqualToConstant:44],
        [title.leadingAnchor constraintEqualToAnchor:leading.trailingAnchor constant:8],
        [title.widthAnchor constraintLessThanOrEqualToConstant:320],
        [detail.leadingAnchor constraintEqualToAnchor:title.trailingAnchor constant:12],
        [detail.trailingAnchor constraintLessThanOrEqualToAnchor:right.leadingAnchor constant:-12],
        [right.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
    ]];
    return row;
}

// 发件人 → 收件人，名字加粗，箭头淡一些。
- (NSTextField *)routeFrom:(NSString *)from to:(NSString *)to {
    NSMutableAttributedString *text = [NSMutableAttributedString new];
    NSDictionary *strong = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],
                             NSForegroundColorAttributeName: CCPetsInkColor()};
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:from ?: @"" attributes:strong]];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"  →  " attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:12], NSForegroundColorAttributeName: CCPetsTertiaryInkColor()}]];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:to ?: @"" attributes:strong]];
    // 富文本标签默认会折行；这里一律单行，名字太长就在末尾省略，不把"→ 收件人"挤到第二行。
    // 抗压缩优先级比右边的说明高：位置不够时先让说明让位。
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    [text addAttribute:NSParagraphStyleAttributeName value:paragraph range:NSMakeRange(0, text.length)];
    NSTextField *label = [NSTextField labelWithAttributedString:text];
    label.usesSingleLineMode = YES;
    label.cell.wraps = NO;
    label.maximumNumberOfLines = 1;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh
        forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

- (NSView *)messagesCard:(NSDictionary *)messages {
    NSMutableArray<NSView *> *rows = [NSMutableArray array];
    if (![messages[@"enabled"] boolValue]) {
        NSView *row = [CCPetsFormBuilder rowWithTitle:L(@"CC Bridge is off")
            subtitle:L(@"Turn it on from the pet's right-click menu to let sessions message each other.") controls:@[]];
        return [self cardWithRows:@[row]];
    }
    for (NSDictionary *entry in messages[@"pending"]) {
        NSString *session = entry[@"session"];
        NSUInteger count = [entry[@"count"] unsignedIntegerValue];
        NSTextField *icon = CCPetsLabel(@"", 12, NSFontWeightRegular, CCPetsTertiaryInkColor());
        NSTextField *name = CCPetsLabel(entry[@"name"], 12, NSFontWeightSemibold, CCPetsInkColor());
        NSTextField *detail = CCPetsLabel(count == 1 ? L(@"1 message waiting. Say anything in that terminal to deliver it.")
            : [NSString stringWithFormat:L(@"%lu messages waiting. Say anything in that terminal to deliver them."),
                (unsigned long)count], 12, NSFontWeightRegular, CCPetsSecondaryInkColor());
        CCPetsChipView *chip = [[CCPetsChipView alloc] initWithText:L(@"Waiting") kind:CCPetsStatusWarn];
        NSButton *jump = ActionButton(L(@"Go to Terminal"), YES, ^{
            [WorkbenchSource() focusBridgeSessionWithID:session];
        });
        [rows addObject:[self messageRowWithLeading:icon title:name detail:detail trailing:@[chip, jump]]];
    }
    NSArray *deliveries = messages[@"deliveries"];
    for (NSDictionary *delivery in deliveries) {
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:[delivery[@"at"] doubleValue]];
        NSTextField *time = CCPetsNumberLabel([NSDateFormatter localizedStringFromDate:date
            dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle], 12, NSFontWeightRegular,
            CCPetsTertiaryInkColor());
        NSTextField *route = [self routeFrom:delivery[@"from"] to:delivery[@"to"]];
        NSTextField *detail = CCPetsLabel(@"", 12, NSFontWeightRegular, CCPetsSecondaryInkColor());
        BOOL unseen = [delivery[@"unseen"] boolValue];
        CCPetsChipView *chip = [[CCPetsChipView alloc] initWithText:unseen ? L(@"Unread") : L(@"Delivered")
            kind:unseen ? CCPetsStatusWork : CCPetsStatusOK];
        NSString *session = delivery[@"toSession"];
        NSButton *jump = ActionButton(L(@"Go to Terminal"), NO, ^{
            [WorkbenchSource() focusBridgeSessionWithID:session];
        });
        jump.toolTip = [NSString stringWithFormat:L(@"Jump to %@'s terminal"), delivery[@"to"]];
        [rows addObject:[self messageRowWithLeading:time title:route detail:detail trailing:@[chip, jump]]];
    }
    if (rows.count == 0) {
        [rows addObject:[CCPetsFormBuilder rowWithTitle:L(@"No messages recently") controls:@[]]];
    }
    return [self cardWithRows:rows];
}

@end
