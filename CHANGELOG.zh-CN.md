# 更新记录

[English](./CHANGELOG.md) | 简体中文

本项目遵循语义化版本号。版本号以 `package.json` 为唯一来源。

## [2.2.0] - 2026-10-08

首个英文语言版本：App 与 CLI 支持英语和简体中文。

### 界面语言

- 界面支持英文和简体中文。右键菜单新增「语言」，可选「跟随系统」「English」「简体中文」；跟随系统时取 macOS 首选语言，都不匹配时用英文。
- `cc-pets` 命令、hooks 和 CC Bridge 消息通过 `~/.cc-pets/language` 跟随同一设置；`CC_PETS_LANGUAGE` 可按次覆盖。
- 新增英文默认台词。没改过的 `~/.cc-pets/speech.txt` 会随语言切换；不含中日韩文字的句子上限放宽到 40 个字符。
- 更新对话框只读取标题与界面语言完全匹配的 Release 段落；缺少对应段落时不展示要点，不会退回其他文字。

### 界面

- 英文 README 展示英文截图，中文 README 保留中文截图，各自两张图并排展示。
- Today 和 Last 7 days 标题加粗，标签间距与趋势图说明位置调整，窗口标题和风险提示精简，移除英文趋势区域的重复说明。
- 更新弹窗以「Current version」标识已安装版本。

## [2.1.2] - 2026-10-04

桌宠提示新版本，新增 `cc-pets doctor` 与 `cc-pets paths`，以及清理相关修复。

### 更新

- 启动 5 秒后到 npm 检查新版本，CLI 再次唤起已运行的桌宠时也会检查（最多每 10 分钟一次）；检查失败不打扰。
- 发现新版本时桌宠弹出可点击的气泡，附上对应 GitHub Release 中最多三条要点。Agent 忙碌时气泡会等待；开启碎碎念时，空闲台词会不时提醒，直到选择「稍后」。
- 桌宠上新增玻璃「↑」角标作为常驻入口；有新版本时，右键菜单顶层临时出现「更新到 x.y.z…」。更新对话框列出要点并可打开完整说明，「关于 CC Pets」改用同样的对话框样式。
- 「检查更新…」与「关于 CC Pets」收进右键菜单新增的「帮助」子菜单。

### 命令行

- 新增 `cc-pets doctor`：只读检查安装状态，包括 Node.js、npm 包 / 原生程序 / 已安装 App 的版本是否一致、Claude Code 与 Codex Hooks（含包被移动后仍指向旧位置的 Hooks）、Claude status line、shell shim 与 `PATH` 顺序、真实 CLI、自动更新配置和 CC Bridge。每个问题都给出修复命令；home 目录显示为 `~`，输出可直接贴进 issue。
- 新增 `cc-pets paths [--json]`：列出偏好、桌宠素材、台词、缓存与运行时状态的存放位置和大小，并注明 `clean` 与 `--purge` 各自会删除哪些。
- `cc-pets clean` 现在也会清理 `~/.cc-pets/cache` 中的素材清单缓存。
- `cc-pets uninstall --purge` 一直会保留 `~/.cc-pets` 中的桌宠素材与台词；帮助、确认提示和 README 现已如实说明，不再写"删除全部本地数据"。

### CC Bridge

- `cc-pets bridge enable`、`cc-pets bridge status` 与 `cc-pets doctor` 会检测当前 Codex 是否支持 `codex queue`。不支持时 CC Bridge 仍可开启，发给 Codex 的消息先进信箱；升级 Codex 后即可自动唤醒，无需重新开启。

## [2.1.1] - 2026-09-30

功能版本：原生 Liquid Glass 面板主题与多终端跳转，以及额度修复。

### 面板与菜单

- 新增 Liquid Glass 面板主题（macOS 26 及以上），在右键菜单「面板主题」里切换；默认仍是经典主题，经典主题不变。作用于额度面板、状态卡、说话气泡和 Agent 会话列表。
- 公开的玻璃样式在 App 未激活时会变成磨砂，而桌宠从不激活。macOS 27 上改用一个未公开的玻璃样式，保持清透和折射；执行 `defaults write com.universewang.cc-pets CCPetsDisableExperimentalGlass -bool YES` 可关闭，回退到公开的 Clear 玻璃。
- 「玻璃压暗」提供通透（0%）、轻度（15%）、标准（25%，默认）、清晰（45%）四档；玻璃上下沿加了柔和暗带，压住过亮的边缘高光。
- Liquid Glass 下额度面板改为白字加彩色圆点，不再使用彩色字和彩色底标签；小字设了字号下限，数字用等宽字形，卡片下垫一层浅衬底。
- Agent 会话列表改为玻璃面板，有高度上限，超出可滚动；与系统菜单不同，不支持方向键选择。
- 主题和压暗档位点击后立即生效，菜单不收起，方便连续对比。
- 右键菜单新增「关于 CC Pets」。
- 菜单开关的悬停说明在桌宠未激活时也能显示。
- 移除右键菜单的「刷新用量」和额度面板的刷新按钮；用量仍定时自动刷新。
- CC Bridge 子菜单从 14 行精简到 6 行；未启用时只显示「启用」。

