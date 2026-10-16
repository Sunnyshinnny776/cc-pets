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

// 分组卡片的底色：浅色下比窗口底亮一档，深色下比窗口底浅一档，和系统设置一致。
static NSColor *FormCardColor(void) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        BOOL dark = [[appearance bestMatchFromAppearancesWithNames:
            @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
        return dark ? [NSColor colorWithWhite:1 alpha:0.05] : [NSColor colorWithWhite:1 alpha:0.75];
    }];
}

@interface CCPetsFormBuilder ()
@property(nonatomic) NSScrollView *scrollView;
@property(nonatomic) NSStackView *stack;
@property(nonatomic) NSMutableArray<NSDictionary *> *entries;
@property(nonatomic) NSMutableDictionary<NSString *, NSView *> *headers;
@end

@implementation CCPetsFormBuilder

- (instancetype)init {
    if ((self = [super init])) {
        self.entries = [NSMutableArray array];
        self.headers = [NSMutableDictionary dictionary];

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
        stack.spacing = 8;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [document addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [document.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
            [document.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor],
            [document.topAnchor constraintEqualToAnchor:clip.topAnchor],
            [stack.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:28],
            [stack.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-28],
            [stack.topAnchor constraintEqualToAnchor:document.topAnchor constant:20],
            [stack.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-28],
        ]];
        self.scrollView = scroll;
        self.stack = stack;
    }
    return self;
}

- (NSArray<NSDictionary *> *)sectionEntries {
    return self.entries;
}

+ (NSView *)rowWithTitle:(NSString *)title controls:(NSArray<NSView *> *)controls {
    NSTextField *label = [NSTextField labelWithString:title];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
        forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *row = [NSStackView stackViewWithViews:[@[label, spacer] arrayByAddingObjectsFromArray:controls]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 8;
    row.edgeInsets = NSEdgeInsetsMake(8, 14, 8, 14);
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:40].active = YES;
    return row;
}

// 分组标题前的彩色图标块和侧边栏同一套（CCPetsSymbolTile），一眼能分出是哪一组。
- (NSView *)addSectionWithID:(NSString *)sectionID title:(NSString *)title symbol:(NSString *)symbol
    color:(NSColor *)color rows:(NSArray<NSView *> *)rows footer:(NSString *)footer {
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:NSFont.systemFontSize + 1 weight:NSFontWeightSemibold];
    NSImageView *icon = [NSImageView imageViewWithImage:CCPetsSymbolTile(symbol, color, 22)];
    [icon.widthAnchor constraintEqualToConstant:22].active = YES;
    [icon.heightAnchor constraintEqualToConstant:22].active = YES;
    NSStackView *header = [NSStackView stackViewWithViews:@[icon, label]];
    header.spacing = 8;
    header.alignment = NSLayoutAttributeCenterY;
    if (self.stack.arrangedSubviews.count > 0) {
        [self.stack setCustomSpacing:24 afterView:self.stack.arrangedSubviews.lastObject];
    }
    [self.stack addArrangedSubview:header];
    [self.stack setCustomSpacing:10 afterView:header];
    if (sectionID) {
        [self.entries addObject:@{@"id": sectionID, @"title": title, @"symbol": symbol, @"color": color}];
        self.headers[sectionID] = header;
    }

    NSStackView *content = [NSStackView stackViewWithViews:@[]];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.spacing = 0;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *row in rows) {
        if (content.arrangedSubviews.count > 0) {
            NSBox *separator = [NSBox new];
            separator.boxType = NSBoxSeparator;
            [content addArrangedSubview:separator];
            [separator.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14].active = YES;
            [separator.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14].active = YES;
        }
        [content addArrangedSubview:row];
        [row.leadingAnchor constraintEqualToAnchor:content.leadingAnchor].active = YES;
        [row.trailingAnchor constraintEqualToAnchor:content.trailingAnchor].active = YES;
    }

    NSBox *card = [NSBox new];
    card.boxType = NSBoxCustom;
    card.titlePosition = NSNoTitle;
    card.cornerRadius = 8;
    card.borderWidth = 1;
    card.borderColor = NSColor.separatorColor;
    card.fillColor = FormCardColor();
    card.contentViewMargins = NSZeroSize;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [card.contentView addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
    ]];
    [self.stack addArrangedSubview:card];
    [card.leadingAnchor constraintEqualToAnchor:self.stack.leadingAnchor].active = YES;
    [card.trailingAnchor constraintEqualToAnchor:self.stack.trailingAnchor].active = YES;

    if (footer.length > 0) {
        NSTextField *note = [NSTextField wrappingLabelWithString:footer];
        note.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        note.textColor = NSColor.secondaryLabelColor;
        note.translatesAutoresizingMaskIntoConstraints = NO;
        [self.stack addArrangedSubview:note];
        [note.leadingAnchor constraintEqualToAnchor:self.stack.leadingAnchor constant:4].active = YES;
        [note.trailingAnchor constraintEqualToAnchor:self.stack.trailingAnchor constant:-4].active = YES;
    }
    return header;
}

- (void)removeAllSections {
    for (NSView *view in [self.stack.arrangedSubviews copy]) {
        [self.stack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    [self.entries removeAllObjects];
    [self.headers removeAllObjects];
}

- (void)scrollToSectionWithID:(NSString *)sectionID {
    NSScrollView *scroll = self.scrollView;
    NSView *document = scroll.documentView;
    [document layoutSubtreeIfNeeded];
    NSView *header = sectionID ? self.headers[sectionID] : nil;
    CGFloat target = 0;
    if (header) {
        // 标题上方留一点空隙，别贴着窗口顶沿；超出可滚范围的（最后几段）停在底部。
        target = [document convertRect:header.bounds fromView:header].origin.y - 16;
        CGFloat maximum = MAX(0, NSHeight(document.frame) - NSHeight(scroll.contentView.bounds));
        target = MIN(MAX(0, target), maximum);
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.25;
        [scroll.contentView.animator setBoundsOrigin:NSMakePoint(0, target)];
    } completionHandler:^{
        [scroll reflectScrolledClipView:scroll.contentView];
    }];
}

@end
