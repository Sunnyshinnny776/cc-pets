# CC Pets Terminal for JetBrains IDEs

本地 macOS 插件，支持基于 IntelliJ 平台的 JetBrains IDE 2026.2 / 2026.3 的 **Reworked** 终端
（IntelliJ IDEA、PyCharm、WebStorm、GoLand、CLion、PhpStorm、RubyMine、Rider 等）。
Android Studio 的平台版本通常落后，需其基线达到 262 后才能安装。
Classic 终端、远程开发和分屏内子终端暂不作为支持范围。

## 安装

1. 在 Pet 的「设置 → 通用 → 终端跳转」找到对应 IDE，点「安装」并确认。
   Pet 把随包 ZIP 解压到该 IDE 的插件目录 `<配置目录>/plugins/cc-pets-terminal`。
2. IDE 正在运行时该行显示「需要重启」，重启后加载。
3. 打开一个项目。Pet 会自动检测连接；无需填写端口或手动配对。
4. 在 Reworked 终端中启动 Agent 并触发新的 Hook 卡片，点击卡片跳转。

只在用户确认后写入，且只写 `cc-pets-terminal` 一个目录：先解压到同目录下的临时文件夹，
校验 jar 后再改名替换，失败时恢复旧版本。目标目录必须属于当前用户且不是符号链接；
IDE 从未启动过（配置目录不存在）或 `idea.properties` 自定义了 `idea.config.path` /
`idea.plugins.path` 时不自动安装，改为手动：Settings → Plugins → ⚙ → Install Plugin from Disk。
已连接过的 IDE 使用插件上报的真实插件目录。用户在 IDE 中禁用的插件保持禁用。

随 CC Pets 更新的 ZIP 版本更高时，该行显示「更新」，流程同安装。卸载或禁用通过 IDE 的
Plugins 设置完成。ZIP 尚未发布到 JetBrains Marketplace。
每个 IDE、稳定版和 EAP 的插件配置独立，需要分别安装。

## 工作方式

每个 IDE 进程注册独立的本机端点。新终端通过 `LocalTerminalCustomizer`
得到 `CC_PETS_IDE_INSTANCE_ID` 和 `CC_PETS_IDE_TERMINAL_ID`；Pet 的 Hook 记录保留
这两个值。插件按标识查找终端，范围包括终端工具窗口的标签页和「作为编辑器标签页打开」后
位于编辑器区（含拆出的独立窗口）的终端，再前置项目窗口、选择标签页并聚焦输入组件。
已打开的终端没有这些标识时，使用其启动 PID 的控制 TTY 精确匹配；不按标题或工作目录猜测。
若 PID 不可用、终端已关闭、匹配不唯一或 IDE 正显示模态对话框，返回失败并提示用户。

Codex 使用共享后台时，会话与终端的配对由 Pet 完成。多个客户端在同目录启动时，
Pet 参考本机 `logs_2.sqlite` 中 TUI 的就绪时刻与进程身份，避免网络初始化延迟导致串台。
它只查询启动元数据；该日志格式是 Codex 内部实现，缺失、变更或同时就绪造成歧义时
不会按“最近启动”猜测。显式 `codex resume <会话 ID>` 可直接按参数匹配。

注册文件位于 `~/Library/Application Support/CC Pets/ide-instances/`。
目录权限为 `0700`，文件为 `0600`，每个进程使用独立随机令牌。
通信仅监听 `127.0.0.1`，要求带 Bearer 令牌的 POST，并拒绝浏览器 Origin 请求。
仅提供状态查询和聚焦操作，不读取终端输出，不向终端输入命令。
Pet 不跟随重定向、不使用代理；过期注册通过进程路径和认证查询排除。
正常卸载/退出会清除注册，异常退出留下的文件不会被视为有效连接。

## 构建

使用 zsh、macOS 自带的 XML/ZIP 工具，以及已安装 IDEA 自带的 Java 25 编译模块，
无需 Python、Gradle 或下载依赖：

```sh
./scripts/build-idea-plugin.sh --ide '/Applications/IntelliJ IDEA.app'
```

输出为 `Resources/IDEPlugins/cc-pets-terminal.zip`，随 npm 包及 Pet 应用一起分发。
普通用户安装 Pet 时不需要 JDK；修改插件源码后，开发者需要重新生成此 ZIP。
可通过 `--output` 指定临时输出，例如检查另一个 IDEA SDK 的编译兼容性。
发布插件时同时更新 `plugin.xml` 和桥接状态中的版本号。

目前的验证包含 2026.2.3、2026.3 EAP SDK 编译和静态检查；真实 IDE 中的安装和
卡片跳转仍需人工验收。该项目默认不执行自动化测试。
