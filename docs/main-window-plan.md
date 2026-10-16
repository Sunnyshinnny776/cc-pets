# CC Pets 主窗口（大面板）实施计划

> 交接文档：给接手的 agent。描述目标、已完成部分、剩余任务（含文件级方案与验收标准）和必须遵守的约束。
> 分支：`feat/native-hook-installer`（与下一个大版本一起发布，直接在该分支上继续提交）。
> 最后更新：2026-10-15。

## 1. 目标

在右键菜单和悬停额度面板之外，给桌宠加一个**普通 App 式的主窗口**：侧边栏 + 内容区，放菜单装不下的设置、历史数据和诊断。要求：

- 纯 AppKit + Objective-C，不引入 Swift / SwiftUI / 第三方库，最低系统 macOS 13。
- **轻量**：窗口懒创建、关闭即释放；页面不可见时不刷新数据、不跑定时器；不新增常驻任务。
- 视觉上以桌宠为主角（宠物名片），不是一张普通的偏好设置表单。页面较长时，侧边栏列出页内分组，点一下直接跳转。

## 2. 已完成（按提交顺序）

| 提交 | 内容 |
|---|---|
| `26ea6db` refactor: route settings through CCPetsPreferences | 新增 `CCPetsPreferences`：所有设置写入的唯一入口（钳制 + 值变才广播 `CCPetsPreferencesDidChangeNotification`）。右键菜单的 setter 拆成「菜单 action（`setXxx:`/`toggleXxx:`）」+「与控件无关的 `updateXxx:`」。 |
| `79177b9` refactor: expose doctor sections for reuse | `CCPetsDoctorSections()` / `CCPetsDoctorReport()` / `CCPetsDoctorHasFailures()`，`cc-pets doctor` 输出逐字不变。 |
| `9950179` feat: add main window with settings page | `CCPetsMainWindow`（侧边栏 + 内容区，Regular/Accessory 激活策略切换）、`CCPetsSettingsPage`、右键菜单「打开 CC Pets…」、完整主菜单（应用 / 编辑 / 窗口）。 |
| `82a49ef` feat: add pet card and colored icons to the main window | 侧边栏宠物名片（`CCPetsSpriteView` 轻量动画 + 状态 + 会话数）、系统设置式彩色图标块 `CCPetsSymbolTile()`。 |
| `393aa6c` feat: add a live preview stage to the settings page | 设置页顶部预览台（已被 `6f1cfcf` 移除，见下）。 |
| `da1267b` / `0c1a472` / `9eee41d` | 抽出 `CCPetsFormBuilder`（分组卡片表单，设置页与诊断页共用）；doctor 的 npm 包目录改为优先按 `/.build/release/` 路径、其次读 `install-app.sh` 写在 App 数据目录的 `package-dir` 记号（装到 `~/Applications` 的 App 是拷贝，推不出包位置）；新增诊断页 `CCPetsDiagnosticsPage`（后台跑 `CCPetsDoctorSections()`，generation 丢弃过期结果，复制命令 / 复制报告，v1 不执行修复）。 |
| 任务 5 提交 | `cc-pets open [page]`：`CCPetsOpenCommand.m`。桌宠在运行（探测 `cc-pets-<uid>.lock` 被占用，不创建锁文件）就发 `com.ccpets.open-main-window.<uid>` 分布式通知；否则不带 `-g` 地 `open <App> --args --open-window [page]`（优先 `~/Applications`，其次包目录里构建的 App）。AppDelegate 启动早期注册观察者，`launchWindowPage` 在启动末尾开窗。页面参数先校验，未知页面退出码 2。 |
| `6f1cfcf` feat: replace the settings preview with sidebar section navigation | 移除预览台（它把真正的设置挤到折叠线下面）及 `configureQuotaPreview:`；侧边栏在当前页面下列出页内分组（设置页：通用、外观、碎碎念……），点击平滑滚动到该组，再点页面行回到顶部。新增协议 `CCPetsMainPageSections`（`pageSections` / `scrollToSectionWithID:`），页面实现即可启用；设置页文档视图改为翻转坐标。「试说一句」保留，只让桌面上的宠物说话。 |

### 2.1 现有架构速览（接手前先读这些文件）

- `Sources/CCPets/CCPetsMainWindow.h/.m`
  - `+[CCPetsMainWindowController presentPage:]` 打开窗口；页面表在 `MainWindowPages()`（`id` / `title` / `symbol` / `color` / `class`），**新增页面只需在这里加一行**并实现一个 `NSViewController` 子类。
  - 打开时切 `NSApplicationActivationPolicyRegular`；最后一个普通窗口（非 `NSPanel`、能成为 main、含最小化）关闭后切回 Accessory 并 `[NSApp deactivate]`。
  - `CCPetsPetCardSource` 协议（AppDelegate 实现）：`petCardSnapshot`。
  - `CCPetsMainPageSections` 协议（页面可选实现）：`pageSections`（每项 `id` / `title` / `symbol` / `color`）、`scrollToSectionWithID:`（nil 回顶部）。侧边栏只为当前页面显示子项；设置页以分组图标名作 section id。变化时 AppDelegate 调 `notePetCardChanged`（合并到下一轮 runloop 发 `CCPetsPetCardDidChangeNotification`）。
- `Sources/CCPets/CCPetsSettingsPage.h/.m`
  - `CCPetsSettingsActions` 协议：页面调用 AppDelegate 的 `update*` 方法。**AppDelegate 不在声明上采纳此协议**（方法分散在多个 category，采纳会触发 `-Wobjc-protocol-method-implementation`）；`tests/test.sh` 会逐条核对协议方法都在 `CCPetsAppDelegate+Private.h` 里声明过。
  - 页面构建工具：`rowWithTitle:controls:`、`switchRowWithTitle:key:apply:`、`popUpWithOptions:selected:action:`、`stepperRowWithTitle:...`、`buttonRowWithTitle:...`、`addSectionWithTitle:symbol:color:rows:footer:`；每个控件注册一个 reloader block，设置变化时全部重跑。
