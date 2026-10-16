#import "CCPetsDiagnosticsPage.h"
#import "CCPetsCLISupport.h"
#import "CCPetsDoctor.h"
#import "CCPetsFormBuilder.h"
#import "CCPetsL10n.h"
#import "CCPetsUIStyle.h"

static void CopyToPasteboard(NSString *text) {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
}

// 级别对应的图标和颜色。
static NSString *LevelSymbol(NSString *level) {
    NSDictionary *symbols = @{@"ok": @"checkmark.circle.fill", @"warn": @"exclamationmark.triangle.fill",
                              @"fail": @"xmark.octagon.fill", @"info": @"info.circle"};
    return symbols[level] ?: symbols[@"info"];
}

static NSColor *LevelColor(NSString *level) {
    if ([level isEqualToString:@"ok"]) return NSColor.systemGreenColor;
    if ([level isEqualToString:@"warn"]) return NSColor.systemOrangeColor;
    if ([level isEqualToString:@"fail"]) return NSColor.systemRedColor;
    return NSColor.systemGrayColor;
}

// 一组里最严重的级别，决定分组标题的图标。
static NSString *WorstLevel(NSArray<NSDictionary *> *results) {
    NSString *worst = @"info";
    for (NSDictionary *result in results) {
        NSString *level = result[@"level"];
        if ([level isEqualToString:@"fail"]) return @"fail";
        if ([level isEqualToString:@"warn"]) worst = @"warn";
        else if ([level isEqualToString:@"ok"] && ![worst isEqualToString:@"warn"]) worst = @"ok";
    }
    return worst;
}

static NSString *SectionSymbol(NSString *level) {
    NSDictionary *symbols = @{@"ok": @"checkmark", @"warn": @"exclamationmark", @"fail": @"xmark", @"info": @"info"};
    return symbols[level];
}

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
@property(nonatomic) NSTextField *summaryLabel;
@property(nonatomic) NSProgressIndicator *spinner;
@property(nonatomic) NSButton *recheckButton;
@property(nonatomic) NSButton *reportButton;
@property(nonatomic) NSMutableArray<CCPetsDiagnosticsHandler *> *handlers;
@property(nonatomic) NSArray<NSDictionary *> *sections;
// 每次检查加一；晚到的旧结果（连点重新检查、页面已换掉）靠它丢弃。
@property(nonatomic) NSUInteger generation;
@end

@implementation CCPetsDiagnosticsPage

- (NSButton *)buttonWithTitle:(NSString *)title action:(void (^)(NSButton *sender))action {
    NSButton *button = [NSButton buttonWithTitle:title target:nil action:nil];
    button.controlSize = NSControlSizeSmall;
    CCPetsDiagnosticsHandler *handler = [CCPetsDiagnosticsHandler new];
    handler.block = ^(id sender) { action(sender); };
    [self.handlers addObject:handler];
    button.target = handler;
    button.action = @selector(invoke:);
    return button;
}

- (void)loadView {
    self.handlers = [NSMutableArray array];
    self.form = [CCPetsFormBuilder new];

    self.summaryLabel = [NSTextField labelWithString:L(@"Checking…")];
    self.summaryLabel.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightMedium];
    self.summaryLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.summaryLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
        forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSProgressIndicator *spinner = [NSProgressIndicator new];
    spinner.style = NSProgressIndicatorStyleSpinning;
    spinner.controlSize = NSControlSizeSmall;
    spinner.displayedWhenStopped = NO;
    self.spinner = spinner;

    __weak typeof(self) weakSelf = self;
    self.recheckButton = [self buttonWithTitle:L(@"Re-check") action:^(NSButton *sender) { [weakSelf runChecks]; }];
    self.reportButton = [self buttonWithTitle:L(@"Copy Report") action:^(NSButton *sender) {
        [weakSelf copyReport:sender];
    }];

    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *header = [NSStackView stackViewWithViews:
        @[self.summaryLabel, spacer, spinner, self.recheckButton, self.reportButton]];
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.alignment = NSLayoutAttributeCenterY;
    header.spacing = 8;
    header.edgeInsets = NSEdgeInsetsMake(14, 28, 10, 28);
    header.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 560)];
    NSScrollView *scroll = self.form.scrollView;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:header];
    [root addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:root.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];
    self.view = root;
    [self runChecks];
}

- (void)dealloc {
    // 已经在跑的检查取消不了，但页面没了就没人接结果；generation 变了回调会直接丢弃。
    self.generation++;
}

- (void)runChecks {
    NSUInteger generation = ++self.generation;
    [self.spinner startAnimation:nil];
    self.recheckButton.enabled = NO;
    self.reportButton.enabled = NO;
    self.summaryLabel.stringValue = L(@"Checking…");
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSDictionary *> *sections = CCPetsDoctorSections();
        dispatch_async(dispatch_get_main_queue(), ^{
            CCPetsDiagnosticsPage *page = weakSelf;
            if (!page || page.generation != generation) return;
            [page showSections:sections];
        });
    });
}

