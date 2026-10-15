#import <Foundation/Foundation.h>

// 把 cc-pets 的 Agent Hooks 写进 Claude Code / Codex 的配置，Claude 一侧还要接入 status line
// 采集额度。原先是 scripts/install-claude-hooks.mjs / install-codex-hooks.mjs，改成原生实现后
// 安装不再依赖 Node。
//
// binary 是写进 hook 命令的 cc-pets 路径，必须是 <包目录>/.build/release/cc-pets：
// 卸载和 cc-pets doctor（scripts/integration-markers.mjs）按这个后缀认领条目。
// Claude 的 status line 包装器取同一包目录下的 bin/claude-statusline-with-pet。
//
// 返回进程退出码：0 成功或没装对应 CLI（跳过不算失败，install-shell-integration.sh 是 set -eu，
// 非零会把后续步骤全部带停），1 配置文件无法解析或写入，2 缺参数。
int InstallClaudeHooks(NSString *binary);
int InstallCodexHooks(NSString *binary);
