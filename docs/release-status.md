# v2.3.0 发布准备状态

目标版本为 `v2.3.0`，在 `publish` 分支完成本地发布前准备。代码基线为 `264fc35502f8b73bf87b68ba62883cd552fa0337`（PR #19）。

2026-10-20 只读核验：最新 GitHub 正式 Release 和 npm Registry 版本均为 `v2.2.1` / `2.2.1`。
历史记录见 [v2.2.1 发布状态](release-status-v2.2.1.md)；更早记录见 [v2.2.0 发布状态](release-status-v2.2.0.md)。

## 本次交付范围

- 新增主窗口：概览、会话、用量、宠物、提醒、设置和诊断，以及 `cc-pets open [page]`。
- Claude / Codex 多 Home 账号管理，额度、历史、在线与审批状态、Hooks 和 CC Bridge 集成按账号隔离；用量展示模式按账号保存。
- 最近 7、30、90 天的本机 Token 用量分析，按账号和模型筛选、每日图表和按日归档。
- Hooks、CC Bridge、诊断和素材管理的原生运行时；Node.js 仅用于 npm 安装与升级。
- 诊断页支持已登记账号的 Hooks 和 Claude status line 自动修复，修改前备份；另有窗口外观、玻璃压暗、ByteMochi 迁移及终端、会话和气泡修复。

## 发布材料

- `package.json` 更新为 `2.3.0`，构建将版本写入二进制及 App 元数据。
- 双语 README 更新本版要点与 Release Note 链接；双语 CHANGELOG 将已交付改动归入 `2.3.0`，保留空的 `Unreleased` 和全部历史版本。
- [双语 Release Note](release-notes-v2.3.0.md) 使用精确语言标题，每种语言 3 条顶层要点、每条不超过 50 字符；补充说明使用段落，并链接到本版 tag 的 CHANGELOG。
- 封面仅替换版本号中的两个数字，尺寸保留 `2560×1280`；逐像素比对共 1545 个像素变化，数字区域外保持一致。
- 中英文主窗口图更新为当前原生 UI 的会话页，均为 `2200×1400`，使用演示会话数据并在 README 明确标注。旧额度面板和菜单图保留历史版本标注。

## 验证与交接进度

| 阶段 | 状态 |
| --- | --- |
| 本地版本与发布材料 | 已完成，纳入本次发布准备提交 |
| `CC_PETS_STRICT=1 npm test` | 2026-10-20 全套通过，退出码 0 |
| Release Note 真实解析、版本、签名、链接与封面 | 核验通过，详见下文 |
| 本地提交 | 2026-10-20：本地 `publish` 发布准备提交，提交号见 Git 历史 |
| push | 本轮未执行 |
| PR 创建与合并 | 本轮未执行 |
| `main` 集成与集成后复验 | 待负责人按单独授权执行 |
| 正式 tag 与 GitHub Release | 本轮未创建、未发布 |
| npm 发布 | 本轮未执行 |

Codex 本轮职责为本地发布前准备、验证与经授权的本地提交。正式版本在 `main` 集成复验完成后由其负责人按授权创建 tag、发布 GitHub Release；npm 由既有负责人协调。GitHub Release 正文须使用已提交的本版 Release Note 文件。每项 Git / 发布动作分别授权、分别报告。

## 本轮验证证据

- 严格回归在脱离 Codex 共享 daemon 的临时 runner 中执行（runner 的 PPID 为 1），耗时约 99 秒；包含原生构建、多语言、Release 解析、CC Bridge、真实事件流及 shim 不污染检查，退出码为 0。
- `package.json`、裸二进制、App 内二进制、`CFBundleShortVersionString` 和 `CFBundleVersion` 均为 `2.3.0`；`codesign --verify --deep --strict` 通过。
- 使用真实 `ReleaseNoteHighlightsForLanguage` 解析最终正文：英语与简体中文各 3 条，无截断；英语长度为 50、40、47，中文为 18、25、16。小写 `english` 无匹配结果。
- 40 个本地文档及图片链接存在；Release Note 的 CHANGELOG 链接均指向目标 `v2.3.0` tag，待负责人创建 tag 后生效。
- 旧 CHANGELOG 版本段保持原样，v2.2.1 发布状态逐字节归档；封面数字区域外逐像素一致。中英文会话页渲染结果已目视核验，真实账号端到端交互本轮未验证。
- 日志和临时校验程序保存在本地忽略目录 `.build/release-prep-v2.3.0/`；本地 agent 规则保持私有。

## 升级交接

升级后需运行一次 `cc-pets install`，刷新原生集成与已安装 App；重启现有 Codex 会话并在 `/hooks` 中重新信任 Hooks。本轮未执行本机安装或重启。
