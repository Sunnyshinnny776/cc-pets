#import "CCPetsDiagnosticsPage.h"
#import "CCPetsDoctor.h"
#import "CCPetsCLISupport.h"
#import "CCPetsFormBuilder.h"
#import "CCPetsL10n.h"
#import "CCPetsUIStyle.h"
#import <objc/runtime.h>

static void CopyToPasteboard(NSString *text) {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
}

#pragma mark - 结果缓存

NSNotificationName const CCPetsDiagnosticsDidChangeNotification = @"CCPetsDiagnosticsDidChange";
static NSArray<NSDictionary *> *DiagnosticsSections;
static NSDate *DiagnosticsCheckedAt;
static BOOL DiagnosticsRunning;
static BOOL DiagnosticsRepairing;
static NSString *DiagnosticsRepairMessage;
static const NSTimeInterval DiagnosticsFreshness = 600;

@implementation CCPetsDiagnosticsStore

+ (NSArray<NSDictionary *> *)sections {
    return DiagnosticsSections;
}

+ (BOOL)running {
    return DiagnosticsRunning;
}

+ (BOOL)repairing { return DiagnosticsRepairing; }
+ (NSString *)repairMessage { return DiagnosticsRepairMessage; }

+ (NSDate *)checkedAt {
    return DiagnosticsCheckedAt;
}

+ (NSUInteger)issueCount {
    NSUInteger count = 0;
    for (NSDictionary *section in DiagnosticsSections) {
        for (NSDictionary *result in section[@"results"]) {
            if ([result[@"level"] isEqualToString:@"warn"] || [result[@"level"] isEqualToString:@"fail"]) count++;
        }
    }
    return count;
}

+ (void)refreshIfStale {
    if (DiagnosticsSections && -DiagnosticsCheckedAt.timeIntervalSinceNow < DiagnosticsFreshness) return;
    [self refresh];
}

+ (void)refresh {
    if (DiagnosticsRunning) return;
    DiagnosticsRunning = YES;
    [NSNotificationCenter.defaultCenter postNotificationName:CCPetsDiagnosticsDidChangeNotification object:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSDictionary *> *sections = CCPetsDoctorSectionsForApp();
        dispatch_async(dispatch_get_main_queue(), ^{
            DiagnosticsSections = sections;
            DiagnosticsCheckedAt = NSDate.date;
            DiagnosticsRunning = NO;
            [NSNotificationCenter.defaultCenter postNotificationName:CCPetsDiagnosticsDidChangeNotification object:nil];
        });
    });
}

