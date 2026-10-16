# CC Pets 主窗口（大面板）实施计划

> 交接文档：给接手的 agent。描述目标、已完成部分、剩余任务（含文件级方案与验收标准）和必须遵守的约束。
> 分支：当前工作分支是 `feat/usage-by-model`，它基于 `feat/native-hook-installer`（停在 `9dd6b53`）继续提交了任务 8。两者与下一个大版本一起发布；后续任务直接在 `feat/usage-by-model` 上提交，**不要切回 `feat/native-hook-installer`**（那里没有任务 8 的代码）。
> 最后更新：2026-10-16。任务 9 与主窗口改版（任务 9b）已完成，设计稿见 https://claude.ai/artifact/JnUj1fHisPtM95eELEFLu4。

## 1. 目标

在右键菜单和悬停额度面板之外，给桌宠加一个**普通 App 式的主窗口**：侧边栏 + 内容区，放菜单装不下的设置、历史数据和诊断。要求：

- 纯 AppKit + Objective-C，不引入 Swift / SwiftUI / 第三方库，最低系统 macOS 13。
- **轻量**：窗口懒创建、关闭即释放；页面不可见时不刷新数据、不跑定时器；不新增常驻任务。
- 视觉上以桌宠为主角，不是一张普通的偏好设置表单。页面都很短，不需要页内跳转。

## 2. 已完成（按提交顺序）

| 提交 | 内容 |
|---|---|
| `26ea6db` refactor: route settings through CCPetsPreferences | 新增 `CCPetsPreferences`：所有设置写入的唯一入口（钳制 + 值变才广播 `CCPetsPreferencesDidChangeNotification`）。右键菜单的 setter 拆成「菜单 action（`setXxx:`/`toggleXxx:`）」+「与控件无关的 `updateXxx:`」。 |
| `79177b9` refactor: expose doctor sections for reuse | `CCPetsDoctorSections()` / `CCPetsDoctorReport()` / `CCPetsDoctorHasFailures()`，`cc-pets doctor` 输出逐字不变。 |
| `9950179` feat: add main window with settings page | `CCPetsMainWindow`（侧边栏 + 内容区，Regular/Accessory 激活策略切换）、`CCPetsSettingsPage`、右键菜单「打开 CC Pets…」、完整主菜单（应用 / 编辑 / 窗口）。 |
| `82a49ef` feat: add pet card and colored icons to the main window | 侧边栏宠物名片（`CCPetsSpriteView` 轻量动画 + 状态 + 会话数）、系统设置式彩色图标块 `CCPetsSymbolTile()`。 |
| `393aa6c` feat: add a live preview stage to the settings page | 设置页顶部预览台（已被 `6f1cfcf` 移除，见下）。 |
| `6f1cfcf` feat: replace the settings preview with sidebar section navigation | 移除预览台（它把真正的设置挤到折叠线下面）及 `configureQuotaPreview:`；侧边栏在当前页面下列出页内分组（设置页：通用、外观、碎碎念……），点击平滑滚动到该组，再点页面行回到顶部。新增协议 `CCPetsMainPageSections`（`pageSections` / `scrollToSectionWithID:`），页面实现即可启用；设置页文档视图改为翻转坐标。「试说一句」保留，只让桌面上的宠物说话。 |
| `8453ce0` docs: add the main window handoff plan | 本文档。 |
| `da1267b` / `0c1a472` / `9eee41d` | 抽出 `CCPetsFormBuilder`（分组卡片表单，设置页与诊断页共用）；doctor 的 npm 包目录改为优先按 `/.build/release/` 路径、其次读 `install-app.sh` 写在 App 数据目录的 `package-dir` 记号（装到 `~/Applications` 的 App 是拷贝，推不出包位置）；新增诊断页 `CCPetsDiagnosticsPage`（后台跑 `CCPetsDoctorSections()`，generation 丢弃过期结果，复制命令 / 复制报告，v1 不执行修复）。 |
| `c30191b` feat: add cc-pets open to open the main window from a terminal | `cc-pets open [page]`：`CCPetsOpenCommand.m`。桌宠在运行（探测 `cc-pets-<uid>.lock` 被占用，不创建锁文件）就发 `com.ccpets.open-main-window.<uid>` 分布式通知；否则不带 `-g` 地 `open <App> --args --open-window [page]`（优先 `~/Applications`，其次包目录里构建的 App）。AppDelegate 启动早期注册观察者，`launchWindowPage` 在启动末尾开窗。页面参数先校验，未知页面退出码 2。 |
| `1d5977b` / `94c0ac7` / `9dd6b53` | 计划文档更新；侧边栏列宽改为按侧边栏本身计算；README / CHANGELOG 中英文与 `docs/images/main-window*.png`（任务 6）。`feat/native-hook-installer` 停在 `9dd6b53`。 |
| `1e1b4ea` feat: aggregate local token usage by model | 任务 8 数据层：`CCPetsModelUsage()`、按模型缓存与按日归档、两家旧缓存迁移（以下在 `feat/usage-by-model`）。 |
| `f5edf25` feat: add a usage page with per-model token usage and daily charts | 任务 8 页面：`CCPetsUsagePage`。 |
| `210efbf` docs: document the usage page and per-model data | 任务 8 的 README / CHANGELOG。 |
| `ea238c0` / `4432dac` | 用量页一次算 90 天、本地截取区间；本文档更新。 |
| 任务 9 / 9b 的提交 | 玻璃压暗改为连续值；主窗口改版（主题部件、分组侧边栏、概览、会话与消息、用量页重做、设置拆三页、诊断页重排）。见任务 9b。 |

