#import "CCPetsFormBuilder.h"
#import "CCPetsUIStyle.h"

// 文档视图要翻转坐标（原点在左上），内容才会从顶部往下排，滚动位置也才好算。
@interface CCPetsFlippedView : NSView
@end

@implementation CCPetsFlippedView
- (BOOL)isFlipped {
    return YES;
}
@end

// 内容最宽 780pt：窗口拉得很宽时，表单和表格不跟着摊成一长条，行内左右两端离得太远不好对照。
static const CGFloat FormMaximumWidth = 780;
static const CGFloat FormSideInset = 28;

@interface CCPetsFormBuilder ()
@property(nonatomic) NSView *view;
@property(nonatomic) NSScrollView *scrollView;
@property(nonatomic) NSStackView *stack;
@property(nonatomic) NSTextField *subtitleLabel;
@property(nonatomic) NSStackView *accessories;
@end

@implementation CCPetsFormBuilder

- (instancetype)init {
    return [self initWithTitle:@"" subtitle:@""];
}

- (instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle {
    if ((self = [super init])) {
        NSTextField *titleLabel = CCPetsLabel(title, 22, NSFontWeightBold, CCPetsInkColor());
        NSTextField *subtitleLabel = CCPetsLabel(subtitle, 12, NSFontWeightRegular, CCPetsSecondaryInkColor());
        [titleLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
            forOrientation:NSLayoutConstraintOrientationHorizontal];
        [subtitleLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
            forOrientation:NSLayoutConstraintOrientationHorizontal];
        self.subtitleLabel = subtitleLabel;
        NSStackView *titles = [NSStackView stackViewWithViews:@[titleLabel, subtitleLabel]];
        titles.orientation = NSUserInterfaceLayoutOrientationVertical;
        titles.alignment = NSLayoutAttributeLeading;
        titles.spacing = 2;

        NSStackView *accessories = [NSStackView stackViewWithViews:@[]];
        accessories.spacing = 8;
        accessories.alignment = NSLayoutAttributeCenterY;
        [accessories setContentHuggingPriority:NSLayoutPriorityRequired
            forOrientation:NSLayoutConstraintOrientationHorizontal];
        [accessories setContentCompressionResistancePriority:NSLayoutPriorityRequired
            forOrientation:NSLayoutConstraintOrientationHorizontal];
        self.accessories = accessories;

        NSView *header = [NSView new];
        NSView *rule = [CCPetsFormBuilder separator];
        for (NSView *view in @[titles, accessories, rule]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [header addSubview:view];
        }

        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 560, 560)];
        scroll.hasVerticalScroller = YES;
        scroll.autohidesScrollers = YES;
        scroll.drawsBackground = NO;
        NSView *document = [[CCPetsFlippedView alloc] initWithFrame:NSZeroRect];
        document.translatesAutoresizingMaskIntoConstraints = NO;
        scroll.documentView = document;
        NSClipView *clip = scroll.contentView;

        NSStackView *stack = [NSStackView stackViewWithViews:@[]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.alignment = NSLayoutAttributeLeading;
        stack.spacing = 16;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [document addSubview:stack];

        NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 560)];
        header.translatesAutoresizingMaskIntoConstraints = NO;
        scroll.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:header];
        [root addSubview:scroll];

        NSLayoutConstraint *fullWidth = [stack.widthAnchor constraintEqualToAnchor:document.widthAnchor
            constant:-2 * FormSideInset];
        fullWidth.priority = NSLayoutPriorityDefaultHigh;
        [NSLayoutConstraint activateConstraints:@[
            [header.topAnchor constraintEqualToAnchor:root.topAnchor],
            [header.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [header.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [titles.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:FormSideInset],
            [titles.topAnchor constraintEqualToAnchor:header.topAnchor constant:6],
            [titles.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-14],
            [accessories.leadingAnchor constraintGreaterThanOrEqualToAnchor:titles.trailingAnchor constant:16],
            [accessories.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-FormSideInset],
            [accessories.centerYAnchor constraintEqualToAnchor:titles.centerYAnchor],
            [rule.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
            [rule.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
            [rule.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],

            [scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor],
            [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [scroll.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
            [document.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
            [document.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor],
            [document.topAnchor constraintEqualToAnchor:clip.topAnchor],
            [stack.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:FormSideInset],
            [stack.trailingAnchor constraintLessThanOrEqualToAnchor:document.trailingAnchor constant:-FormSideInset],
            [stack.widthAnchor constraintLessThanOrEqualToConstant:FormMaximumWidth],
            fullWidth,
            [stack.topAnchor constraintEqualToAnchor:document.topAnchor constant:18],
            [stack.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-28],
        ]];
        self.view = root;
        self.scrollView = scroll;
        self.stack = stack;
    }
    return self;
}

- (void)setAccessoryViews:(NSArray<NSView *> *)views {
    for (NSView *view in [self.accessories.arrangedSubviews copy]) {
        [self.accessories removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    for (NSView *view in views) [self.accessories addArrangedSubview:view];
}

+ (NSView *)separator {
    CCPetsLineView *line = [CCPetsLineView new];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    [line.heightAnchor constraintEqualToConstant:1].active = YES;
    return line;
}

+ (NSView *)rowWithTitle:(NSString *)title controls:(NSArray<NSView *> *)controls {
    return [self rowWithTitle:title subtitle:nil controls:controls];
}

+ (NSView *)rowWithTitle:(NSString *)title subtitle:(NSString *)subtitle controls:(NSArray<NSView *> *)controls {
    NSTextField *label = CCPetsLabel(title, 13, NSFontWeightRegular, CCPetsInkColor());
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
        forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSView *titleView = label;
    if (subtitle.length > 0) {
        NSTextField *detail = CCPetsLabel(subtitle, 11, NSFontWeightRegular, CCPetsTertiaryInkColor());
        [detail setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
            forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSStackView *titles = [NSStackView stackViewWithViews:@[label, detail]];
        titles.orientation = NSUserInterfaceLayoutOrientationVertical;
        titles.alignment = NSLayoutAttributeLeading;
        titles.spacing = 1;
        [titles setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
            forOrientation:NSLayoutConstraintOrientationHorizontal];
        titleView = titles;
    }
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *row = [NSStackView stackViewWithViews:[@[titleView, spacer] arrayByAddingObjectsFromArray:controls]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 8;
    row.edgeInsets = NSEdgeInsetsMake(8, 14, 8, 14);
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:subtitle.length > 0 ? 48 : 40].active = YES;
    return row;
}

- (void)addGroupTitle:(NSString *)title note:(NSString *)note {
    NSTextField *label = CCPetsLabel(title, 13, NSFontWeightSemibold, CCPetsInkColor());
    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObject:label];
    if (note.length > 0) [views addObject:CCPetsLabel(note, 11, NSFontWeightRegular, CCPetsTertiaryInkColor())];
    NSStackView *header = [NSStackView stackViewWithViews:views];
    header.spacing = 8;
    header.alignment = NSLayoutAttributeFirstBaseline;
    header.edgeInsets = NSEdgeInsetsMake(0, 2, 0, 0);
    // 分组标题和它下面的卡片贴近一些，和上一组拉开：一眼看出谁属于谁。
    if (self.stack.arrangedSubviews.count > 0) {
        [self.stack setCustomSpacing:22 afterView:self.stack.arrangedSubviews.lastObject];
    }
    [self.stack addArrangedSubview:header];
    [self.stack setCustomSpacing:8 afterView:header];
}

- (NSView *)addGroupWithTitle:(NSString *)title rows:(NSArray<NSView *> *)rows footer:(NSString *)footer {
    if (title.length > 0) [self addGroupTitle:title note:nil];

    NSStackView *content = [NSStackView stackViewWithViews:@[]];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.spacing = 0;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *row in rows) {
        if (content.arrangedSubviews.count > 0) {
            NSView *separator = [CCPetsFormBuilder separator];
            [content addArrangedSubview:separator];
            [separator.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14].active = YES;
            [separator.trailingAnchor constraintEqualToAnchor:content.trailingAnchor].active = YES;
        }
        [content addArrangedSubview:row];
        [row.leadingAnchor constraintEqualToAnchor:content.leadingAnchor].active = YES;
        [row.trailingAnchor constraintEqualToAnchor:content.trailingAnchor].active = YES;
    }

    CCPetsCardView *card = [CCPetsCardView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:card.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];
    [self addView:card];
    if (footer.length > 0) [self addFootnote:footer];
    return card;
}

- (void)addView:(NSView *)view {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack addArrangedSubview:view];
    [view.leadingAnchor constraintEqualToAnchor:self.stack.leadingAnchor].active = YES;
    [view.trailingAnchor constraintEqualToAnchor:self.stack.trailingAnchor].active = YES;
}

- (NSTextField *)addFootnote:(NSString *)text {
    NSTextField *note = CCPetsWrappingLabel(text, 11, NSFontWeightRegular, CCPetsTertiaryInkColor());
    if (self.stack.arrangedSubviews.count > 0) {
        [self.stack setCustomSpacing:8 afterView:self.stack.arrangedSubviews.lastObject];
    }
    note.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack addArrangedSubview:note];
    [note.leadingAnchor constraintEqualToAnchor:self.stack.leadingAnchor constant:2].active = YES;
    [note.trailingAnchor constraintEqualToAnchor:self.stack.trailingAnchor constant:-2].active = YES;
    return note;
}

- (void)removeAllContent {
    for (NSView *view in [self.stack.arrangedSubviews copy]) {
        [self.stack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
}

@end
