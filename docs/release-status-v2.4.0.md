# v2.4.0 发布状态

2026-11-03 在 `publish` 分支准备 v2.4.0。代码基线为 `277c7f08b5f23fedd6f57456ecc7a772acf41a78`（PR #25）；包含 v2.3.0 之后的 PR #23、#24、#25。以下保留准备阶段的历史快照；正式发布结果见下方记录。

历史记录已逐字节归档至 [v2.3.0 发布状态](release-status-v2.3.0.md)；更早记录见 [v2.2.1](release-status-v2.2.1.md) 和 [v2.2.0](release-status-v2.2.0.md)。

## main 集成与正式发布（2026-11-03）

- PR #26 与 PR #27 已合并；本地 `main` 快进至 `4da042c7171e39874c95df37ace24eb69b431cb8`，与远端一致。
- 在该提交重新运行 `CC_PETS_STRICT=1 npm test`，全套通过，退出码 0，耗时 47 秒；runner 脱离共享 Codex daemon 的父进程链，真实事件流与 shim 污染检查通过。
- 同一提交的 [main CI](https://github.com/Sunnyshinnny776/cc-pets/actions/runs/41627543933) 通过。
- package、裸二进制、App 内二进制及两个 plist 版本字段均为 `2.4.0`；`codesign --verify --deep --strict` 通过。
- 双语 Release Note 实际解析各得到 3 条对应要点，无截断；多语言检查、51 个本地文档/图片链接、历史 CHANGELOG 与 v2.3.0 Release Note 保留检查及 `git diff --check` 通过。
- 已推送 annotated tag `v2.4.0`，指向上述 main 提交；已发布 [CC Pets 2.4.0](https://github.com/Sunnyshinnny776/cc-pets/releases/tag/v2.4.0)，发布时间为 `2026-11-03T11:31:13Z`，为正式版本，非 draft、非 prerelease。
- 发布后已核对远端 tag 指向，GitHub Release 正文与 tag 内 `docs/release-notes-v2.4.0.md` 逐字节一致。
- 本轮未执行 npm 发布，交由既有负责人协调；未更新本机已安装 App。未重新进行完整终端跳转或 VPN 实网人工验收。

发布后的文档记录在 `publish` 准备，经 PR 集成回 `main`；正式 tag 保持指向已验证的发布提交。

## 交付范围

- 终端精准跳转：VS Code 1.80+ 及其分支、JetBrains 2026.2 / 2026.3 Reworked 终端，以及 Ghostty 1.4+、iTerm2；设置页管理权限、扩展和连接状态。远程 IDE、JetBrains Classic 和分屏内子终端不在支持范围内。
- 可选 Shadowrocket 启动保护，默认关闭；包装脚本在启动前检查 VPN 与服务出口，检查失败时阻止启动。绕过包装脚本的启动不受此检查覆盖。
- CC Bridge 身份匹配、并发更新、收件确认恢复、账号 Home 路由与 watcher 开关修复，简化跨会话消息信封；输出与确认之间崩溃仍可能重复消息。
- Codex cache write 去重与归档迁移、后台用量补充、模型独立图表、分账号低额度提醒。
- 设置页外观与终端列表调整、Liquid Glass 压暗预览和 0–100 显示刻度；宠物页确认删除未选中的自定义宠物及素材目录变化刷新。
- 签名后二进制原子替换、构建执行检查和测试失败定位改进。

## 发布材料

`package.json`、双语 README、双语 CHANGELOG、[双语 Release Note](release-notes-v2.4.0.md) 和封面统一为 v2.4.0。CHANGELOG 保留空的 `Unreleased`，本版日期为准备日期 2026-11-03；正式发布日期如有变化，由发布负责人同步调整。v2.3.0 及更早的 CHANGELOG 和 Release Note 保持原文。

Release Note 每种语言恰好三条顶层要点，每条不超过 50 字符；补充说明使用段落，CHANGELOG 链接指向目标 v2.4.0 tag，创建 tag 前尚未生效。正式发布必须使用已提交的该文件，不能以 GitHub 自动生成正文替代。

## 验证与交接进度

下表为发布准备提交前的验证快照。用户随后已授权本地提交、push `publish` 和创建面向 `main` 的 PR；实际提交号、远端同步与 PR 状态以 Git 历史及对应 PR 为准。合并、tag、GitHub Release 和 npm 发布仍未执行。

| 阶段 | 状态 |
| --- | --- |
| 本地同步 | `publish` 已 fast-forward 至 `277c7f0` |
| 版本与发布材料 | 已准备，尚未提交 |
| v2.4.0 严格回归 | 2026-11-03 `CC_PETS_STRICT=1 npm test` 全套通过，退出码 0，耗时 69.4 秒；runner 脱离共享 daemon |
| Release Note 实际解析 | 英语、简体中文各 3 条，无截断；长度分别为 44/47/46、14/22/17；精确语言标题校验通过 |
| 封面 | 2560×1280，仅版本数字区域的 361 个像素变化；区域外逐像素一致，已目视核验 v2.4.0 |
| 二进制、App 版本与签名 | package、裸二进制、App 内二进制及两个 plist 版本字段均为 2.4.0；`codesign --verify --deep --strict` 通过 |
| 文档链接、历史保留与 diff 检查 | 54 个本地文档/图片链接存在，目标 tag URL 版本一致；历史 CHANGELOG、v2.3.0 Release Note 和发布状态归档逐字节核验通过；`git diff --check` 通过 |
| 本地提交 | 本轮未执行 |
| push | 本轮未执行 |
| PR 创建 / 合并 | 本轮未执行 |
| `main` 集成及复验 | 本轮未执行，由 `main` 负责人按授权完成 |
| 正式 tag / GitHub Release | 本轮未执行 |
| npm 发布 | 本轮未执行，按既有负责人分工协调 |
| 本机安装 | 本轮未执行 |

本轮仅修改发布材料，未修改产品源码、扩展或测试。终端真实跳转、VPN 实网、消息崩溃恢复和最新设置/宠物页面的双语交互未在本轮重新人工验收；仓库中既有的 JetBrains 人工验收记录属于此前证据。现有 README 产品截图沿用原图。严格回归通过也不替代这些人工验收。

本轮校验脚本及日志存放在本地忽略目录 `.build/release-prep-v2.4.0/`；本地 agent 规则不纳入交付。

## 升级与发布交接

升级后运行 `cc-pets install` 刷新已安装 App 和集成，重启正在运行的 Codex 会话，并在 `/hooks` 中信任更新后的 Hooks。终端扩展在设置页安装或更新，按提示重启 JetBrains 或重新加载 VS Code。

准备材料经审阅及分别授权提交、push、创建 PR 后，由 `main` 负责人按授权完成远端集成和复验。Release Note 必须在创建 tag 前提交；正式 tag 和发布另需授权。发布正文使用 `docs/release-notes-v2.4.0.md`，tag 文件与 GitHub Release 正文须一致。

## 诊断版本来源提示补充（2026-11-03）

在 `publish` 工作区补充本地版本来源识别：解析软链后，以包根目录的 `.git` 文件或目录识别源码 checkout/worktree，以 `node_modules` 下的包目录识别本地 npm 包；无法确认时显示“本地包”。诊断页、复制报告与 `paths` 共用该文案，保留安装一致性告警，并明确线上版本由更新检查单独查询。双语 README、CHANGELOG 与 Release Note 已同步。

本轮 `CC_PETS_STRICT=1 npm test` 全套通过（退出码 0，52 秒），包含 5 类来源 × 2 种语言 × 2 种版本匹配状态的 20 组测试；runner 脱离共享 daemon 的父进程链。多语言检查与 `git diff --check` 通过。使用真实诊断页组件和隔离数据生成了源码/npm 两种来源的中英文离屏预览，已核查改动文案无截断；预览只包含版本检查区域，不代表完整桌面端交互验收。

上述验证完成后，维护者已授权将该补充提交并 push 至 `publish`，纳入现有 [PR #27](https://github.com/Sunnyshinnny776/cc-pets/pull/27)，由维护者手动合并；实际提交与合并状态以 PR 为准。本轮未更新已安装 App，未创建正式 tag 或 GitHub Release，未执行 npm 发布。
