#!/bin/zsh
set -eu

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
source "${PROJECT_DIR}/scripts/i18n.zsh"
LAUNCHER="${PROJECT_DIR}/bin/codex-with-pet"
CLAUDE_LAUNCHER="${PROJECT_DIR}/bin/claude-with-pet"
SHELL_RC="${ZDOTDIR:-${HOME}}/.zshrc"
SHIM_DIR="${CC_PETS_SHIM_DIR:-${HOME}/.cc-pets/shims}"
SHIM_START_MARKER="# >>> cc-pets-shims >>>"
SHIM_END_MARKER="# <<< cc-pets-shims <<<"

# 安装本身不需要 Node。npm 装包时 node 所在目录（nvm 之类）里通常也有 claude / codex，
# 补进 PATH，下面探测 CLI、注册 MCP 才找得到它们。
NODE_EXECUTABLE="${npm_node_execpath:-}"
if [[ -z "${NODE_EXECUTABLE}" || ! -x "${NODE_EXECUTABLE}" ]]; then
  NODE_EXECUTABLE="$(command -v node || true)"
fi
if [[ -n "${NODE_EXECUTABLE}" && -x "${NODE_EXECUTABLE}" ]]; then
  export PATH="${NODE_EXECUTABLE:h}:${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
fi

"${PROJECT_DIR}/scripts/build.sh"
PET_BINARY="${PROJECT_DIR}/.build/release/cc-pets"
# 只迁移已经含 CC Pets 管理标记的默认 Home；不扫描或自动接管其他目录。
"${PET_BINARY}" profile migrate
# 官方默认 Home 保持旧版的自动集成行为；其他 Home 仍必须从菜单手动导入。
"${PET_BINARY}" profile ensure-defaults
# 先迁移改名前留下的旧条目和 alias 段落，当前版本的集成留给下面原位覆盖。
"${PET_BINARY}" --uninstall-integrations --prepare-install "${SHELL_RC}"
"${PROJECT_DIR}/scripts/install-app.sh"
# 安装/升级适配官方默认 Home，并修复用户明确登记过的自定义 Home。
"${PET_BINARY}" profile repair-all || \
  print -u2 "$(cc_pets_t "Some registered Agent profiles need repair; open Multi-Account in the main window and retry.")"
"${PET_BINARY}" --configure-updater
# CC Bridge 默认关闭；用户开启过的话，包路径可能随升级变化，按原选项重写一遍集成。
"${PET_BINARY}" bridge refresh || \
  print -u2 "$(cc_pets_t "Failed to refresh the CC Bridge integration; retry later with cc-pets bridge enable.")"

PET_APP="${PROJECT_DIR}/.build/release/CC Pets.app"
PET_APP_EXECUTABLE="${PET_APP}/Contents/MacOS/cc-pets"
INSTALLED_PET_APP="${CC_PETS_APPLICATIONS_DIR:-${HOME}/Applications}/CC Pets.app"
INSTALLED_PET_APP_EXECUTABLE="${INSTALLED_PET_APP}/Contents/MacOS/cc-pets"
LEGACY_PET_APP_EXECUTABLE="${PROJECT_DIR}/.build/release/CodexPet.app/Contents/MacOS/codex-pet"
PET_WAS_RUNNING=0
for executable in "${PET_APP_EXECUTABLE}" "${INSTALLED_PET_APP_EXECUTABLE}" "${LEGACY_PET_APP_EXECUTABLE}"; do
  if pgrep -f "${executable}" >/dev/null 2>&1; then
    pkill -f "${executable}" || true
    PET_WAS_RUNNING=1
  fi
done
if (( PET_WAS_RUNNING )); then
  for _ in {1..30}; do
    if ! pgrep -f "${PET_APP_EXECUTABLE}" >/dev/null 2>&1 && \
       ! pgrep -f "${INSTALLED_PET_APP_EXECUTABLE}" >/dev/null 2>&1 && \
       ! pgrep -f "${LEGACY_PET_APP_EXECUTABLE}" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  open -g "${INSTALLED_PET_APP}" --args --managed
  print "$(cc_pets_t "Restarted the running pet so the new version takes effect now.")"
fi

# 早期版本用 alias 接管 codex / claude。alias 名区分大小写，而 macOS 文件系统默认不区分：
# 用户敲 Claude / CODEX 时 zsh 找不到同名 alias，就直接从 PATH 里命中真二进制，
# 桌宠不会被拉起。改成 PATH 前置的 shim 目录后，任意大小写写法都会命中同一个文件。
mkdir -p "${SHIM_DIR}"
ln -sfn "${LAUNCHER}" "${SHIM_DIR}/codex"
ln -sfn "${CLAUDE_LAUNCHER}" "${SHIM_DIR}/claude"

if ! grep -Fq "${SHIM_START_MARKER}" "${SHELL_RC}" 2>/dev/null; then
  {
    print ""
    print "${SHIM_START_MARKER}"
    # 追加在 .zshrc 末尾，保证排在 nvm 之类会前置 PATH 的初始化之后；
    # path 的唯一属性会去掉旧位置的重复项，然后每次 source 都把 shim
    # 重新放到首位。不能只判断“PATH 里已经存在”：终端恢复旧环境时，
    # shim 可能在 nvm 后面，导致 codex / claude 绕过包装器。
    print "typeset -U path"
    print "path=(${(q)SHIM_DIR} \$path)"
    print "${SHIM_END_MARKER}"
  } >> "${SHELL_RC}"
fi

print "$(cc_pets_t "Installed. CC Pets was added to {installedPetApp}. Run source {shellRc}; after that, running codex or claude (in any capitalization) starts the pet automatically." installedPetApp="${(q)INSTALLED_PET_APP}" shellRc="${(q)SHELL_RC}")"
print "$(cc_pets_t "Default Claude and Codex Homes were integrated automatically; add custom Homes from Multi-Account in the main window.")"
print "$(cc_pets_t "After the first launch, run /hooks and trust the CC Pets hooks to enable Agent animations.")"
