#!/bin/zsh
set -eu

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
LAUNCHER="${PROJECT_DIR}/bin/codex-with-pet"
CLAUDE_LAUNCHER="${PROJECT_DIR}/bin/claude-with-pet"
SHELL_RC="${ZDOTDIR:-${HOME}}/.zshrc"
SHIM_DIR="${CC_PETS_SHIM_DIR:-${HOME}/.cc-pets/shims}"
SHIM_START_MARKER="# >>> cc-pets-shims >>>"
SHIM_END_MARKER="# <<< cc-pets-shims <<<"

NODE_EXECUTABLE="${npm_node_execpath:-}"
if [[ -z "${NODE_EXECUTABLE}" || ! -x "${NODE_EXECUTABLE}" ]]; then
  NODE_EXECUTABLE="$(command -v node || true)"
fi
if [[ -z "${NODE_EXECUTABLE}" || ! -x "${NODE_EXECUTABLE}" ]]; then
  print -u2 "安装失败：找不到可执行的 Node.js。"
  exit 1
fi
export PATH="${NODE_EXECUTABLE:h}:${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"

"${NODE_EXECUTABLE}" "${PROJECT_DIR}/scripts/uninstall-integrations.mjs" --prepare-install "${SHELL_RC}"
"${PROJECT_DIR}/scripts/build.sh"
"${PROJECT_DIR}/scripts/install-app.sh"
"${NODE_EXECUTABLE}" "${PROJECT_DIR}/scripts/install-codex-hooks.mjs" "${PROJECT_DIR}/.build/release/cc-pets"
"${NODE_EXECUTABLE}" "${PROJECT_DIR}/scripts/install-claude-hooks.mjs" \
  "${PROJECT_DIR}/.build/release/cc-pets"
"${NODE_EXECUTABLE}" "${PROJECT_DIR}/scripts/configure-updater.mjs"
# CC Bridge 默认关闭；用户开启过的话，包路径可能随升级变化，按原选项重写一遍集成。
"${NODE_EXECUTABLE}" "${PROJECT_DIR}/scripts/bridge/cli.mjs" refresh || \
  print -u2 "CC Bridge 集成刷新失败，可稍后执行 cc-pets bridge enable 重试。"

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
  print "已重启正在运行的桌宠，使新版本立即生效。"
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

print "安装完成。CC Pets 已加入 ${(q)INSTALLED_PET_APP}；执行 source ${(q)SHELL_RC}，之后运行 codex 或 claude（含 Codex / Claude 等任意大小写写法）会自动启动桌宠。"
print "首次启动后执行 /hooks，信任 CC Pets Hooks 以启用 Agent 工作动画。"
