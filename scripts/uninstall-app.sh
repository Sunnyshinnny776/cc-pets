#!/bin/zsh
set -eu
source "${0:A:h}/i18n.zsh"

APPLICATIONS_DIR="${CC_PETS_APPLICATIONS_DIR:-${HOME}/Applications}"
TARGET_APP="${APPLICATIONS_DIR}/CC Pets.app"
TARGET_EXECUTABLE="${TARGET_APP}/Contents/MacOS/cc-pets"

if [[ -e "${TARGET_APP}" ]]; then
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "${TARGET_APP}/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "${BUNDLE_ID}" != "com.universewang.cc-pets" ]]; then
    print -u2 "$(cc_pets_t "Refusing to delete: {targetApp} isn't the CC Pets app (bundle ID mismatch)." targetApp="${TARGET_APP}")"
    exit 2
  fi
fi

if [[ "${CC_PETS_SKIP_APP_STOP:-0}" != "1" ]] && pgrep -f "${TARGET_EXECUTABLE}" >/dev/null 2>&1; then
  pkill -f "${TARGET_EXECUTABLE}" || true
fi

if [[ -e "${TARGET_APP}" ]]; then
  rm -rf "${TARGET_APP}"
  print "$(cc_pets_t "App removed: {targetApp}" targetApp="${TARGET_APP}")"
else
  print "$(cc_pets_t "App not installed: {targetApp}" targetApp="${TARGET_APP}")"
fi
