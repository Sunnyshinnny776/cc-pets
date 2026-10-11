#import "CCPetsPhrasesEditor.h"
#import "CCPetsL10n.h"
#import "CCPetsPhrases.h"

static void (^PetPhrasesSpeakHandler)(NSString *);

@interface PetPhrasesEditorController () <NSTextViewDelegate>
@property NSTextView *textView;
@property NSPopUpButton *tagPicker;
@property NSTextField *statusLabel;
@property NSButton *speakButton;
@property NSButton *saveButton;
@property NSButton *saveAndCloseButton;
@property NSButton *revertButton;
// 只在专属页出现：把默认台词整份填进来，给空白页一个起点。
@property NSButton *fillButton;
// 编辑的是通用词库还是某只宠物的专属词库。
@property NSSegmentedControl *scopeControl;
@property BOOL petScope;
// 打开这一页时锁定的 petID。不是每次都现取 PetPhrasesCurrentPetID()：用户完全可能
// 一边开着编辑器一边切宠物，现取的话保存会落到另一只身上，而他看着的还是这一只的文本。
@property(copy) NSString *scopePetID;
// 载入时文件的 mtime。保存前比一次，防止把外部编辑器的改动直接盖掉。
@property NSDate *loadedStamp;
// 载入时的全文。判断"有没有改过"用，切换 scope 前要靠它决定问不问。
@property(copy) NSString *loadedText;
@end

@implementation PetPhrasesEditorController

+ (instancetype)shared {
    static PetPhrasesEditorController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [PetPhrasesEditorController new]; });
    return shared;
}

+ (void)setSpeakHandler:(void (^)(NSString *))handler {
    PetPhrasesSpeakHandler = [handler copy];
}

+ (void)present {
    PetPhrasesEditorController *controller = [self shared];
    [controller buildWindowIfNeeded];
    [controller syncScopeToCurrentPet];
    [controller refreshLocalizedUI];
    [controller reloadFromDisk];
    [NSApp activateIgnoringOtherApps:YES];
    [controller.window makeKeyAndOrderFront:nil];
    [controller.window makeFirstResponder:controller.textView];
}

#pragma mark - 界面