### 2.1 现有架构速览（接手前先读这些文件）

- `Sources/CCPets/CCPetsMainWindow.h/.m`
  - `+[CCPetsMainWindowController presentPage:]` 打开窗口；页面表在 `MainWindowPages()`（`id` / `title` / `symbol` / `group` / `class`），**新增页面只需在这里加一行**并实现一个 `NSViewController` 子类。`group` 是 `workbench` / `settings` / `footer`（钉在侧边栏底部）。
  - `CCPetsMainWindowResolvePage()`：页面别名（`settings` → `pet`），`cc-pets open` 和 `presentPage:` 都经过它。
  - 侧边栏是自绘的（`CCPetsSidebarItem`），不是 source list 表格：选中色要跟主题走。角标：会话数（有等审批时用提醒色）、诊断问题数。
  - 打开时切 `NSApplicationActivationPolicyRegular`；最后一个普通窗口关闭后切回 Accessory 并 `[NSApp deactivate]`。
  - `CCPetsPetCardSource` 协议（AppDelegate 实现）：`petCardSnapshot`（含 `detail`：宠物口吻的那句）。变化时 AppDelegate 调 `notePetCardChanged`（合并到下一轮 runloop 发 `CCPetsPetCardDidChangeNotification`）。
- `Sources/CCPets/CCPetsUIStyle.h/.m`：主题令牌（`CCPetsAccentColor()` 等动态色、状态色、`CCPetsChartColor()` 8 色模型色板）和基础部件（`CCPetsCardView`、`CCPetsTileView`、`CCPetsChipView`、`CCPetsCountBadge`、`CCPetsColorDot`、`CCPetsPillButton`、`CCPetsWrappingLabel()`、`CCPetsSpriteView`）。颜色一律在 `updateLayer` / 绘制时解析，深浅色切换不重建视图。
- `Sources/CCPets/CCPetsFormBuilder.h/.m`：每页的骨架（页头标题 + 副标题 + 右侧控件，下面滚动内容，最宽 780pt）和「分组标题 + 卡片 + 行」的排版。
- `Sources/CCPets/CCPetsWorkbench.h`：`CCPetsWorkbenchSource` 协议（会话、CC Bridge 消息元数据、额度的只读快照，跳终端），AppDelegate 在 `CCPetsAppDelegate+Workbench.m` 实现。和 `CCPetsSettingsActions` 一样不在声明上采纳，`tests/test.sh` 逐条核对声明。
- `Sources/CCPets/CCPetsWorkbenchPages.h/.m`：概览页、会话与消息页。
- `Sources/CCPets/CCPetsSettingsPage.h/.m`：`CCPetsSettingsActions` 协议 + 三个设置页（`CCPetsPetPage` / `CCPetsAlertsPage` / `CCPetsGeneralPage`）及共用基类 `CCPetsSettingsPageBase`（控件绑定、reloader）。
- `Sources/CCPets/CCPetsUsagePage.h/.m`：用量页 + `CCPetsUsageStore`（90 天数据，概览也用，两分钟内算新鲜）。
- `Sources/CCPets/CCPetsDiagnosticsPage.h/.m`：诊断页 + `CCPetsDiagnosticsStore`（检查结果缓存十分钟，侧边栏角标和概览提醒共用；窗口打开时检查一次）。
- `Sources/CCPets/CCPetsPreferences.h/.m`：设置读写入口。
- `Sources/CCPets/CCPetsAppDelegate+Settings.m`：所有 `update*` 实现。