- `Sources/CCPets/CCPetsUIStyle.h/.m`：`CCPetsSymbolTile()`、`CCPetsSpriteView`（按 Agent 状态选和桌宠一致的动画行；窗口关闭 / 最小化停表）。
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

### 任务 8（v2）：按模型的用量统计 + 「用量与趋势」页

**数据已核实存在**：

| | Claude Code | Codex |
|---|---|---|
| 日志 | `~/.claude/projects/**/*.jsonl`（含 `subagents/agent-*.jsonl`） | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` |
| 模型 | 每条 `assistant` 行的 `message.model` | `turn_context` 行的 `payload.model`（还有 `effort`），**与用量不在同一行** |
| token | `message.usage`：`input_tokens` / `output_tokens` / `cache_read_input_tokens` / `cache_creation_input_tokens` | `token_count` / `token_usage_record`：`input_tokens` / `cached_input_tokens` / `cache_write_input_tokens` / `output_tokens` / `reasoning_output_tokens` |

**坑**：
1. 口径不同：Claude 的 `input_tokens` **不含**缓存，命中率 = `cacheRead / (input + cacheRead + cacheWrite)`；Codex 的 `cached_input_tokens` **是** `input_tokens` 的子集（`input + output = total`），命中率 = `cached / input`。UI 统一成「非缓存输入 / 缓存读 / 缓存写 / 输出」四栏，Codex 先相减。
2. Claude 同一请求多行写入、usage 递增：沿用 `ClaudeTokenTotals`（`CCPetsUsage.m`）按 identity 逐字段取 max 的去重，模型跟着 identity 走。
3. Codex 会话中途 `/model` 切换：delta 必须归属到「当时生效的 `turn_context`」；增量追读（按 offset 续读）时要把每个文件的 `currentModel` 一起存进缓存。
4. 过滤 `<synthetic>` 等伪模型名。
5. 历史深度有限：现有 `monthlyArchive` 只有总量；Claude Code 默认约 30 天清理转录。

**改法**：
- `CCPetsUsage.m` `ClaudeTokenRecord` 加模型字段（定长：用 `uint32 modelIndex` + 旁表）；**二进制缓存必须 bump schema**，旧缓存失效重扫一次。
- Codex 读取路径识别 `turn_context`，token 记录带 `model`；文件续读状态保存 `currentModel`。
- 聚合输出在现有 `totals` 旁新增 `byModel: {model: {input, output, cacheRead, cacheWrite, reasoning, requests}}`，每日序列同理；现有字段不变，面板不受影响。
- `MonthlyArchiveSchemaVersion`（`CCPetsUsage.m`）升到 3，归档带 `byModel`。
- 新页面 `CCPetsUsagePage`：按模型列表（各指标 + 命中率 + 请求数），点开看每日堆叠柱状图；按 CLI / 时间区间筛选。全量聚合在后台队列、仅页面打开时触发，复用增量缓存。图表自绘（参照 `QuotaDashboardView`），不用 Swift Charts。
- 测试：`tests/token-usage-harness.m` 补切模型、多行去重跨模型、Codex 续读保持模型上下文、旧缓存迁移。

### 任务 9（v2）：会话页、概览页

- **会话页**：所有在线和最近会话（右键面板只显示 8 个），状态、持续时长、审批等待时长、点击回跳终端（`CCPetsTerminalFocus`）。数据来自 AppDelegate 的 `agentSessionRecords`（通过新的只读协议提供，不让页面 import 私有头）。
- **概览页（方案 D）**：设为默认首页（`MainWindowPages()` 第一项）。大尺寸宠物 + 额度环（5 小时 / 本周）+ 今日 token + 在线会话 + 待审批数。

### 任务 10（v3）：事件时间线、CC Bridge 页、宠物库

- 事件时间线：`CCPetsEvents` 现在是瞬时消费，需新增**有上限的**落盘存储（环形缓冲 / 限 N 条的 JSONL，放在 `CCPetsPaths` 的状态目录）。
- CC Bridge 页：收件箱与历史、在线 agent、文件预留表（`CCPetsBridgeStore`）。
- 宠物库：网格浏览、预览全部动画行、PetDex 下载、台词编辑器收进主窗口。

## 4. 必须遵守的约束

1. **提交信息不加任何署名**（不要 `Co-Authored-By`、不要 "Generated with Claude Code"）。提交风格：`feat: …` / `refactor: …` / `fix: …`，英文正文说明动机。
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
- 已知局限：侧边栏的 vibrancy 背景截不到（显示为空白），名片可单独挪到普通窗口里截。

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

- 侧边栏 vibrancy 背景与名片的整体观感。
- 关窗后 Dock 图标、菜单栏收回；窗口打开时切到别的 App 再回来，桌宠和气泡一直在。
- 名片宠物的动作 / 状态随 Agent 事件变化。
- 设置页侧边栏分组跳转：点击各子项滚动位置是否合适（尤其最后几组停在底部）、切换语言后子项是否正确重建。

## 6. 已知行为变化（写进 CHANGELOG）

- 台词编辑器在前台时 ⌘Q 现在会退出桌宠（以前没有反应）；编辑器未保存内容会丢失。
- 说话气泡不再随 App 失焦隐藏（与桌宠、状态卡一致）。
- 碎碎念频率只接受 `low` / `normal` / `high` / `chatty`，其他值写入时规整为 `normal`（读取效果不变）。