- (void)buildWindowIfNeeded {
    if (self.window) return;

    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 620, 640)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                  NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    window.title = L(@"Pet Lines");
    window.releasedWhenClosed = NO;
    window.minSize = NSMakeSize(460, 400);
    [window center];

    NSView *root = window.contentView;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextView *textView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    textView.minSize = NSMakeSize(0, 0);
    textView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    textView.verticallyResizable = YES;
    textView.horizontallyResizable = NO;
    textView.autoresizingMask = NSViewWidthSizable;
    textView.textContainer.widthTracksTextView = YES;
    textView.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
    // 台词是纯文本：富文本会把粘贴进来的字体样式一起带进文件。
    textView.richText = NO;
    textView.allowsUndo = YES;
    // 智能引号会把英文引号换成弯引号、破折号会被合并——台词里无所谓，
    // 但 {slot} 这类记号一旦被"智能"处理过就再也对不上白名单了。
    textView.automaticQuoteSubstitutionEnabled = NO;
    textView.automaticDashSubstitutionEnabled = NO;
    textView.automaticTextReplacementEnabled = NO;
    textView.automaticSpellingCorrectionEnabled = NO;
    textView.textContainerInset = NSMakeSize(8, 10);
    textView.delegate = self;
    scroll.documentView = textView;
    self.textView = textView;

    NSTextField *status = [NSTextField labelWithString:@""];
    status.font = [NSFont systemFontOfSize:11];
    status.textColor = NSColor.secondaryLabelColor;
    status.lineBreakMode = NSLineBreakByTruncatingTail;
    status.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel = status;

    NSPopUpButton *picker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    picker.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSString *tag in PetPhraseAllTags()) {
        [picker addItemWithTitle:[NSString stringWithFormat:L(@"%1$@ (%2$@)"),
            PetPhraseTagDescription(tag), tag]];
        picker.lastItem.representedObject = tag;
    }
    self.tagPicker = picker;

    NSButton *speak = [NSButton buttonWithTitle:L(@"Try a Line") target:self
        action:@selector(speakSample:)];
    speak.translatesAutoresizingMaskIntoConstraints = NO;
    self.speakButton = speak;

    NSButton *save = [NSButton buttonWithTitle:L(@"Save") target:self action:@selector(save:)];
    // ⌘S 而不是回车：这是个多行文本编辑器，回车要用来换行。
    save.keyEquivalent = @"s";
    save.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    save.translatesAutoresizingMaskIntoConstraints = NO;
    self.saveButton = save;

    NSButton *saveAndClose = [NSButton buttonWithTitle:L(@"Save & Close") target:self
        action:@selector(saveAndClose:)];
    saveAndClose.keyEquivalent = @"\r";
    saveAndClose.translatesAutoresizingMaskIntoConstraints = NO;
    self.saveAndCloseButton = saveAndClose;

    NSButton *revert = [NSButton buttonWithTitle:L(@"Restore Defaults…") target:self
        action:@selector(revertToDefault:)];
    revert.translatesAutoresizingMaskIntoConstraints = NO;
    self.revertButton = revert;

    // 两段式而不是下拉菜单：一共就两个去处，而且"我现在改的是哪一份"必须一眼可见——
    // 藏进下拉里的话，用户很容易把只想给一只宠物写的台词存进通用词库。
    NSSegmentedControl *scope = [NSSegmentedControl segmentedControlWithLabels:@[L(@"Shared"), L(@"This Pet")]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(scopeChanged:)];
    scope.translatesAutoresizingMaskIntoConstraints = NO;
    scope.selectedSegment = 0;
    self.scopeControl = scope;

    // 专属页初次打开是空白的——空白在语义上是对的（全部回落到通用），但一个空白文本框
    // 不告诉任何人该往里写什么。这个按钮就是那个起点：把默认台词整份填进来，
    // 用户在上面改字、删掉不想接管的小节即可。
    NSButton *fill = [NSButton buttonWithTitle:L(@"Insert Template") target:self
        action:@selector(fillFromDefault:)];
    fill.translatesAutoresizingMaskIntoConstraints = NO;
    fill.hidden = YES;
    self.fillButton = fill;

    for (NSView *view in @[scroll, status, picker, speak, save, saveAndClose, revert, scope, fill]) {
        [root addSubview:view];
    }

    [NSLayoutConstraint activateConstraints:@[
        [scope.topAnchor constraintEqualToAnchor:root.topAnchor constant:12],
        [scope.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:16],
        [fill.leadingAnchor constraintGreaterThanOrEqualToAnchor:scope.trailingAnchor constant:12],
        [fill.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-16],
        [fill.centerYAnchor constraintEqualToAnchor:scope.centerYAnchor],

        [scroll.topAnchor constraintEqualToAnchor:scope.bottomAnchor constant:10],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:status.topAnchor constant:-8],

        [status.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:16],
        [status.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-16],
        [status.bottomAnchor constraintEqualToAnchor:picker.topAnchor constant:-8],

        [picker.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:16],
        [picker.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-14],
        [picker.widthAnchor constraintLessThanOrEqualToConstant:240],
        [speak.leadingAnchor constraintEqualToAnchor:picker.trailingAnchor constant:8],
        [speak.centerYAnchor constraintEqualToAnchor:picker.centerYAnchor],
        [revert.leadingAnchor constraintGreaterThanOrEqualToAnchor:speak.trailingAnchor constant:8],
        [revert.trailingAnchor constraintEqualToAnchor:save.leadingAnchor constant:-8],
        [revert.centerYAnchor constraintEqualToAnchor:picker.centerYAnchor],
        [save.trailingAnchor constraintEqualToAnchor:saveAndClose.leadingAnchor constant:-8],
        [save.centerYAnchor constraintEqualToAnchor:picker.centerYAnchor],
        [saveAndClose.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-16],
        [saveAndClose.centerYAnchor constraintEqualToAnchor:picker.centerYAnchor],
    ]];

    self.window = window;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(languageDidChange:)
        name:CCPetsLanguageDidChangeNotification object:nil];
}

