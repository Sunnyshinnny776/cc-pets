#import "CCPetsPetCatalog.h"
#import "CCPetsCatalogModel.h"
#import "CCPetsFormBuilder.h"
#import "CCPetsL10n.h"
#import "CCPetsPetStore.h"
#import "CCPetsUIStyle.h"
#import <ImageIO/ImageIO.h>

NSNotificationName const CCPetsCatalogDidInstallNotification = @"CCPetsCatalogDidInstall";

static NSUserInterfaceItemIdentifier const ItemIdentifier = @"CCPetsCatalogItem";
static const NSInteger Columns = 5;
static const NSInteger PageSize = Columns * 5;
static const CGFloat ItemHeight = 170;
static const CGFloat ItemSpacing = 10;
// 退回整张精灵图时：卡片里的格子是 66×72pt，2x 屏上每格约 144px 高就够，不必解原图。
static const CGFloat CardCellPixels = 144;

typedef NS_ENUM(NSInteger, CatalogPetState) {
    CatalogPetAvailable,
    CatalogPetInstalled,
    CatalogPetCurrent,
    CatalogPetInstalling,
    CatalogPetFailed,
};

static NSString *CatalogText(NSDictionary *pet, NSString *key) {
    return [pet[key] isKindOfClass:NSString.class] ? pet[key] : @"";
}

static NSString *PetTitle(NSDictionary *pet) {
    NSString *title = CatalogText(pet, @"displayName");
    return title.length ? title : CatalogText(pet, @"slug");
}

static NSString *KindName(NSString *kind) {
    if ([kind isEqualToString:@"character"]) return L(@"Character");
    if ([kind isEqualToString:@"creature"]) return L(@"Creature");
    if ([kind isEqualToString:@"object"]) return L(@"Object");
    return kind;
}

static NSString *PetCredit(NSDictionary *pet) {
    NSString *author = CatalogText(pet, @"submittedBy");
    NSString *kind = KindName(CatalogText(pet, @"kind"));
    NSMutableArray *parts = [NSMutableArray array];
    if (author.length) [parts addObject:[NSString stringWithFormat:L(@"by %@"), author]];
    if (kind.length) [parts addObject:kind];
    if (CCPetsCatalogInstallText(pet).length) [parts addObject:CCPetsCatalogInstallText(pet)];
    return [parts componentsJoinedByString:@" · "];
}

// 解码整张精灵图并给出行数。cellPixels 为 0 时用原尺寸，否则缩到每格大约这么高。
static CGImageRef CreateSheet(NSData *data, CGFloat cellPixels, NSInteger *rows) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return NULL;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    size_t width = [properties[(NSString *)kCGImagePropertyPixelWidth] unsignedLongValue];
    size_t height = [properties[(NSString *)kCGImagePropertyPixelHeight] unsignedLongValue];
    NSInteger rowCount = CCPetsCatalogSheetRowCount(width, height);
    CGImageRef sheet = NULL;
    if (cellPixels > 0 && height > rowCount * cellPixels) {
        NSDictionary *options = @{
            (NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
            (NSString *)kCGImageSourceThumbnailMaxPixelSize: @(rowCount * cellPixels),
            (NSString *)kCGImageSourceShouldCacheImmediately: @YES,
        };
        sheet = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    } else {
        sheet = CGImageSourceCreateImageAtIndex(source, 0,
            (__bridge CFDictionaryRef)@{(NSString *)kCGImageSourceShouldCacheImmediately: @YES});
    }
    CFRelease(source);
    if (rows) *rows = rowCount;
    return sheet;
}

// 待机首帧。重画进独立位图：直接裁出来的子图会一直引用整张大图的像素。
static NSImage *FirstFrame(CGImageRef sheet, NSInteger rows) {
    size_t width = CGImageGetWidth(sheet) / 8, height = CGImageGetHeight(sheet) / rows;
    if (!width || !height) return nil;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space,
        (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return nil;
    // 位图原点在左下，整张图往下挪，让第一行第一格落进画布。
    CGContextDrawImage(context, CGRectMake(0, (CGFloat)height - CGImageGetHeight(sheet),
        CGImageGetWidth(sheet), CGImageGetHeight(sheet)), sheet);
    CGImageRef frame = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (!frame) return nil;
    NSImage *image = [[NSImage alloc] initWithCGImage:frame size:NSZeroSize];
    CGImageRelease(frame);
    return image;
}

// preview.webp 是一行若干帧（每格 192×208）。铺进 8 格宽的画布，和整张精灵图同一种布局，
// CCPetsSpriteView 才能按「1 行 × 8 格」去切。
static CGImageRef CreateStripSheet(NSData *data) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return NULL;
    CGImageRef strip = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!strip) return NULL;
    size_t width = CGImageGetWidth(strip), height = CGImageGetHeight(strip);
    size_t cell = (size_t)llround(height * 192.0 / 208.0);
    CGContextRef context = NULL;
    if (cell && width >= cell) {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        context = CGBitmapContextCreate(NULL, cell * 8, height, 8, 0, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(space);
    }
    if (context) CGContextDrawImage(context, CGRectMake(0, 0, width, height), strip);
    CGImageRelease(strip);
    if (!context) return NULL;
    CGImageRef sheet = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return sheet;
}

static BOOL ResponseOK(NSData *data, NSURLResponse *response, NSError *error) {
    return !error && data.length && [response isKindOfClass:NSHTTPURLResponse.class]
        && ((NSHTTPURLResponse *)response).statusCode == 200;
}

static NSImage *Placeholder(void) {
    return [NSImage imageWithSystemSymbolName:@"pawprint" accessibilityDescription:nil];
}

#pragma mark - 视图部件

// 固定 5 列，卡片宽度跟着窗口走；左右留边和页头对齐。窗口变宽变窄时重新排。
@interface CCPetsCatalogLayout : NSCollectionViewFlowLayout
// 上次排版时的可见宽度；宽度没变的边界变化（滚动）不用重排。
@property(nonatomic) CGFloat preparedWidth;
@end

@implementation CCPetsCatalogLayout
- (void)prepareLayout {
    self.preparedWidth = NSWidth(self.collectionView.enclosingScrollView.contentView.bounds);
    [super prepareLayout];
}
- (BOOL)shouldInvalidateLayoutForBoundsChange:(NSRect)newBounds {
    return NSWidth(newBounds) != self.preparedWidth;
}
@end

// 方向键由 NSCollectionView 自己处理；回车 / 空格打开选中宠物的详情。
@interface CCPetsCatalogCollectionView : NSCollectionView
@property(nonatomic, copy) void (^onActivate)(NSIndexPath *indexPath);
@end

@implementation CCPetsCatalogCollectionView
- (void)keyDown:(NSEvent *)event {
    NSIndexPath *selected = self.selectionIndexPaths.anyObject;
    BOOL activate = event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 49;
    if (activate && selected && self.onActivate) self.onActivate(selected);
    else [super keyDown:event];
}
@end

@interface CCPetsCatalogTile : CCPetsTileView
@property(nonatomic, copy) void (^onHover)(BOOL inside);
@end

