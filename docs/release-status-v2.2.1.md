# v2.2.1 发布状态

2026-10-11 已从 `main` 发布正式 tag `v2.2.1` 与 [GitHub Release](https://github.com/Sunnyshinnny776/cc-pets/releases/tag/v2.2.1)。
本次包含宠物大小、台词来源、菜单与渲染更新。npm 尚未发布；当前机器未登录 npm，等待 npm 负责人发布。

## 分支职责与发布顺序

- `publish` 完成代码、文档、截图与验证；测试版本使用预发布号并标记 GitHub prerelease。
- 经明确授权集成 `main` 后复验，正式 tag 和 GitHub Release 从 `main` 发布。
- npm 发布由独立负责人执行，在 GitHub Release 就绪后协调；未发布 npm 时，自动更新器不会发现新版本。
- 上一版历史记录见 [v2.2.0 发布状态](release-status-v2.2.0.md)，历史 Release Note 保留。

## 本次交付

- `package.json` 更新为 `2.2.1`，构建时写入二进制与 app 元数据。
- 双语 CHANGELOG 将本次 `Unreleased` 改动归入 `2.2.1`，保留空的 `Unreleased` 小节。
- 双语 README 更新本版要点、Release Note 链接、版本管理与更新说明读取来源。
- [双语 Release Note](release-notes-v2.2.1.md) 使用精确语言标题，每种语言 3 条顶层要点，每条不超过 50 字符；补充细节使用段落。
- 双语 CONTRIBUTING 和本地 `AGENTS.md` 固化每次发版的文档同步、正文解析与先提交再打 tag 规则；本地规则不提交远端。
- README 封面版本文字更新为 `v2.2.1`，尺寸为 `2560×1280`；界面截图保留其原有版本说明。

## 验证与发布进度

- 2026-10-11：在脱离 Codex 共享 daemon 进程链的隔离环境完成 `CC_PETS_STRICT=1 npm test`，全套通过，包括控制终端回落、Retina 图片加载、多语言、CC Bridge、真实事件流与 shim 不污染检查。
- 首轮直接运行停在控制终端回落检查；源码检测到共享 daemon 时会拒绝推断终端，隔离复验通过，未修改代码或跳过检查。
- 使用真实 `ReleaseNoteHighlightsForLanguage` 校验本版正文：英语与简体中文各 3 条，无截断；小写 `english` 不匹配。
- 二进制版本、app 短版本与构建版本均为 `2.2.1`，应用签名、版本文档本地链接与图片路径、diff 空白检查通过。
- 发布准备提交 `cf885fa` 已推送 `publish`；[PR #11](https://github.com/Sunnyshinnny776/cc-pets/pull/11) 的 macOS CI 通过后 squash 合并到 `main`，集成提交为 `bceca64`。
- 本地 `main` 集成环境复验 `CC_PETS_STRICT=1 npm test` 全套通过；远端 squash 集成树与本地已验证的发布准备树完全一致。
- 正式 tag `v2.2.1` 指向 `bceca64`；GitHub Release 为正式版本（非 draft、非 prerelease），使用已提交的本版 Release Note。
- GitHub Release 正文、远端 tag 中的正文文件与本地已验证文件逐一比对一致。
- 本地桌面端已安装并重启为 `2.2.1`，签名校验通过，安装的二进制与已验证构建一致。
- npm 登录检查返回 `ENEEDAUTH`，未执行 npm 发布；自动更新仍等待对应 npm 版本上线。