// 只更新界面文案，保留编辑内容、撤销记录和当前编辑的宠物。
- (void)refreshLocalizedUI {
    self.window.title = L(@"Pet Lines");
    self.speakButton.title = L(@"Try a Line");
    self.saveButton.title = L(@"Save");
    self.saveAndCloseButton.title = L(@"Save & Close");
    self.fillButton.title = L(@"Insert Template");
    [self.scopeControl setLabel:L(@"Shared") forSegment:0];
    [self.scopeControl setLabel:self.scopePetID.length > 0 ?
        [NSString stringWithFormat:L(@"This Pet · %@"),
            [self displayNameForPetID:self.scopePetID]] : L(@"This Pet") forSegment:1];
    [self syncRevertButtonTitle];
    // 更新原有菜单项，不改变用户选中的情境。
    for (NSMenuItem *item in self.tagPicker.itemArray) {
        NSString *tag = item.representedObject;
        item.title = [NSString stringWithFormat:L(@"%1$@ (%2$@)"),
            PetPhraseTagDescription(tag), tag];
    }
}

- (void)languageDidChange:(NSNotification *)notification {
    [self refreshLocalizedUI];
    // 通用词库可能已随语言切换换成新默认内容；有草稿时只刷新界面，不能重载覆盖它。
    if (![self isDirty]) [self reloadFromDisk];
    else [self showCurrentFileStatus];
}

#pragma mark - 编辑范围

// 菜单里显示的宠物名。petID 是 external:哆啦A梦 / builtin:默认.webp，
// 前缀和扩展名对用户没有意义。
- (NSString *)displayNameForPetID:(NSString *)petID {
    NSRange colon = [petID rangeOfString:@":"];
    NSString *name = colon.location == NSNotFound ? petID :
        [petID substringFromIndex:colon.location + 1];
    NSString *extension = name.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"webp"] || [extension isEqualToString:@"png"]) {
        name = name.stringByDeletingPathExtension;
    }
    return name;
}

// 把"当前宠物"那一段的标题换成真名，并处理没有宠物的情况。
//
// 每次打开窗口都要跑：窗口是单例且不随关闭销毁，用户完全可能关掉编辑器、切一只宠物、
// 再打开——那时段标题还停在上一只身上，他会以为自己在给这只写。
- (void)syncScopeToCurrentPet {
    NSString *petID = PetPhrasesCurrentPetID();
    BOOL hasPet = petID.length > 0;
    [self.scopeControl setLabel:hasPet ?
        [NSString stringWithFormat:L(@"This Pet · %@"), [self displayNameForPetID:petID]] :
        L(@"This Pet") forSegment:1];
    [self.scopeControl setEnabled:hasPet forSegment:1];

    // 宠物变了（或没了）而这一页正停在专属范围上：跟着走，但别把用户没存的东西冲掉。
    if (self.petScope && (!hasPet || ![petID isEqualToString:self.scopePetID])) {
        if ([self isDirty] && ![self confirmDiscardChanges]) {
            // 用户选择留在原地。此时 scopePetID 还是老那只，保存仍然落在他看着的那份上。
            return;
        }
        self.petScope = hasPet;
    }
    self.scopePetID = petID;
    if (!hasPet) self.petScope = NO;
    self.scopeControl.selectedSegment = self.petScope ? 1 : 0;
    [self syncRevertButtonTitle];
}

- (void)syncRevertButtonTitle {
    // 专属词库没有"默认"这一说，它的默认状态就是空文件（全部回落到通用）。
    self.revertButton.title = self.petScope ? L(@"Clear Page…") : L(@"Restore Defaults…");
    // 通用页不需要这个按钮：它本来就是从默认台词拷出来的，不存在空白无从下手的问题，
    // 想拿回默认内容有"恢复默认台词…"。
    self.fillButton.hidden = !self.petScope;
}

- (void)scopeChanged:(id)sender {
    BOOL wantPet = self.scopeControl.selectedSegment == 1;
    if (wantPet == self.petScope) return;
    if ([self isDirty] && ![self confirmDiscardChanges]) {
        self.scopeControl.selectedSegment = self.petScope ? 1 : 0;
        return;
    }
    self.petScope = wantPet;
    [self syncRevertButtonTitle];
    [self reloadFromDisk];
}