@implementation CCPetsCatalogTile
- (void)mouseEntered:(NSEvent *)event {
    [super mouseEntered:event];
    if (self.onHover) self.onHover(YES);
}
- (void)mouseExited:(NSEvent *)event {
    [super mouseExited:event];
    if (self.onHover) self.onHover(NO);
}
@end

static CCPetsCardView *SkeletonBar(CGFloat width, CGFloat height) {
    CCPetsCardView *bar = [CCPetsCardView new];
    bar.cornerRadius = height / 2;
    bar.fillColor = CCPetsHoverColor();
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [bar.widthAnchor constraintEqualToConstant:width].active = YES;
    [bar.heightAnchor constraintEqualToConstant:height].active = YES;
    return bar;
}

@interface CCPetsCatalogItem : NSCollectionViewItem
@property(nonatomic) CCPetsCatalogTile *tile;
@property(nonatomic) NSImageView *preview;
@property(nonatomic) CCPetsSpriteView *sprite;
@property(nonatomic) NSTextField *name;
@property(nonatomic) NSTextField *credit;
@property(nonatomic) NSButton *actionButton;
@property(nonatomic) NSImageView *badge;
@property(nonatomic) NSArray<NSView *> *skeleton;
@property(nonatomic, copy) NSString *slug;
@property(nonatomic) NSURLSessionDataTask *task;
@property(nonatomic) BOOL hovering;
// 卡片要被换给别的宠物之前调用，目录借此关掉指向它的详情。
@property(nonatomic, copy) void (^onReuse)(CCPetsCatalogItem *item);
@end

@implementation CCPetsCatalogItem

- (void)loadView {
    CCPetsCatalogTile *tile = [CCPetsCatalogTile new];
    self.tile = tile;
    self.view = tile;

    NSImageView *preview = [NSImageView new];
    preview.imageScaling = NSImageScaleProportionallyUpOrDown;
    preview.contentTintColor = CCPetsTertiaryInkColor();
    CCPetsSpriteView *sprite = [[CCPetsSpriteView alloc] initWithFrame:NSZeroRect];
    sprite.playing = NO;
    sprite.hidden = YES;
    NSTextField *name = CCPetsLabel(@"", 12, NSFontWeightSemibold, CCPetsInkColor());
    NSTextField *credit = CCPetsLabel(@"", 11, NSFontWeightRegular, CCPetsTertiaryInkColor());
    for (NSTextField *label in @[name, credit]) {
        label.alignment = NSTextAlignmentCenter;
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
            forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    NSButton *button = [NSButton buttonWithTitle:L(@"Use") target:nil action:nil];
    button.controlSize = NSControlSizeSmall;
    button.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    NSImageView *badge = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"checkmark.circle.fill"
        accessibilityDescription:L(@"Installed")]];
    badge.contentTintColor = CCPetsAccentColor();
    badge.toolTip = L(@"Installed");
    CCPetsCardView *nameBar = SkeletonBar(64, 10), *creditBar = SkeletonBar(44, 8), *buttonBar = SkeletonBar(48, 18);
    self.skeleton = @[nameBar, creditBar, buttonBar];

    for (NSView *view in @[preview, sprite, name, credit, button, badge]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [tile addSubview:view];
    }
    for (NSView *bar in self.skeleton) [tile addSubview:bar];
    [NSLayoutConstraint activateConstraints:@[
        [preview.topAnchor constraintEqualToAnchor:tile.topAnchor constant:12],
        [preview.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [preview.widthAnchor constraintEqualToConstant:66],
        [preview.heightAnchor constraintEqualToConstant:72],
        [sprite.topAnchor constraintEqualToAnchor:preview.topAnchor],
        [sprite.leadingAnchor constraintEqualToAnchor:preview.leadingAnchor],
        [sprite.trailingAnchor constraintEqualToAnchor:preview.trailingAnchor],
        [sprite.bottomAnchor constraintEqualToAnchor:preview.bottomAnchor],
        [name.topAnchor constraintEqualToAnchor:preview.bottomAnchor constant:6],
        [name.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:8],
        [name.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-8],
        [credit.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:1],
        [credit.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:8],
        [credit.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-8],
        [button.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [button.bottomAnchor constraintEqualToAnchor:tile.bottomAnchor constant:-10],
        [button.widthAnchor constraintLessThanOrEqualToAnchor:tile.widthAnchor constant:-16],
        [badge.topAnchor constraintEqualToAnchor:tile.topAnchor constant:8],
        [badge.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-8],
        [badge.widthAnchor constraintEqualToConstant:15],
        [badge.heightAnchor constraintEqualToConstant:15],
        [nameBar.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [nameBar.topAnchor constraintEqualToAnchor:preview.bottomAnchor constant:9],
        [creditBar.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [creditBar.topAnchor constraintEqualToAnchor:nameBar.bottomAnchor constant:7],
        [buttonBar.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [buttonBar.bottomAnchor constraintEqualToAnchor:tile.bottomAnchor constant:-12],
    ]];
    tile.cursorExclusionView = button;
    self.preview = preview;
    self.sprite = sprite;
    self.name = name;
    self.credit = credit;
    self.actionButton = button;
    self.badge = badge;
}

- (void)setSkeletonShown:(BOOL)shown {
    for (NSView *bar in self.skeleton) bar.hidden = !shown;
    for (NSView *view in @[self.name, self.credit, self.actionButton]) view.hidden = shown;
    if (shown) self.badge.hidden = YES;
}

- (void)stopHover {
    self.hovering = NO;
    self.sprite.playing = NO;
    self.sprite.hidden = YES;
    self.preview.hidden = NO;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    if (self.onReuse) self.onReuse(self);
    [self.task cancel];
    self.task = nil;
    self.slug = nil;
    [self stopHover];
    [self.sprite setSheet:nil rowCount:1];
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    self.tile.fillColor = selected ? CCPetsSelectionColor() : nil;
}

@end

#pragma mark - 详情

// 点卡片弹出的详情：大号动画预览、可切换的几种状态动作、使用 / 仅安装。
@interface CCPetsCatalogDetail : NSViewController
@property(nonatomic) NSDictionary *pet;
@property(nonatomic, copy) void (^onUse)(BOOL activate);
@property(nonatomic) CCPetsSpriteView *sprite;
@property(nonatomic) NSProgressIndicator *spinner;
@property(nonatomic) NSSegmentedControl *states;
@property(nonatomic) NSButton *useButton;
@property(nonatomic) NSButton *installButton;
@property(nonatomic) NSTextField *message;
@end

@implementation CCPetsCatalogDetail

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 260)];
    CCPetsSpriteView *sprite = [[CCPetsSpriteView alloc] initWithFrame:NSZeroRect];
    sprite.translatesAutoresizingMaskIntoConstraints = NO;
    [sprite.widthAnchor constraintEqualToConstant:120].active = YES;
    [sprite.heightAnchor constraintEqualToConstant:130].active = YES;
    NSProgressIndicator *spinner = [NSProgressIndicator new];
    spinner.style = NSProgressIndicatorStyleSpinning;
    spinner.controlSize = NSControlSizeSmall;
    spinner.displayedWhenStopped = NO;
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [sprite addSubview:spinner];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:sprite.centerXAnchor],
        [spinner.centerYAnchor constraintEqualToAnchor:sprite.centerYAnchor],
    ]];
    [spinner startAnimation:nil];

    NSSegmentedControl *states = [NSSegmentedControl segmentedControlWithLabels:
        @[L(@"Resting"), L(@"Busy"), L(@"Needs You"), L(@"Finished")]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeState:)];
    states.controlSize = NSControlSizeSmall;
    states.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    states.selectedSegment = 0;
    states.enabled = NO;
    CCPetsApplyAccent(states);

    NSTextField *name = CCPetsLabel(PetTitle(self.pet), 15, NSFontWeightSemibold, CCPetsInkColor());
    NSTextField *credit = CCPetsLabel(PetCredit(self.pet), 11, NSFontWeightRegular, CCPetsSecondaryInkColor());
    for (NSTextField *label in @[name, credit]) {
        label.alignment = NSTextAlignmentCenter;
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
            forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    NSTextField *message = CCPetsWrappingLabel(@"", 11, NSFontWeightRegular, CCPetsStatusColor(CCPetsStatusError));
    message.alignment = NSTextAlignmentCenter;
    // 换行标签平时在布局时才知道宽度；算 popover 高度（fittingSize）时要提前给定，否则按一行算。
    message.preferredMaxLayoutWidth = 228;
    message.hidden = YES;

    NSButton *use = [NSButton buttonWithTitle:L(@"Use") target:self action:@selector(use:)];
    use.keyEquivalent = @"\r";
    CCPetsApplyAccent(use);
    NSButton *install = [NSButton buttonWithTitle:L(@"Install Only") target:self action:@selector(install:)];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[install, use]];
    buttons.spacing = 8;

    NSStackView *stack = [NSStackView stackViewWithViews:@[sprite, states, name, credit, message, buttons]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 6;
    stack.edgeInsets = NSEdgeInsetsMake(16, 16, 16, 16);
    [stack setCustomSpacing:12 afterView:sprite];
    [stack setCustomSpacing:10 afterView:states];
    [stack setCustomSpacing:12 afterView:credit];
    [stack setCustomSpacing:12 afterView:message];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:root.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [root.widthAnchor constraintEqualToConstant:260],
        [name.widthAnchor constraintLessThanOrEqualToConstant:228],
        [credit.widthAnchor constraintLessThanOrEqualToConstant:228],
        [message.widthAnchor constraintEqualToConstant:228],
    ]];
    self.view = root;
    self.sprite = sprite;
    self.spinner = spinner;
    self.states = states;
    self.useButton = use;
    self.installButton = install;
    self.message = message;
    [self fitContent];
}