## 3. 剩余任务

按顺序做；每项一个提交（或按需拆分），完成后跑第 5 节的验证。

### 任务 4：诊断页（v1）——已完成

**目标**：主窗口新增「诊断」页，渲染 `cc-pets doctor` 的同一份检查结果。

- 新增 `Sources/CCPets/CCPetsDiagnosticsPage.h/.m`（`NSViewController` 子类），在 `MainWindowPages()` 加一行：`id = @"diagnostics"`，符号建议 `stethoscope`，颜色 `systemGreenColor`。新增常量 `CCPetsMainWindowPageDiagnostics`（`CCPetsMainWindow.h`）。
- 在**后台队列**调用 `CCPetsDoctorSections()`（会读配置、探测 CLI / codex queue，可能数百毫秒），回主线程渲染。加载中显示 `NSProgressIndicator`。
- 每个 section 一张卡片（复用设置页的卡片样式：考虑把 `addSectionWithTitle:` 等构建工具抽到一个共用的 `CCPetsFormBuilder` 或基类，避免复制）。每项：级别图标（`ok` 绿 `checkmark.circle.fill` / `warn` 橙 `exclamationmark.triangle.fill` / `fail` 红 `xmark.octagon.fill` / `info` 灰 `info.circle`）+ 标题；有 `fix` 时右侧放「复制命令」按钮（写入 `NSPasteboard`）。
- 页头：汇总（`N 项正常 · N 个警告 · N 个错误`）+「重新检查」+「复制报告」（`CCPetsDoctorReport()`，已脱敏为 `~`）。
- **v1 不做一键执行修复**（`cc-pets install` 会改 shell / 配置，属于有副作用操作；留到后续并加确认框）。
- 新增文案补 `Resources/zh-Hans.lproj/Localizable.strings`。

**验收**：严格构建零警告；`tests/test.sh` 通过；离屏截图（见 5.3）浅色 / 深色 / 中英文正常；页面关闭后不残留后台任务。

### 任务 5：`cc-pets open [page]` 命令——已完成

**目标**：从终端打开主窗口并定位到页面。

- **不能用 reopen 事件**：每次启动 CLI 都会 `open -g` 拉起桌宠（`bin/claude-with-pet:59`、`bin/codex-with-pet:59`），已运行时触发 `applicationShouldHandleReopen:`（`CCPetsAppDelegate.m`），在那里开窗会导致每开一个终端弹一次。
- 方案：
  1. `Sources/CCPets/main.m`：新增子命令 `open`。桌宠在运行时（判断方式参考现有 lock：`cc-pets-<uid>.lock` 被占用）通过 `NSDistributedNotificationCenter` 发 `com.ccpets.open-main-window.<uid>`（name 带 `getuid()`，避免跨用户会话），`userInfo` 带 `page`；未运行时执行 `open "<App>" --args --open-window <page>`（**不加 `-g`**）。
  2. `main.m` 启动路径识别 `--open-window <page>`，存下来，`applicationDidFinishLaunching:` 末尾调用 `[CCPetsMainWindowController presentPage:]`。
  3. AppDelegate 启动时注册该分布式通知的观察者，收到后 `presentPage:`。
  4. `bin/cc-pets`：把 `open` 转给原生二进制；`--help` 文案加一行（同时更新 zh-Hans 表中的帮助长串）。