### Agent 状态

- 修复 Codex 气泡跳错终端：Codex 0.159 把所有终端的会话放进同一个 `codex app-server --managed-daemon` 执行，hook 继承的是最先拉起它的终端的环境。现在 `codex-with-pet` 会登记每次启动，hook 按同一工作目录把新会话配到对应的启动记录；配不准时气泡不跳转。本版本之前启动的 Codex 会话需要重启一次。

### 额度与用量

- 修复空闲的 Claude 会话把额度回退到更早、更高的剩余值：只有更新的响应才能把数值调低，已过期的 5 小时窗口不再显示旧百分比。
- Codex 的实时额度在重启和 app-server 中断期间也能保留，不再回退到几小时前的会话日志快照。

### 命令行

- 新增 `cc-pets --help`；未知参数改为以退出码 2 报错，不再启动桌宠；`cc-pets uninstall --purge` 现在生效。

## [2.1.0] - 2026-09-24

CC Bridge：Claude Code 与 Codex 会话之间互发消息。

### CC Bridge（实验性，默认关闭）

- 新增 `cc-pets bridge enable|disable|status`：让本机的 Claude Code 与 Codex 终端会话互相发现、发消息、唤醒对方，支持 Claude ↔ Codex、Codex ↔ Codex，详见 [CC_BRIDGE.zh-CN.md](./CC_BRIDGE.zh-CN.md)。
- 只使用官方扩展点：MCP server（`list_agents` / `send_message` / `check_inbox`）负责发送；投递到 Codex 用 `codex queue`，投递到 Claude Code 用 `asyncRewake` hook。
- 投递前确认目标在线，避免 Codex 在 resume 时执行过期消息；单条 16KB 上限、24 小时过期、同一对会话 10 分钟 20 条的防循环限流。
- `cc-pets uninstall` 一并移除 CC Bridge 集成；重装与升级时按原选项自动刷新。
- 文件预留：`reserve_files` / `release_files` / `list_reservations`，第一次编辑他人预留的文件时由 PreToolUse hook 暂停一次并说明原因，重试即放行，过期与会话结束自动释放。
- 桌宠显示：状态图标右下角的消息角标（蓝色为新送达，橙色为信箱积压），会话菜单列出最近的跨会话消息，点击跳到收件会话的终端；只显示会话名与时间，不显示正文。
- 选项与菜单开关：`cc-pets bridge configure` 与 `enable` 支持 `--approve` / `--codex-approve` / `--claude-allow`（按分组放开 Codex 免审批与 Claude 免确认）、`--wake`、`--edit-guard`，未给出的选项保持原值；桌宠右键菜单新增 CC Bridge 开关组（启用、免审批四组、自动唤醒、编辑拦截、消息角标、新消息系统通知）。
- 会话名可自定义：启动时用 `CC_BRIDGE_NAME`，或会话内调用 `set_name` / `cc-pets bridge name`；`list_agents` 显示会话所在终端（tty）。

### Agent 状态

- 修复在 VS Code 家族编辑器里点状态卡片无法回跳：`TERM_PROGRAM=vscode` 是 VS Code、Cursor、Windsurf、Antigravity 共用的标记，不再由它单独决定跳转的应用——捕获到的 bundle ID 优先，候选里没在运行的直接跳过，不再让整次回跳失败。

## [2.0.3] - 2026-09-17

修复未经包装脚本启动的 Agent 的终端回跳与会话存活判定。

### Agent 状态

- 缺少 `CC_PETS_TERMINAL_*` 时回退到内核信息：通过 `sysctl(KERN_PROC_PID)` 读取控制终端，并沿父进程链向上找到宿主终端应用，直接启动的 `claude` / `codex` 也能回跳。
- 修复没有 pid 文件的会话被立即判定为离线的问题：存活判定优先使用 pid 文件，从未写过 pid 文件的 provider 回退到活动宽限窗口。

