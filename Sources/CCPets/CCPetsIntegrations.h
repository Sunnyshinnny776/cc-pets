#import <Foundation/Foundation.h>

// CC Pets 在 Claude Code / Codex 配置和 shell 里留下的集成：Agent Hooks、Claude status line
// 额度采集、.zshrc 里的 shim 段落与 shim 软链。原先是 scripts/install-claude-hooks.mjs、
// install-codex-hooks.mjs 和 uninstall-integrations.mjs，改成原生实现后安装和卸载都不再依赖 Node。
// CC Bridge 的集成不在这里，仍由 scripts/bridge 负责。

// 写进 Claude Code / Codex 配置里的条目怎么认。安装、卸载、cc-pets doctor 共用这一份，
// 以免哪天改了写法，doctor 还按旧规则说"一切正常"。Legacy 是改名前（codex-pet）的写法。
extern NSString *const CCPetsClaudeHookMarker;
extern NSString *const CCPetsLegacyClaudeHookMarker;
extern NSString *const CCPetsCodexHookMarker;
extern NSString *const CCPetsLegacyCodexHookMarker;
extern NSString *const CCPetsStatusLineMarker;
extern NSString *const CCPetsLegacyStatusLineMarker;
extern NSString *const CCPetsStatusLineStartMarker;
extern NSString *const CCPetsStatusLineEndMarker;
extern NSString *const CCPetsCreatedStatusLineMarker;
extern NSString *const CCPetsShimStartMarker;
extern NSString *const CCPetsShimEndMarker;

// marker + 指向 <包目录>/.build/release/<executable> 的 --hook 命令才算自家条目。
BOOL CCPetsIsManagedHookCommand(id command, NSString *marker, NSString *executable);
// 包装器形态的 status line：marker + bin/claude-statusline-with-pet + base64 编码的原命令。
BOOL CCPetsIsManagedStatusLine(NSString *command, NSString *marker);
// 能就地注入 prelude 的 status line 命令解析出的脚本：@{script, target, interpreter, flags}，不能注入时为 nil。
NSDictionary<NSString *, id> *CCPetsParseStatusLineCommand(id command);

// 写入 Hooks。binary 是写进 hook 命令的 cc-pets 路径，必须是 <包目录>/.build/release/cc-pets：
// 卸载和 cc-pets doctor 按这个后缀认领条目。
// Claude 的 status line 包装器取同一包目录下的 bin/claude-statusline-with-pet。
//
// 返回进程退出码：0 成功或没装对应 CLI（跳过不算失败，install-shell-integration.sh 是 set -eu，
// 非零会把后续步骤全部带停），1 配置文件无法解析或写入，2 缺参数。
int InstallClaudeHooks(NSString *binary);
int InstallCodexHooks(NSString *binary);

// 移除上面写入的一切，并还原 status line。shellRC 为 nil 时不碰 shell 配置。
// preparingInstall：安装前的清理，只迁移改名前（codex-pet 时代）的旧条目和 alias 段落，
// 当前版本的 Hooks、status line 注入和 shim 都留给紧接着的安装去覆盖。
// 返回 0；有配置文件解析失败时照常处理其余部分，最后返回 1。
int UninstallIntegrations(BOOL preparingInstall, NSString *shellRC);

// 记下 npm 安装时用的 node 与 npm-cli，供应用内一键更新使用（<Application Support>/CC Pets/updater.json）。
int ConfigureUpdater(void);
