#!/bin/zsh
set -eu

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
SHELL_RC="${ZDOTDIR:-${HOME}}/.zshrc"
PET_BIN="${PROJECT_DIR}/.build/release/cc-pets"
PET_APP_EXECUTABLE="${PROJECT_DIR}/.build/release/CC Pets.app/Contents/MacOS/cc-pets"
INSTALLED_APP_EXECUTABLE="${CC_PETS_APPLICATIONS_DIR:-${HOME}/Applications}/CC Pets.app/Contents/MacOS/cc-pets"
LEGACY_PET_APP_EXECUTABLE="${PROJECT_DIR}/.build/release/CodexPet.app/Contents/MacOS/codex-pet"

PURGE=0
ASSUME_YES=0
for argument in "$@"; do
  [[ "${argument}" == "--purge" ]] && PURGE=1
  [[ "${argument}" == "--yes" ]] && ASSUME_YES=1
done

if (( PURGE && ! ASSUME_YES )); then
  if [[ ! -t 0 ]]; then
    print -u2 "完整卸载会删除应用、额度历史、更新配置、日志和偏好（保留 ~/.cc-pets 的素材与台词）。非交互环境请显式添加 --yes。"
    exit 2
  fi
  print -u2 "完整卸载会永久删除 CC Pets 应用、额度历史、更新配置、日志和偏好；~/.cc-pets 下的桌宠素材与台词会保留。是否继续？[y/N] "
  if ! read -r reply || [[ "${reply:l}" != "y" && "${reply:l}" != "yes" ]]; then
    print "已取消完整卸载。"
    exit 0
  fi
fi

if [[ "${CC_PETS_SKIP_APP_STOP:-0}" != "1" ]]; then
  for executable in "${PET_APP_EXECUTABLE}" "${INSTALLED_APP_EXECUTABLE}" "${LEGACY_PET_APP_EXECUTABLE}"; do
    if pgrep -f "${executable}" >/dev/null 2>&1; then
      pkill -f "${executable}" || true
    fi
  done
  if (( PURGE )); then
    for _ in {1..30}; do
      running=0
      for executable in "${PET_APP_EXECUTABLE}" "${INSTALLED_APP_EXECUTABLE}" "${LEGACY_PET_APP_EXECUTABLE}"; do
        if pgrep -f "${executable}" >/dev/null 2>&1; then
          running=1
        fi
      done
      (( running == 0 )) && break
      sleep 0.1
    done
    if (( running != 0 )); then
      print -u2 "完整卸载失败：CC Pets 未能退出，尚未删除集成或本地数据。"
      exit 1
    fi
  fi
fi

node "${PROJECT_DIR}/scripts/uninstall-integrations.mjs" "${SHELL_RC}"

if (( PURGE )); then
  if [[ ! -x "${PET_BIN}" ]]; then
    print -u2 "完整卸载失败：找不到 ${PET_BIN}，本地数据尚未删除。"
    exit 1
  fi
  "${PET_BIN}" --purge-data
  CC_PETS_SKIP_APP_STOP=1 "${PROJECT_DIR}/scripts/uninstall-app.sh"
  print "完整卸载完成；桌宠素材与台词保留在 ~/.cc-pets，不再需要可手动删除。npm 包本身如仍存在，可继续执行 npm uninstall -g cc-pets。"
  exit 0
fi

print "卸载集成完成。执行 source ${(q)SHELL_RC} 更新当前终端；如需删除 npm 包，再执行 npm uninstall -g cc-pets。"
