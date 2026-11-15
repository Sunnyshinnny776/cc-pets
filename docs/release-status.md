# v2.5.0 发布准备状态

2026-11-15 在 `publish` 分支准备 v2.5.0，尚未正式发布。本文件记录发布准备提交前的验证快照。本轮已获取远程引用，并将本地 `publish` 从 `5b8958c` 快进到远程 `main` 的 `9280afd2949ddef4b33a59dd2ed468aa99a7f06e`，同步 29 个提交，无冲突；未操作本地 `main`。发布范围包含 v2.4.0 之后合并的 PR #28、#29、#30、#31。

上一版状态已逐字节归档至 [v2.4.0 发布状态](release-status-v2.4.0.md)；更早记录见 [v2.3.0](release-status-v2.3.0.md)、[v2.2.1](release-status-v2.2.1.md) 和 [v2.2.0](release-status-v2.2.0.md)。历史状态是当时的证据，不代表本轮重新验证。

## 交付范围

- 菜单栏模式：仅桌宠（默认）、桌宠 + 菜单栏或仅菜单栏；面板查看在线会话、各账号额度和今日用量。图标跟随状态，待审批时可直接跳到对应终端，⌥ 点击仍打开面板；额度数字可独立关闭。
- 会话展示与生命周期：状态卡按会话区分、悬停查看完整名称及目录，中文显示自动名称的动物别名；跟踪 Codex 桌面端持久化聊天、过滤临时任务、处理会话结束并避免尾随事件覆盖终态。
- CC Bridge：逐次 `session_id` 调用者识别、保留非管理区配置、并发预留与限额、目录/glob/软链冲突识别、消息正文与离线会话清理、watcher 唤醒修复。

仅菜单栏模式隐藏桌宠与浮层并跳过碎碎念，状态跟踪和系统通知继续运行。送达不表示已读或接受；队列超时回退信箱可能重复投递。`release_files` 的空 `paths` 数组不释放预留，省略该参数才释放全部。未收到结束事件时，Codex 桌面聊天可能保持在线直到应用退出。

## 发布材料

`package.json`、双语 README、双语 CHANGELOG、[双语 Release Note](release-notes-v2.5.0.md) 与封面统一为 v2.5.0。CHANGELOG 保留空的 `Unreleased`，原有未发布条目整体归入 `2.5.0`，准备日期为 2026-11-15；若正式发布日期变化，由发布负责人调整。

Release Note 使用准确的 `## English` / `## 简体中文` 标题，各三条不超过 50 字符的顶层要点；补充信息使用段落。CHANGELOG 链接指向 v2.5.0 tag，在创建 tag 前尚未生效。已逐字节核验 v2.4.0 及更早的 CHANGELOG、Release Note 和发布状态归档保持原文。

## 验证与交接进度

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

本轮只交付正式版本准备材料，不从 `publish` 发布稳定版本或预发布。用户已授权提交、push 和创建 PR；后续由 `main` 负责人按授权完成远端合并及集成复验，本地 `main` 只同步远端已完成的集成结果。v2.5.0 Release Note 必须在创建 tag 前提交，正式 tag、GitHub Release 和 npm 发布均须按分工另行授权。

正式发布使用 `gh release create v2.5.0 --notes-file docs/release-notes-v2.5.0.md`，tag 内文件与 GitHub Release 正文须一致；不能以 GitHub 自动生成正文替代。
