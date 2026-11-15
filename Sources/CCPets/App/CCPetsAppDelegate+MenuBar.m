// 显示位置：仅桌宠 / 桌宠 + 菜单栏 / 仅菜单栏。
//
// 「仅菜单栏」只关掉桌面上看得见的东西：桌宠窗口、状态卡、说话气泡、悬停面板和更新气泡。
// 事件读取、会话记录、额度采集、系统通知照常运行，菜单栏图标和主窗口都靠它们。
// 浮层各自的显示入口在 petVisible 为 NO 时直接不弹，不在这里逐个追着关。
#import "CCPetsAppDelegate+Private.h"

@implementation AppDelegate (MenuBar)

- (BOOL)petVisible {
    return ![CCPetsDisplayMode() isEqualToString:CCPetsDisplayModeMenuBar];
}

- (BOOL)menuBarVisible {
    return ![CCPetsDisplayMode() isEqualToString:CCPetsDisplayModePet];
}

- (void)updateDisplayMode:(NSString *)mode {
    if (CCPetsPrefSetObject(CCPetsDisplayModeKey, mode)) [self applyDisplayMode];
}

// 菜单栏图标自己监听设置变更，改完数字当场刷新。
- (void)updateMenuBarShowsPercent:(BOOL)enabled {
    CCPetsPrefSetBool(CCPetsMenuBarShowsPercentKey, enabled);
}

- (void)applyDisplayMode {
    if ([self menuBarVisible] && !self.statusItemController) {
        [self installStatusItem];
    } else if (![self menuBarVisible] && self.statusItemController) {
        [self.statusItemController invalidate];
        self.statusItemController = nil;
    }
    if ([self petVisible]) [self showPetWindows];
    else [self hidePetWindows];
    [self.statusItemController refresh];
}

- (void)installStatusItem {
    CCPetsStatusItemController *controller = [[CCPetsStatusItemController alloc] initWithSource:(id)self];
    __weak typeof(self) weakSelf = self;
    controller.petVisibleProvider = ^BOOL { return [weakSelf petVisible]; };
    controller.stateColorProvider = ^NSColor *(NSString *state) { return [weakSelf statusColorForState:state]; };
    // 菜单栏图标只在「桌宠 + 菜单栏」和「仅菜单栏」下存在，勾选项就在这两者之间切换。
    controller.togglePetVisible = ^{
        [weakSelf updateDisplayMode:[weakSelf petVisible] ? CCPetsDisplayModeMenuBar : CCPetsDisplayModeBoth];
    };
    controller.pendingUpdateVersionProvider = ^NSString * {
        return weakSelf.updating ? nil : weakSelf.pendingUpdateVersion;
    };
    controller.showPendingUpdate = ^{ [weakSelf showPendingUpdate:nil]; };
    // 右键和桌宠右键同一份菜单：启用 CC Bridge、免审批这些只在那里，仅菜单栏时不能没有入口。
    controller.contextMenuProvider = ^NSMenu * { return [weakSelf.petView buildContextMenu]; };
    controller.contextMenuFinished = ^{ [weakSelf.petView finishContextMenu]; };
    self.statusItemController = controller;
}

- (void)showPetWindows {
    [self.panel orderFrontRegardless];
    [self.petView setAnimationSuspended:NO];
    // 状态卡按原来的偏好还原；没有活跃会话时 updateStatusBubbleExpanded: 自己会保持隐藏。
    [self updateStatusBubbleExpanded:self.statusBubbleExpanded];
    [self refreshUpdateBadge];
}

- (void)hidePetWindows {
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(hideQuotaDashboardIfNeeded) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(hideSpeechBubble) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(restoreStatusDetail) object:nil];
    self.pocketHovering = NO;
    self.dashboardHovering = NO;
    self.updateBubbleVisible = NO;
    self.updateBubbleSuppressedStatus = NO;
    [self.quotaPanel orderOut:nil];
    [self.speechPanel orderOut:nil];
    [self.statusPanel orderOut:nil];
    [CCPetsGlassMenu dismiss];
    [self.panel orderOut:nil];
    // 看不见的宠物不必逐帧动画，和屏幕睡眠走同一个开关。
    [self.petView setAnimationSuspended:YES];
}

@end
