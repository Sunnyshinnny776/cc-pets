# 更新记录

[English](./CHANGELOG.md) | 简体中文

本项目遵循语义化版本号。版本号以 `package.json` 为唯一来源。

## [未发布]

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