- (NSUInteger)countOfLevel:(NSString *)level {
    NSUInteger count = 0;
    for (NSDictionary *section in self.sections) {
        for (NSDictionary *result in section[@"results"]) {
            if ([result[@"level"] isEqualToString:level]) count++;
        }
    }
    return count;
}

- (void)showSections:(NSArray<NSDictionary *> *)sections {
    self.sections = sections;
    [self.spinner stopAnimation:nil];
    self.recheckButton.enabled = YES;
    self.reportButton.enabled = YES;

    NSUInteger warn = [self countOfLevel:@"warn"], fail = [self countOfLevel:@"fail"];
    self.summaryLabel.stringValue = [@[
        CCPetsInterpolate(L(@"{count} OK"), @{@"count": @([self countOfLevel:@"ok"])}),
        CCPetsInterpolate(warn == 1 ? L(@"{count} warning") : L(@"{count} warnings"), @{@"count": @(warn)}),
        CCPetsInterpolate(fail == 1 ? L(@"{count} error") : L(@"{count} errors"), @{@"count": @(fail)}),
    ] componentsJoinedByString:@" · "];

    [self.form removeAllSections];
    for (NSUInteger index = 0; index < sections.count; index++) {
        NSDictionary *section = sections[index];
        NSMutableArray<NSView *> *rows = [NSMutableArray array];
        for (NSDictionary *result in section[@"results"]) [rows addObject:[self rowForResult:result]];
        NSString *worst = WorstLevel(section[@"results"]);
        [self.form addSectionWithID:[NSString stringWithFormat:@"%lu", (unsigned long)index]
            title:section[@"title"] symbol:SectionSymbol(worst) color:LevelColor(worst) rows:rows footer:nil];
    }
    [self.form scrollToSectionWithID:nil];
}

// 级别图标 + 标题（可换行、可选中复制）；有修复建议时下面一行显示命令，右侧放"复制命令"。
- (NSView *)rowForResult:(NSDictionary *)result {
    NSString *level = result[@"level"];
    NSImageView *icon = [NSImageView imageViewWithImage:
        [NSImage imageWithSystemSymbolName:LevelSymbol(level) accessibilityDescription:level] ?: [NSImage new]];
    icon.contentTintColor = LevelColor(level);
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [icon.widthAnchor constraintEqualToConstant:18].active = YES;
    [icon.heightAnchor constraintEqualToConstant:18].active = YES;

    NSTextField *title = [NSTextField wrappingLabelWithString:result[@"title"]];
    title.selectable = YES;
    [title setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
        forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSMutableArray<NSView *> *texts = [NSMutableArray arrayWithObject:title];

    NSString *fix = result[@"fix"];
    if (fix.length > 0) {
        // 命令都不长，单行显示；换行的标签在行内自动布局里高度会少算一截。
        NSTextField *command = [NSTextField labelWithString:fix];
        command.selectable = YES;
        command.lineBreakMode = NSLineBreakByTruncatingMiddle;
        command.font = [NSFont monospacedSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
        command.textColor = NSColor.secondaryLabelColor;
        [command setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
            forOrientation:NSLayoutConstraintOrientationHorizontal];
        [texts addObject:command];
    }
    NSStackView *textStack = [NSStackView stackViewWithViews:texts];
    textStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    textStack.alignment = NSLayoutAttributeLeading;
    textStack.spacing = 2;

    // 用约束直接排，而不是 NSStackView 的 edgeInsets：后者在含换行标签的行里会吃掉下边距。
    NSView *row = [NSView new];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:icon];
    [row addSubview:textStack];
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [icon.topAnchor constraintEqualToAnchor:row.topAnchor constant:11],
        [textStack.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:10],
        [textStack.topAnchor constraintEqualToAnchor:row.topAnchor constant:10],
        [textStack.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-10],
    ]];
    if (fix.length > 0) {
        __weak typeof(self) weakSelf = self;
        NSButton *copy = [self buttonWithTitle:L(@"Copy Command") action:^(NSButton *sender) {
            CopyToPasteboard(fix);
            [weakSelf flashCopied:sender original:L(@"Copy Command")];
        }];
        copy.translatesAutoresizingMaskIntoConstraints = NO;
        [copy setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [copy setContentCompressionResistancePriority:NSLayoutPriorityRequired
            forOrientation:NSLayoutConstraintOrientationHorizontal];
        [row addSubview:copy];
        [constraints addObjectsFromArray:@[
            [copy.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
            [copy.topAnchor constraintEqualToAnchor:row.topAnchor constant:9],
            [textStack.trailingAnchor constraintEqualToAnchor:copy.leadingAnchor constant:-10],
        ]];
    } else {
        [constraints addObject:[textStack.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
    return row;
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
    if (self.sections.count == 0) return;
    CopyToPasteboard(CCPetsDoctorReport(self.sections));
    [self flashCopied:sender original:L(@"Copy Report")];
}

@end