// popover 不会按自动布局收缩，用 preferredContentSize 告诉它内容多高；错误提示出现 / 消失时再算一次。
- (void)fitContent {
    [self.view layoutSubtreeIfNeeded];
    self.preferredContentSize = self.view.fittingSize;
}

- (void)setSheet:(NSImage *)sheet rowCount:(NSInteger)rows {
    [self view];
    [self.spinner stopAnimation:nil];
    [self.sprite setSheet:sheet rowCount:rows];
    self.states.enabled = sheet != nil;
}

- (void)applyState:(CatalogPetState)state error:(NSString *)error {
    [self view];
    BOOL installed = state == CatalogPetInstalled || state == CatalogPetCurrent;
    self.installButton.hidden = installed;
    self.installButton.enabled = state != CatalogPetInstalling;
    self.useButton.enabled = state != CatalogPetCurrent && state != CatalogPetInstalling;
    self.useButton.title = state == CatalogPetCurrent ? L(@"In Use")
        : state == CatalogPetInstalling ? L(@"Installing…")
        : state == CatalogPetFailed ? L(@"Retry") : L(@"Use");
    self.message.stringValue = error ?: @"";
    self.message.hidden = state != CatalogPetFailed || error.length == 0;
    [self fitContent];
}

- (void)changeState:(NSSegmentedControl *)control {
    NSArray *states = @[@"idle", @"tool", @"approval", @"completed"];
    self.sprite.state = states[MAX(0, MIN((NSInteger)states.count - 1, control.selectedSegment))];
}

- (void)use:(id)sender {
    if (self.onUse) self.onUse(YES);
}

- (void)install:(id)sender {
    if (self.onUse) self.onUse(NO);
}

@end

#pragma mark - 页码

// 页码按钮：当前页填强调色，其余只有文字。
@interface CCPetsPageButton : NSButton
@property(nonatomic, copy) NSString *label;
@property(nonatomic) BOOL current;
@property(nonatomic) NSLayoutConstraint *widthConstraint;
@end

@implementation CCPetsPageButton

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.bordered = NO;
        self.wantsLayer = YES;
        self.layer.cornerRadius = 6;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self.heightAnchor constraintEqualToConstant:26].active = YES;
        _widthConstraint = [self.widthAnchor constraintEqualToConstant:28];
        _widthConstraint.active = YES;
    }
    return self;
}

- (void)setLabel:(NSString *)label {
    _label = [label copy];
    [self updateLook];
}

- (void)setCurrent:(BOOL)current {
    _current = current;
    [self updateLook];
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    [self updateLook];
}

- (void)updateLook {
    NSColor *ink = self.current ? NSColor.whiteColor : self.enabled ? CCPetsInkColor() : CCPetsTertiaryInkColor();
    self.attributedTitle = [[NSAttributedString alloc] initWithString:self.label ?: @""
        attributes:@{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12
            weight:self.current ? NSFontWeightSemibold : NSFontWeightRegular], NSForegroundColorAttributeName: ink}];
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self.layer.backgroundColor = self.current ? CCPetsAccentFillColor().CGColor : NSColor.clearColor.CGColor;
    }];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateLook];
}