+ (void)repairIssues:(NSArray<NSDictionary *> *)issues {
    if (DiagnosticsRunning) return;
    NSMutableOrderedSet<NSString *> *profileIDs = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *issue in issues) {
        NSString *profileID = issue[@"repairProfileID"];
        if ([profileID isKindOfClass:NSString.class] && profileID.length > 0) [profileIDs addObject:profileID];
    }
    if (profileIDs.count == 0) return;
    DiagnosticsRunning = YES;
    DiagnosticsRepairing = YES;
    DiagnosticsRepairMessage = nil;
    [NSNotificationCenter.defaultCenter postNotificationName:CCPetsDiagnosticsDidChangeNotification object:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSString *> *details = [NSMutableArray array];
        BOOL failed = NO;
        for (NSString *profileID in profileIDs) {
            NSString *output = nil, *errorOutput = nil;
            int status = CCPetsRun(CCPetsExecutablePath(), @[@"doctor", @"--repair-profile", profileID],
                nil, nil, 60, &output, &errorOutput);
            if (status != 0) {
                failed = YES;
                NSString *reason = status == CCPetsRunTimedOut ? L(@"The repair timed out.")
                    : (status == CCPetsRunLaunchFailed ? L(@"The repair command could not be started.") : nil);
                if (reason) [details addObject:reason];
                if (errorOutput.length > 0) [details addObject:errorOutput];
                if (output.length > 0) [details addObject:output];
            } else {
                for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
                    // 安装器的详细输出只在失败时显示，成功保留备份位置。
                    if ([line hasPrefix:[NSString stringWithFormat:L(@"Configuration backup: %@"), @""]]) {
                        [details addObject:line];
                    }
                }
            }
        }
        NSArray<NSDictionary *> *sections = CCPetsDoctorSectionsForApp();
        BOOL unresolved = NO;
        for (NSDictionary *section in sections) {
            for (NSDictionary *result in section[@"results"]) {
                if (result[@"repairProfileID"] && [profileIDs containsObject:result[@"repairProfileID"]] &&
                    ([@[@"fail", @"warn"] containsObject:result[@"level"]])) unresolved = YES;
            }
        }
        NSString *summary = failed ? L(@"Some repairs failed. See the details below or copy the command to retry in a terminal.")
            : (unresolved ? L(@"Repair finished, but some issues still need attention. The checks have been refreshed.")
                : L(@"Repair completed. The checks have been refreshed."));
        NSString *message = [[@[summary] arrayByAddingObjectsFromArray:details] componentsJoinedByString:@"\n"];
        dispatch_async(dispatch_get_main_queue(), ^{
            DiagnosticsSections = sections;
            DiagnosticsCheckedAt = NSDate.date;
            DiagnosticsRepairMessage = message;
            DiagnosticsRepairing = NO;
            DiagnosticsRunning = NO;
            [NSNotificationCenter.defaultCenter postNotificationName:CCPetsDiagnosticsDidChangeNotification object:nil];
        });
    });
}

@end

#pragma mark - 页面

// 控件的 target 只能是对象，用它把 action 转成 block。
@interface CCPetsDiagnosticsHandler : NSObject
@property(nonatomic, copy) void (^block)(id sender);
- (void)invoke:(id)sender;
@end

@implementation CCPetsDiagnosticsHandler
- (void)invoke:(id)sender {
    if (self.block) self.block(sender);
}
@end

@interface CCPetsDiagnosticsPage ()
@property(nonatomic) CCPetsFormBuilder *form;
@property(nonatomic) NSProgressIndicator *spinner;
@property(nonatomic) NSButton *recheckButton;
@property(nonatomic) NSButton *reportButton;
@property(nonatomic) NSButton *repairAllButton;
// 正常项默认折叠；展开状态跨重新检查保留。
@property(nonatomic) BOOL showsPassed;
@end

@implementation CCPetsDiagnosticsPage

- (NSButton *)buttonWithTitle:(NSString *)title action:(void (^)(NSButton *sender))action {
    NSButton *button = [NSButton buttonWithTitle:title target:nil action:nil];
    button.controlSize = NSControlSizeSmall;
    button.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    CCPetsDiagnosticsHandler *handler = [CCPetsDiagnosticsHandler new];
    handler.block = ^(id sender) { action(sender); };
    button.target = handler;
    button.action = @selector(invoke:);
    static char HandlerKey;
    objc_setAssociatedObject(button, &HandlerKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return button;
}

- (void)loadView {
    self.form = [[CCPetsFormBuilder alloc] initWithTitle:L(@"Diagnostics") subtitle:L(@"Checking…")];

    NSProgressIndicator *spinner = [NSProgressIndicator new];
    spinner.style = NSProgressIndicatorStyleSpinning;
    spinner.controlSize = NSControlSizeSmall;
    spinner.displayedWhenStopped = NO;
    self.spinner = spinner;
    __weak typeof(self) weakSelf = self;
    self.reportButton = [self buttonWithTitle:L(@"Copy Report") action:^(NSButton *sender) { [weakSelf copyReport:sender]; }];
    self.recheckButton = [self buttonWithTitle:L(@"Re-check") action:^(NSButton *sender) {
        [CCPetsDiagnosticsStore refresh];
    }];
    self.repairAllButton = [self buttonWithTitle:L(@"Fix All") action:^(NSButton *sender) {
        NSArray *issues = [[weakSelf resultsWithLevels:@[@"fail"]]
            arrayByAddingObjectsFromArray:[weakSelf resultsWithLevels:@[@"warn"]]];
        [CCPetsDiagnosticsStore repairIssues:issues];
    }];
    [self.form setAccessoryViews:@[spinner, self.reportButton, self.recheckButton, self.repairAllButton]];
    self.view = self.form.view;

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(storeDidChange:)
        name:CCPetsDiagnosticsDidChangeNotification object:nil];
    [self render];
    [CCPetsDiagnosticsStore refreshIfStale];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)storeDidChange:(NSNotification *)notification {
    [self render];
}

