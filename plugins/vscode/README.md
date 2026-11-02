# CC Pets Terminal for VS Code

本地 macOS 扩展，让 CC Pets 的 Agent 卡片精确跳回 VS Code 集成终端。适用于 VS Code 1.80+
及其分支（Cursor、Windsurf、VSCodium、VS Code Insiders 等）。终端位于面板、分屏或编辑器区
都可以选中。远程窗口（Remote SSH / WSL / Dev Container）里的终端不在支持范围内。

Pet 不按 bundle ID 列名单识别分支：带有 `Contents/Resources/app/product.json` 的应用都视为
VS Code 家族，从中读取 CLI 名称（`applicationName`）和数据目录（`dataFolderName`）。

## 安装

1. 在 Pet 的「设置 → 通用 → 终端跳转」找到对应应用，点「安装」并确认。
   Pet 调用应用自带的 CLI 安装随包 VSIX：
   `<App>/Contents/Resources/app/bin/<applicationName> --install-extension cc-pets-terminal.vsix --force`。
   扩展目录、`extensions.json` 和配置文件（profile）都交给应用自己处理。
2. 已打开的窗口通常会自动加载新装的扩展；没连上时执行「Developer: Reload Window」。
   更新扩展后需要重新加载窗口，该行在这期间显示「需要重新加载」。
3. 在终端中启动 Agent，触发新的 Hook 卡片后点击卡片跳转。

应用没有 CLI 时改为手动安装：扩展视图 → ⋯ → 从 VSIX 安装…（Install from VSIX…）。
每个应用的扩展相互独立，需要分别安装。

## 工作方式

每个窗口有自己的 extension host，所以每个窗口各注册一个本机端点。点击卡片时：

1. Pet 用 Hook 记录的 TTY 依次询问同一应用的各个窗口。
2. 扩展用 `terminal.processId` 和 `ps -o tty=` 把各终端换成 TTY 后精确比对。
   唯一匹配的窗口调用 `terminal.show()` 选中终端并聚焦输入，然后回报自己的工作区路径。
3. 扩展 API 没有前置系统窗口的接口。Pet 把这个工作区（文件夹或 `.code-workspace`）
   交给应用再打开一次，VS Code 会聚焦已打开它的那个窗口，必要时切换桌面。
   路径不存在时不打开，避免开出新窗口；空窗口没有工作区，这时只激活应用。
4. 找不到对应终端（例如扩展装好之前就开着的远程窗口）或没有连接中的窗口时，Pet 退回到只激活应用。

TTY 在本机唯一，不按标题、工作目录或终端顺序猜测。从 JetBrains 终端里用 `code` 启动的
VS Code 会把 `CC_PETS_IDE_*` 继承给自己的终端；Pet 看到目标应用属于 VS Code 家族时忽略这两个值，
不交给 JetBrains 插件。扩展不改终端环境变量：`environmentVariableCollection` 一变，VS Code
会自动重启尚未交互的终端，或给已有终端挂上需要重启的提示。

注册文件与 JetBrains 插件共用 `~/Library/Application Support/CC Pets/ide-instances/`，以
`"kind": "vscode"` 区分。目录权限为 `0700`，文件为 `0600`，每个窗口使用独立的随机令牌。
通信仅监听 `127.0.0.1`，要求带 Bearer 令牌的 POST，并拒绝带浏览器 Origin 的请求。
只提供状态查询（`/status`）和聚焦（`/focus`），不读取终端输出，不向终端输入。
注册文件中的主程序 PID 和 `.app` 路径必须对应一个正在运行的 VS Code 家族应用，
extension host 的 PID 也必须存活，因此关掉的窗口留下的文件不会被视为有效连接。

## 构建

只用 macOS 自带的 zsh、plutil、xmllint 和 zip，不需要 Node、npm 或 vsce：

```sh
./scripts/build-vscode-extension.sh
```

输出为 `Resources/IDEPlugins/cc-pets-terminal.vsix`（固定时间戳，重复构建结果一致），
随 npm 包及 Pet 应用一起分发。修改扩展后需要重新生成 VSIX 并提交。
发布新版时更新 `package.json` 的 `version`，Pet 据此提示「更新」。

调试时可用开发模式加载源码目录：

```sh
code --extensionDevelopmentPath="$PWD/plugins/vscode"
```
