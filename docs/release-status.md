# v2.3.0 发布准备状态

目标版本保持 `v2.3.0`，在 `publish` 分支完成本地发布前准备。2026-10-21 已同步远端新增的 [PR #21](https://github.com/Sunnyshinnny776/cc-pets/pull/21)，代码基线更新为 `83ba417236609de75bda8b56ec1311d6e7b9f0de`，包含原先 PR #19 的改动。

2026-10-21 只读核验：最新 GitHub 正式 Release 和 npm Registry 版本仍为 `v2.2.1` / `2.2.1`；`v2.3.0` 尚未正式发布。
历史记录见 [v2.2.1 发布状态](release-status-v2.2.1.md)；更早记录见 [v2.2.0 发布状态](release-status-v2.2.0.md)。

## 本次交付范围

- 新增主窗口：概览、会话、用量、宠物、多账号、提醒、设置和诊断，以及 `cc-pets open [page]`。
- Claude / Codex 多 Home 账号管理，额度、历史、在线与审批状态、Hooks 和 CC Bridge 集成按账号隔离；用量展示模式按账号保存。
- 最近 7、30、90 天的本机 Token 用量分析，按账号和模型筛选、每日图表和按日归档。
- Hooks、CC Bridge、诊断和素材管理的原生运行时；Node.js 仅用于 npm 安装与升级。
- 诊断页支持已登记账号的 Hooks 和 Claude status line 自动修复，修改前备份；另有窗口外观、玻璃压暗、ByteMochi 迁移及终端、会话和气泡修复。

### PR #21 追加范围

- 账号管理移至主窗口「多账号」页，支持 `cc-pets open accounts`，显示 Home 路径与集成状态，并提供修复、重命名及自定义 Home 的重新定位和移除集成。
- 新建 CC Bridge 会话使用 `<账号名>.<项目目录名>.<动物>` 命名，已有会话保留原名；会话页路由列可使用剩余宽度，完整路由可悬停查看。
- 修复指向 App 包内程序的旧 Pet Hooks 重复累积、Claude Home 被误登记为 Codex 账号及账号操作忙碌时无反馈的问题；设置页移除应用数据目录入口。
- 原生源码按模块重组并拆分较大实现，构建与测试递归发现源码；以上改动全部纳入 `2.3.0`，不另增版本。

## 发布材料

- `package.json` 保持 `2.3.0`，构建将版本写入二进制及 App 元数据；本轮不修改版本号或封面版本。
- 双语 README 和 Release Note 补入「多账号」页、会话命名与升级修复说明；双语 CHANGELOG 将 PR #21 一并归入 `2.3.0`，日期更新为本轮准备日期 `2026-10-21`，保留空的 `Unreleased` 和全部历史版本。
- [双语 Release Note](release-notes-v2.3.0.md) 使用精确语言标题，每种语言 3 条顶层要点、每条不超过 50 字符；补充说明使用段落，并链接到本版 tag 的 CHANGELOG。
- 封面仅替换版本号中的两个数字，尺寸保留 `2560×1280`；逐像素比对共 1545 个像素变化，数字区域外保持一致。
- 中英文主窗口图按 PR #21 的原生 UI 重新渲染，均为 `2200×1400`，展示「多账号」入口与新格式会话名，使用演示会话数据并在 README 明确标注。旧额度面板和菜单图保留历史版本标注。

## 验证与交接进度

| 阶段 | 状态 |
| --- | --- |
| 本地版本与发布材料 | PR #21 已纳入 `2.3.0`；本轮文档与预览更新纳入本次本地提交 |
| `CC_PETS_STRICT=1 npm test` | 2026-10-21 全套通过，退出码 0，耗时约 133 秒 |
| Release Note 真实解析、版本、签名、链接与封面 | 本轮核验通过，详见下文 |
| 本地提交 | 2026-10-21：经用户授权提交本轮文档与预览补充，提交号见 Git 历史；原准备提交 `c3c5e5b` 已重放为 `332cc12`，父提交为远端 PR #21 |
| push | 本轮未执行 |
| PR 创建与合并 | 本轮未执行 |
| `main` 集成与集成后复验 | 待负责人按单独授权执行 |
| 正式 tag 与 GitHub Release | 本轮未创建、未发布 |
| npm 发布 | 本轮未执行 |

Codex 本轮职责为本地 `publish` 同步、发布材料补充与验证。原准备提交已重放到远端最新基线，旧提交保留在本地备份分支 `backup/publish-v2.3.0-pre-pr21-20261021`。本轮文档与预览补充经用户授权纳入本次本地提交；push、PR 及发布动作仍须分别授权。正式版本在 `main` 集成复验完成后由其负责人按授权创建 tag、发布 GitHub Release；npm 由既有负责人协调。GitHub Release 正文须使用已提交的本版 Release Note 文件。

## 2026-10-20 原准备记录

- 严格回归在脱离 Codex 共享 daemon 的临时 runner 中执行（runner 的 PPID 为 1），耗时约 99 秒；包含原生构建、多语言、Release 解析、CC Bridge、真实事件流及 shim 不污染检查，退出码为 0。
- `package.json`、裸二进制、App 内二进制、`CFBundleShortVersionString` 和 `CFBundleVersion` 均为 `2.3.0`；`codesign --verify --deep --strict` 通过。
- 使用真实 `ReleaseNoteHighlightsForLanguage` 解析最终正文：英语与简体中文各 3 条，无截断；英语长度为 50、40、47，中文为 18、25、16。小写 `english` 无匹配结果。
- 40 个本地文档及图片链接存在；Release Note 的 CHANGELOG 链接均指向目标 `v2.3.0` tag，待负责人创建 tag 后生效。
- 旧 CHANGELOG 版本段保持原样，v2.2.1 发布状态逐字节归档；封面数字区域外逐像素一致。中英文会话页渲染结果已目视核验，真实账号端到端交互本轮未验证。
- 日志和临时校验程序保存在本地忽略目录 `.build/release-prep-v2.3.0/`。以上为上一轮证据，本轮结果单独记录。

## 2026-10-21 追加验证证据

- GitHub PR #21 的合入目标为 `publish`，合入提交为 `83ba417236609de75bda8b56ec1311d6e7b9f0de`；本地发布准备提交以它为父提交。
- 严格回归在脱离 Codex 共享 daemon 的 runner 中执行（PPID 为 1），耗时 132.9 秒，退出码为 0；包含递归源码打包检查、账号 Home 校验、Hooks、Release 解析、多语言、CC Bridge 及真实事件流和 shim 不污染检查。
- `package.json`、裸二进制、App 内二进制、`CFBundleShortVersionString` 和 `CFBundleVersion` 均为 `2.3.0`；`codesign --verify --deep --strict` 通过。
- 使用真实 `ReleaseNoteHighlightsForLanguage` 解析最终正文：英语和简体中文各 3 条，无截断，长度分别为 50、40、47 和 18、25、16；小写 `english` 无匹配。独立校验首次未指定本地化目录时退出码为 1，显式设置 `CC_PETS_LOCALIZATION_DIR` 后通过双语校验。
- 38 个本地文档及图片链接存在；Release Note 的 CHANGELOG 链接均指向目标 `v2.3.0` tag，待负责人创建 tag 后生效。
- `package.json`、封面及历史发布状态归档与昨天的准备提交逐字节一致，旧 CHANGELOG 版本段保持原样；双语会话页预览按当前代码重新渲染并目视核验，包含「多账号」入口与演示会话名。真实账号端到端交互本轮未验证。
- 本轮未修改产品源码；6 个文档和 2 张预览图的补充纳入本次本地提交，提交前 `git diff --check` 通过。本地 agent 规则保持私有；日志和临时校验程序保存在忽略目录 `.build/release-prep-v2.3.0-pr21/`。

## 升级交接

升级后需运行一次 `cc-pets install`，刷新原生集成与已安装 App；重启现有 Codex 会话并在 `/hooks` 中重新信任 Hooks。本轮未执行本机安装或重启。