- (NSArray<NSDictionary *> *)resultsWithLevels:(NSArray<NSString *> *)levels {
    NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
    for (NSDictionary *section in CCPetsDiagnosticsStore.sections) {
        for (NSDictionary *result in section[@"results"]) {
            if (![levels containsObject:result[@"level"]]) continue;
            NSMutableDictionary *entry = [result mutableCopy];
            entry[@"area"] = section[@"title"];
            [matches addObject:entry];
        }
    }
    return matches;
}

- (void)render {
    BOOL running = CCPetsDiagnosticsStore.running;
    if (running) [self.spinner startAnimation:nil];
    else [self.spinner stopAnimation:nil];
    self.recheckButton.enabled = !running;
    NSArray<NSDictionary *> *sections = CCPetsDiagnosticsStore.sections;
    self.reportButton.enabled = sections.count > 0;
    [self.form removeAllContent];
    self.repairAllButton.hidden = YES;
    if (!sections) {
        self.form.subtitleLabel.stringValue = L(@"Checking…");
        return;
    }

    // 失败排在警告前面：失败是"现在就不工作"，警告是"可能出问题"。
    NSArray<NSDictionary *> *issues = [[self resultsWithLevels:@[@"fail"]]
        arrayByAddingObjectsFromArray:[self resultsWithLevels:@[@"warn"]]];
    NSArray<NSDictionary *> *passed = [self resultsWithLevels:@[@"ok"]];
    NSArray<NSDictionary *> *notes = [self resultsWithLevels:@[@"info"]];
    BOOL repairable = NO;
    for (NSDictionary *issue in issues) if (issue[@"repairProfileID"]) repairable = YES;
    self.repairAllButton.hidden = !repairable && !CCPetsDiagnosticsStore.repairing;
    self.repairAllButton.enabled = repairable && !running;
    self.repairAllButton.title = CCPetsDiagnosticsStore.repairing ? L(@"Repairing…") : L(@"Fix All");
    NSUInteger total = issues.count + passed.count + notes.count;
    NSString *checked = running ? (CCPetsDiagnosticsStore.repairing ? L(@"Repairing…") : L(@"Checking…"))
        : [NSString stringWithFormat:L(@"Last checked %@"),
        [NSDateFormatter localizedStringFromDate:CCPetsDiagnosticsStore.checkedAt
            dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle]];
    self.form.subtitleLabel.stringValue = [NSString stringWithFormat:L(@"%1$@ · %2$lu checks"), checked,
        (unsigned long)total];

    [self.form addView:[self healthBannerForIssues:issues]];
    if (CCPetsDiagnosticsStore.repairMessage.length > 0) {
        NSTextField *message = [self.form addFootnote:CCPetsDiagnosticsStore.repairMessage];
        message.selectable = YES;
    }
    for (NSDictionary *issue in issues) [self.form addView:[self issueCard:issue]];
    if (passed.count > 0) [self.form addView:[self passedCard:passed]];
    for (NSDictionary *note in notes) {
        [self.form addFootnote:[NSString stringWithFormat:L(@"Note: %@"), note[@"title"]]];
    }
}