## [2.0.2] - 2026-09-11

多会话 Agent 列表，以及会话存活判定与 Codex 用量趋势修复。

### Agent 状态

- 所有 Hook 状态卡都可点击并返回触发事件的终端；Terminal 和 iTerm2 按 TTY 精确选中，其他终端回退为激活所属应用。
- 圆形状态图标可展开最近 8 个在线 Agent 终端会话，并以角标显示等待审批的会话数，这些会话在列表中置顶。
- Agent 停在等待审批超过 2 分钟、或停在思考态超过 5 分钟时提醒一次，并把状态卡重新推到眼前；该会话有新事件后重新武装。
- 存在未处理的审批时，状态卡不再在闲置 60 秒后清空。
- 修复在线会话残留：只有控制终端仍与 pid 文件中记录的 TTY 一致时才算在线，关闭窗口后残留的 Node 孤儿进程不再让会话一直挂在列表里。

### 额度与用量

- 修复 7 天百分比可用时，用量趋势列仍被「等待刷新」覆盖的问题；限流脚注使用独立配色。
- 限流期间保留官方窗口百分比写入额度历史，长期限流的 provider 仍有样本可以绘制趋势曲线。

## [2.0.1] - 2026-09-07

额度显示与面板稳定性问题修复。

### 额度与用量

- 从 Codex App Server 读取实时额度窗口，并叠加到本机聚合的 Token 用量上；后台保持长连接，处理刷新、通知、超时与降级回退。
- 修复额度重置后 Codex 额度不再显示的问题：过期的会话额度窗口现在会独立丢弃，耗尽状态在重置前后也能正确保留。
- 官方额度数据尚不可用时，显示“等待刷新”状态。

### 桌宠与互动

- 修复面板偶尔无法显示的问题。
- 统一宠物台词视角为第一人称：由“宠物旁观 Agent”调整为“宠物即 Agent”。

## [2.0.0] - 2026-08-23

首个开源版本。

### 桌宠与互动

- macOS 原生 AppKit 桌宠，运行时不依赖 Electron，也不需要 Codex/Claude 桌面端。
- 待机呼吸、随机小动作、拖动滞后与落脚回弹；头部、口袋、脚部和身体两侧的悬停与点击反馈。
- 右键菜单可切换桌宠、刷新用量、开关额度历史与系统通知、检查更新或退出。
- 支持内置素材与 `~/.cc-pets/pets/` 下的外部素材，兼容 `spriteVersionNumber` v1 / v2 网格。

### 额度与用量

- 从本机 `~/.codex/sessions` 与 Claude Code 官方 status line 数据读取 5 小时额度、周额度和重置时间。
- 悬停口袋展开额度面板，用两张卡分别展示 Codex、Claude 的剩余百分比、本机 Token 与近 7 天趋势。
- 可选记录最近 7 天的本地额度历史；默认关闭，仅保存在本机。
- 支持「订阅额度 / API 用量」两种展示模式。

### Agent 状态

- 由 Codex Hooks 与 Claude Code Hooks 驱动思考、工具调用、审批、子 Agent、完成与失败动画。
- 桌宠旁显示脱敏后的玻璃状态卡片，可折叠并显示活跃 CLI 会话数。
- 可分别启用任务完成、失败和等待审批的 macOS 系统通知。
- 第三方 CLI Agent 可通过统一 Provider 事件协议接入，详见
  [`PROVIDER_PROTOCOL.zh-CN.md`](./PROVIDER_PROTOCOL.zh-CN.md)。

### 台词

- 桌宠台词全部来自 `~/.cc-pets/speech.txt`，可在内置编辑器中修改，支持实时数据槽位。
- 可为单只宠物写专属台词（`~/.cc-pets/speech/<宠物名>.txt`），按小节整体覆盖通用台词。
- 四档碎碎念频率，Agent 工作期间不插嘴。

### 安装与集成

- `npm install -g cc-pets` 自动构建原生应用、安装两套 Hooks 与 shell 集成，并安装
  `~/Applications/CC Pets.app`。
- 通过 `~/.cc-pets/shims` 下的软链接管 `codex` / `claude`，任意大小写写法都能拉起桌宠。
- `cc-pets install` / `uninstall` / `uninstall-app` 提供可重复执行的初始化与清理流程。

### 隐私

- 不上传会话内容、额度、凭据或使用统计，不包含遥测。
- 状态卡片与通知只显示 Provider、状态类别和脱敏后的工具类别。
