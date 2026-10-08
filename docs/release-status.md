# v2.2.0 发布状态

目标：首个英文语言版本。当前为 `publish` 上的发布准备，尚未发布正式 GitHub Release。

## 分支职责与交付范围

- `publish`：开发、修改、验证和测试版本。测试版本使用预发布号并标记 GitHub prerelease。
- `main`：集成完成的交付，复验后发布正式 tag 和 GitHub Release。
- 提交到 `main` 前，代码、文档、截图和验证必须全部完成。
- npm 发布由独立负责人执行，在对应 GitHub Release 准备好后协调发布。

## 已完成的准备

- `package.json` 版本更新为 `2.2.0`，构建时写入二进制及 app 元数据。
- 英文 App/CLI 本地化、额度面板文案与间距优化、更新弹窗的 Current version 文案。
- Release 要点取消全文 fallback；只读取与当前语言标题完全匹配的段落。
- 中英文 README、CHANGELOG、CONTRIBUTING 更新；新增英文额度面板和语言菜单截图。
- 四张面板/菜单截图均为 `1356×957`；中文 README 只展示两张中文截图，英文 README 只展示两张英文截图，各自两图并排，每张占 45%，合计占页面容器的 90%。
- 双语 [GitHub Release 正文草稿](release-notes-v2.2.0.md)；每个语言段 3 条要点，每条不超过 50 字符。

## 验证与交接

- 2026-10-08：在脱离 Codex 共享 daemon 的隔离环境完成 `CC_PETS_STRICT=1 npm test`，全套通过，包括 Hook 控制终端回落、Release 解析、多语言、CC Bridge 和真实用户状态污染检查。
- 二进制及 app 的短版本/构建版本均验证为 `2.2.0`；本地化检查与 diff 空白检查通过。
- 四张截图均核验为 `1356×957`，英文图等比例缩放并补边，完整保留面板、桌宠和菜单。
- Release 正文通过实际解析函数校验：英语与简体中文各 3 条要点，无截断；小写 `english` 不匹配且不会读取中文。
- README 和状态文档中的本地链接、插图路径完成核验。
- 本交付提交并推送到 `origin/publish`，供本地测试及正式版集成；合并 `main`、正式 tag 和 GitHub Release 待后续发布操作。
- 历史版本记录保留；封面仅将版本文字更新为 v2.2.0，尺寸仍为 `2560×1280`，版本文字区域外逐像素验证保持不变。