// 顶部一句话结论：有几项要处理、怎么修。
- (NSView *)healthBannerForIssues:(NSArray<NSDictionary *> *)issues {
    BOOL failing = NO;
    for (NSDictionary *issue in issues) if ([issue[@"level"] isEqualToString:@"fail"]) failing = YES;
    CCPetsStatusKind kind = issues.count == 0 ? CCPetsStatusOK : (failing ? CCPetsStatusError : CCPetsStatusWarn);
    NSString *symbol = issues.count == 0 ? @"checkmark" : (failing ? @"xmark" : @"exclamationmark");
    NSImageView *icon = [NSImageView imageViewWithImage:[[NSImage imageWithSystemSymbolName:symbol
        accessibilityDescription:nil] imageWithSymbolConfiguration:[NSImageSymbolConfiguration
        configurationWithPointSize:15 weight:NSFontWeightBold]] ?: [NSImage new]];
    icon.contentTintColor = CCPetsStatusColor(kind);
    CCPetsColorDot *badge = [[CCPetsColorDot alloc] initWithColor:CCPetsStatusBackgroundColor(kind) diameter:38];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [badge addSubview:icon];
    [NSLayoutConstraint activateConstraints:@[
        [icon.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
    ]];

    NSString *title = issues.count == 0 ? L(@"Everything looks good")
        : (issues.count == 1 ? L(@"1 item needs attention")
            : [NSString stringWithFormat:L(@"%lu items need attention"), (unsigned long)issues.count]);
    NSString *detail = issues.count == 0 ? L(@"Hooks, the status line and the command line tools are all in place.")
        : L(@"Auto-fix backs up your configuration and repairs registered Agent Hooks and the Claude status line. For other issues, copy the command and run it in a terminal.");
    NSTextField *titleLabel = CCPetsLabel(title, 15, NSFontWeightBold, CCPetsInkColor());
    NSTextField *detailLabel = CCPetsWrappingLabel(detail, 12, NSFontWeightRegular, CCPetsSecondaryInkColor());
    NSStackView *texts = [NSStackView stackViewWithViews:@[titleLabel, detailLabel]];
    texts.orientation = NSUserInterfaceLayoutOrientationVertical;
    texts.alignment = NSLayoutAttributeLeading;
    texts.spacing = 3;

    CCPetsCardView *card = [CCPetsCardView new];
    for (NSView *view in @[badge, texts]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [badge.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [badge.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [texts.leadingAnchor constraintEqualToAnchor:badge.trailingAnchor constant:14],
        [texts.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [texts.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [texts.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
        [card.heightAnchor constraintGreaterThanOrEqualToConstant:66],
    ]];
    return card;
}

// 一条问题：左侧级别色条，所属模块，标题，修复命令 + 复制。
- (NSView *)issueCard:(NSDictionary *)issue {
    BOOL failing = [issue[@"level"] isEqualToString:@"fail"];
    CCPetsCardView *card = [CCPetsCardView new];
    card.stripeColor = CCPetsStatusColor(failing ? CCPetsStatusError : CCPetsStatusWarn);
    NSTextField *area = CCPetsLabel(issue[@"area"], 11, NSFontWeightRegular, CCPetsTertiaryInkColor());
    NSTextField *title = CCPetsWrappingLabel(issue[@"title"], 13, NSFontWeightSemibold, CCPetsInkColor());
    title.selectable = YES;
    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObjects:area, title, nil];

    NSString *fix = issue[@"fix"];
    if (fix.length > 0) {
        NSTextField *command = CCPetsLabel(fix, 11, NSFontWeightRegular, CCPetsInkColor());
        command.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
        command.selectable = YES;
        command.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [command setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
            forOrientation:NSLayoutConstraintOrientationHorizontal];
        CCPetsCardView *code = [CCPetsCardView new];
        code.cornerRadius = 6;
        code.fillColor = CCPetsBackgroundColor();
        command.translatesAutoresizingMaskIntoConstraints = NO;
        [code addSubview:command];
        __weak typeof(self) weakSelf = self;
        NSButton *copy = [self buttonWithTitle:L(@"Copy Command") action:^(NSButton *sender) {
            CopyToPasteboard(fix);
            [weakSelf flashCopied:sender original:L(@"Copy Command")];
        }];
        [copy setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSMutableArray<NSView *> *actions = [NSMutableArray arrayWithObjects:code, copy, nil];
        if (issue[@"repairProfileID"]) {
            NSButton *repair = [self buttonWithTitle:L(@"Auto-fix") action:^(NSButton *sender) {
                [CCPetsDiagnosticsStore repairIssues:@[issue]];
            }];
            repair.enabled = !CCPetsDiagnosticsStore.running;
            [repair setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
            [repair setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
            [actions addObject:repair];
        }
        NSStackView *line = [NSStackView stackViewWithViews:actions];
        line.spacing = 8;
        line.alignment = NSLayoutAttributeCenterY;
        [NSLayoutConstraint activateConstraints:@[
            [command.leadingAnchor constraintEqualToAnchor:code.leadingAnchor constant:8],
            [command.trailingAnchor constraintEqualToAnchor:code.trailingAnchor constant:-8],
            [command.topAnchor constraintEqualToAnchor:code.topAnchor constant:5],
            [command.bottomAnchor constraintEqualToAnchor:code.bottomAnchor constant:-5],
        ]];
        [views addObject:line];
    }
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 4;
    [stack setCustomSpacing:8 afterView:title];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:11],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
        [title.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    ]];
    if (views.count > 2) [views.lastObject.widthAnchor constraintLessThanOrEqualToAnchor:stack.widthAnchor].active = YES;
    [stack setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationVertical];
    return card;
}

// 正常项折叠成一行"✓ 11 项正常"，点开看清单。
- (NSView *)passedCard:(NSArray<NSDictionary *> *)passed {
    __weak typeof(self) weakSelf = self;
    NSButton *toggle = [self buttonWithTitle:@"" action:^(NSButton *sender) {
        weakSelf.showsPassed = !weakSelf.showsPassed;
        [weakSelf render];
    }];
    toggle.bordered = NO;
    toggle.imagePosition = NSImageLeft;
    toggle.image = [NSImage imageWithSystemSymbolName:self.showsPassed ? @"chevron.down" : @"chevron.right"
        accessibilityDescription:nil];
    toggle.contentTintColor = CCPetsTertiaryInkColor();
    toggle.attributedTitle = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"  %@",
        passed.count == 1 ? L(@"1 check passed") : [NSString stringWithFormat:L(@"%lu checks passed"),
            (unsigned long)passed.count]] attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: CCPetsStatusColor(CCPetsStatusOK)}];
    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObject:toggle];
    if (self.showsPassed) {
        for (NSDictionary *result in passed) {
            NSTextField *line = CCPetsWrappingLabel([NSString stringWithFormat:@"%@ · %@", result[@"area"],
                result[@"title"]], 12, NSFontWeightRegular, CCPetsSecondaryInkColor());
            line.selectable = YES;
            [views addObject:line];
        }
    }
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    CCPetsCardView *card = [CCPetsCardView new];
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:10],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-10],
    ]];
    for (NSView *view in views) {
        if (view != toggle) [view.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor constant:22].active = YES;
        if (view != toggle) [view.trailingAnchor constraintLessThanOrEqualToAnchor:stack.trailingAnchor].active = YES;
    }
    return card;
}

// 点了之后按钮上短暂显示"已复制"，不用再弹别的提示。
- (void)flashCopied:(NSButton *)button original:(NSString *)original {
    button.title = L(@"Copied");
    __weak NSButton *weakButton = button;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        weakButton.title = original;
    });
}

- (void)copyReport:(NSButton *)sender {
    NSArray<NSDictionary *> *sections = CCPetsDiagnosticsStore.sections;
    if (sections.count == 0) return;
    CopyToPasteboard(CCPetsDoctorReport(sections));
    [self flashCopied:sender original:L(@"Copy Report")];
}

@end