// 当前这一页对应磁盘上的哪个文件。
- (NSString *)currentFilePath {
    if (!self.petScope) return PetPhrasesFilePath();
    return PetPhrasesFilePathForPetID(self.scopePetID);
}

- (BOOL)isDirty {
    return ![(self.textView.string ?: @"") isEqualToString:self.loadedText ?: @""];
}

- (BOOL)confirmDiscardChanges {
    NSAlert *alert = [NSAlert new];
    alert.messageText = L(@"This Page Isn't Saved");
    alert.informativeText = L(@"Unsaved changes will be lost if you switch.");
    [alert addButtonWithTitle:L(@"Discard Changes")];
    [alert addButtonWithTitle:L(@"Stay")];
    return [alert runModal] == NSAlertFirstButtonReturn;
}

#pragma mark - 读写

- (void)reloadFromDisk {
    // 专属词库不预先生成：空文件和"没有这个文件"在语义上完全一样（都是全部回落到通用），
    // 凭空造一堆空文件只会让 speech/ 目录里全是噪音，用户还得挨个点开确认是不是空的。
    if (!self.petScope) PetPhrasesEnsureFileExists();
    NSString *path = [self currentFilePath];
    NSString *text = [NSString stringWithContentsOfFile:path
        encoding:NSUTF8StringEncoding error:nil] ?: @"";
    self.textView.string = text;
    self.loadedText = text;
    self.loadedStamp = [NSFileManager.defaultManager attributesOfItemAtPath:path
        error:nil][NSFileModificationDate];
    [self showCurrentFileStatus];
}

- (void)showCurrentFileStatus {
    NSString *path = [self currentFilePath];
    if (self.petScope && self.textView.string.length == 0) {
        [self showStatus:[NSString stringWithFormat:
            L(@"%@ · Still empty, so this pet uses the shared lines. Only write the sections you want to change, or click “Insert Template” at the top right to see what's possible."), path]
            warning:NO];
        return;
    }
    [self showStatus:[NSString stringWithFormat:@"%@", path] warning:NO];
}

- (void)showStatus:(NSString *)message warning:(BOOL)warning {
    self.statusLabel.stringValue = message ?: @"";
    self.statusLabel.textColor = warning ? NSColor.systemOrangeColor :
        NSColor.secondaryLabelColor;
}

- (void)save:(id)sender {
    [self performSave];
}

// 保存成功才关窗。失败或被用户取消时留在原地，否则用户的改动会连同窗口一起消失。
- (void)saveAndClose:(id)sender {
    if (![self performSave]) return;
    [self.window close];
}

