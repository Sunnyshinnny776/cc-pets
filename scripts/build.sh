#!/bin/zsh
set -eu

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
source "${PROJECT_DIR}/scripts/i18n.zsh"
BUILD_DIR="${PROJECT_DIR}/.build/release"
CACHE_DIR="${PROJECT_DIR}/.build/clang-cache"
APP_DIR="${BUILD_DIR}/CC Pets.app"
APP_MACOS_DIR="${APP_DIR}/Contents/MacOS"
APP_RESOURCES_DIR="${APP_DIR}/Contents/Resources"
RESOURCE_DIR="${CC_PETS_RESOURCE_DIR:-${PROJECT_DIR}/Sources/CCPets/Resources}"
PACKAGE_VERSION="$(node -p "require('${PROJECT_DIR}/package.json').version")"
mkdir -p "${BUILD_DIR}" "${CACHE_DIR}" "${APP_MACOS_DIR}" "${APP_RESOURCES_DIR}"

# 之前没有任何优化和告警选项：默认等于 -O0，且第一次开启 -Wall -Wextra 就抓到了
# 真实错误（atomic 属性只自定义了一半访问器）。CC_PETS_STRICT=1 时把告警升级为错误，
# 供 CI 使用，本地开发保持只警告。
WARNING_FLAGS=(-Wall -Wextra -Wno-unused-parameter)
if [[ "${CC_PETS_STRICT:-0}" == "1" ]]; then
  WARNING_FLAGS+=(-Werror)
fi

SOURCES=("${PROJECT_DIR}"/Sources/CCPets/*.m(N))
if (( ${#SOURCES[@]} == 0 )); then
  print -u2 "$(cc_pets_t "Build failed: no .m source files found in Sources/CCPets.")"
  exit 1
fi

CLANG_MODULE_CACHE_PATH="${CACHE_DIR}" clang \
  -fobjc-arc \
  -fmodules-cache-path="${CACHE_DIR}" \
  -mmacosx-version-min=13.0 \
  -Os \
  "${WARNING_FLAGS[@]}" \
  "-DCC_PETS_VERSION=\"${PACKAGE_VERSION}\"" \
  -I"${PROJECT_DIR}/Sources/CCPets" \
  -framework Cocoa \
  -framework CoreServices \
  -framework ImageIO \
  -framework IOKit \
  -framework QuartzCore \
  -framework UserNotifications \
  "${SOURCES[@]}" \
  -o "${BUILD_DIR}/cc-pets"

find "${BUILD_DIR}" -maxdepth 1 -type f \( -name '*.webp' -o -name '*.png' \) -delete
find "${APP_MACOS_DIR}" -maxdepth 1 -type f \( -name '*.webp' -o -name '*.png' \) -delete
find "${APP_RESOURCES_DIR}" -maxdepth 1 -type f \( -name '*.webp' -o -name '*.png' \) -delete
SPRITES=("${RESOURCE_DIR}"/*.webp(N) "${RESOURCE_DIR}"/*.png(N))
if (( ${#SPRITES[@]} > 0 )); then
  cp "${SPRITES[@]}" "${BUILD_DIR}/"
  cp "${SPRITES[@]}" "${APP_RESOURCES_DIR}/"
fi
# 默认台词。代码里不再留内置词库，这个文件就是默认台词的唯一来源，
# 首次启动时被拷到 ~/.cc-pets/phrases.txt。
# 裸二进制旁边也放一份：直接跑 .build/release/cc-pets 时没有 app bundle。
# 每种界面语言一份：phrases.default.<语言>.txt。加语言只加文件，这里按通配符全拷。
for PHRASES_FILE in "${PROJECT_DIR}"/Resources/phrases.default*.txt(N); do
  cp "${PHRASES_FILE}" "${APP_RESOURCES_DIR}/${PHRASES_FILE:t}"
  cp "${PHRASES_FILE}" "${BUILD_DIR}/${PHRASES_FILE:t}"
done
# 界面文案（各语言的 Localizable.strings，英文是源码原文不需要表）和 Info.plist 的本地化
# （各语言的 InfoPlist.strings）。有哪些 .lproj 就支持哪些语言，app 运行时同样按目录发现。
# 裸二进制旁边同样放一份，CCPetsL10n.m 会去可执行文件旁边找。
for LPROJ_DIR in "${PROJECT_DIR}"/Resources/*.lproj(N/); do
  rm -rf "${APP_RESOURCES_DIR}/${LPROJ_DIR:t}" "${BUILD_DIR}/${LPROJ_DIR:t}"
  cp -R "${LPROJ_DIR}" "${APP_RESOURCES_DIR}/${LPROJ_DIR:t}"
  cp -R "${LPROJ_DIR}" "${BUILD_DIR}/${LPROJ_DIR:t}"
done
cp "${BUILD_DIR}/cc-pets" "${APP_MACOS_DIR}/cc-pets"
cp "${PROJECT_DIR}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "${PROJECT_DIR}/Resources/AppIcon.icns" "${APP_RESOURCES_DIR}/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${PACKAGE_VERSION}" "${APP_DIR}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${PACKAGE_VERSION}" "${APP_DIR}/Contents/Info.plist"
# 支持的语言按 Resources 下的 .lproj 目录生成，加语言不用改 Info.plist 模板。
/usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations array" "${APP_DIR}/Contents/Info.plist"
LOCALIZATIONS=(en "${PROJECT_DIR}"/Resources/*.lproj(N/:t:r))
for LOCALIZATION in ${(u)LOCALIZATIONS}; do
  /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations: string ${LOCALIZATION}" \
    "${APP_DIR}/Contents/Info.plist"
done
/usr/bin/codesign --force --sign - "${APP_DIR}" >/dev/null
print "$(cc_pets_t "Built: {buildDir}/cc-pets" buildDir="${BUILD_DIR}")"
print "$(cc_pets_t "App bundle ready: {appDir}" appDir="${APP_DIR}")"