- (void)resetCursorRects {
    if (self.enabled && !self.current) [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}

@end

#pragma mark - 目录

@interface CCPetsPetCatalog () <NSSearchFieldDelegate, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout,
    NSPopoverDelegate>
@property(nonatomic) CCPetsFormBuilder *form;
@property(nonatomic) NSSearchField *search;
@property(nonatomic) NSSegmentedControl *kinds;
@property(nonatomic) NSButton *hideInstalled;
@property(nonatomic) NSScrollView *scroll;
@property(nonatomic) CCPetsCatalogCollectionView *collectionView;
@property(nonatomic) NSStackView *emptyState;
@property(nonatomic) NSImageView *emptyIcon;
@property(nonatomic) NSTextField *emptyMessage;
@property(nonatomic) NSButton *emptyButton;
@property(nonatomic) NSView *pager;
@property(nonatomic) NSStackView *pageButtons;
@property(nonatomic) CCPetsPageButton *previousButton;
@property(nonatomic) CCPetsPageButton *nextButton;
// 自己记着发出去的下载：离开页面时同步取消。NSURLSession 的 getAllTasks 是异步的，
// 回调晚到时会把刚切回来新发的请求一起取消，卡片就一直停在占位图。
@property(nonatomic) NSHashTable<NSURLSessionTask *> *tasks;
@property(nonatomic) NSTextField *pageSummary;
@property(nonatomic) NSTextField *jumpField;
@property(nonatomic) NSInteger page;
@property(nonatomic) NSPopover *popover;
@property(nonatomic) CCPetsCatalogDetail *detail;
@property(nonatomic, copy) NSString *loadError;
@property(nonatomic) NSArray<NSDictionary *> *pets;
@property(nonatomic) NSArray<NSDictionary *> *matches;
@property(nonatomic) NSDictionary<NSString *, NSDictionary *> *petsBySlug;
@property(nonatomic) NSDictionary<NSString *, NSString *> *installed;
@property(nonatomic, copy) NSString *currentID;
@property(nonatomic) NSMutableSet<NSString *> *installing;
@property(nonatomic) NSMutableDictionary<NSString *, NSString *> *failures;
@property(nonatomic) NSMutableDictionary<NSString *, NSNumber *> *rowCounts;
@property(nonatomic) NSURLSession *session;
// 三级缓存：首帧（小，留得多）、退回整张精灵图时的原始数据（按字节计）、悬停播放用的图（只留一两页）。
@property(nonatomic) NSCache<NSString *, NSImage *> *frames;
@property(nonatomic) NSCache<NSString *, NSData *> *sheetData;
@property(nonatomic) NSCache<NSString *, NSImage *> *hoverSheets;
@property(nonatomic) BOOL loading;
@property(nonatomic) BOOL visible;
@end

@implementation CCPetsPetCatalog

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _installing = [NSMutableSet set];
    _failures = [NSMutableDictionary dictionary];
    _rowCounts = [NSMutableDictionary dictionary];
    _frames = [NSCache new];
    _frames.countLimit = 400;
    _sheetData = [NSCache new];
    _sheetData.totalCostLimit = 48 * 1024 * 1024;
    _hoverSheets = [NSCache new];
    _hoverSheets.countLimit = 2 * PageSize;
    _tasks = [NSHashTable weakObjectsHashTable];
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.defaultSessionConfiguration;
    config.HTTPMaximumConnectionsPerHost = 6;
    // 卡片小图几十 KB，详情里的整张精灵图约 2MB。素材响应是 immutable，单独给一块磁盘缓存，
    // 下次打开不用再下：系统默认的共享缓存太小，单个响应超过容量 5% 就不缓存。
    // 放在 pet-store 缓存目录下，cc-pets clean 会一并清掉。
    config.URLCache = [[NSURLCache alloc] initWithMemoryCapacity:0 diskCapacity:200 * 1024 * 1024
        directoryURL:[NSURL fileURLWithPath:[CCPetsPetStoreCacheDirectory() stringByAppendingPathComponent:@"petdex-previews"]
            isDirectory:YES]];
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 3;
    _session = [NSURLSession sessionWithConfiguration:config delegate:nil delegateQueue:queue];

    _search = [NSSearchField new];
    _search.placeholderString = L(@"Search by pet name or creator");
    _search.delegate = self;
    [_search setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_search.widthAnchor constraintGreaterThanOrEqualToConstant:150].active = YES;
    _kinds = [NSSegmentedControl segmentedControlWithLabels:@[L(@"All"), L(@"Characters"), L(@"Creatures"), L(@"Objects")]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(filterPets)];
    _kinds.selectedSegment = 0;
    CCPetsApplyAccent(_kinds);
    // 项目统一用 CCPetsSwitch，不用左侧复选框；点文字也能切换。
    _hideInstalled = [CCPetsSwitch new];
    _hideInstalled.target = self;
    _hideInstalled.action = @selector(filterPets);
    _hideInstalled.accessibilityLabel = L(@"Hide Installed");
    NSTextField *hideLabel = CCPetsLabel(L(@"Hide Installed"), 12, NSFontWeightRegular, CCPetsSecondaryInkColor());
    [hideLabel addGestureRecognizer:[[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(toggleHideInstalled:)]];
    NSStackView *hideToggle = [NSStackView stackViewWithViews:@[_hideInstalled, hideLabel]];
    hideToggle.spacing = 6;
    for (NSView *view in @[_kinds, hideToggle]) {
        [view setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [view setContentCompressionResistancePriority:NSLayoutPriorityRequired
            forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    NSStackView *toolbar = [NSStackView stackViewWithViews:@[_search, _kinds, hideToggle]];
    toolbar.spacing = 10;
    toolbar.alignment = NSLayoutAttributeCenterY;

    CCPetsCatalogLayout *layout = [CCPetsCatalogLayout new];
    layout.minimumInteritemSpacing = ItemSpacing;
    layout.minimumLineSpacing = ItemSpacing;
    CCPetsCatalogCollectionView *collection = [[CCPetsCatalogCollectionView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
    collection.collectionViewLayout = layout;
    collection.backgroundColors = @[NSColor.clearColor];
    collection.selectable = YES;
    collection.dataSource = self;
    collection.delegate = self;
    [collection registerClass:CCPetsCatalogItem.class forItemWithIdentifier:ItemIdentifier];
    __weak typeof(self) weakSelf = self;
    collection.onActivate = ^(NSIndexPath *indexPath) { [weakSelf showDetailsAtIndexPath:indexPath]; };
    _collectionView = collection;

    NSScrollView *scroll = [NSScrollView new];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;
    scroll.documentView = collection;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll = scroll;
    // 可见宽度一变就重排：窗口缩放之外，常驻滚动条出现 / 消失也会让可见区变窄 / 变宽，
    // 不重排的话按旧宽度算出的 5 张卡片放不下，会被挤成 4 列。
    scroll.contentView.postsFrameChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(visibleWidthDidChange:)
        name:NSViewFrameDidChangeNotification object:scroll.contentView];

    _emptyIcon = [NSImageView new];
    _emptyIcon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:28 weight:NSFontWeightLight];
    _emptyIcon.contentTintColor = CCPetsTertiaryInkColor();
    _emptyMessage = CCPetsWrappingLabel(@"", 13, NSFontWeightRegular, CCPetsSecondaryInkColor());
    _emptyMessage.alignment = NSTextAlignmentCenter;
    [_emptyMessage.widthAnchor constraintLessThanOrEqualToConstant:360].active = YES;
    _emptyButton = [NSButton buttonWithTitle:@"" target:self action:@selector(emptyStateAction:)];
    _emptyState = [NSStackView stackViewWithViews:@[_emptyIcon, _emptyMessage, _emptyButton]];
    _emptyState.orientation = NSUserInterfaceLayoutOrientationVertical;
    _emptyState.spacing = 10;
    _emptyState.hidden = YES;
    _emptyState.translatesAutoresizingMaskIntoConstraints = NO;

    // 底部页码栏：‹ 1 2 3 … 末页 ›，右侧是总页数和跳页。
    _pageButtons = [NSStackView stackViewWithViews:@[]];
    _pageButtons.spacing = 2;
    _previousButton = [self pageButton:@"‹" page:0 enabled:NO];
    _nextButton = [self pageButton:@"›" page:0 enabled:NO];
    _pageSummary = CCPetsLabel(@"", 12, NSFontWeightRegular, CCPetsSecondaryInkColor());
    _jumpField = [NSTextField textFieldWithString:@""];
    _jumpField.placeholderString = L(@"Page");
    _jumpField.alignment = NSTextAlignmentCenter;
    _jumpField.target = self;
    _jumpField.action = @selector(jumpToPage:);
    [_jumpField.widthAnchor constraintEqualToConstant:52].active = YES;
    NSButton *jump = [NSButton buttonWithTitle:L(@"Go") target:self action:@selector(jumpToPage:)];
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    // 整组靠右：页码固定 7 个等宽位置，‹ › 和跳页框的位置不随翻页移动。
    NSStackView *pagerRow = [NSStackView stackViewWithViews:@[spacer, _pageSummary, _previousButton, _pageButtons,
        _nextButton, _jumpField, jump]];
    [pagerRow setCustomSpacing:4 afterView:_previousButton];
    [pagerRow setCustomSpacing:4 afterView:_pageButtons];
    [pagerRow setCustomSpacing:14 afterView:_nextButton];
    pagerRow.spacing = 8;
    pagerRow.alignment = NSLayoutAttributeCenterY;
    pagerRow.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *rule = [CCPetsFormBuilder separator];
    NSView *pager = [NSView new];
    pager.translatesAutoresizingMaskIntoConstraints = NO;
    [pager addSubview:rule];
    [pager addSubview:pagerRow];
    _pager = pager;

    NSView *content = [NSView new];
    [content addSubview:scroll];
    [content addSubview:pager];
    [content addSubview:_emptyState];
    _form = [[CCPetsFormBuilder alloc] initWithTitle:L(@"Pet") subtitle:L(@"Pick and install community pets.")
        toolbar:toolbar content:content];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:content.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:pager.topAnchor],
        [pager.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [pager.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [pager.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [rule.topAnchor constraintEqualToAnchor:pager.topAnchor],
        [rule.leadingAnchor constraintEqualToAnchor:pager.leadingAnchor],
        [rule.trailingAnchor constraintEqualToAnchor:pager.trailingAnchor],
        // 页码栏和页头、卡片同一列对齐。
        [pagerRow.leadingAnchor constraintEqualToAnchor:_form.stack.leadingAnchor],
        [pagerRow.trailingAnchor constraintEqualToAnchor:_form.stack.trailingAnchor],
        [pagerRow.topAnchor constraintEqualToAnchor:rule.bottomAnchor constant:10],
        [pagerRow.bottomAnchor constraintEqualToAnchor:pager.bottomAnchor constant:-12],
        [_emptyState.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [_emptyState.centerYAnchor constraintEqualToAnchor:content.centerYAnchor constant:-30],
        [_emptyState.leadingAnchor constraintGreaterThanOrEqualToAnchor:content.leadingAnchor constant:28],
    ]];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_session invalidateAndCancel];
}

- (void)show {
    self.visible = YES;
    if (!self.pets && !self.loading) [self loadCatalog];
    // 离开页面时取消了下载中的预览，回来后把可见卡片重新配一遍，没图的接着下。
    else if (self.pets) [self.collectionView reloadData];
}

- (void)pausePreviews {
    self.visible = NO;
    [self.popover close];
    for (NSURLSessionTask *task in self.tasks.allObjects) [task cancel];
    [self.tasks removeAllObjects];
}

#pragma mark 数据

- (void)loadCatalog {
    if (self.loading) return;
    self.loading = YES;
    self.loadError = nil;
    self.emptyMessage.toolTip = nil;
    [self reloadContent];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // 清单和热门榜同时取，排序要等两份都回来；热门榜拿不到就按清单原顺序。
        __block NSArray *popular = nil;
        dispatch_group_t group = dispatch_group_create();
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            popular = CCPetsPetdexPopularPets();
        });
        NSString *error = nil;
        NSArray *manifest = CCPetsPetdexCatalog(&error);
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        NSArray *pets = manifest ? CCPetsCatalogSortByPopularity(manifest, popular) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) catalog = weakSelf;
            if (!catalog) return;
            catalog.loading = NO;
            if (!pets) {
                // 底层错误里带着来源名和 HTTP 状态，只放进提示，界面上说人话。
                catalog.loadError = L(@"Couldn't load the pet list. Check your network and try again.");
                catalog.emptyMessage.toolTip = error;
                [catalog reloadContent];
                return;
            }
            NSMutableDictionary *bySlug = [NSMutableDictionary dictionaryWithCapacity:pets.count];
            for (NSDictionary *pet in pets) bySlug[pet[@"slug"]] = pet;
            catalog.petsBySlug = bySlug;
            catalog.pets = pets;
            [catalog filterPets];
        });
    });
}

