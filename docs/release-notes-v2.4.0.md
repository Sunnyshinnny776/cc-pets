## English

CC Pets v2.4.0 adds exact terminal jumps, optional launch protection, more reliable CC Bridge delivery and corrected token accounting.

- Jump to the exact terminal across more apps.
- Check launch exits and improve Bridge delivery.
- Track token usage and manage pets more easily.

### Terminal jump and settings

Use the bundled extensions for VS Code 1.80+ and its forks, or JetBrains 2026.2 / 2026.3 Reworked terminals. Ghostty 1.4+ selects tabs and splits by TTY; iTerm2 selects sessions by TTY. Manage permissions, plugin installation and updates in Settings → Terminal Jump. Remote IDE windows are outside the supported scope; JetBrains Classic terminals and split subterminals are also excluded.

Settings groups terminal states into a compact card and puts Panel Appearance first, with live Liquid Glass dimming previews and a 0–100 display scale. The Pet page can delete unselected custom pets after confirmation and refreshes when the user's pet folder changes. Built-in pets remain protected.

### Launch protection and CC Bridge

Optional Shadowrocket launch protection is off by default. Wrappers check the VPN and service trace endpoint before starting a session, blocking CN, HK, unknown exits and failed requests. Launches that bypass wrappers are not checked. Custom endpoints must provide valid trace data; see the README for configuration limits.

CC Bridge rejects ambiguous session identities, serializes updates and recovers unconfirmed inbox messages. A crash between output and confirmation can still repeat a message ID. Delivery uses the recipient's Codex Home, watcher settings are rechecked, and message envelopes are shorter. Builds replace signed executables atomically to avoid signature-related launch failures.

### Usage and upgrade

Codex cache-write accounting no longer counts the same tokens twice; existing daily archives are migrated. Local Codex SQLite logs supplement background totals without inventing an input/output/cache breakdown or duplicating persisted sessions. Every model keeps its own chart series. Low-quota reminders track each subscription account independently at 20%, 10% and 5%.

After upgrading, run `cc-pets install` to refresh the installed app and integrations. Restart running Codex sessions and trust updated hooks in `/hooks`. Install or update terminal extensions from Settings, then restart JetBrains or reload VS Code when prompted.

See [CHANGELOG.md](https://github.com/Sunnyshinnny776/cc-pets/blob/v2.4.0/CHANGELOG.md) for the full list.

## 简体中文

CC Pets v2.4.0 新增终端精准跳转、可选启动保护，并改进 CC Bridge 投递可靠性和 Token 统计。

- 支持更多应用的终端精准跳转。
- 检查启动出口，改进 Bridge 消息投递。
- 改进 Token 统计与宠物管理。

### 终端跳转与设置

VS Code 1.80+ 及其分支、JetBrains 2026.2 / 2026.3 Reworked 终端可使用随包扩展精确跳转。Ghostty 1.4+ 按 TTY 选择标签页和分屏，iTerm2 按 TTY 选择会话。在「设置 → 终端跳转」管理权限、插件安装和更新。远程 IDE 窗口不在支持范围内；JetBrains Classic 终端及分屏内子终端同样不在支持范围内。

设置页将终端状态集中为紧凑卡片，面板外观置顶，提供 Liquid Glass 压暗实时预览，并以 0–100 刻度显示。「宠物」页可在确认后删除未选中的自定义宠物，用户素材目录变化后自动刷新；内置宠物受保护。

### 启动保护与 CC Bridge

可选 Shadowrocket 启动保护默认关闭。包装脚本在启动会话前检查 VPN 和服务 trace 端点，阻止 CN、HK、未知出口及请求失败的启动。绕过包装脚本启动时不检查；自定义端点必须返回有效 trace 数据，配置限制详见 README。

CC Bridge 拒绝有歧义的会话身份，串行处理更新，并可恢复未确认的信箱消息；输出与确认之间崩溃仍可能重复同一消息 ID。投递使用接收方 Codex Home，运行中的 watcher 会重新检查开关，消息信封也更简短。构建原子替换已签名的可执行文件，避免签名相关启动失败。

### 用量与升级

修复 Codex cache write 重复计数，并迁移已有按日归档。本机 Codex SQLite 日志补充后台总量，不推算 input/output/cache 明细，也不重复累计已持久化的会话。所有模型保留独立图表序列；低额度提醒按订阅账号分别跟踪 20%、10%、5% 阈值。

升级后运行 `cc-pets install` 刷新已安装 App 与集成；重启正在运行的 Codex 会话，并在 `/hooks` 中信任更新后的 Hooks。终端扩展在设置页安装或更新，按提示重启 JetBrains 或重新加载 VS Code。

完整改动见 [CHANGELOG.zh-CN.md](https://github.com/Sunnyshinnny776/cc-pets/blob/v2.4.0/CHANGELOG.zh-CN.md)。
