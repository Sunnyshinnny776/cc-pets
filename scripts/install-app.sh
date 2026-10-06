#!/bin/zsh
set -eu

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
source "${PROJECT_DIR}/scripts/i18n.zsh"
SOURCE_APP="${PROJECT_DIR}/.build/release/CC Pets.app"
APPLICATIONS_DIR="${CC_PETS_APPLICATIONS_DIR:-${HOME}/Applications}"
TARGET_APP="${APPLICATIONS_DIR}/CC Pets.app"

if [[ ! -d "${SOURCE_APP}" ]]; then
  "${PROJECT_DIR}/scripts/build.sh" >/dev/null
fi

mkdir -p "${APPLICATIONS_DIR}"
STAGING_DIR="$(mktemp -d "${APPLICATIONS_DIR}/.cc-pets-install.XXXXXX")"
STAGING_APP="${STAGING_DIR}/CC Pets.app"
BACKUP_APP="${STAGING_DIR}/previous.app"

cleanup() {
  rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

/usr/bin/ditto "${SOURCE_APP}" "${STAGING_APP}"
if [[ -e "${TARGET_APP}" ]]; then
  mv "${TARGET_APP}" "${BACKUP_APP}"
fi
if ! mv "${STAGING_APP}" "${TARGET_APP}"; then
  if [[ -e "${BACKUP_APP}" ]]; then
    mv "${BACKUP_APP}" "${TARGET_APP}"
  fi
  print -u2 "$(cc_pets_t "Failed to install CC Pets.app; the existing app was kept.")"
  exit 1
fi

print "$(cc_pets_t "App installed: {targetApp}" targetApp="${TARGET_APP}")"