- (void)controlTextDidChange:(NSNotification *)note {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(filterPets) object:nil];
    [self performSelector:@selector(filterPets) withObject:nil afterDelay:0.18];
}

- (void)filterPets {
    if (!self.pets) return;
    NSString *query = [self.search.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray *kinds = @[@"", @"character", @"creature", @"object"];
    NSString *kind = kinds[MAX(0, MIN((NSInteger)kinds.count - 1, self.kinds.selectedSegment))];
    BOOL hideInstalled = self.hideInstalled.state == NSControlStateValueOn;
    NSDictionary *installed = self.installed;
    self.matches = [self.pets filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *pet, NSDictionary *bindings) {
        if (kind.length && ![CatalogText(pet, @"kind") isEqualToString:kind]) return NO;
        if (hideInstalled && installed[pet[@"slug"]]) return NO;
        if (!query.length) return YES;
        for (NSString *key in @[@"displayName", @"slug", @"submittedBy"]) {
            if ([CatalogText(pet, key) localizedStandardContainsString:query]) return YES;
        }
        return NO;
    }]];
    [self goToPage:0];
}

- (NSInteger)pageCount {
    return MAX((NSInteger)1, ((NSInteger)self.matches.count + PageSize - 1) / PageSize);
}

- (NSDictionary *)petAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger index = self.page * PageSize + indexPath.item;
    return index >= 0 && index < (NSInteger)self.matches.count ? self.matches[(NSUInteger)index] : nil;
}

- (void)goToPage:(NSInteger)page {
    self.page = MAX(0, MIN(page, self.pageCount - 1));
    [self.popover close];
    [self.collectionView deselectAll:nil];
    [self reloadContent];
    [self.scroll.contentView scrollToPoint:NSZeroPoint];
    [self.scroll reflectScrolledClipView:self.scroll.contentView];
    // 当前页的图先下，稍后再低优先级把下一页的小图拉进缓存，翻页时基本就是现成的。
    NSInteger next = self.page + 1;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) catalog = weakSelf;
        if (catalog.visible && catalog.page == next - 1) [catalog prefetchPage:next];
    });
}

