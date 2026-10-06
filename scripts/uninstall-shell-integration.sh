#!/bin/zsh
set -eu

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
source "${PROJECT_DIR}/scripts/i18n.zsh"
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
    print -u2 "$(cc_pets_t "A full uninstall removes the app, quota history, updater config, logs and preferences (keeping pets and lines in ~/.cc-pets). Add --yes when running non-interactively.")"
    exit 2
  fi
  print -u2 "$(cc_pets_t "A full uninstall permanently removes the CC Pets app, quota history, updater config, logs and preferences; pets and lines in ~/.cc-pets are kept. Continue? [y/N] ")"
  if ! read -r reply || [[ "${reply:l}" != "y" && "${reply:l}" != "yes" ]]; then
    print "$(cc_pets_t "Full uninstall canceled.")"
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
      print -u2 "$(cc_pets_t "Full uninstall failed: CC Pets didn't quit, so no integrations or local data were removed.")"
      exit 1
    fi
  fi
fi

node "${PROJECT_DIR}/scripts/uninstall-integrations.mjs" "${SHELL_RC}"

if (( PURGE )); then
  if [[ ! -x "${PET_BIN}" ]]; then
    print -u2 "$(cc_pets_t "Full uninstall failed: {petBin} not found, so local data wasn't removed." petBin="${PET_BIN}")"
    exit 1
  fi
  "${PET_BIN}" --purge-data
  CC_PETS_SKIP_APP_STOP=1 "${PROJECT_DIR}/scripts/uninstall-app.sh"
  print "$(cc_pets_t "Full uninstall done. Pets and lines remain in ~/.cc-pets; delete them manually if you no longer need them. If the npm package is still installed, run npm uninstall -g cc-pets.")"
  exit 0
fi

print "$(cc_pets_t "Integrations removed. Run source {shellRc} to update this terminal; to remove the npm package, run npm uninstall -g cc-pets." shellRc="${(q)SHELL_RC}")"
