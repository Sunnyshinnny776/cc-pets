## English

CC Pets v2.3.0 adds a main window, multiple Claude / Codex accounts and token usage by model, with a native runtime and diagnostic repairs.

- Manage sessions, usage and settings in one window.
- Track accounts and token usage by model.
- Run natively with backed-up diagnostic repairs.

### Main window and usage

Open Overview, Sessions, Usage, Pet, Alerts, Settings or Diagnostics from the menu or `cc-pets open [page]`. Overview shows every registered account; Sessions lists live agents and CC Bridge delivery status, with terminal jump-back. The Usage page filters local history by account and model over 7, 30 or 90 days, with daily stacked charts, cache hit rates and request counts. Daily archives retain usage after old Claude transcripts are removed.

The window has a separate System Default / Light / Dark appearance setting. Pet settings are grouped into shorter pages, the right-click menu keeps common actions, and glass dimming is continuously adjustable from 0–45%.

### Accounts, native runtime and repairs

Default Claude / Codex Homes are integrated automatically; add custom Homes explicitly from Agent Accounts. Quota, history, hooks, CC Bridge integration and live state are scoped to each account. API authentication uses API usage; subscription accounts can choose plan quota or API usage independently. Starting another account on the same terminal clears stale session records.

Hooks, CC Bridge, diagnostics and pet management run natively. Node.js is needed only for npm installation and updates. Diagnostics can repair registered accounts' hooks and Claude status lines, backing up configuration and affected scripts first. Other issues retain manual fix commands; plain `cc-pets doctor` remains read-only.

### Upgrade

Run `cc-pets install` after upgrading to refresh integrations and the installed app. Restart running Codex sessions and trust the updated hooks in `/hooks`. The built-in pet is named ByteMochi; its existing selection and pet-specific lines are migrated without overwriting an existing destination file.

See [CHANGELOG.md](https://github.com/Sunnyshinnny776/cc-pets/blob/v2.3.0/CHANGELOG.md) for the full list.

## 简体中文

CC Pets v2.3.0 新增主窗口、多 Claude / Codex 账号和按模型统计 Token 用量，并提供原生运行时与诊断修复。

- 主窗口集中管理会话、用量与桌宠设置。
- 多账号独立展示额度，按模型分析 Token 用量。
- 原生运行时，诊断修复前自动备份。

### 主窗口与用量

从菜单或 `cc-pets open [page]` 打开概览、会话、用量、宠物、提醒、设置或诊断。概览展示所有已登记账号；会话页列出在线 Agent 与 CC Bridge 投递状态，并可跳回终端。用量页支持最近 7、30、90 天，按账号和模型筛选，提供每日堆叠图、缓存命中率和请求数。按日归档让 Claude 旧转录被清理后仍保留历史用量。

主窗口可独立选择跟随系统、浅色或深色外观。桌宠设置拆成更短的页面，右键菜单保留常用操作，玻璃压暗支持 0–45% 连续调节。

### 账号、原生运行时与修复

默认 Claude / Codex Home 自动集成；自定义 Home 从「Agent 账户」手动添加。额度、历史、Hooks、CC Bridge 集成和在线状态按账号隔离。API 认证使用 API 用量，订阅账号可独立选择订阅额度或 API 用量。同一终端切换账号后会清理旧会话记录。

Hooks、CC Bridge、诊断和素材管理均为原生实现，Node.js 只用于 npm 安装和升级。诊断页可修复已登记账号的 Hooks 与 Claude status line，修改前备份配置及相关脚本。其他问题保留手动修复命令；普通 `cc-pets doctor` 继续保持只读。

### 升级

升级后运行一次 `cc-pets install`，刷新集成和已安装 App。重启正在运行的 Codex 会话，并在 `/hooks` 中重新信任更新后的 Hooks。内置宠物更名为 ByteMochi，原有选中状态与专属台词自动迁移，已存在的目标文件不会被覆盖。

完整改动见 [CHANGELOG.zh-CN.md](https://github.com/Sunnyshinnny776/cc-pets/blob/v2.3.0/CHANGELOG.zh-CN.md)。