- (void)pageButtonClicked:(NSButton *)button {
    [self goToPage:button.tag];
}

- (void)jumpToPage:(id)sender {
    NSInteger number = [self.jumpField.stringValue stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceCharacterSet].integerValue;
    self.jumpField.stringValue = @"";
    if (number < 1 || !self.pets) {
        NSBeep();
        return;
    }
    [self goToPage:number - 1];
}

- (CCPetsPageButton *)pageButton:(NSString *)label page:(NSInteger)page enabled:(BOOL)enabled {
    CCPetsPageButton *button = [CCPetsPageButton new];
    button.label = label;
    button.tag = page;
    button.target = self;
    button.action = @selector(pageButtonClicked:);
    button.enabled = enabled;
    button.current = NO;
    return button;
}

- (void)rebuildPager {
    for (NSView *view in [self.pageButtons.arrangedSubviews copy]) {
        [self.pageButtons removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    BOOL shown = self.pets && self.matches.count > 0;
    self.pager.hidden = !shown;
    if (!shown) return;
    NSInteger count = self.pageCount, current = self.page;
    NSString *widest = [NSString stringWithFormat:@"%ld", (long)count];
    CGFloat width = MAX(28, ceil([widest sizeWithAttributes:@{NSFontAttributeName:
        [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold]}].width) + 14);
    for (NSNumber *slot in CCPetsCatalogPageSlots(count, current)) {
        NSInteger page = slot.integerValue;
        CCPetsPageButton *button = page < 0 ? [self pageButton:@"…" page:0 enabled:NO]
            : [self pageButton:[NSString stringWithFormat:@"%ld", (long)page + 1] page:page enabled:YES];
        button.current = page == current;
        button.widthConstraint.constant = width;
        [self.pageButtons addArrangedSubview:button];
    }
    self.previousButton.tag = current - 1;
    self.previousButton.enabled = current > 0;
    self.nextButton.tag = current + 1;
    self.nextButton.enabled = current < count - 1;
    self.pageSummary.stringValue = [NSString stringWithFormat:L(@"%ld pages"), (long)count];
}

- (void)toggleHideInstalled:(id)sender {
    self.hideInstalled.state = self.hideInstalled.state == NSControlStateValueOn ? NSControlStateValueOff : NSControlStateValueOn;
    [self filterPets];
}

- (BOOL)filtersActive {
    return self.search.stringValue.length > 0 || self.kinds.selectedSegment > 0
        || self.hideInstalled.state == NSControlStateValueOn;
}

// 列表、页码、空状态、页头副标题一起刷新。
- (void)reloadContent {
    [self.collectionView reloadData];
    [self rebuildPager];
    NSString *icon = nil, *message = nil, *button = nil;
    if (self.loadError) {
        icon = @"wifi.exclamationmark";
        message = self.loadError;
        button = L(@"Retry");
    } else if (self.pets && self.matches.count == 0) {
        icon = @"magnifyingglass";
        message = L(@"No matching pets");
        button = self.filtersActive ? L(@"Clear Filters") : nil;
    }
    self.emptyState.hidden = message == nil;
    if (message) {
        self.emptyIcon.image = [NSImage imageWithSystemSymbolName:icon accessibilityDescription:nil];
        self.emptyMessage.stringValue = message;
        self.emptyButton.title = button ?: @"";
        self.emptyButton.hidden = button == nil;
    }
    NSTextField *subtitle = self.form.subtitleLabel;
    if (self.loading) subtitle.stringValue = L(@"Loading pets…");
    else if (!self.pets) subtitle.stringValue = L(@"Pick and install community pets.");
    else if (self.matches.count == self.pets.count)
        subtitle.stringValue = [NSString stringWithFormat:L(@"%lu community pets"), (unsigned long)self.pets.count];
    else subtitle.stringValue = [NSString stringWithFormat:L(@"Showing %lu of %lu pets"),
        (unsigned long)self.matches.count, (unsigned long)self.pets.count];
}

- (void)emptyStateAction:(id)sender {
    if (self.loadError) {
        [self loadCatalog];
        return;
    }
    self.search.stringValue = @"";
    self.kinds.selectedSegment = 0;
    self.hideInstalled.state = NSControlStateValueOff;
    [self filterPets];
}

- (CatalogPetState)stateForSlug:(NSString *)slug {
    if ([self.installing containsObject:slug]) return CatalogPetInstalling;
    NSString *installedID = self.installed[slug];
    if (installedID) return [installedID isEqual:self.currentID] ? CatalogPetCurrent : CatalogPetInstalled;
    return self.failures[slug] ? CatalogPetFailed : CatalogPetAvailable;
}

- (void)setInstalledPets:(NSArray<NSDictionary *> *)options currentID:(NSString *)currentID {
    NSMutableDictionary *installed = [NSMutableDictionary dictionary];
    for (NSDictionary *pet in options) {
        NSString *slug = pet[@"petdexSlug"];
        if (slug.length && (!installed[slug] || [pet[@"id"] isEqual:currentID])) installed[slug] = pet[@"id"];
    }
    self.installed = installed;
    self.currentID = currentID;
    [self refreshVisibleState];
}

- (void)refreshVisibleState {
    for (CCPetsCatalogItem *item in self.collectionView.visibleItems) {
        if (item.slug) [self updateItem:item];
    }
    NSString *slug = CatalogText(self.detail.pet, @"slug");
    if (self.popover.shown && slug.length) [self.detail applyState:[self stateForSlug:slug] error:self.failures[slug]];
}

#pragma mark 安装

// activate 为 YES 时装完直接换上；已经装过的只切换。
- (void)usePet:(NSDictionary *)pet activate:(BOOL)activate {
    NSString *slug = pet[@"slug"];
    NSString *installedID = self.installed[slug];
    if (installedID) {
        if (activate && ![installedID isEqual:self.currentID] && self.selectPet) self.selectPet(installedID);
        return;
    }
    if ([self.installing containsObject:slug]) return;
    [self.installing addObject:slug];
    [self.failures removeObjectForKey:slug];
    [self refreshVisibleState];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        BOOL saved = CCPetsInstallPetdexPet(pet, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) catalog = weakSelf;
            if (!catalog) return;
            [catalog.installing removeObject:slug];
            if (saved) {
                // 宠物页收到通知会同步重扫素材并回调 setInstalledPets:，之后 installed 里就有新 id。
                [NSNotificationCenter.defaultCenter postNotificationName:CCPetsCatalogDidInstallNotification object:nil];
                NSString *petID = catalog.installed[slug];
                if (activate && petID && catalog.selectPet) catalog.selectPet(petID);
            } else {
                catalog.failures[slug] = error.length ? error : L(@"Install failed.");
            }
            [catalog refreshVisibleState];
        });
    });
}

- (void)useFromButton:(NSButton *)button {
    NSDictionary *pet = self.petsBySlug[button.identifier];
    if (pet) [self usePet:pet activate:YES];
}

- (void)useFromMenu:(NSMenuItem *)item {
    NSDictionary *pet = self.petsBySlug[item.representedObject];
    if (pet) [self usePet:pet activate:YES];
}

