# 参与贡献

[English](./CONTRIBUTING.md) | 简体中文

感谢你参与 CC Pets。提交改动前，请先确认：

1. 改动聚焦于一个明确问题，并避免提交无关格式化。
2. 新素材必须是原创作品，或具有允许修改和再分发的明确许可证。
3. 不要提交 Codex/Claude 会话、额度缓存、API Key、Cookie、个人路径或其他敏感信息。
4. 运行 `npm test`，确保原生构建、Hooks、额度采集、卸载和包装器测试全部通过。
5. 对用户可见的行为变化同步更新 `README.zh-CN.md` 和 `CHANGELOG.zh-CN.md`。

建议先开一个 GitHub Issue 描述较大的功能改动，达成一致后再提交 Pull Request。

## 分支与发布规则

在 `publish` 完成开发、修改、测试和测试版本准备。测试版本必须在 GitHub 标记为
prerelease，并使用如 `2.2.0-rc.1` 的预发布版本号。`main` 仅负责正式版本，包括正式
GitHub Release 和 tag。提交到 `main` 前，代码、文档、截图与验证必须全部完成；
在 `main` 完成集成验证后才能发布正式版本。
测试版本需显式安装，自动更新器只接受正式版本号。
当前待发布版本为 **v2.2.0**，作为首个英文语言版本。
验证和交接状态见[发布状态](docs/release-status.md)。

## 多语言

界面文案在源码里写英文原文，这段原文就是其他各语言表的 key：

- Objective-C：用户可见的字符串包在 `L(@"…")` 里（见 `Sources/CCPets/CCPetsL10n.h`）。
  译文需要调换参数顺序时用 `%1$@` / `%2$@`。
- Node.js：用 `scripts/i18n.mjs` 的 `t("…", { name })`，参数写成 `{name}` 占位。
- zsh：用 `scripts/i18n.zsh` 的 `cc_pets_t "…" name="$value"`。原文必须是字面量，
  变量一律写成 `{name}` 占位，不能直接拼进原文。

新增或修改英文原文时，要同步更新每张表里的 key。`node scripts/check-l10n.mjs`（`npm test`
也会跑）会逐个语言报出缺翻译、多余条目和占位符不一致。

### 新增一种语言

新增语言只需要加文件，不用改代码。以语言 `xx` 为例（用 macOS 的语言标识，如 `ja`、`zh-Hant`）：

1. `Resources/xx.lproj/Localizable.strings`：复制 `zh-Hans` 那张表，逐条翻译值。
   填好两条元信息：`"Language Name"`（「语言」菜单里显示的名字，用该语言自己的写法）和
   `"Release Notes Section"`（GitHub Release 说明里该语言段落的标题，多种写法用 `|` 隔开）。
2. `Resources/xx.lproj/InfoPlist.strings`：翻译 `NSAppleEventsUsageDescription`。
3. `scripts/locales/xx.json`：复制 `zh-Hans.json`，翻译 CLI 文案。
4. 可选：`Resources/phrases.default.xx.txt`，从 `phrases.default.en.txt` 翻译默认台词；
   没有的话桌宠退回英文台词。

`node scripts/check-l10n.mjs --missing xx` 会列出还没翻译的 key。App 按 `.lproj` 目录发现语言，
`build.sh` 据此生成 `CFBundleLocalizations`，`package.json` 已按通配符包含这些文件。

### GitHub Release 说明

每个 GitHub Release 的正文必须按语言分段。使用完全匹配的标题 `## English` 和
`## 简体中文`，标题下面写对应语言的顶层列表要点。更新器只读取与当前界面语言标题
完全匹配的段落，不会退回全文，也不会读取其他语言；缺少匹配段落时，更新对话框不展示
要点，不会从其他文字中猜测。英文和简体中文的要点应保持语义对应。

## 素材规范

- 支持 PNG 或 WebP，背景必须透明。
- 内置素材按 `8×9` 网格切分。外部 Codex/PetDex 素材支持
  `spriteVersionNumber` v1（`1536×1872`、`8×9`）和
  v2（`1536×2288`、`8×11`），每格均为 `192×208`。
- 九行动画帧数依次为 `6/8/8/4/5/8/6/6/6`，未使用单元格必须保持透明。
- 请在 Pull Request 中说明素材作者、来源和许可证。