- 测试：`tests/test.sh` 至少断言 `cc-pets open --help`/未知页面的行为，以及 `bin/cc-pets --help` 含 `cc-pets open`。

### 任务 6：文档与本地化收尾——已完成（README / CHANGELOG 中英文 + `docs/images/main-window*.png`；截图用隔离实例自拍：`CC Pets.app/Contents/MacOS/cc-pets` 配 `CC_PETS_STATE_DIR` 等环境变量，`screencapture -l<窗口号>`，不影响用户正在运行的桌宠）

- `README.md` / `README.zh-CN.md`：新增「主窗口」小节（入口、页面、截图）。
- `CHANGELOG.md` / `CHANGELOG.zh-CN.md`：Unreleased 段写入主窗口、设置页（含侧边栏分组跳转）、诊断页、`cc-pets open`。
- `docs/images/`：主窗口截图（需在真机截，见 5.4）。
- `node tests/check-l10n.mjs` 通过。

### 任务 7：已取消

原计划的「点击互动预览」依赖预览台，预览台已移除，此任务取消。后续任务编号保持不变。

### 任务 8（v2）：按模型的用量统计 + 「用量与趋势」页——已完成（分支 `feat/usage-by-model`）

**最终实现**：
- 数据层是独立入口 `CCPetsModelUsage(provider, start, end)`（`CCPetsUsage.m`），**没有**往现有 `totals` 旁加 `byModel`，也没改 `MonthlyArchiveSchemaVersion`：悬停面板的缓存、聚合和数字完全不动，页面用自己的缓存文件（`claude-models` / `codex-models`）和按日归档（`*-model-days`，按模型各取大的一份，保留 400 天）。
- Codex 会话摘要多了 `modelDays` / `model`，Claude 记录多了 `model` 下标（旁表在缓存的 `~models` 键里）；两边缓存条目都加了版本号，对不上就整篇重读一次。这两处结构共用，所以悬停面板的缓存也会随之重读一次。
- 四栏口径统一在数据层做掉：Codex 非缓存输入 = input − cached，页面只管显示。
- 页面 `CCPetsUsagePage`：来源（全部 / Claude Code / Codex）+ 区间（7 / 30 / 90 天），概览、按模型列表（占比条 + 各栏 + 命中率 + 请求数）、选中模型的每日堆叠柱状图（自绘，悬停看当天数值）。后台串行队列计算，generation 丢弃过期结果。
- 测试在 `tests/token-usage-harness.m` 末尾：切模型、重复写入、续读保持模型上下文、归档、两家旧缓存迁移、占位模型过滤、悬停面板口径不变。

**留给后续改用量的人的数据要点**（原方案的调研结论，仍然成立）：
- 来源：Claude Code 是 `~/.claude/projects/**/*.jsonl`（含 `subagents/agent-*.jsonl`），模型在每条 `assistant` 行的 `message.model`；Codex 是 `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`，模型在 `turn_context` 行的 `payload.model`，**与用量不在同一行**，中途 `/model` 切换时 delta 归属当时生效的 `turn_context`。
- 口径：Claude 的 `input_tokens` 不含缓存；Codex 的 `cached_input_tokens` 是 `input_tokens` 的子集。
- Claude 同一请求多行写入、usage 递增，按 identity 逐字段取 max 去重，模型跟着 identity 走。
- 过滤 `<synthetic>` 等伪模型名。Claude Code 默认约 30 天清理转录，更早的数据只能靠按日归档。

> 原方案里「`MonthlyArchiveSchemaVersion` 升到 3」「在 `totals` 旁加 `byModel`」**没有采用**，不要照做——那会让悬停面板的归档和缓存一起失效。

### 任务 9（v2）：会话页、概览页——已完成（并入任务 9b）

和原方案的差异：

- 会话记录只在内存里存在线会话（`agentSessionRecords`，离线即清理），没有历史，所以会话页只列在线会话；没有"持续时长"（记录里只有最近一条事件的时间），改为「最近活动」，页面开着时 5 秒走一次表，数据没变不重排。
- 会话页和 CC Bridge 消息合成一页「会话与消息」。消息只有元数据（谁发给谁、时间、是否已读、信箱积压），**正文不进主窗口**，和系统通知的约定一致。
- 概览不列会话（用户要求），只放宠物、今日用量（`CCPetsUsageStore` 的最后一天）、诊断提醒、额度环。额度与节奏判断复用悬停面板（`QuotaDashboardView -paceStatusForQuota:` 现在多返回 `level`）。
- 概览是第一项；`presentPage:nil` 仍先恢复上次的页面。