- (void)installFromMenu:(NSMenuItem *)item {
    NSDictionary *pet = self.petsBySlug[item.representedObject];
    if (pet) [self usePet:pet activate:NO];
}

#pragma mark 卡片

- (NSInteger)collectionView:(NSCollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    if (!self.pets) return self.loading ? PageSize : 0;
    return MAX(0, MIN(PageSize, (NSInteger)self.matches.count - self.page * PageSize));
}

- (NSCollectionViewItem *)collectionView:(NSCollectionView *)collectionView
    itemForRepresentedObjectAtIndexPath:(NSIndexPath *)indexPath {
    CCPetsCatalogItem *item = [collectionView makeItemWithIdentifier:ItemIdentifier forIndexPath:indexPath];
    __weak typeof(self) weakSelf = self;
    item.onReuse = ^(CCPetsCatalogItem *reused) {
        if (reused.slug && [reused.slug isEqual:CatalogText(weakSelf.detail.pet, @"slug")]) [weakSelf.popover close];
    };
    [item.task cancel];
    item.task = nil;
    [item stopHover];
    if (!self.pets) {
        item.slug = nil;
        item.preview.image = Placeholder();
        item.tile.onClick = nil;
        item.tile.onHover = nil;
        item.tile.menu = nil;
        item.tile.selected = NO;
        item.tile.toolTip = nil;
        [item setSkeletonShown:YES];
        return item;
    }
    NSDictionary *pet = [self petAtIndexPath:indexPath];
    NSString *slug = pet[@"slug"];
    item.slug = slug;
    [item setSkeletonShown:NO];
    item.name.stringValue = PetTitle(pet);
    NSString *author = CatalogText(pet, @"submittedBy"), *installs = CCPetsCatalogInstallText(pet);
    item.credit.stringValue = author.length && installs.length ? [NSString stringWithFormat:@"%@ · %@", author, installs]
        : author.length ? author : installs;
    item.tile.toolTip = [@[PetTitle(pet), PetCredit(pet)] componentsJoinedByString:@"\n"];
    item.tile.accessibilityLabel = PetTitle(pet);
    item.actionButton.identifier = slug;
    item.actionButton.target = self;
    item.actionButton.action = @selector(useFromButton:);
    __weak CCPetsCatalogItem *weakItem = item;
    item.tile.onClick = ^{
        CCPetsCatalogItem *strongItem = weakItem;
        NSIndexPath *path = strongItem ? [weakSelf.collectionView indexPathForItem:strongItem] : nil;
        if (!path) return;
        [weakSelf.collectionView deselectAll:nil];
        [weakSelf.collectionView selectItemsAtIndexPaths:[NSSet setWithObject:path] scrollPosition:NSCollectionViewScrollPositionNone];
        [weakSelf.collectionView.window makeFirstResponder:weakSelf.collectionView];
        [weakSelf showDetailsAtIndexPath:path];
    };
    item.tile.onHover = ^(BOOL inside) {
        CCPetsCatalogItem *strongItem = weakItem;
        if (!strongItem.slug) return;
        if (inside) [weakSelf startHoverForItem:strongItem];
        else [strongItem stopHover];
    };
    NSImage *frame = [self.frames objectForKey:slug];
    item.preview.image = frame ?: Placeholder();
    if (!frame) {
        item.task = [self fetchPreviewForPet:pet priority:NSURLSessionTaskPriorityHigh completion:^{
            CCPetsCatalogItem *target = weakItem;
            if (![target.slug isEqual:slug]) return;
            target.preview.image = [weakSelf.frames objectForKey:slug] ?: Placeholder();
            if (target.hovering) [weakSelf startHoverForItem:target];
        }];
    }
    [self updateItem:item];
    return item;
}

- (void)updateItem:(CCPetsCatalogItem *)item {
    NSString *slug = item.slug;
    CatalogPetState state = [self stateForSlug:slug];
    NSButton *button = item.actionButton;
    button.enabled = state != CatalogPetCurrent && state != CatalogPetInstalling;
    NSString *title = state == CatalogPetCurrent ? L(@"In Use")
        : state == CatalogPetInstalling ? L(@"Installing…")
        : state == CatalogPetFailed ? L(@"Retry") : L(@"Use");
    if (state == CatalogPetFailed) {
        button.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{
            NSFontAttributeName: button.font, NSForegroundColorAttributeName: CCPetsStatusColor(CCPetsStatusError)}];
        button.toolTip = self.failures[slug];
    } else {
        button.title = title;
        button.toolTip = state == CatalogPetAvailable ? L(@"Download this pet and switch to it") : nil;
    }
    item.badge.hidden = state != CatalogPetInstalled && state != CatalogPetCurrent;
    item.tile.selected = state == CatalogPetCurrent;

    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    NSMenuItem *use = [menu addItemWithTitle:L(@"Use") action:@selector(useFromMenu:) keyEquivalent:@""];
    use.enabled = button.enabled;
    if (state == CatalogPetAvailable || state == CatalogPetFailed) {
        [menu addItemWithTitle:L(@"Install Only") action:@selector(installFromMenu:) keyEquivalent:@""];
    }
    for (NSMenuItem *menuItem in menu.itemArray) {
        menuItem.target = self;
        menuItem.representedObject = slug;
    }
    item.tile.menu = menu;
}

// 卡片预览：先取网站卡片用的小图；拿不到再退回整张精灵图。结果写进缓存，完成后在主线程回调。
- (NSURLSessionDataTask *)fetchPreviewForPet:(NSDictionary *)pet priority:(float)priority
                                   completion:(void (^)(void))completion {
    NSURLRequest *request = CCPetsPetdexThumbnailRequest(pet);
    if (!request) return [self fetchSheetPreviewForPet:pet priority:priority completion:completion];
    NSString *slug = pet[@"slug"];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) return;
        CGImageRef sheet = ResponseOK(data, response, error) ? CreateStripSheet(data) : NULL;
        NSImage *frame = sheet ? FirstFrame(sheet, 1) : nil;
        NSImage *strip = frame ? [[NSImage alloc] initWithCGImage:sheet size:NSZeroSize] : nil;
        if (sheet) CGImageRelease(sheet);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) catalog = weakSelf;
            if (!catalog) return;
            if (!frame) {
                [catalog fetchSheetPreviewForPet:pet priority:priority completion:completion];
                return;
            }
            [catalog.frames setObject:frame forKey:slug];
            [catalog.hoverSheets setObject:strip forKey:slug];
            catalog.rowCounts[slug] = @1;
            if (completion) completion();
        });
    }];
    task.priority = priority;
    [self.tasks addObject:task];
    [task resume];
    return task;
}

