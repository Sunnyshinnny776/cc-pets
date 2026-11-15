# v2.5.0 发布状态

2026-11-15 已从 `main` 正式发布 v2.5.0，发布结果见下方记录。发布范围包含 v2.4.0 之后合并的 PR #28、#29、#30、#31，以及发布准备 PR #32 和发布前的双语 README 补检修正。

以下保留发布准备阶段的历史快照：当时在 `publish` 分支准备材料，本地 `publish` 从 `5b8958c` 快进到远程 `main` 的 `9280afd2949ddef4b33a59dd2ed468aa99a7f06e`，同步 29 个提交，无冲突；该准备阶段未操作本地 `main`。

上一版状态已逐字节归档至 [v2.4.0 发布状态](release-status-v2.4.0.md)；更早记录见 [v2.3.0](release-status-v2.3.0.md)、[v2.2.1](release-status-v2.2.1.md) 和 [v2.2.0](release-status-v2.2.0.md)。历史状态是当时的证据，不代表本轮重新验证。

## 正式发布与最终验证（2026-11-15）

- 按维护者授权，发布前的双语 README 修正与验证记录直接提交并推送到 `main`，提交为 `d35f1ab20a3a474aff551cd3a12957bec3b6b16d`。PR #33 已撤回且未合并；本轮在 `publish` 新增的两个提交已撤回，远端与本地 `publish` 恢复为 `dd45d30`。
- 在最终发布提交重新运行 `CC_PETS_STRICT=1 npm test`，全套通过，退出码 0，耗时 50.8 秒；独立 runner 的 PPID=1，真实事件流与 shim 污染检查通过。对应的 [main CI](https://github.com/Sunnyshinnny776/cc-pets/actions/runs/43728259675) 通过。
- package、裸二进制、App 内二进制和两个 plist 版本字段均为 `2.5.0`，App 严格签名验证通过；实际解析再次得到预期的中英各三条更新要点，无截断或跨语言内容。海报右上角为 `v2.5.0`。
- 已推送 annotated tag `v2.5.0`，指向上述发布提交；已发布 [CC Pets 2.5.0](https://github.com/Sunnyshinnny776/cc-pets/releases/tag/v2.5.0)，发布时间为 `2026-11-15T15:13:11Z`，为 Latest 正式版本，非 draft、非 prerelease。
- 已核对远端 annotated tag 及目标提交，GitHub Release 正文、远端 tag 文件和本地 `docs/release-notes-v2.5.0.md` 逐字节一致。发布后记录直接更新至 `main`，正式 tag 保持指向已验证的发布提交。
- 未执行 npm 发布或本机安装；未重新人工验收菜单栏交互、终端跳转、会话生命周期与 Bridge 恢复。

## main 集成复验与发版补检（2026-11-15，发布前快照）

- PR #32 已合并；本地 `main` 快进至 `c13a2ba651fc2a8b1beb547a1aaa6e57fa78df5a`，与远端一致。
- 在该提交重新运行 `CC_PETS_STRICT=1 npm test`，全套通过，退出码 0；独立 runner 的 PPID=1，耗时 106.5 秒，真实事件流与 shim 污染检查通过。同一提交的 [main CI](https://github.com/Sunnyshinnny776/cc-pets/actions/runs/43727008797) 通过。
- package、裸二进制、App 内二进制及两个 plist 版本字段均为 `2.5.0`；`codesign --verify --deep --strict` 通过。实际 Release Note 解析与预期的中英各三条要点完全一致，无截断或跨语言内容。
- 检查了 72 个本地文档/图片链接；发布准备前的历史记录保持不变。与 v2.4.0 tag 相比，旧版中文 CHANGELOG 仅包含此前已提交的 Shadowrocket 名称修正。
- 已目视确认海报右上角为 `v2.5.0`，`main`、`publish` 和已提交图片的 SHA-256 一致。
- 补检发现双语 README 对应用菜单与菜单栏状态图标的描述混淆，并残留「主窗口 / main window」称呼；修正已在 `publish` 准备，待提交和集成。`git diff --check` 通过；本次补检未修改产品源码。
- 正式 tag 和 GitHub Release 尚未创建；发布后还需更新双语 CONTRIBUTING 的当前正式版本与本文件。未执行 npm 发布或本机安装；未重新人工验收菜单栏交互、终端跳转、会话生命周期和 Bridge 恢复。

## 交付范围

- 菜单栏模式：仅桌宠（默认）、桌宠 + 菜单栏或仅菜单栏；面板查看在线会话、各账号额度和今日用量。图标跟随状态，待审批时可直接跳到对应终端，⌥ 点击仍打开面板；额度数字可独立关闭。
- 会话展示与生命周期：状态卡按会话区分、悬停查看完整名称及目录，中文显示自动名称的动物别名；跟踪 Codex 桌面端持久化聊天、过滤临时任务、处理会话结束并避免尾随事件覆盖终态。
- CC Bridge：逐次 `session_id` 调用者识别、保留非管理区配置、并发预留与限额、目录/glob/软链冲突识别、消息正文与离线会话清理、watcher 唤醒修复。

仅菜单栏模式隐藏桌宠与浮层并跳过碎碎念，状态跟踪和系统通知继续运行。送达不表示已读或接受；队列超时回退信箱可能重复投递。`release_files` 的空 `paths` 数组不释放预留，省略该参数才释放全部。未收到结束事件时，Codex 桌面聊天可能保持在线直到应用退出。

## 发布材料

`package.json`、双语 README、双语 CHANGELOG、[双语 Release Note](release-notes-v2.5.0.md) 与封面统一为 v2.5.0。CHANGELOG 保留空的 `Unreleased`，原有未发布条目整体归入 `2.5.0`，准备日期为 2026-11-15；若正式发布日期变化，由发布负责人调整。

Release Note 使用准确的 `## English` / `## 简体中文` 标题，各三条不超过 50 字符的顶层要点；补充信息使用段落。CHANGELOG 链接指向 v2.5.0 tag，在创建 tag 前尚未生效。已逐字节核验 v2.4.0 及更早的 CHANGELOG、Release Note 和发布状态归档保持原文。

## 验证与交接进度（发布准备快照）

下表为提交前快照。用户已授权本地提交、push `publish` 和创建面向 `main` 的 PR；实际提交号、远端同步和 PR 状态以 Git 历史及对应 PR 为准。PR 合并、正式 tag、GitHub Release 和 npm 发布仍需分别授权。

| 阶段 | 本轮状态 |
| --- | --- |
| 本地同步 | 已快进到 `origin/main` 的 `9280afd`；本地仍为 `publish` |
| 版本与发布材料 | v2.5.0 已准备；尚未提交 |
| `CC_PETS_STRICT=1 npm test` | 2026-11-15 全套通过，退出码 0，耗时 105.3 秒；独立 runner 的 PPID=1；真实事件流与 shim 污染检查通过 |
| Release Note 实际解析 | 调用 `ReleaseNoteHighlightsForLanguage`，中英各三条、无截断；长度分别为 43/50/47 和 12/16/23；精确语言标题检查通过 |
| 二进制、App 版本与签名 | package、裸二进制、App 内二进制及两个 plist 版本字段均为 2.5.0；`codesign --verify --deep --strict` 通过 |
| 文档链接、历史保留与 diff 检查 | 56 个本地文档/图片链接存在；目标 tag URL 版本一致；全部原有 CHANGELOG 内容和历史发布文件逐字节保留；`git diff --check` 通过 |
| 封面 | 2560×1280，仅版本数字区域的 340 个像素变化，区域外逐像素一致；已目视核验 v2.5.0 |
| 本地提交 | 提交前尚未执行；用户已授权 |
| push | 提交前尚未执行；用户已授权推送 `publish` |
| PR 创建 | 提交前尚未执行；用户已授权创建面向 `main` 的 PR |
| PR 合并 | 本轮未执行，仍需单独授权 |
| v2.5.0 材料的 `main` 集成及复验 | 本轮未执行，由 `main` 负责人按授权完成 |
| v2.5.0 正式 tag / GitHub Release | 本轮未执行 |
| v2.5.0 npm 发布 | 本轮未执行，按既有负责人分工协调 |
| 本机安装 | 本轮未执行 |

本轮仅编辑发布材料，未修改产品源码、扩展或测试。未重新人工验收菜单栏显示模式、审批终端跳转、真实 Codex 桌面会话生命周期、Bridge 跨宿主调用与消息恢复、VPN 实网或双语完整交互。现有 README 截图沿用原图，未新增菜单栏截图；自动回归不替代上述人工验收。

本轮校验脚本与日志保留在本地忽略目录 `.build/release-prep-v2.5.0/`；本地 agent 规则不纳入交付。

## 升级与发布交接

升级后运行 `cc-pets install` 刷新 App 和集成；重启正在运行的 Codex 会话，并在 `/hooks` 中信任更新后的 Hooks。重新连接 CC Bridge MCP，加载包含 `session_id` 的工具定义。终端扩展按设置页提示安装或更新。

v2.5.0 已按维护者授权从 `main` 发布，Release Note 在创建 tag 前已提交；发布后的文档记录也按本轮授权直接提交至 `main`。npm 发布仍由既有负责人协调，本轮未执行。

正式发布已使用 `gh release create v2.5.0 --notes-file docs/release-notes-v2.5.0.md`；已核验 tag 内文件与 GitHub Release 正文一致，未使用 GitHub 自动生成正文。