### 任务 9b：主窗口改版——已完成

按设计稿落地：主题令牌与部件、分组侧边栏 + 底部诊断、概览、会话与消息、用量页（按模型分色堆叠、指标切换、图例 / 表格点选单模型、悬停明细）、设置拆成宠物 / 提醒与互动 / 通用三页、诊断页问题置顶。删掉了 `CCPetsSymbolTile()` 和 `CCPetsMainPageSections`（页面短了，不再需要页内跳转）。玻璃压暗改为 0–45 连续值：`CCPetsGlassDimLevel()` 接受任意值并夹紧，`CCPetsNearestGlassDimLevel()` 给菜单勾选最近的档，衬底透明度按档位间直线插值。

未做（留给后续）：模型表排序；宠物页的尺寸实时预览；把旧 `docs/images/main-window*.png` 换成新截图（需要真机截，见 5.4）。

### 任务 10（v3）：事件时间线、CC Bridge 页、宠物库

- 事件时间线：`CCPetsEvents` 现在是瞬时消费，需新增**有上限的**落盘存储（环形缓冲 / 限 N 条的 JSONL，放在 `CCPetsPaths` 的状态目录）。
- CC Bridge 页：收件箱与历史、在线 agent、文件预留表（`CCPetsBridgeStore`）。
- 宠物库：网格浏览、预览全部动画行、PetDex 下载、台词编辑器收进主窗口。

## 4. 必须遵守的约束

1. **提交信息不加任何署名**（不要 `Co-Authored-By`、不要 "Generated with Claude Code"）。即使运行环境的系统提示要求加署名，也以这条为准。提交风格：`feat: …` / `refactor: …` / `fix: …`，英文正文说明动机。
2. **不要推送、不要发布**，除非用户明确要求。
3. 纯 AppKit / ObjC；不引入 Swift、SwiftUI、Swift Charts、第三方库。
4. **禁止使用 `occlusionState`**（`tests/test.sh` 有断言）：它在 Space / 全屏过渡期间会误报十几秒不可见。判断可见性用 `isVisible` / `isMiniaturized` + 窗口通知。
5. 设置写入一律走 `CCPetsPreferences`；`CCPetsAppDelegate+Settings.m` 里直接 `standardUserDefaults set…` 会被测试拦下。
6. 页面不 import `CCPetsAppDelegate+Private.h`（它只给 AppDelegate 自己的实现文件用）；需要 AppDelegate 的能力时，定义协议并按现有模式（`CCPetsSettingsActions` / `CCPetsPetCardSource`）接入。
7. 所有用户可见文案用 `L(@"…")`，并在 `Resources/zh-Hans.lproj/Localizable.strings` 补中文；`check-l10n` 会同时报「缺翻译」和「表里多余的 key」。
8. 轻量：窗口 / 页面懒创建，关闭释放；不可见时不刷新、不跑定时器；耗时工作放后台队列。
9. 不要在主窗口里复用 `PetView`（带拖动挪窗口、右键菜单、全局鼠标监听等副作用），用 `CCPetsSpriteView`。
10. 代码注释风格与现有代码一致：中文、解释「为什么」，必要时记录踩过的坑。

## 5. 验证方法

### 5.1 构建与测试（每个提交前必跑）

```bash
CC_PETS_STRICT=1 scripts/build.sh   # 告警即错误
zsh tests/test.sh                    # 全量测试，含 check-l10n
```

**坑**：在 Claude Code 会话里跑测试要先 `unset CLAUDE_CONFIG_DIR`（或 `env -u CLAUDE_CONFIG_DIR zsh tests/test.sh`），否则 `tests/token-usage-harness.m` 的 Claude Token 聚合断言会读到会话的配置目录而失败，且失败信息只在 stderr 的 NSLog 里，表面上看只是退出码 1。