- (NSURLSessionDataTask *)fetchSheetPreviewForPet:(NSDictionary *)pet priority:(float)priority
                                        completion:(void (^)(void))completion {
    NSURLRequest *request = CCPetsPetdexPreviewRequest(pet);
    if (!request) return nil;
    NSString *slug = pet[@"slug"];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!ResponseOK(data, response, error)) return;
        NSInteger rows = 9;
        CGImageRef sheet = CreateSheet(data, CardCellPixels, &rows);
        if (!sheet) return;
        NSImage *frame = FirstFrame(sheet, rows);
        CGImageRelease(sheet);
        if (!frame) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) catalog = weakSelf;
            if (!catalog) return;
            [catalog.frames setObject:frame forKey:slug];
            [catalog.sheetData setObject:data forKey:slug cost:data.length];
            catalog.rowCounts[slug] = @(rows);
            if (completion) completion();
        });
    }];
    task.priority = priority;
    [self.tasks addObject:task];
    [task resume];
    return task;
}

- (void)prefetchPage:(NSInteger)page {
    NSInteger start = page * PageSize, end = MIN(start + PageSize, (NSInteger)self.matches.count);
    for (NSInteger index = start; index < end; index++) {
        NSDictionary *pet = self.matches[(NSUInteger)index];
        if (![self.frames objectForKey:pet[@"slug"]]) [self fetchPreviewForPet:pet priority:NSURLSessionTaskPriorityLow completion:nil];
    }
}

// 悬停时播待机动画。小图取回时已经铺好画布；退回整张精灵图的，从缓存的原始数据现解。
- (void)startHoverForItem:(CCPetsCatalogItem *)item {
    NSString *slug = item.slug;
    item.hovering = YES;
    NSImage *sheet = [self.hoverSheets objectForKey:slug];
    NSInteger rows = self.rowCounts[slug].integerValue ?: 9;
    if (sheet) {
        [item.sprite setSheet:sheet rowCount:rows];
        item.sprite.state = @"idle";
        item.sprite.hidden = NO;
        item.preview.hidden = YES;
        item.sprite.playing = YES;
        return;
    }
    NSData *data = [self.sheetData objectForKey:slug];
    __weak typeof(self) weakSelf = self;
    __weak CCPetsCatalogItem *weakItem = item;
    if (!data) {
        // 播放用的图被缓存挤掉了：重新取一次（磁盘缓存命中，很快），回来还停在卡片上就播。
        NSDictionary *pet = self.petsBySlug[slug];
        if (!pet || item.task.state == NSURLSessionTaskStateRunning) return;
        item.task = [self fetchPreviewForPet:pet priority:NSURLSessionTaskPriorityHigh completion:^{
            CCPetsCatalogItem *target = weakItem;
            if (target.hovering && [target.slug isEqual:slug] && [weakSelf.hoverSheets objectForKey:slug]) {
                [weakSelf startHoverForItem:target];
            }
        }];
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSInteger decodedRows = 9;
        CGImageRef image = CreateSheet(data, CardCellPixels, &decodedRows);
        if (!image) return;
        NSImage *decoded = [[NSImage alloc] initWithCGImage:image size:NSZeroSize];
        CGImageRelease(image);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.hoverSheets setObject:decoded forKey:slug];
            CCPetsCatalogItem *target = weakItem;
            if (target.hovering && [target.slug isEqual:slug]) [weakSelf startHoverForItem:target];
        });
    });
}

#pragma mark 详情

- (void)showDetailsAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *pet = [self petAtIndexPath:indexPath];
    if (!self.pets || !pet) return;
    [self.collectionView scrollToItemsAtIndexPaths:[NSSet setWithObject:indexPath]
        scrollPosition:NSCollectionViewScrollPositionNearestHorizontalEdge];
    [self.collectionView layoutSubtreeIfNeeded];
    NSView *anchor = [self.collectionView itemAtIndexPath:indexPath].view;
    if (!anchor) return;
    NSString *slug = pet[@"slug"];
    [self.popover close];

    CCPetsCatalogDetail *detail = [CCPetsCatalogDetail new];
    detail.pet = pet;
    __weak typeof(self) weakSelf = self;
    detail.onUse = ^(BOOL activate) { [weakSelf usePet:pet activate:activate]; };
    [detail applyState:[self stateForSlug:slug] error:self.failures[slug]];
    NSPopover *popover = [NSPopover new];
    popover.behavior = NSPopoverBehaviorTransient;
    popover.contentViewController = detail;
    popover.delegate = self;
    self.detail = detail;
    self.popover = popover;
    [popover showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSRectEdgeMaxX];
    [self loadDetailSheet:pet into:detail];
}

// 详情里的大图按原尺寸解码，只在弹出时解一张，不进缓存。
- (void)loadDetailSheet:(NSDictionary *)pet into:(CCPetsCatalogDetail *)detail {
    NSString *slug = pet[@"slug"];
    __weak CCPetsCatalogDetail *weakDetail = detail;
    void (^decode)(NSData *) = ^(NSData *data) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSInteger rows = 9;
            CGImageRef image = CreateSheet(data, 0, &rows);
            NSImage *sheet = image ? [[NSImage alloc] initWithCGImage:image size:NSZeroSize] : nil;
            if (image) CGImageRelease(image);
            dispatch_async(dispatch_get_main_queue(), ^{ [weakDetail setSheet:sheet rowCount:rows]; });
        });
    };
    NSData *cached = [self.sheetData objectForKey:slug];
    if (cached) {
        decode(cached);
        return;
    }
    NSURLRequest *request = CCPetsPetdexPreviewRequest(pet);
    if (!request) {
        [detail setSheet:nil rowCount:9];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL ok = !error && data.length && [response isKindOfClass:NSHTTPURLResponse.class]
            && ((NSHTTPURLResponse *)response).statusCode == 200;
        if (!ok) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakDetail setSheet:nil rowCount:9]; });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf.sheetData setObject:data forKey:slug cost:data.length]; });
        decode(data);
    }] resume];
}

- (void)popoverDidClose:(NSNotification *)notification {
    if (notification.object == self.popover) {
        self.popover = nil;
        self.detail = nil;
    }
}

#pragma mark 布局

// 卡片宽度和左右留边都按这一个宽度算，和流式布局实际可用的宽度一致。
- (CGFloat)visibleWidth {
    return NSWidth(self.scroll.contentView.bounds);
}

- (void)visibleWidthDidChange:(NSNotification *)notification {
    CCPetsCatalogLayout *layout = (CCPetsCatalogLayout *)self.collectionView.collectionViewLayout;
    if (self.visibleWidth == layout.preparedWidth) return;
    [layout invalidateLayout];
}

- (NSSize)collectionView:(NSCollectionView *)collectionView layout:(NSCollectionViewLayout *)layout
    sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat width = self.visibleWidth;
    CGFloat available = width - 2 * [CCPetsFormBuilder contentInsetForWidth:width];
    return NSMakeSize(MAX(80, floor((available - (Columns - 1) * ItemSpacing) / Columns)), ItemHeight);
}

- (NSEdgeInsets)collectionView:(NSCollectionView *)collectionView layout:(NSCollectionViewLayout *)layout
    insetForSectionAtIndex:(NSInteger)section {
    CGFloat inset = [CCPetsFormBuilder contentInsetForWidth:self.visibleWidth];
    return NSEdgeInsetsMake(12, inset, 28, inset);
}

@end