// 保存时校验，不做实时校验——边打边标红只会干扰输入，而且写到一半的行必然是"错"的。
// 返回是否真的写进了文件（被校验拦下、被 mtime 冲突取消都算没写）。
- (BOOL)performSave {
    // 标签被删掉时先补回原位，并阻止本次保存。
    //
    // 只报错是把人卡死：编辑器里已经看不到那一行了，用户既不知道少的是哪个，也不知道
    // 该写成什么样。补回后仍不能直接写盘——否则“标签不可删除”只是句提示，用户看不到
    // 修复结果就已经覆盖了文件。必须让用户确认恢复位置和内容，再主动保存一次。
    NSArray<NSString *> *restored = nil;
    NSString *text = self.textView.string ?: @"";
    // 专属词库跳过这一步：那份文件本来就该只有用户想改的那几节，把 22 个标签全补进去
    // 正好毁掉它的用法——补完之后每一节都"存在"，等于这只宠物再也不会回落到通用了。
    NSString *repaired = self.petScope ? text : PetPhraseTextWithRestoredTags(text, &restored);
    if (restored.count > 0) {
        // 走 shouldChangeTextInRange: 让这一步能被 ⌘Z 撤销，用户不满意可以退回去。
        NSRange all = NSMakeRange(0, text.length);
        if ([self.textView shouldChangeTextInRange:all replacementString:repaired]) {
            [self.textView.textStorage replaceCharactersInRange:all withString:repaired];
            [self.textView didChangeText];
            text = repaired;
        }
        [self presentIssues:@[] blocking:YES restored:restored];
        return NO;
    }

    NSArray<PetPhraseIssue *> *issues = self.petScope ?
        PetPhraseValidateTextForPet(text) : PetPhraseValidateText(text);
    if (PetPhraseIssuesHaveError(issues)) {
        [self presentIssues:issues blocking:YES restored:restored];
        return NO;
    }
    if (![self confirmNoExternalChange]) return NO;

    NSString *path = [self currentFilePath];
    if (path.length == 0) {
        [self showStatus:L(@"No pet is selected, so pet-specific lines can't be saved.") warning:YES];
        return NO;
    }
    NSError *error = nil;
    // 结尾补一个换行：没有的话下次追加小节会直接粘在最后一句后面。
    NSString *normalized = [text hasSuffix:@"\n"] ? text : [text stringByAppendingString:@"\n"];
    // 专属目录是懒创建的，第一次给某只宠物写台词时才出现。
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil];
    if (![normalized writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        [self showStatus:[NSString stringWithFormat:L(@"Save failed: %@"),
            error.localizedDescription ?: L(@"unknown error")] warning:YES];
        return NO;
    }
    self.loadedStamp = [NSFileManager.defaultManager attributesOfItemAtPath:path
        error:nil][NSFileModificationDate];
    self.loadedText = normalized;

    if (issues.count > 0) {
        [self presentIssues:issues blocking:NO restored:nil];
        [self showStatus:[NSString stringWithFormat:issues.count != 1
            ? L(@"Saved, with %lu notices") : L(@"Saved, with %lu notice"),
            (unsigned long)issues.count] warning:YES];
        return YES;
    }
    [self showStatus:L(@"Saved. Takes effect now.") warning:NO];
    return YES;
}

// 外部编辑器可能同时改了这个文件。直接覆盖会静默吃掉别人的改动，所以问一次。
- (BOOL)confirmNoExternalChange {
    NSDate *current = [NSFileManager.defaultManager
        attributesOfItemAtPath:[self currentFilePath] error:nil][NSFileModificationDate];
    if (!current || !self.loadedStamp || [current isEqualToDate:self.loadedStamp]) return YES;

    NSAlert *alert = [NSAlert new];
    alert.messageText = L(@"File Changed on Disk");
    alert.informativeText = L(@"Another app changed the lines file after the editor opened it. Saving will overwrite those changes.");
    [alert addButtonWithTitle:L(@"Overwrite")];
    [alert addButtonWithTitle:L(@"Cancel")];
    [alert addButtonWithTitle:L(@"Reload")];
    NSModalResponse response = [alert runModal];
    if (response == NSAlertSecondButtonReturn) return NO;
    if (response == NSAlertThirdButtonReturn) {
        [self reloadFromDisk];
        return NO;
    }
    return YES;
}

