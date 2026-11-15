## English

CC Pets v2.5.0 adds a menu bar mode, clearer session status and lifecycle tracking, and CC Bridge reliability fixes.

- Check sessions and quota from the menu bar.
- See clearer session status and lifecycle tracking.
- Fix Bridge identity, reservations and delivery.

### Menu bar

Choose Desktop Pet (default), Pet + Menu Bar, or Menu Bar Only under Main menu → Settings → Show In. The menu bar panel shows up to five online sessions, per-account quota and today's tokens. Click a session to jump to its terminal; right-click the icon for the pet's context menu. While a session awaits approval, left-click jumps straight to its terminal when available; ⌥-click opens the panel.

The terminal-shaped icon follows agent status and shows an approval count. Optional quota text shows the lowest 5-hour quota among subscription accounts, turning orange at 20% or below and red at 10%. Menu Bar Only hides the pet and its floating panels and skips chatter; tracking, quota collection and system notifications continue.

### Sessions

Status cards show the session name and expose the full name and working directory on hover. Chinese displays add animal aliases to generated Bridge names; message addresses remain the original name or ref. Persistent Codex desktop chats join online counts, while transient tasks without persisted transcripts are excluded from Bridge recipients. Session-end hooks clear ended sessions and approvals, and trailing events no longer overwrite a completed turn. Desktop chats may remain online until the app exits if no end event arrives.

### CC Bridge and upgrade

Per-call `session_id` identifies callers sharing a Codex app-server process and must pass live-session and host checks. File reservations serialize concurrent changes, detect directory/glob overlaps and resolve symlinks consistently. Configuration edits preserve content outside Bridge's managed block. Message limits and cleanup are safer under concurrent sends, session exits and disabling Bridge; receipts no longer retain message bodies.

Delivery still does not mean the recipient has read or accepted a message. A queue timeout can fall back to the inbox and deliver twice. `release_files` with an empty `paths` array releases nothing; omit `paths` to release all of the caller's reservations.

After upgrading, run `cc-pets install` to refresh the app and integrations. Restart running Codex sessions and trust updated hooks in `/hooks`. Reconnect CC Bridge MCP to load tool definitions with `session_id`. Reinstall or reload terminal extensions only when Settings prompts you.

See [CHANGELOG.md](https://github.com/Sunnyshinnny776/cc-pets/blob/v2.5.0/CHANGELOG.md) for the full list.

## 简体中文

CC Pets v2.5.0 新增菜单栏模式，改进会话状态与生命周期跟踪，并修复 CC Bridge 可靠性问题。

- 在菜单栏查看会话与额度。
- 更清楚地展示会话状态与生命周期。
- 改进 Bridge 身份、文件预留与消息投递。

### 菜单栏

在「主菜单 → 设置 → 显示位置」选择仅桌宠（默认）、桌宠 + 菜单栏或仅菜单栏。菜单栏面板显示最多五个在线会话、各账号额度和今日 Token；点击会话可跳到终端，右键图标打开桌宠右键菜单。有会话待审批且可定位终端时，左键直接跳到对应终端；按住 ⌥ 点击打开面板。

终端形图标跟随 Agent 状态变色，并显示待审批数量。可选额度数字显示订阅账号中最低的五小时剩余额度，20% 及以下为橙色、10% 及以下为红色。仅菜单栏模式隐藏桌宠及浮层、跳过碎碎念；状态跟踪、额度采集和系统通知继续运行。

### 会话

状态卡显示会话名，悬停可查看完整名称和工作目录。中文显示为自动生成的 Bridge 名称附加动物别名；消息寻址仍使用原始名称或 ref。Codex 桌面端的持久化聊天计入在线数量，没有持久化转录的临时任务不注册为 Bridge 收件人。会话结束 Hook 清理会话及待审批记录，尾随事件不再覆盖已完成回合的终态；未收到结束事件时，桌面聊天可能保留在线直到应用退出。

### CC Bridge 与升级

逐次传入的 `session_id` 用于识别共享 Codex app-server 进程的调用者，须通过在线会话及宿主校验。文件预留串行处理并发变更，识别目录与 glob 重叠，并统一解析软链。配置修改保留 Bridge 管理块以外的内容。改进并发发送、会话退出和关闭 Bridge 时的消息限额与清理；回执不再保存消息正文。

送达仍不代表收件方已读或同意。队列超时可能回退到信箱并重复送达。`release_files` 传空的 `paths` 数组不释放任何预留；省略 `paths` 才释放调用者的全部预留。

升级后运行 `cc-pets install` 刷新 App 与集成；重启正在运行的 Codex 会话，并在 `/hooks` 中信任更新后的 Hooks。重新连接 CC Bridge MCP，加载含 `session_id` 的工具定义。终端扩展仅在设置页提示时重新安装或加载。

完整改动见 [CHANGELOG.zh-CN.md](https://github.com/Sunnyshinnny776/cc-pets/blob/v2.5.0/CHANGELOG.zh-CN.md)。