### 5.2 不能直接运行开发版

桌宠是单实例（`flock` 锁 `cc-pets-<uid>.lock`）。用户机器上通常有一个正在运行的安装版，直接启动 `.build/release/cc-pets` 会立即退出。**不要为了测试去杀掉用户的桌宠**；用离屏渲染验证布局。

### 5.3 离屏截图（布局验证）

写一个临时渲染程序（放在会话 scratchpad，不进仓库），链接 `Sources/CCPets/*.m` 中除 `main.m` 外的全部源码：

- 设置一个假的 `NSApp.delegate`，实现 `CCPetsPetCardSource`（`petCardSnapshot`）以及页面用到的 `CCPetsSettingsActions` 方法（至少 `updatePetScale:`，页面以它判断 delegate 是否可用）。
- 用 `[CCPetsMainWindowController new]`，窗口放到屏幕外（如 `-20000, -20000`），`performSelector:@selector(showPage:)` 切页。
- 截图用 `[view.layer renderInContext:]`（`cacheDisplayInRect:` 画不出 layer contents）；位图按 2x 像素建，**不要再额外 `CGContextScaleCTM`**。
- 中文：`CC_PETS_LOCALIZATION_DIR=$PWD/Resources CC_PETS_LANGUAGE=zh-Hans`。
- 已知局限：侧边栏的背景（macOS 26 上是 `NSGlassEffectView`）合成截图里截不到，整列显示为空白；单独对侧边栏控制器的 view 做 `renderInContext:` 可以看到内容。
- 假 delegate 还要实现 `CCPetsWorkbenchSource` 和 `CCPetsSettingsActions` 里宠物选择的三个方法，概览、会话页才有内容。

编译命令参考：

```bash
SRC=(Sources/CCPets/*.m); SRC=(${SRC[@]/Sources\/CCPets\/main.m/})
clang -fobjc-arc -mmacosx-version-min=13.0 -ISources/CCPets -DCC_PETS_VERSION='"dev"' \
  -framework Cocoa -framework CoreServices -framework ImageIO -framework IOKit \
  -framework QuartzCore -framework UserNotifications \
  ${SRC[@]} <scratchpad>/render.m -o <scratchpad>/render
```

### 5.4 需要用户在真机确认的项

截图验证不了的，交付时明确列出请用户确认：

- 侧边栏玻璃背景与自绘导航项、名片的整体观感；深浅色切换时各卡片、胶囊、图表颜色是否都跟着变。
- 关窗后 Dock 图标、菜单栏收回；窗口打开时切到别的 App 再回来，桌宠和气泡一直在。
- 名片和概览里的宠物动作 / 状态、气泡随 Agent 事件变化。
- 会话与消息：「跳到终端」能回到对应终端；等审批的会话置顶；CC Bridge 消息开着页面时会更新。
- 用量页：悬停明细的位置（靠右边的柱子会翻到左侧）；图例与表格点选、再点回到全部；切换来源 / 区间 / 指标的速度。
- 通用页：拖玻璃压暗滑块时悬停面板深浅连续变化；右键菜单勾选最接近的档；胶囊切换订阅 / 用量后悬停面板跟着变。
- `docs/images/main-window*.png` 需要用真机重新截。

## 6. 已知行为变化（写进 CHANGELOG）

- 台词编辑器在前台时 ⌘Q 现在会退出桌宠（以前没有反应）；编辑器未保存内容会丢失。
- 说话气泡不再随 App 失焦隐藏（与桌宠、状态卡一致）。
- 碎碎念频率只接受 `low` / `normal` / `high` / `chatty`，其他值写入时规整为 `normal`（读取效果不变）。
- 主窗口记住的窗口大小换了键名（默认窗口变大），改版后第一次打开会回到居中的默认大小。
- `cc-pets open settings` 现在打开「宠物」页。
- 玻璃压暗可以是 0–45 之间任意值；只用过菜单的用户不受影响（四档值本身不变）。
- 升级后第一次统计用量会整篇重读一次本地日志（Claude / Codex 缓存条目加了版本号，悬停面板的缓存也在内），日志多时首次显示额度面板 token 数会慢一些，之后恢复增量读取。