- (void)presentIssues:(NSArray<PetPhraseIssue *> *)issues blocking:(BOOL)blocking
    restored:(NSArray<NSString *> *)restored {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    // 补回标签这件事必须说在最前面：用户看到的文本被我们改过了，不说清楚就是偷偷动手。
    if (restored.count > 0) {
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSString *tag in restored) {
            [names addObject:[NSString stringWithFormat:L(@"[%1$@] (%2$@)"), tag,
                PetPhraseTagDescription(tag)]];
        }
        [lines addObject:[NSString stringWithFormat:
            L(@"Tags can't be deleted, so %@ was put back in place (⌘Z to undo)."),
            [names componentsJoinedByString:@"、"]]];
        if (blocking) [lines addObject:L(@"Nothing was saved. Check the restored tags, then save again.")];
        [lines addObject:@""];
    }
    for (PetPhraseIssue *issue in issues) {
        NSString *prefix = issue.level == PetPhraseIssueLevelError ? L(@"Must fix: ") : L(@"Note: ");
        NSString *where = issue.line > 0 ?
            [NSString stringWithFormat:L(@"Line %ld "), (long)issue.line] : @"";
        [lines addObject:[NSString stringWithFormat:@"%@%@%@", prefix, where, issue.message]];
        // 一屏放不下就没人看了，剩下的等改完这批再报。
        if (lines.count >= 12) {
            [lines addObject:[NSString stringWithFormat:L(@"…and %lu more"),
                (unsigned long)(issues.count - lines.count + 1)]];
            break;
        }
    }
    NSAlert *alert = [NSAlert new];
    if (blocking) {
        alert.messageText = L(@"Can't Save Yet");
    } else {
        alert.messageText = issues.count > 0 ? L(@"Saved, but Some Lines Won't Be Used") : L(@"Saved");
    }
    alert.informativeText = [lines componentsJoinedByString:@"\n"];
    alert.alertStyle = blocking ? NSAlertStyleWarning : NSAlertStyleInformational;
    [alert addButtonWithTitle:L(@"OK")];
    [alert runModal];
    if (blocking) {
        [self showStatus:restored.count > 0 ?
            L(@"Tags restored, nothing saved yet. Check and save again.") :
            L(@"Some problems must be fixed before saving.") warning:YES];
    }
}

#pragma mark - 试说一句

// 对着编辑器里【还没保存】的文本取，这样用户改完不用先保存就能听到效果。
- (void)speakSample:(id)sender {
    NSString *tag = self.tagPicker.selectedItem.representedObject;
    NSString *draft = self.textView.string ?: @"";
    // 专属这一页没写这一节时，桌宠实际会说通用词库里的那一节——预览必须走同一条路，
    // 否则用户看到"[idle] 里没有能说的句子"，会以为这只宠物闲着的时候是哑的。
    BOOL fellBack = NO;
    if (self.petScope && !PetPhraseTextContainsTag(draft, tag)) {
        draft = [NSString stringWithContentsOfFile:PetPhrasesFilePath()
            encoding:NSUTF8StringEncoding error:nil] ?: @"";
        fellBack = YES;
    }
    NSString *text = PetPhraseForTagInText(tag, draft, [self sampleSlots]);
    if (text.length == 0) {
        [self showStatus:[NSString stringWithFormat:L(@"[%@] has no usable lines."), tag] warning:YES];
        return;
    }
    if (PetPhrasesSpeakHandler) PetPhrasesSpeakHandler(text);
    [self showStatus:[NSString stringWithFormat:L(@"Trying: %1$@%2$@"), text,
        fellBack ? L(@" (from the shared lines)") : @""] warning:NO];
}

// 预览用的假数据。用真实数据的话，没在跑 agent 时 {toolName} 之类全是空的，
// 带槽位的句子会被整条跳过，用户会以为自己写错了。
- (NSDictionary<NSString *, NSString *> *)sampleSlots {
    return @{
        @"quota5h": @"12%", @"resetTime": @"18:30", @"toolName": @"Bash",
        @"sessionMin": @"95", @"failCount": @"3", @"hour": @"2",
    };
}

#pragma mark - 填入默认台词

// 给空白的专属页一个起点，同时**不破坏回落**。
//
// 直接填入完整的默认台词是错的：那样 22 个小节全都"存在"，这只宠物从此每一节都自己
// 管，再也不会回落到通用词库——正好毁掉专属词库的全部用法。
//
// 所以填进来的是整份**注释状态**的默认台词。用户看得见每一节可以写什么（这才是空白页
// 真正缺的东西），而注释行在解析时一行都不算数，所以填完之后这只宠物说的仍然全是通用
// 台词，什么都没变。想让哪一节归它自己管，把那一节的 # 去掉再改字。
//
// 也不做成"只填小节头、不填台词"的骨架：那样每一节都存在且为空，按语义等于这只宠物
// 在所有情境下全部闭嘴，比空白页更糟——用户点完初始化，桌宠反而一句话都不说了。
- (NSString *)commentedDefaultText {
    NSString *defaults = [NSString stringWithContentsOfFile:PetPhrasesDefaultFilePath()
        encoding:NSUTF8StringEncoding error:nil];
    if (defaults.length == 0) return nil;

    NSString *petName = self.scopePetID.length > 0 ?
        [self displayNameForPetID:self.scopePetID] : L(@"this pet");
    NSMutableString *text = [NSMutableString stringWithFormat:
        L(@"# ↓↓↓ Lines just for %1$@. Everything below is commented out and inactive ↓↓↓\n"
        "#\n"
        "# To give %1$@ its own lines for a situation, uncomment that tag and write lines under it\n"
        "# An uncommented tag with no lines keeps the pet quiet in that situation\n"
        "# Tags left commented out fall back to the shared lines\n"
        "\n"), petName];

    for (NSString *line in [defaults componentsSeparatedByString:@"\n"]) {
        // 已经是注释的行不再叠一层 #，双井号只是噪音。空行保持空行，
        // 不然满屏 "#" 会把小节之间的呼吸感全填满。
        if (line.length == 0) { [text appendString:@"\n"]; continue; }
        [text appendFormat:[line hasPrefix:@"#"] ? @"%@\n" : @"# %@\n", line];
    }
    return text;
}

- (void)fillFromDefault:(id)sender {
    NSString *text = [self commentedDefaultText];
    if (text.length == 0) {
        [self showStatus:L(@"Default lines file not found.") warning:YES];
        return;
    }
    // 空白页直接填，不打断——那正是这个按钮存在的理由。已经写了东西才问一句。
    if ((self.textView.string ?: @"").length > 0) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = L(@"Overwrite This Page?");
        alert.informativeText = L(@"This page will be replaced with the full default lines (all commented out). Nothing is saved yet; ⌘Z undoes it.");
        [alert addButtonWithTitle:L(@"Overwrite")];
        [alert addButtonWithTitle:L(@"Cancel")];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
    }
    // 走 shouldChangeTextInRange: 而不是直接设 string，这样这一步能被 ⌘Z 撤销。
    NSRange all = NSMakeRange(0, self.textView.string.length);
    if (![self.textView shouldChangeTextInRange:all replacementString:text]) return;
    [self.textView.textStorage replaceCharactersInRange:all withString:text];
    [self.textView didChangeText];
    [self showStatus:L(@"Default lines inserted, all commented out and inactive. Remove the # in front of a section to make it this pet's own.") warning:NO];
}

#pragma mark - 恢复默认 / 清空

- (void)revertToDefault:(id)sender {
    NSAlert *alert = [NSAlert new];
    // 专属词库的"默认状态"就是空白：清空 = 这只宠物全部回落到通用台词。
    // 拿默认词库去填它是错的——那等于把 22 个小节全部标成"专属接管"，再也不会回落。
    alert.messageText = self.petScope ? L(@"Clear This Pet's Lines?") : L(@"Restore Default Lines?");
    alert.informativeText = self.petScope ?
        L(@"After clearing, this pet goes back to the shared lines. Nothing is saved yet; ⌘Z undoes it.") :
        L(@"The editor content will be replaced with the default lines. Nothing is saved yet; ⌘Z undoes it.");
    [alert addButtonWithTitle:self.petScope ? L(@"Clear") : L(@"Restore")];
    [alert addButtonWithTitle:L(@"Cancel")];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    NSString *text = @"";
    if (!self.petScope) {
        text = [NSString stringWithContentsOfFile:PetPhrasesDefaultFilePath()
            encoding:NSUTF8StringEncoding error:nil];
        if (text.length == 0) {
            [self showStatus:L(@"Default lines file not found.") warning:YES];
            return;
        }
    }
    // 走 shouldChangeTextInRange: 而不是直接设 string，这样这一步能被 ⌘Z 撤销。
    NSRange all = NSMakeRange(0, self.textView.string.length);
    if (![self.textView shouldChangeTextInRange:all replacementString:text]) return;
    [self.textView.textStorage replaceCharactersInRange:all withString:text];
    [self.textView didChangeText];
    [self showStatus:self.petScope ? L(@"Cleared. Click Save to write it to the file.") :
        L(@"Default lines inserted. Click Save to write them to the file.") warning:NO];
}

@end
