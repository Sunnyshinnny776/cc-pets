#!/bin/zsh
set -eu
setopt NO_BG_NICE

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
typeset -a TEST_EXTRA_TEMP_DIRS=()

cleanup_test_temp_dirs() {
  local parameter_name cleanup_path
  for parameter_name in ${(k)parameters}; do
    [[ "${parameter_name}" == *_TMP || "${parameter_name}" == *_TMP_DIR ]] || continue
    [[ "${parameters[$parameter_name]}" == *array* ]] && continue
    cleanup_path="${(P)parameter_name}"
    if [[ -d "${cleanup_path}" &&
          ("${cleanup_path}" == /tmp/cc-pets-* || "${cleanup_path}" == /private/tmp/cc-pets-*) ]]; then
      /bin/rm -rf -- "${cleanup_path}"
    fi
  done
  for cleanup_path in "${TEST_EXTRA_TEMP_DIRS[@]}"; do
    if [[ -d "${cleanup_path}" &&
          ("${cleanup_path}" == /tmp/cc-pets-* || "${cleanup_path}" == /private/tmp/cc-pets-*) ]]; then
      /bin/rm -rf -- "${cleanup_path}"
    fi
  done
}
trap cleanup_test_temp_dirs EXIT

# 测试跑包装脚本和 hook，它们都会写事件/状态文件。凡是忘了给 CC_PETS_STATE_DIR 的地方，
# 都会写进用户真实的事件流里，把正在运行的桌宠打回“正在启动”。这里记下基线偏移，
# 收尾时只检查新增的那一段。
#
# 判据是行内的 testMark 而不是文件大小：这台机器上随时可能有真实的 Claude / Codex 会话
# 在写同一个文件（开发时几乎总有），按大小判会把它们的写入算到测试头上，npm publish
# 撞上就会莫名其妙失败。标记由 CC_PETS_TEST_MARK 注入，测试起的每个子进程都带着它，
# 漏设 CC_PETS_STATE_DIR 的用例照样会被抓到。
export CC_PETS_TEST_MARK="test-$$"

# 额度快照的 resets_at 必须落在当前窗口里（见 CCPetsUsage.m 的 QuotaWindowLooksCurrent），
# 写死的时间戳一旦成为过去就会被合理地拒收，用例会在某天突然全红。统一按运行时刻算。
QUOTA_FUTURE_FIVE=$(( $(date +%s) + 3600 ))
QUOTA_FUTURE_WEEK=$(( $(date +%s) + 86400 ))
LIVE_EVENT_LOG="${${TMPDIR:-/tmp/}%/}/cc-pets-$(id -u)-agent-events.ndjson"
LIVE_EVENT_BASELINE=0
[[ -f "${LIVE_EVENT_LOG}" ]] && LIVE_EVENT_BASELINE="$(wc -c < "${LIVE_EVENT_LOG}")"

# 卸载逻辑在没有 CC_PETS_SHIM_DIR 时会回退到 ~/.cc-pets/shims，删掉里面指向
# bin/{codex,claude}-with-pet 的软链——开发机上那正是用户自己那份，删完 codex /
# claude 的桌宠集成就失效了。逐处补变量挡不住新增用例，所以在这里给全局兜底：
# 漏设的用例自动落到临时目录，需要独立目录的用例再就近覆盖。
SHIM_GUARD_TMP="$(mktemp -d /tmp/cc-pets-shim-guard.XXXXXX)"
export CC_PETS_SHIM_DIR="${SHIM_GUARD_TMP}/shims"

# 兜底本身失灵是最坏的情况，所以再记一份真实 shim 的快照，收尾比对。
LIVE_SHIM_DIR="${HOME}/.cc-pets/shims"
live_shim_snapshot() {
  local name entry snapshot=""
  if [[ ! -d "${LIVE_SHIM_DIR}" ]]; then
    print -r -- "absent"
    return
  fi
  for name in codex claude; do
    entry="${LIVE_SHIM_DIR}/${name}"
    if [[ -L "${entry}" ]]; then
      snapshot+="${name} -> $(readlink "${entry}")"$'\n'
    elif [[ -e "${entry}" ]]; then
      snapshot+="${name} present"$'\n'
    else
      snapshot+="${name} missing"$'\n'
    fi
  done
  print -r -- "${snapshot}"
}
LIVE_SHIM_BASELINE="$(live_shim_snapshot)"

# 数出 file 里 skip 字节之后、由本次测试写入的事件条数。
marked_event_count() {
  local file="$1" skip="$2" size=0
  [[ -f "${file}" ]] || { print 0; return }
  size="$(wc -c < "${file}")"
  (( size < skip )) && skip=0
  (( size > skip )) || { print 0; return }
  tail -c "+$(( skip + 1 ))" "${file}" | grep -c "\"testMark\":\"${CC_PETS_TEST_MARK}\"" || true
}

# main.m 已按模块拆分，源码级断言要覆盖 Sources/CCPets 下所有实现与头文件。
PET_SOURCES=("${PROJECT_DIR}"/Sources/CCPets/*.m(N) "${PROJECT_DIR}"/Sources/CCPets/*.h(N))
if (( ${#PET_SOURCES[@]} == 0 )); then
  print -u2 "找不到任何 Objective-C 源文件"
  exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PROJECT_DIR}/Resources/Info.plist" >/dev/null 2>&1 || \
   /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PROJECT_DIR}/Resources/Info.plist" >/dev/null 2>&1; then
  print -u2 "Info.plist 模板不应硬编码版本，版本必须来自 package.json"
  exit 1
fi
EMPTY_RESOURCE_TMP="$(mktemp -d /tmp/cc-pets-empty-resources-test.XXXXXX)"
CC_PETS_RESOURCE_DIR="${EMPTY_RESOURCE_TMP}" "${PROJECT_DIR}/scripts/build.sh" >/dev/null
if find "${PROJECT_DIR}/.build/release" \
  "${PROJECT_DIR}/.build/release/CC Pets.app/Contents/MacOS" \
  "${PROJECT_DIR}/.build/release/CC Pets.app/Contents/Resources" \
  -maxdepth 1 -type f \( -name '*.webp' -o -name '*.png' \) | grep -q .; then
  print -u2 "空素材构建仍残留精灵图"
  exit 1
fi
print "空素材目录构建测试通过"

# main.m 拆成多个模块后，package.json 的 files 若仍只列 main.m，发布包会缺源文件、
# 用户安装时 build.sh 直接失败。本地开发从工作树构建，看不出这个问题。
# --ignore-scripts 是必须的：prepack 就是 npm test，否则会递归调用自己。
NPM_CACHE_TMP="$(mktemp -d /tmp/cc-pets-npm-cache-test.XXXXXX)"
PACK_LIST="$(cd "${PROJECT_DIR}" && env npm_config_cache="${NPM_CACHE_TMP}" \
  npm pack --dry-run --json --ignore-scripts 2>/dev/null)"
for source_file in "${PROJECT_DIR}"/Sources/CCPets/*.m(N) "${PROJECT_DIR}"/Sources/CCPets/*.h(N); do
  relative="Sources/CCPets/${source_file:t}"
  if ! print -r -- "${PACK_LIST}" | grep -Fq "\"${relative}\""; then
    print -u2 "发布包缺少源文件 ${relative}；检查 package.json 的 files 字段"
    exit 1
  fi
done
# 构建期资源同理：build.sh 会从 Resources/ 拷贝，漏进 files 白名单的话本地构建照样绿，
# 用户 npm install 时才在 cp 那一步炸掉。files 是逐个文件列的，新加资源极易漏。
for resource_file in "${PROJECT_DIR}"/Resources/*(N.); do
  relative="Resources/${resource_file:t}"
  if ! print -r -- "${PACK_LIST}" | grep -Fq "\"${relative}\""; then
    print -u2 "发布包缺少资源 ${relative}；检查 package.json 的 files 字段"
    exit 1
  fi
done
print "发布包源文件完整性测试通过"
"${PROJECT_DIR}/scripts/build.sh"
[[ -x "${PROJECT_DIR}/.build/release/cc-pets" ]]
[[ -x "${PROJECT_DIR}/.build/release/CC Pets.app/Contents/MacOS/cc-pets" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "${PROJECT_DIR}/.build/release/CC Pets.app/Contents/Info.plist")" == "CC Pets" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${PROJECT_DIR}/.build/release/CC Pets.app/Contents/Info.plist")" == "com.universewang.cc-pets" ]]
PACKAGE_VERSION="$(node -p "require('${PROJECT_DIR}/package.json').version")"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PROJECT_DIR}/.build/release/CC Pets.app/Contents/Info.plist")" == "${PACKAGE_VERSION}" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PROJECT_DIR}/.build/release/CC Pets.app/Contents/Info.plist")" == "${PACKAGE_VERSION}" ]]
[[ "$("${PROJECT_DIR}/.build/release/cc-pets" --version)" == "cc-pets ${PACKAGE_VERSION}" ]]
[[ "$("${PROJECT_DIR}/.build/release/cc-pets" -v)" == "cc-pets ${PACKAGE_VERSION}" ]]
[[ "$("${PROJECT_DIR}/.build/release/cc-pets" -version)" == "cc-pets ${PACKAGE_VERSION}" ]]
[[ "$("${PROJECT_DIR}/.build/release/cc-pets" --compare-versions 0.2.13 0.2.14)" == "-1" ]]
[[ "$("${PROJECT_DIR}/.build/release/cc-pets" --compare-versions 1.0.0 0.99.99)" == "1" ]]
[[ "$("${PROJECT_DIR}/.build/release/cc-pets" --compare-versions 0.2.13 0.2.13)" == "0" ]]
if "${PROJECT_DIR}/.build/release/cc-pets" --compare-versions latest 0.2.14 >/dev/null 2>&1; then
  print -u2 "非法版本号不应通过自动更新校验"
  exit 1
fi
if "${PROJECT_DIR}/.build/release/cc-pets" --compare-versions 01.0.0 1.0.0 >/dev/null 2>&1; then
  print -u2 "带前导零的版本号不应通过自动更新校验"
  exit 1
fi
/usr/bin/codesign --verify "${PROJECT_DIR}/.build/release/CC Pets.app"
print "CC Pets 应用包名称、版本命令与元数据测试通过"
print "自动更新版本比较测试通过"

APP_INSTALL_TMP="$(mktemp -d /tmp/cc-pets-app-install-test.XXXXXX)"
CC_PETS_APPLICATIONS_DIR="${APP_INSTALL_TMP}/Applications" "${PROJECT_DIR}/scripts/install-app.sh" >/dev/null
INSTALLED_APP="${APP_INSTALL_TMP}/Applications/CC Pets.app"
[[ -x "${INSTALLED_APP}/Contents/MacOS/cc-pets" ]]
[[ -f "${INSTALLED_APP}/Contents/Resources/AppIcon.icns" ]]
if find "${INSTALLED_APP}/Contents/MacOS" -maxdepth 1 -type f \( -name '*.webp' -o -name '*.png' \) | grep -q .; then
  print -u2 "应用可执行目录不应包含精灵图"
  exit 1
fi
find "${INSTALLED_APP}/Contents/Resources" -maxdepth 1 -type f \( -name '*.webp' -o -name '*.png' \) | grep -q .
CC_PETS_APPLICATIONS_DIR="${APP_INSTALL_TMP}/Applications" CC_PETS_SKIP_APP_STOP=1 \
  "${PROJECT_DIR}/scripts/uninstall-app.sh" >/dev/null
[[ ! -e "${INSTALLED_APP}" ]]
print "用户级应用安装与显式卸载测试通过"

UPDATER_TMP="$(mktemp -d /tmp/cc-pets-updater-test.XXXXXX)"
UPDATE_NODE_PATH="$(command -v node)"
UPDATE_NPM_PATH="${npm_execpath:-$(command -v npm)}"
CC_PETS_APPLICATION_SUPPORT_DIR="${UPDATER_TMP}" \
  CC_PETS_APPLICATIONS_DIR="${UPDATER_TMP}/Applications" \
  npm_node_execpath="${UPDATE_NODE_PATH}" npm_execpath="${UPDATE_NPM_PATH}" \
  node "${PROJECT_DIR}/scripts/configure-updater.mjs"
[[ "$(stat -f '%Lp' "${UPDATER_TMP}/updater.json")" == "600" ]]
node -e '
  const fs = require("fs");
  const config = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (config.schemaVersion !== 2) process.exit(1);
  if (!config.nodePath.startsWith("/") || !config.npmCliPath.startsWith("/")) process.exit(1);
  if (config.appPath !== process.argv[2]) process.exit(1);
' "${UPDATER_TMP}/updater.json" "${UPDATER_TMP}/Applications/CC Pets.app"
RECORDED_NODE="$(node -p "require(process.argv[1]).nodePath" "${UPDATER_TMP}/updater.json")"
RECORDED_NPM_CLI="$(node -p "require(process.argv[1]).npmCliPath" "${UPDATER_TMP}/updater.json")"
[[ "$("${RECORDED_NODE}" "${RECORDED_NPM_CLI}" --version)" == <->.* ]]
mkdir -p "${UPDATER_TMP}/bin"
print -r -- '#!/bin/zsh
print -r -- "$@" > "${CC_PETS_RESTART_LOG}"' > "${UPDATER_TMP}/bin/open"
chmod +x "${UPDATER_TMP}/bin/open"
EXITED_PID=0
CC_PETS_OPEN_PATH="${UPDATER_TMP}/bin/open" CC_PETS_RESTART_LOG="${UPDATER_TMP}/restart.log" \
  "${PROJECT_DIR}/.build/release/cc-pets" --restart-after-pid "${EXITED_PID}" \
  "${UPDATER_TMP}/Applications/CC Pets.app" --managed
grep -Fq -- "-g ${UPDATER_TMP}/Applications/CC Pets.app --args --managed" "${UPDATER_TMP}/restart.log"
grep -q '检查更新…' "${PET_SOURCES[@]}"
grep -q 'https://registry.npmjs.org/cc-pets/latest' "${PET_SOURCES[@]}"
grep -Fq 'environment[@"PATH"] = [NSString stringWithFormat:@"%@:%@", nodeDirectory, existingPath]' \
  "${PET_SOURCES[@]}"
grep -Fq 'task.environment = environment' "${PET_SOURCES[@]}"
print "应用内自动更新配置与独立重启测试通过"

grep -q 'spriteVersionNumber' "${PET_SOURCES[@]}"
grep -q 'return version == 2 ? 11 : 9' "${PET_SOURCES[@]}"
grep -q 'self.sheet.size.height / self.spriteRowCount' "${PET_SOURCES[@]}"
if grep -q 'self.sheet.size.height / 9.0' "${PET_SOURCES[@]}"; then
  print -u2 "精灵图仍固定按 9 行切分"
  exit 1
fi
print "Codex spriteVersionNumber v1/v2 布局测试通过"

grep -q 'addGlobalMonitorForEventsMatchingMask:NSEventMaskMouseMoved' "${PET_SOURCES[@]}"
# 十六向是否可用改由能力位表达，行数判断只在这一处。断言跟着挪，守的还是同一件事：
# 十六向跟随按 11 行素材启用。
grep -q 'self.hasLookRows = self.spriteRowCount >= 11' "${PET_SOURCES[@]}"
grep -q '!self.hasLookRows' "${PET_SOURCES[@]}"
grep -q 'direction == self.lookDirection' "${PET_SOURCES[@]}"
grep -q 'self.rowIndex = 9 + direction / 8' "${PET_SOURCES[@]}"
grep -q 'self.frameIndex = direction % 8' "${PET_SOURCES[@]}"
print "Codex v2 十六向鼠标跟随配置测试通过"

grep -q 'NSMenuDelegate' "${PET_SOURCES[@]}"
grep -q 'willHighlightItem' "${PET_SOURCES[@]}"
grep -q 'sheet.size.height - cellHeight' "${PET_SOURCES[@]}"
grep -q 'petMenuPreviewPanel' "${PET_SOURCES[@]}"
grep -q 'NSUnionRect(menuGroupFrame, ancestorFrame)' "${PET_SOURCES[@]}"
if grep -q 'candidate.image = nil' "${PET_SOURCES[@]}"; then
  print -u2 "桌宠缩略图不应再修改菜单项图片，避免名称被挤压"
  exit 1
fi
print "桌宠切换菜单 1-1 帧侧边悬停预览配置测试通过"

# 这里刻意不读本机真实的 ~/.codex：机器上有没有 Codex 会话是环境决定的（CI runner 上
# 一条都没有），跟着环境走的断言只会在别人机器上红。空态和有数据两条路径分别用受控
# 目录钉住——这一段钉空态：没有任何会话时必须干净地报错并以非零退出，而不是打印半截
# 结果让调用方以为拿到了额度。
CODEX_EMPTY_TMP="$(mktemp -d /tmp/cc-pets-codex-empty-test.XXXXXX)"
if EMPTY_OUTPUT="$(CC_PETS_CODEX_HOME="${CODEX_EMPTY_TMP}" \
  "${PROJECT_DIR}/.build/release/cc-pets" --status 2>&1)"; then
  print -u2 "没有 Codex 会话时 --status 应当以非零退出，实际输出: ${EMPTY_OUTPUT}"
  exit 1
fi
[[ "${EMPTY_OUTPUT}" == *"Codex usage unavailable"* ]]
print "无 Codex 数据时的空态测试通过"

CODEX_USAGE_TMP="$(mktemp -d /tmp/cc-pets-codex-usage-test.XXXXXX)"
mkdir -p "${CODEX_USAGE_TMP}/sessions/2026/07/22"
print -r -- '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"window_minutes":300,"used_percent":12.5},"secondary":{"window_minutes":10080,"used_percent":34.5}}}}' \
  > "${CODEX_USAGE_TMP}/sessions/2026/07/22/session.jsonl"
SYNTHETIC_OUTPUT="$(CC_PETS_CODEX_HOME="${CODEX_USAGE_TMP}" "${PROJECT_DIR}/.build/release/cc-pets" --status)"
[[ "${SYNTHETIC_OUTPUT}" == "five_hour=12.5% week=34.5%" ]]
grep -q '@interface CodexUsageReader' "${PET_SOURCES[@]}"
grep -q 'consumeIncrementalData' "${PET_SOURCES[@]}"
print "Codex 会话增量读取与解析测试通过"

PHRASES_TMP="$(mktemp -d /tmp/cc-pets-phrases-test.XXXXXX)"
clang -fobjc-arc -mmacosx-version-min=13.0 \
  -I"${PROJECT_DIR}/Sources/CCPets" -framework Foundation \
  "${PROJECT_DIR}/Sources/CCPets/CCPetsPhrases.m" \
  "${PROJECT_DIR}/tests/phrases-harness.m" \
  -o "${PHRASES_TMP}/phrases-test"
CC_PETS_PHRASES_FILE="${PHRASES_TMP}/speech.txt" \
  CC_PETS_PHRASES_PET_DIR="${PHRASES_TMP}/speech" \
  CC_PETS_PHRASES_DEFAULT_FILE="${PROJECT_DIR}/Resources/phrases.default.txt" \
  "${PHRASES_TMP}/phrases-test"
rm -rf "${PHRASES_TMP}"
# 用户词条永远是数据，不是格式串。这条守着别让人图省事改成 stringWithFormat:。
if grep -q 'stringWithFormat:template' "${PET_SOURCES[@]}"; then
  print -u2 "用户词条不能交给 stringWithFormat:，一个 %@ 就会让桌宠崩溃"
  exit 1
fi
# 碎碎念的闸门必须是"agent 在不在干活"，不能退回"状态卡在不在"——状态卡只要客户端
# 活着就常驻，用它当闸门等于开着终端就永远不碎碎念（这个 bug 犯过一次）。
if ! grep -q 'if (\[self agentBusyForSpeech\]) return;' "${PROJECT_DIR}/Sources/CCPets/CCPetsAppDelegate.m"; then
  print -u2 "considerIdleSpeech 必须用 agentBusyForSpeech 当闸门"
  exit 1
fi
if grep -q 'if (self.statusPanel.isVisible) return;' "${PROJECT_DIR}/Sources/CCPets/CCPetsAppDelegate.m"; then
  print -u2 "碎碎念不能再以'状态卡可见'为由整段闭嘴"
  exit 1
fi
# 借走状态卡副行说完闲话必须还回去，否则副行会一直挂着闲话像卡死了。
grep -q 'restoreStatusDetail' "${PROJECT_DIR}/Sources/CCPets/CCPetsAppDelegate.m"
# 频率四档要同时出现在档位表和右键菜单里，少一头就是"菜单里能选但没效果"。
for freq in low normal high chatty; do
  if ! grep -q "\"${freq}\"" "${PROJECT_DIR}/Sources/CCPets/PetView.m"; then
    print -u2 "右键菜单缺少碎碎念频率档位 ${freq}"
    exit 1
  fi
done
grep -q 'PetSpeechRateChatty' "${PROJECT_DIR}/Sources/CCPets/CCPetsAppDelegate.m"
print "碎碎念闸门与频率档位测试通过"

# 台词文件是纯文本不是 JSON：普通用户写不了 JSON，且少个逗号整个文件静默失效。
grep -q 'speech.txt' "${PET_SOURCES[@]}"
if grep -q 'phrases.json' "${PET_SOURCES[@]}"; then
  print -u2 "台词文件应当是纯文本 speech.txt，不要退回 JSON"
  exit 1
fi
# 默认词库是打包的文本文件，不是代码里的字典。两份词库同时存在于运行期就必然要回答
# "以谁为准"，而那正是 merge/replace 让用户看不懂的根源。
if [[ ! -f "${PROJECT_DIR}/Resources/phrases.default.txt" ]]; then
  print -u2 "缺少默认词库 Resources/phrases.default.txt"
  exit 1
fi
if grep -q 'BuiltinPhrases' "${PET_SOURCES[@]}"; then
  print -u2 "代码里不应再有内置词库，默认台词只能来自 Resources/phrases.default.txt"
  exit 1
fi
# 默认词库必须随 app 一起打包，否则用户装完一句话都不会说。
grep -q 'phrases.default.txt' "${PROJECT_DIR}/scripts/build.sh"
# 台词编辑器必须是 app 内置的：交给系统编辑器就没有任何校验反馈，
# 小节名拼错、句子超长、槽位写错全是静默失效。
if grep -q 'openURL.*PetPhrasesFilePath\|PetPhrasesFilePath.*openURL' \
    "${PROJECT_DIR}/Sources/CCPets/CCPetsAppDelegate.m"; then
  print -u2 "台词不应再交给系统编辑器打开"
  exit 1
fi
grep -q 'PetPhrasesEditorController' "${PROJECT_DIR}/Sources/CCPets/CCPetsAppDelegate.m"
# 保存并关闭必须走同一条保存路径：保存失败/被取消时不能把窗口连同改动一起关掉。
grep -q 'saveAndClose:' "${PROJECT_DIR}/Sources/CCPets/CCPetsPhrasesEditor.m"
# 标签被删时要先补回原位再校验，光报错会让用户在编辑器里找不到该补什么。
grep -q 'PetPhraseTextWithRestoredTags' "${PROJECT_DIR}/Sources/CCPets/CCPetsPhrasesEditor.m"
# ⌘C/⌘V/⌘A/⌘Z 靠主菜单的 keyEquivalent 分发。这个 app 是 LSUIElement，不设主菜单的话
# 台词编辑器里这些快捷键全部落空（犯过一次）。
grep -q 'NSApp.mainMenu = mainMenu' "${PROJECT_DIR}/Sources/CCPets/CCPetsAppDelegate.m"
for selector in undo: redo: cut: copy: paste: selectAll:; do
  if ! grep -q "@selector(${selector})" "${PROJECT_DIR}/Sources/CCPets/CCPetsAppDelegate.m"; then
    print -u2 "编辑菜单缺少 ${selector}，对应快捷键会没反应"
    exit 1
  fi
done
print "编辑菜单快捷键接线测试通过"
if ! grep -q 'if (!\[self performSave\]) return;' \
    "${PROJECT_DIR}/Sources/CCPets/CCPetsPhrasesEditor.m"; then
  print -u2 "保存并关闭必须在保存成功后才关窗"
  exit 1
fi
print "默认词库与内置编辑器接线测试通过"

IMPORT_PETS_TMP="$(mktemp -d /tmp/cc-pets-import-pets-test.XXXXXX)"
clang -fobjc-arc -mmacosx-version-min=13.0 \
  -I"${PROJECT_DIR}/Sources/CCPets" -framework Foundation \
  "${PROJECT_DIR}/Sources/CCPets/CCPetsPaths.m" \
  "${PROJECT_DIR}/tests/import-codex-pets-harness.m" \
  -o "${IMPORT_PETS_TMP}/import-pets-test"
CC_PETS_CODEX_HOME="${IMPORT_PETS_TMP}/codex" \
  CC_PETS_PETS_DIR="${IMPORT_PETS_TMP}/own" \
  "${IMPORT_PETS_TMP}/import-pets-test"
rm -rf "${IMPORT_PETS_TMP}"

# 桌宠只扫自己的素材目录，不能再去拼 PetDex / Codex 的目录路径。
# 只匹配路径常量（@".petdex/pets"），提示文案里的 ~/.petdex/pets/ 不算。
if grep -qE '@"\.(petdex|codex)/pets' "${PROJECT_DIR}/Sources/CCPets/CCPetsAppDelegate.m"; then
  print -u2 "桌宠端仍在直接拼 ~/.petdex/pets 或 ~/.codex/pets 的路径"
  exit 1
fi
grep -q 'OwnPetsDirectory' "${PROJECT_DIR}/Sources/CCPets/CCPetsAppDelegate.m"
print "桌宠只扫自身素材目录测试通过"

PET_ALIAS_TMP="$(mktemp -d /tmp/cc-pets-alias-test.XXXXXX)"
mkdir -p "${PET_ALIAS_TMP}/波霸"
CC_PETS_PETS_DIR="${PET_ALIAS_TMP}" node "${PROJECT_DIR}/scripts/pet-store.mjs" remove 波霸 >/dev/null
[[ ! -e "${PET_ALIAS_TMP}/波霸" ]]
print "桌宠素材中文别名测试通过"

TOKEN_USAGE_TMP="$(mktemp -d /tmp/cc-pets-token-usage-test.XXXXXX)"
clang -fobjc-arc -mmacosx-version-min=13.0 \
  -I"${PROJECT_DIR}/Sources/CCPets" \
  -framework Foundation \
  "${PROJECT_DIR}/Sources/CCPets/CCPetsPaths.m" \
  "${PROJECT_DIR}/Sources/CCPets/CCPetsUsage.m" \
  "${PROJECT_DIR}/tests/token-usage-harness.m" \
  -o "${TOKEN_USAGE_TMP}/token-usage-test"
# Token 摘要缓存落在 Application Support 下，测试必须用自己的目录，否则会往用户真实的
# 缓存目录里丢文件。
CC_PETS_CODEX_HOME="${TOKEN_USAGE_TMP}/codex" \
CC_PETS_APPLICATION_SUPPORT_DIR="${TOKEN_USAGE_TMP}/Application Support" \
  "${TOKEN_USAGE_TMP}/token-usage-test"

write_session_file() {
  local session_path="$1"
  local five="$2"
  local week="$3"

  mkdir -p "${session_path:h}"
  print -r -- "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"window_minutes\":300,\"used_percent\":${five}},\"secondary\":{\"window_minutes\":10080,\"used_percent\":${week}}}}}" \
    > "${session_path}"
}

assert_status_equals() {
  local codex_home="$1"
  local expected="$2"
  local label="$3"

  local actual
  actual="$(CC_PETS_CODEX_HOME="${codex_home}" "${PROJECT_DIR}/.build/release/cc-pets" --status)"
  if [[ "${actual}" != "${expected}" ]]; then
    print -u2 "${label}失败：期望 ${expected}，实际 ${actual}"
    exit 1
  fi
}

# 会话发现按 YYYY/MM/DD 倒序下钻，必须能跨月/跨年溢出。
DESCENT_TMP="$(mktemp -d /tmp/cc-pets-session-descent-test.XXXXXX)"
write_session_file "${DESCENT_TMP}/sessions/2026/07/31/rollout-a.jsonl" 11.5 22.5
write_session_file "${DESCENT_TMP}/sessions/2026/08/01/rollout-b.jsonl" 33.5 44.5
assert_status_equals "${DESCENT_TMP}" "five_hour=33.5% week=44.5%" "跨月下钻测试"

# 只取“最近 N 天”会让闲置数天的用户冷启动一无所获，必须一直回溯到真的找到文件。
IDLE_TMP="$(mktemp -d /tmp/cc-pets-session-idle-test.XXXXXX)"
write_session_file "${IDLE_TMP}/sessions/2026/03/05/rollout-old.jsonl" 55.5 66.5
assert_status_equals "${IDLE_TMP}" "five_hour=55.5% week=66.5%" "长期闲置后仍能发现会话测试"

# 非 YYYY/MM/DD 的杂项目录不参与，即使里面的文件更新。
DECOY_DIR_TMP="$(mktemp -d /tmp/cc-pets-session-decoy-test.XXXXXX)"
write_session_file "${DECOY_DIR_TMP}/sessions/2026/07/22/rollout-real.jsonl" 12.5 34.5
write_session_file "${DECOY_DIR_TMP}/sessions/backup/rollout-decoy.jsonl" 99.5 99.5
assert_status_equals "${DECOY_DIR_TMP}" "five_hour=12.5% week=34.5%" "忽略非日期目录测试"
print "会话目录定向下钻测试通过"

if grep -q 'scheduledTimerWithTimeInterval:0.15' "${PET_SOURCES[@]}"; then
  print -u2 "Agent 事件仍在使用 150ms 定时轮询"
  exit 1
fi
grep -q 'DISPATCH_SOURCE_TYPE_VNODE' "${PET_SOURCES[@]}"
grep -q 'DISPATCH_VNODE_WRITE' "${PET_SOURCES[@]}"
print "Agent 文件事件监听配置测试通过"

# 常驻开销：额度面板不可见时降频、客户端轮询放宽、定时器允许内核合并唤醒。
if grep -qE 'scheduledTimerWithTimeInterval:1 target:self selector:@selector\(refreshClientLifecycle' \
  "${PET_SOURCES[@]}"; then
  print -u2 "客户端存活检查仍在以 1 秒周期轮询"
  exit 1
fi
if grep -qE 'scheduledTimerWithTimeInterval:5 target:self selector:@selector\(refreshUsage' \
  "${PET_SOURCES[@]}"; then
  print -u2 "额度刷新仍是固定 5 秒周期，面板不可见时应降频"
  exit 1
fi
grep -q 'UsageRefreshIntervalHidden = 120.0' "${PET_SOURCES[@]}"
grep -q 'rescheduleUsageTimer' "${PET_SOURCES[@]}"
grep -q '\.tolerance' "${PET_SOURCES[@]}"
print "常驻定时器周期与唤醒合并配置测试通过"

# 额度变化走内核事件；定时器只作 120 秒兜底。
grep -q 'FSEventStreamCreate' "${PET_SOURCES[@]}"
grep -q 'kFSEventStreamCreateFlagFileEvents' "${PET_SOURCES[@]}"
grep -q 'kFSEventStreamEventFlagMustScanSubDirs' "${PET_SOURCES[@]}"
grep -q 'refreshForSessionURL' "${PET_SOURCES[@]}"
# 一批事件里的多个会话文件必须整批交给 reader 判断，不能在回调里"最后一个胜出"。
grep -q 'refreshForSessionURLs' "${PET_SOURCES[@]}"
grep -q 'startClaudeSource' "${PET_SOURCES[@]}"
grep -q 'DISPATCH_VNODE_RENAME' "${PET_SOURCES[@]}"
grep -q 'claudeModifiedAt' "${PET_SOURCES[@]}"
print "Codex/Claude 额度事件监听与缓存配置测试通过"

USAGE_MONITOR_TMP="$(mktemp -d /tmp/cc-pets-usage-monitor-test.XXXXXX)"
clang -fobjc-arc -mmacosx-version-min=13.0 \
  -I"${PROJECT_DIR}/Sources/CCPets" \
  -framework Foundation -framework CoreServices \
  "${PROJECT_DIR}/Sources/CCPets/CCPetsPaths.m" \
  "${PROJECT_DIR}/Sources/CCPets/CCPetsUsage.m" \
  "${PROJECT_DIR}/Sources/CCPets/CCPetsCodexRateLimits.m" \
  "${PROJECT_DIR}/Sources/CCPets/CCPetsUsageMonitor.m" \
  "${PROJECT_DIR}/tests/usage-monitor-harness.m" \
  -o "${USAGE_MONITOR_TMP}/usage-monitor-test"
CC_PETS_CODEX_HOME="${USAGE_MONITOR_TMP}/codex" \
CC_PETS_STATE_DIR="${USAGE_MONITOR_TMP}/state" \
CC_PETS_APPLICATION_SUPPORT_DIR="${USAGE_MONITOR_TMP}/Application Support" \
  "${USAGE_MONITOR_TMP}/usage-monitor-test"

SESSION_PICK_TMP="$(mktemp -d /tmp/cc-pets-session-pick-test.XXXXXX)"
clang -fobjc-arc -mmacosx-version-min=13.0 \
  -I"${PROJECT_DIR}/Sources/CCPets" \
  -framework Foundation \
  "${PROJECT_DIR}/Sources/CCPets/CCPetsPaths.m" \
  "${PROJECT_DIR}/Sources/CCPets/CCPetsUsage.m" \
  "${PROJECT_DIR}/tests/session-pick-harness.m" \
  -o "${SESSION_PICK_TMP}/session-pick-test"
CC_PETS_CODEX_HOME="${SESSION_PICK_TMP}/codex" \
CC_PETS_STATE_DIR="${SESSION_PICK_TMP}/state" \
CC_PETS_APPLICATION_SUPPORT_DIR="${SESSION_PICK_TMP}/Application Support" \
TMPDIR="${SESSION_PICK_TMP}/" \
  "${SESSION_PICK_TMP}/session-pick-test"

# 超大素材按实际显示尺寸解码；预览缓存必须有明确的数量和成本上限。
grep -q 'CGImageSourceCreateThumbnailAtIndex' "${PET_SOURCES[@]}"
grep -q 'kCGImageSourceThumbnailMaxPixelSize' "${PET_SOURCES[@]}"
grep -Fq 'NSCache<NSString *, NSImage *>' "${PET_SOURCES[@]}"
grep -q 'countLimit = 24' "${PET_SOURCES[@]}"
grep -Fq 'totalCostLimit = 4 * 1024 * 1024' "${PET_SOURCES[@]}"
grep -q 'NSFileModificationDate' "${PET_SOURCES[@]}"
print "精灵图降采样与有限预览缓存配置测试通过"

IMAGE_LOADER_TMP="$(mktemp -d /tmp/cc-pets-image-loader-test.XXXXXX)"
clang -fobjc-arc -mmacosx-version-min=13.0 \
  -I"${PROJECT_DIR}/Sources/CCPets" \
  -framework Cocoa -framework ImageIO \
  "${PROJECT_DIR}/Sources/CCPets/CCPetsImageLoader.m" \
  "${PROJECT_DIR}/tests/image-loader-harness.m" \
  -o "${IMAGE_LOADER_TMP}/image-loader-test"
"${IMAGE_LOADER_TMP}/image-loader-test" \
  "${PROJECT_DIR}/Sources/CCPets/Resources/默认.webp"

# 系统低功耗和减少动态效果会降低空闲动画频率。
grep -q 'NSProcessInfoPowerStateDidChangeNotification' "${PET_SOURCES[@]}"
grep -q 'accessibilityDisplayShouldReduceMotion' "${PET_SOURCES[@]}"
grep -Fq 'interval *= 1.5' "${PET_SOURCES[@]}"
grep -Fq 'interval *= 2.0' "${PET_SOURCES[@]}"
print "低功耗与减少动态效果适配测试通过"

# 异常退出在 approval 状态时，记录不能无限常驻。
grep -Fq 'PendingApprovalTTL = 24 * 60 * 60' "${PET_SOURCES[@]}"
grep -q 'PendingApprovalLimit = 100' "${PET_SOURCES[@]}"
grep -q 'prunePendingApprovalRecords' "${PET_SOURCES[@]}"
print "待审批记录 TTL 与容量上限测试通过"

# 精灵动画：显示器睡眠时暂停、十六向跟随期间停表、定时器不再持有 PetView。
# 桌宠置顶，全屏也压不住它，"被遮挡"几乎不会真实发生；且 occlusionState 实测会在
# Space/全屏过渡期间误报十几秒不可见，把可见的桌宠冻住。不要退回去用它。
# 只看真实代码，注释里为了记录这个决策会提到符号名本身。
if cat "${PET_SOURCES[@]}" | grep -v '^[[:space:]]*//' | grep -q 'occlusionState'; then
  print -u2 "不应依赖 occlusionState 判断桌宠可见性：置顶窗口收益近零，且过渡期会误报"
  exit 1
fi
grep -q 'NSWorkspaceScreensDidSleepNotification' "${PET_SOURCES[@]}"
grep -q 'NSWorkspaceScreensDidWakeNotification' "${PET_SOURCES[@]}"
grep -q 'sharedWorkspace.notificationCenter' "${PET_SOURCES[@]}"
grep -q 'setAnimationSuspended' "${PET_SOURCES[@]}"
grep -q 'animationSuspended && self.lookDirection < 0' "${PET_SOURCES[@]}"
if grep -qE 'scheduledTimerWithTimeInterval:[0-9.]+ target:self[[:space:]]*$|target:self\n *selector:@selector\(nextFrame' \
  "${PET_SOURCES[@]}"; then
  print -u2 "动画定时器仍以 target:self 持有 PetView，构成保留环"
  exit 1
fi
grep -q '__weak PetView \*weakSelf' "${PET_SOURCES[@]}"
print "精灵动画休眠暂停与定时器生命周期测试通过"

# 事件文件只被追加，需有上限，否则长期运行会无限增长。
grep -q 'AgentEventLogSizeLimit' "${PET_SOURCES[@]}"
grep -q 'ftruncate' "${PET_SOURCES[@]}"
print "Agent 事件日志上限配置测试通过"

assert_file_contains() {
  local file_path="$1"
  local expected="$2"
  local label="$3"

  if [[ ! -s "${file_path}" ]]; then
    print -u2 "${label}失败：未生成事件文件 ${file_path}"
    exit 1
  fi
  if ! grep -q -- "${expected}" "${file_path}"; then
    print -u2 "${label}失败：事件文件中缺少 ${expected}"
    print -u2 -- "--- ${file_path} ---"
    sed -n '1,20p' "${file_path}" >&2
    exit 1
  fi
}

HOOK_TMP="$(mktemp -d /tmp/cc-pets-hook-test.XXXXXX)"
HOOK_EVENT_FILE="${HOOK_TMP}/cc-pets-$(id -u)-agent-events.ndjson"
print -n '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' | \
  CC_PETS_STATE_DIR="${HOOK_TMP}" "${PROJECT_DIR}/.build/release/cc-pets" --hook
assert_file_contains "${HOOK_EVENT_FILE}" '"event":"PreToolUse"' "Codex Agent Hook 事件测试"
assert_file_contains "${HOOK_EVENT_FILE}" '"tool":"Bash"' "Codex Agent Hook 工具名测试"
print "Codex Agent Hook 事件测试通过"

AUTO_REVIEW_TMP="$(mktemp -d /tmp/cc-pets-auto-review-test.XXXXXX)"
AUTO_REVIEW_HOME="${AUTO_REVIEW_TMP}/codex"
AUTO_REVIEW_STATE="${AUTO_REVIEW_TMP}/state"
mkdir -p "${AUTO_REVIEW_HOME}" "${AUTO_REVIEW_STATE}"
print -r -- 'approvals_reviewer = "auto_review"' > "${AUTO_REVIEW_HOME}/config.toml"
print -n '{"hook_event_name":"PermissionRequest","tool_name":"Bash"}' | \
  CODEX_HOME="${AUTO_REVIEW_HOME}" CC_PETS_CODEX_AGENT_HOOK=1 \
  CC_PETS_STATE_DIR="${AUTO_REVIEW_STATE}" "${PROJECT_DIR}/.build/release/cc-pets" --hook
AUTO_REVIEW_EVENT_FILE="${AUTO_REVIEW_STATE}/cc-pets-$(id -u)-agent-events.ndjson"
assert_file_contains "${AUTO_REVIEW_EVENT_FILE}" '"state":"auto_review"' "Codex 自动审批状态测试"

MANUAL_REVIEW_TMP="$(mktemp -d /tmp/cc-pets-manual-review-test.XXXXXX)"
MANUAL_REVIEW_HOME="${MANUAL_REVIEW_TMP}/codex"
MANUAL_REVIEW_STATE="${MANUAL_REVIEW_TMP}/state"
mkdir -p "${MANUAL_REVIEW_HOME}" "${MANUAL_REVIEW_STATE}"
print -r -- 'approvals_reviewer = "user"' > "${MANUAL_REVIEW_HOME}/config.toml"
print -n '{"hook_event_name":"PermissionRequest","tool_name":"Bash"}' | \
  CODEX_HOME="${MANUAL_REVIEW_HOME}" CC_PETS_CODEX_AGENT_HOOK=1 \
  CC_PETS_STATE_DIR="${MANUAL_REVIEW_STATE}" "${PROJECT_DIR}/.build/release/cc-pets" --hook
MANUAL_REVIEW_EVENT_FILE="${MANUAL_REVIEW_STATE}/cc-pets-$(id -u)-agent-events.ndjson"
assert_file_contains "${MANUAL_REVIEW_EVENT_FILE}" '"state":"approval"' "Codex 人工审批状态测试"
print "Codex 自动审批与人工审批状态区分测试通过"
grep -q 'pendingApprovalRecords' "${PET_SOURCES[@]}"
grep -q 'session.length > 0' "${PET_SOURCES[@]}"
grep -Fq 'record[@"session"]' "${PET_SOURCES[@]}"
grep -Fq 'self.pendingApprovalRecords[approvalKey] = record' "${PET_SOURCES[@]}"
print "跨 Agent 人工审批记录保存测试通过"

# 等审批的会话是停住不动的，时间戳只会越来越旧：状态卡正文跟着最新事件走，会话
# 列表按时间倒序，两边都会把最该处理的那条推到看不见的地方。角标和置顶各补一头。
grep -q 'pendingApprovalSessionRecords' "${PET_SOURCES[@]}"
grep -q 'refreshApprovalBadge' "${PET_SOURCES[@]}"
grep -q 'CCPetsApprovalBadgeView' "${PET_SOURCES[@]}"
if ! grep -q 'leftApproval ? NSOrderedAscending : NSOrderedDescending' "${PET_SOURCES[@]}"; then
  print -u2 "会话列表没有把等审批的排到最前面，最该处理的那条会沉到列表底部"
  exit 1
fi
# 角标不能吃掉圆形状态图标的点击，否则会话列表再也弹不出来。
if ! grep -Fq -e 'hitTest:(NSPoint)point { return nil; }' "${PET_SOURCES[@]}"; then
  print -u2 "待审批角标没有放行点击，会挡住状态图标"
  exit 1
fi
# 60 秒没有新事件就清场的规则不该把未处理的审批一起收走。
if ! grep -q 'if (self.hasAgentStatus && pending.count > 0)' "${PET_SOURCES[@]}"; then
  print -u2 "气泡清场没有为未处理的审批留回落，审批会随沉默一起消失"
  exit 1
fi
print "待审批角标与会话列表置顶测试通过"

grep -q 'AgentApprovalStallInterval' "${PET_SOURCES[@]}"
grep -q 'AgentThinkingStallInterval' "${PET_SOURCES[@]}"
grep -q 'checkStalledAgentSessions' "${PET_SOURCES[@]}"
grep -q 'NotificationStallKey' "${PET_SOURCES[@]}"
# 去重键必须带上会话当时的时间戳：只用会话键的话，卡住提醒一辈子只会响一次。
if ! grep -Fq '[NSString stringWithFormat:@"%@|%.0f", key, timestamp]' "${PET_SOURCES[@]}"; then
  print -u2 "卡住提醒的去重键不含时间戳，会话恢复后再次卡住将不再提醒"
  exit 1
fi
if ! grep -q 'intersectSet:valid' "${PET_SOURCES[@]}"; then
  print -u2 "卡住提醒的去重集合没有回收失效键，会随会话数无限增长"
  exit 1
fi
grep -q '响应超时' "${PET_SOURCES[@]}"
print "Agent 卡住检测与提醒测试通过"

print -n '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash"}' | \
  CC_PETS_STATE_DIR="${HOOK_TMP}" "${PROJECT_DIR}/.build/release/cc-pets" --hook
assert_file_contains "${HOOK_EVENT_FILE}" '"event":"PostToolUseFailure"' "Claude Code 失败事件测试"
assert_file_contains "${HOOK_EVENT_FILE}" '"failed":true' "Claude Code 失败标记测试"
print "Claude Code 失败事件测试通过"

POST_TOOL_TMP="$(mktemp -d /tmp/cc-pets-post-tool-test.XXXXXX)"
POST_TOOL_EVENT_FILE="${POST_TOOL_TMP}/cc-pets-$(id -u)-agent-events.ndjson"
print -n '{"hook_event_name":"PostToolUse","tool_name":"Bash"}' | \
  CC_PETS_CODEX_AGENT_HOOK=1 CC_PETS_STATE_DIR="${POST_TOOL_TMP}" \
  "${PROJECT_DIR}/.build/release/cc-pets" --hook
assert_file_contains "${POST_TOOL_EVENT_FILE}" '"provider":"Codex"' "Codex 工具完成 Provider 测试"
assert_file_contains "${POST_TOOL_EVENT_FILE}" '"state":"thinking"' "Codex 工具完成后恢复思考测试"
print "Codex 工具完成后恢复思考状态测试通过"

emit_hook_event() {
  local state_dir="$1"
  local payload="$2"

  print -rn -- "${payload}" | CC_PETS_CODEX_AGENT_HOOK=1 CC_PETS_STATE_DIR="${state_dir}" \
    "${PROJECT_DIR}/.build/release/cc-pets" --hook
}

# 失败判定只认显式信号。任意层级出现非空 error 键就判失败会让成功的任务
# 播失败动画并弹“任务失败”通知。
FAILURE_TMP="$(mktemp -d /tmp/cc-pets-failure-detect-test.XXXXXX)"
FAILURE_EVENT_FILE="${FAILURE_TMP}/cc-pets-$(id -u)-agent-events.ndjson"
emit_hook_event "${FAILURE_TMP}" \
  '{"hook_event_name":"PostToolUse","tool_name":"Read","tool_response":{"diagnostics":[{"error":"unused variable"}]}}'
assert_file_contains "${FAILURE_EVENT_FILE}" '"failed":false' "嵌套 error 键不应判定为失败测试"

# 只有 NSNumber / NSString 响应 -boolValue，"is_error": null 曾导致 SIGABRT。
NULL_FLAG_TMP="$(mktemp -d /tmp/cc-pets-null-flag-test.XXXXXX)"
NULL_FLAG_EVENT_FILE="${NULL_FLAG_TMP}/cc-pets-$(id -u)-agent-events.ndjson"
emit_hook_event "${NULL_FLAG_TMP}" \
  '{"hook_event_name":"PostToolUse","tool_name":"Read","tool_response":{"is_error":null}}'
assert_file_contains "${NULL_FLAG_EVENT_FILE}" '"failed":false' "is_error 为 null 时不应崩溃测试"

# 真正的失败信号必须仍然被识别，包括嵌一层的 status。
for failure_payload in \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"is_error":true}}' \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"success":false}}' \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"result":{"status":"failed"}}}'; do
  REAL_FAILURE_TMP="$(mktemp -d /tmp/cc-pets-real-failure-test.XXXXXX)"
  TEST_EXTRA_TEMP_DIRS+=("${REAL_FAILURE_TMP}")
  emit_hook_event "${REAL_FAILURE_TMP}" "${failure_payload}"
  assert_file_contains "${REAL_FAILURE_TMP}/cc-pets-$(id -u)-agent-events.ndjson" \
    '"failed":true' "显式失败信号识别测试"
done
print "工具失败判定收窄与空值健壮性测试通过"

# JSON 与换行必须一次 write 写完，否则并发 hook 会交错出坏行、丢事件。
RACE_TMP="$(mktemp -d /tmp/cc-pets-append-race-test.XXXXXX)"
RACE_EVENT_FILE="${RACE_TMP}/cc-pets-$(id -u)-agent-events.ndjson"
for _ in {1..60}; do
  emit_hook_event "${RACE_TMP}" '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' 2>/dev/null &
done
wait
RACE_REPORT="$(python3 - "${RACE_EVENT_FILE}" <<'PY'
import json, sys
total = bad = 0
with open(sys.argv[1], "rb") as handle:
    for raw in handle:
        line = raw.strip()
        if not line:
            continue
        total += 1
        try:
            json.loads(line)
        except Exception:
            bad += 1
print(f"{total} {bad}")
PY
)"
RACE_TOTAL="${RACE_REPORT%% *}"
RACE_BAD="${RACE_REPORT##* }"
if [[ "${RACE_TOTAL}" != "60" || "${RACE_BAD}" != "0" ]]; then
  print -u2 "并发追加原子性测试失败：期望 60 行 0 坏行，实际 ${RACE_TOTAL} 行 ${RACE_BAD} 坏行"
  exit 1
fi
print "并发事件追加原子性测试通过"

PROVIDER_TMP="$(mktemp -d /tmp/cc-pets-provider-test.XXXXXX)"
PROVIDER_EVENT_FILE="${PROVIDER_TMP}/cc-pets-$(id -u)-agent-events.ndjson"
print -n '{"schemaVersion":1,"provider":"MyAgent","state":"tool","tool":"shell"}' | \
  CC_PETS_STATE_DIR="${PROVIDER_TMP}" "${PROJECT_DIR}/.build/release/cc-pets" --provider-event
assert_file_contains "${PROVIDER_EVENT_FILE}" '"provider":"MyAgent"' "Provider 名称测试"
assert_file_contains "${PROVIDER_EVENT_FILE}" '"state":"tool"' "Provider 状态测试"
assert_file_contains "${PROVIDER_EVENT_FILE}" '"event":"PreToolUse"' "Provider 动画映射测试"
if print -n '{"schemaVersion":1,"provider":"MyAgent","state":"unknown"}' | \
  CC_PETS_STATE_DIR="${PROVIDER_TMP}" "${PROJECT_DIR}/.build/release/cc-pets" --provider-event \
  >/dev/null 2>&1; then
  print -u2 "非法 Provider 状态不应写入事件"
  exit 1
fi
print "统一 Provider 事件协议校验与映射测试通过"

CLAUDE_TMP="$(mktemp -d /tmp/cc-pets-claude-config-test.XXXXXX)"
CLAUDE_STATUS_SCRIPT="${CLAUDE_TMP}/statusline-command.sh"
print -r -- '#!/bin/zsh
/bin/cat >/dev/null
print -n original-status' > "${CLAUDE_STATUS_SCRIPT}"
chmod +x "${CLAUDE_STATUS_SCRIPT}"
node -e '
  const fs = require("fs");
  const script = process.argv[2];
  const encoded = Buffer.from(script).toString("base64");
  const quote = String.fromCharCode(39);
  const config = {
    model: "opus",
    env: { HTTP_PROXY: "http://127.0.0.1:1082" },
    statusLine: {
      type: "command",
      command: `CLAUDE_PET_STATUS_LINE=1 ${quote}/old/package/bin/claude-statusline-with-pet${quote} ${quote}${encoded}${quote}`,
      refreshInterval: 60
    },
    hooks: { PreToolUse: [{ matcher: "Bash", hooks: [
      { type: "command", command: "existing-hook" },
      { type: "command", command: `CLAUDE_PET_AGENT_HOOK=1 ${quote}/old/.build/release/codex-pet${quote} --hook` },
      { type: "command", command: "CLAUDE_PET_AGENT_HOOK=1 /other/tool --hook" }
    ] }] }
  };
  fs.writeFileSync(process.argv[1], JSON.stringify(config));
' "${CLAUDE_TMP}/settings.json" "${CLAUDE_STATUS_SCRIPT}"
CLAUDE_CONFIG_DIR="${CLAUDE_TMP}" node "${PROJECT_DIR}/scripts/install-claude-hooks.mjs" "${PROJECT_DIR}/.build/release/cc-pets" >/dev/null
CLAUDE_CONFIG_DIR="${CLAUDE_TMP}" node "${PROJECT_DIR}/scripts/install-claude-hooks.mjs" "${PROJECT_DIR}/.build/release/cc-pets" >/dev/null
node -e '
  const fs = require("fs");
  const config = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const script = fs.readFileSync(process.argv[2], "utf8");
  if (config.model !== "opus" || config.env.HTTP_PROXY !== "http://127.0.0.1:1082") process.exit(1);
  const handlers = Object.values(config.hooks).flat().flatMap(group => group.hooks || []);
  if (!handlers.some(handler => handler.command === "existing-hook")) process.exit(1);
  const petHandlers = handlers.filter(handler => handler.command?.includes("CC_PETS_CLAUDE_AGENT_HOOK=1"));
  if (petHandlers.length !== 14) process.exit(1);
  if (handlers.some(handler => handler.command?.includes("/.build/release/codex-pet"))) process.exit(1);
  if (!handlers.some(handler => handler.command === "CLAUDE_PET_AGENT_HOOK=1 /other/tool --hook")) process.exit(1);
  if (config.statusLine.refreshInterval !== 60 || config.statusLine.command !== process.argv[2]) process.exit(1);
  if ((script.match(/# >>> cc-pets-statusline >>>/g) || []).length !== 1) process.exit(1);
  if (!script.includes("print -n original-status")) process.exit(1);
' "${CLAUDE_TMP}/settings.json" "${CLAUDE_STATUS_SCRIPT}"
CLAUDE_INJECTED_USAGE_TMP="$(mktemp -d /tmp/cc-pets-claude-injected-usage-test.XXXXXX)"
CLAUDE_INJECTED_OUTPUT="$(print -rn -- "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":23.5,\"resets_at\":${QUOTA_FUTURE_FIVE}}}}" | \
  CC_PETS_STATE_DIR="${CLAUDE_INJECTED_USAGE_TMP}" "${CLAUDE_STATUS_SCRIPT}")"
[[ "${CLAUDE_INJECTED_OUTPUT}" == "original-status" ]]
node -e '
  const fs = require("fs");
  const file = fs.readdirSync(process.argv[1]).find(name => name.endsWith("claude-usage.json"));
  const cache = JSON.parse(fs.readFileSync(`${process.argv[1]}/${file}`, "utf8"));
  if (cache.five_hour.used_percentage !== 23.5) process.exit(1);
' "${CLAUDE_INJECTED_USAGE_TMP}"
print "Claude Code Hooks 合并与幂等测试通过"

# 第三方状态栏（`bun x ccstatusline` 之类带参数的命令行）没法就地插 prelude。statusline 是
# Claude 额度的唯一来源，改不了就等于这些用户永远拿不到额度，因此要回退到包装器：
# command 换成 claude-statusline-with-pet + base64 原命令，采集完再把原命令照常执行。
CLAUDE_WRAPPED_TMP="$(mktemp -d /tmp/cc-pets-claude-wrapped-status-test.XXXXXX)"
print -r -- '{"statusLine":{"type":"command","command":"print -n third-party-status","refreshInterval":30}}' \
  > "${CLAUDE_WRAPPED_TMP}/settings.json"
CLAUDE_CONFIG_DIR="${CLAUDE_WRAPPED_TMP}" node "${PROJECT_DIR}/scripts/install-claude-hooks.mjs" "${PROJECT_DIR}/.build/release/cc-pets" >/dev/null
CLAUDE_CONFIG_DIR="${CLAUDE_WRAPPED_TMP}" node "${PROJECT_DIR}/scripts/install-claude-hooks.mjs" "${PROJECT_DIR}/.build/release/cc-pets" >/dev/null
node -e '
  const fs = require("fs");
  const config = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const command = config.statusLine.command;
  // 其余字段不能被包装动作顺手改掉。
  if (config.statusLine.refreshInterval !== 30 || config.statusLine.type !== "command") process.exit(1);
  if (!command.startsWith("CC_PETS_CLAUDE_STATUS_LINE=1 ")) process.exit(1);
  if (!command.includes("/bin/claude-statusline-with-pet")) process.exit(1);
  const match = command.match(/'\''([A-Za-z0-9+/=]*)'\''\s*$/);
  if (!match || Buffer.from(match[1], "base64").toString("utf8") !== "print -n third-party-status") process.exit(1);
' "${CLAUDE_WRAPPED_TMP}/settings.json"
# 包装后的 command 必须真的能跑：额度写进缓存，原命令的输出原样透传给 Claude Code。
CLAUDE_WRAPPED_USAGE_TMP="$(mktemp -d /tmp/cc-pets-claude-wrapped-usage-test.XXXXXX)"
CLAUDE_WRAPPED_COMMAND="$(node -e '
  const fs = require("fs");
  process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).statusLine.command);
' "${CLAUDE_WRAPPED_TMP}/settings.json")"
CLAUDE_WRAPPED_OUTPUT="$(print -rn -- "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":31.5,\"resets_at\":${QUOTA_FUTURE_FIVE}}}}" | \
  CC_PETS_STATE_DIR="${CLAUDE_WRAPPED_USAGE_TMP}" /bin/zsh -c "${CLAUDE_WRAPPED_COMMAND}")"
[[ "${CLAUDE_WRAPPED_OUTPUT}" == "third-party-status" ]]
node -e '
  const fs = require("fs");
  const file = fs.readdirSync(process.argv[1]).find(name => name.endsWith("claude-usage.json"));
  if (!file) process.exit(1);
  const cache = JSON.parse(fs.readFileSync(`${process.argv[1]}/${file}`, "utf8"));
  if (cache.five_hour.used_percentage !== 31.5) process.exit(1);
' "${CLAUDE_WRAPPED_USAGE_TMP}"
CLAUDE_CONFIG_DIR="${CLAUDE_WRAPPED_TMP}" CODEX_HOME="${CLAUDE_WRAPPED_TMP}/codex" \
  node "${PROJECT_DIR}/scripts/uninstall-integrations.mjs" >/dev/null
node -e '
  const fs = require("fs");
  const config = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (config.statusLine.command !== "print -n third-party-status") process.exit(1);
  if (config.statusLine.refreshInterval !== 30) process.exit(1);
' "${CLAUDE_WRAPPED_TMP}/settings.json"
print "Claude Code 第三方 status line 包装接入与卸载还原测试通过"

CLAUDE_EMPTY_TMP="$(mktemp -d /tmp/cc-pets-claude-empty-status-test.XXXXXX)"
print -r -- '{}' > "${CLAUDE_EMPTY_TMP}/settings.json"
CLAUDE_CONFIG_DIR="${CLAUDE_EMPTY_TMP}" node "${PROJECT_DIR}/scripts/install-claude-hooks.mjs" "${PROJECT_DIR}/.build/release/cc-pets" >/dev/null
node -e '
  const fs = require("fs");
  const config = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (config.statusLine.command !== process.argv[2]) process.exit(1);
  if (!fs.readFileSync(process.argv[2], "utf8").includes("# CC Pets created this status line script")) process.exit(1);
' "${CLAUDE_EMPTY_TMP}/settings.json" "${CLAUDE_EMPTY_TMP}/statusline-command.sh"
CLAUDE_CONFIG_DIR="${CLAUDE_EMPTY_TMP}" CODEX_HOME="${CLAUDE_EMPTY_TMP}/codex" \
  node "${PROJECT_DIR}/scripts/uninstall-integrations.mjs" >/dev/null
node -e '
  const fs = require("fs");
  const config = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (config.statusLine || fs.existsSync(process.argv[2])) process.exit(1);
' "${CLAUDE_EMPTY_TMP}/settings.json" "${CLAUDE_EMPTY_TMP}/statusline-command.sh"
print "Claude Code 空 status line 创建与卸载恢复测试通过"

UNINSTALL_TMP="$(mktemp -d /tmp/cc-pets-uninstall-test.XXXXXX)"
mkdir -p "${UNINSTALL_TMP}/bin" "${UNINSTALL_TMP}/codex" "${UNINSTALL_TMP}/claude" "${UNINSTALL_TMP}/zdot"
print -r -- '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"existing-codex-hook"},{"type":"command","command":"CODEX_PET_AGENT_HOOK=1 '\''/old/.build/release/codex-pet'\'' --hook"},{"type":"command","command":"CODEX_PET_AGENT_HOOK=1 /other/tool --hook"}]}]}}' > "${UNINSTALL_TMP}/codex/hooks.json"
UNINSTALL_STATUS_SCRIPT="${UNINSTALL_TMP}/claude/statusline-command.sh"
print -r -- '#!/bin/zsh
/bin/cat >/dev/null
print -n original-status' > "${UNINSTALL_STATUS_SCRIPT}"
chmod +x "${UNINSTALL_STATUS_SCRIPT}"
node -e '
  const fs = require("fs");
  const script = process.argv[2];
  const encoded = Buffer.from(script).toString("base64");
  const quote = String.fromCharCode(39);
  const config = {
    statusLine: { type: "command", command: `CLAUDE_PET_STATUS_LINE=1 ${quote}/old/package/bin/claude-statusline-with-pet${quote} ${quote}${encoded}${quote}`, refreshInterval: 60 },
    hooks: { PreToolUse: [{ hooks: [
      { type: "command", command: "existing-claude-hook" },
      { type: "command", command: `CLAUDE_PET_AGENT_HOOK=1 ${quote}/old/.build/release/codex-pet${quote} --hook` },
      { type: "command", command: "CLAUDE_PET_AGENT_HOOK=1 /other/tool --hook" }
    ] }] }
  };
  fs.writeFileSync(process.argv[1], JSON.stringify(config));
' "${UNINSTALL_TMP}/claude/settings.json" "${UNINSTALL_STATUS_SCRIPT}"
print -r -- 'export KEEP_ME=1
# >>> codex-pet >>>
alias codex=/tmp/old-codex-with-pet
# <<< codex-pet <<<
# >>> claude-pet >>>
alias claude=/tmp/old-claude-with-pet
# <<< claude-pet <<<
# >>> cc-pets-codex >>>
alias codex=/tmp/codex-with-pet
# <<< cc-pets-codex <<<
# >>> cc-pets-claude >>>
alias claude=/tmp/claude-with-pet
# <<< cc-pets-claude <<<' > "${UNINSTALL_TMP}/zdot/.zshrc"
print -r -- '#!/bin/zsh
exit 1' > "${UNINSTALL_TMP}/bin/pgrep"
chmod +x "${UNINSTALL_TMP}/bin/pgrep"
CODEX_HOME="${UNINSTALL_TMP}/codex" CLAUDE_CONFIG_DIR="${UNINSTALL_TMP}/claude" \
  ZDOTDIR="${UNINSTALL_TMP}/zdot" CC_PETS_APPLICATIONS_DIR="${UNINSTALL_TMP}/Applications" \
  CC_PETS_APPLICATION_SUPPORT_DIR="${UNINSTALL_TMP}/Application Support" \
  CC_PETS_SHIM_DIR="${UNINSTALL_TMP}/shims" \
  PATH="${UNINSTALL_TMP}/bin:${PATH}" \
  "${PROJECT_DIR}/scripts/install-shell-integration.sh" >/dev/null
[[ -x "${UNINSTALL_TMP}/Applications/CC Pets.app/Contents/MacOS/cc-pets" ]]
UNINSTALL_CODEX_SHIM="${UNINSTALL_TMP}/shims/codex"
UNINSTALL_CLAUDE_SHIM="${UNINSTALL_TMP}/shims/claude"
[[ -L "${UNINSTALL_CODEX_SHIM}" && "${UNINSTALL_CODEX_SHIM:A}" == "${PROJECT_DIR}/bin/codex-with-pet" ]]
[[ -L "${UNINSTALL_CLAUDE_SHIM}" && "${UNINSTALL_CLAUDE_SHIM:A}" == "${PROJECT_DIR}/bin/claude-with-pet" ]]
node -e '
  const fs = require("fs");
  const codex = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const claude = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const rc = fs.readFileSync(process.argv[3], "utf8");
  const statusScript = fs.readFileSync(process.argv[4], "utf8");
  const codexCommands = Object.values(codex.hooks || {}).flat().flatMap(group => group.hooks || []).map(hook => hook.command);
  const claudeCommands = Object.values(claude.hooks || {}).flat().flatMap(group => group.hooks || []).map(hook => hook.command);
  if (codexCommands.filter(command => command?.includes("CC_PETS_CODEX_AGENT_HOOK=1")).length !== 8) process.exit(1);
  if (codexCommands.some(command => command?.includes("/.build/release/codex-pet"))) process.exit(1);
  if (!codexCommands.includes("CODEX_PET_AGENT_HOOK=1 /other/tool --hook")) process.exit(1);
  if (claudeCommands.filter(command => command?.includes("CC_PETS_CLAUDE_AGENT_HOOK=1")).length !== 14) process.exit(1);
  if (claudeCommands.some(command => command?.includes("/.build/release/codex-pet"))) process.exit(1);
  if (!claudeCommands.includes("CLAUDE_PET_AGENT_HOOK=1 /other/tool --hook")) process.exit(1);
  if (claude.statusLine.command !== process.argv[4]) process.exit(1);
  if ((statusScript.match(/# >>> cc-pets-statusline >>>/g) || []).length !== 1) process.exit(1);
  if (!rc.includes("# >>> cc-pets-shims >>>")) process.exit(1);
  if (!rc.includes("typeset -U path") || !/path=\(.*shims .*\$path\)/.test(rc)) process.exit(1);
  // alias 区分大小写，挡不住 Claude / CODEX 这些写法；升级时老段落必须被迁移掉，
  // 否则 alias 仍会抢在 shim 前面命中小写调用，两套机制并存难以排查。
  if (/cc-pets-codex|cc-pets-claude|codex-pet|claude-pet/.test(rc)) process.exit(1);
  if (/^alias (codex|claude)=/m.test(rc)) process.exit(1);
' "${UNINSTALL_TMP}/codex/hooks.json" "${UNINSTALL_TMP}/claude/settings.json" "${UNINSTALL_TMP}/zdot/.zshrc" "${UNINSTALL_STATUS_SCRIPT}"
# 父进程里已有一个排在后面的 shim 是 macOS 终端恢复会话时的常见情况。
# 重新加载 .zshrc 必须把它移到首位，且不留下重复项。
PATH="/usr/bin:${UNINSTALL_TMP}/shims:/bin" \
  ZDOTDIR="${UNINSTALL_TMP}/zdot" CC_PETS_SHIM_DIR="${UNINSTALL_TMP}/shims" \
  /bin/zsh -c '
    source "${ZDOTDIR}/.zshrc"
    [[ "${path[1]}" == "${CC_PETS_SHIM_DIR}" ]]
    matches=("${(@M)path:#${CC_PETS_SHIM_DIR}}")
    (( ${#matches} == 1 ))
  '
CODEX_HOME="${UNINSTALL_TMP}/codex" CLAUDE_CONFIG_DIR="${UNINSTALL_TMP}/claude" \
  ZDOTDIR="${UNINSTALL_TMP}/zdot" CC_PETS_SKIP_APP_STOP=1 \
  CC_PETS_SHIM_DIR="${UNINSTALL_TMP}/shims" \
  "${PROJECT_DIR}/scripts/uninstall-shell-integration.sh" >/dev/null
CODEX_HOME="${UNINSTALL_TMP}/codex" CLAUDE_CONFIG_DIR="${UNINSTALL_TMP}/claude" \
  ZDOTDIR="${UNINSTALL_TMP}/zdot" CC_PETS_SKIP_APP_STOP=1 \
  CC_PETS_SHIM_DIR="${UNINSTALL_TMP}/shims" \
  "${PROJECT_DIR}/scripts/uninstall-shell-integration.sh" >/dev/null
node -e '
  const fs = require("fs");
  const codex = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const claude = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const rc = fs.readFileSync(process.argv[3], "utf8");
  const statusScript = fs.readFileSync(process.argv[4], "utf8");
  const codexCommands = Object.values(codex.hooks || {}).flat().flatMap(group => group.hooks || []).map(hook => hook.command);
  const claudeCommands = Object.values(claude.hooks || {}).flat().flatMap(group => group.hooks || []).map(hook => hook.command);
  if (!codexCommands.includes("existing-codex-hook") || !codexCommands.includes("CODEX_PET_AGENT_HOOK=1 /other/tool --hook")) process.exit(1);
  if (codexCommands.some(command => command?.includes("CC_PETS_CODEX_AGENT_HOOK=1"))) process.exit(1);
  if (!claudeCommands.includes("existing-claude-hook") || !claudeCommands.includes("CLAUDE_PET_AGENT_HOOK=1 /other/tool --hook")) process.exit(1);
  if (claudeCommands.some(command => command?.includes("CC_PETS_CLAUDE_AGENT_HOOK=1"))) process.exit(1);
  if (claude.statusLine.command !== process.argv[4] || claude.statusLine.refreshInterval !== 60) process.exit(1);
  if (statusScript.includes("cc-pets-statusline") || !statusScript.includes("print -n original-status")) process.exit(1);
  if (!rc.includes("export KEEP_ME=1") || /cc-pets-shims|cc-pets-codex|cc-pets-claude|codex-pet|claude-pet/.test(rc)) process.exit(1);
' "${UNINSTALL_TMP}/codex/hooks.json" "${UNINSTALL_TMP}/claude/settings.json" "${UNINSTALL_TMP}/zdot/.zshrc" "${UNINSTALL_STATUS_SCRIPT}"
# shim 留在 PATH 里而包已被卸载，敲 claude 会得到"命令存在但跑不起来"，比没装还糟。
[[ ! -L "${UNINSTALL_TMP}/shims/codex" && ! -L "${UNINSTALL_TMP}/shims/claude" ]]
[[ ! -d "${UNINSTALL_TMP}/shims" ]]
print "新旧安装集成迁移、可逆卸载与幂等测试通过"

# ---- 缓存清理与完整卸载 ----
CLEAN_TMP="$(mktemp -d /tmp/cc-pets-clean-test.XXXXXX)"
mkdir -p "${CLEAN_TMP}/state/cc-pets-$(id -u)-clients" \
  "${CLEAN_TMP}/Application Support/CC Pets" "${CLEAN_TMP}/.build/clang-cache"
print old-event > "${CLEAN_TMP}/state/cc-pets-$(id -u)-agent-events.ndjson"
print old-usage > "${CLEAN_TMP}/state/cc-pets-$(id -u)-claude-usage.json"
print usage-lock > "${CLEAN_TMP}/state/cc-pets-$(id -u)-claude-usage.json.lock"
print lock > "${CLEAN_TMP}/state/cc-pets-$(id -u).lock"
print Codex > "${CLEAN_TMP}/state/cc-pets-$(id -u)-clients/999999"
print history > "${CLEAN_TMP}/Application Support/CC Pets/quota-history.json"
print updater > "${CLEAN_TMP}/Application Support/CC Pets/updater.json"
print log > "${CLEAN_TMP}/Application Support/CC Pets/update.log"
print cache > "${CLEAN_TMP}/.build/clang-cache/module"
CC_PETS_STATE_DIR="${CLEAN_TMP}/state" \
CC_PETS_APPLICATION_SUPPORT_DIR="${CLEAN_TMP}/Application Support/CC Pets" \
CC_PETS_BUILD_CACHE_DIR="${CLEAN_TMP}/.build/clang-cache" \
  "${PROJECT_DIR}/.build/release/cc-pets" --clean >/dev/null
[[ ! -e "${CLEAN_TMP}/state/cc-pets-$(id -u)-agent-events.ndjson" ]]
[[ ! -e "${CLEAN_TMP}/state/cc-pets-$(id -u)-claude-usage.json" ]]
# 锁文件必须长期保留；即使桌宠没运行，Claude statusline 仍可能持有它。
[[ -e "${CLEAN_TMP}/state/cc-pets-$(id -u)-claude-usage.json.lock" ]]
[[ ! -e "${CLEAN_TMP}/state/cc-pets-$(id -u).lock" ]]
[[ ! -e "${CLEAN_TMP}/state/cc-pets-$(id -u)-clients" ]]
[[ ! -e "${CLEAN_TMP}/Application Support/CC Pets/update.log" ]]
[[ ! -e "${CLEAN_TMP}/.build/clang-cache" ]]
[[ -e "${CLEAN_TMP}/Application Support/CC Pets/quota-history.json" ]]
[[ -e "${CLEAN_TMP}/Application Support/CC Pets/updater.json" ]]
print "安全缓存清理边界测试通过"

# 桌宠未运行不代表 Claude statusline 没在写额度。清理拿不到额度锁时必须保留缓存，
# 更不能 unlink 正被持有的锁，否则后来者会创建新 inode、两批写者同时进入临界区。
CLEAN_LOCK_TMP="$(mktemp -d /tmp/cc-pets-clean-lock-test.XXXXXX)"
mkdir -p "${CLEAN_LOCK_TMP}/state" "${CLEAN_LOCK_TMP}/Application Support/CC Pets" \
  "${CLEAN_LOCK_TMP}/.build/clang-cache"
CLEAN_LOCK_USAGE="${CLEAN_LOCK_TMP}/state/cc-pets-$(id -u)-claude-usage.json"
CLEAN_LOCK_FILE="${CLEAN_LOCK_USAGE}.lock"
print usage > "${CLEAN_LOCK_USAGE}"
python3 - "${CLEAN_LOCK_FILE}" "${CLEAN_LOCK_TMP}/ready" <<'PY' &
import fcntl, pathlib, sys, time
with open(sys.argv[1], "w") as handle:
    fcntl.flock(handle, fcntl.LOCK_EX)
    pathlib.Path(sys.argv[2]).touch()
    time.sleep(30)
PY
CLEAN_QUOTA_LOCK_PID=$!
for _ in {1..100}; do
  [[ -e "${CLEAN_LOCK_TMP}/ready" ]] && break
  sleep 0.01
done
CC_PETS_STATE_DIR="${CLEAN_LOCK_TMP}/state" \
CC_PETS_APPLICATION_SUPPORT_DIR="${CLEAN_LOCK_TMP}/Application Support/CC Pets" \
CC_PETS_BUILD_CACHE_DIR="${CLEAN_LOCK_TMP}/.build/clang-cache" \
  "${PROJECT_DIR}/.build/release/cc-pets" --clean >/dev/null
[[ -e "${CLEAN_LOCK_USAGE}" && -e "${CLEAN_LOCK_FILE}" ]]
kill "${CLEAN_QUOTA_LOCK_PID}" 2>/dev/null || true
wait "${CLEAN_QUOTA_LOCK_PID}" 2>/dev/null || true
CC_PETS_STATE_DIR="${CLEAN_LOCK_TMP}/state" \
CC_PETS_APPLICATION_SUPPORT_DIR="${CLEAN_LOCK_TMP}/Application Support/CC Pets" \
CC_PETS_BUILD_CACHE_DIR="${CLEAN_LOCK_TMP}/.build/clang-cache" \
  "${PROJECT_DIR}/.build/release/cc-pets" --clean >/dev/null
[[ ! -e "${CLEAN_LOCK_USAGE}" && -e "${CLEAN_LOCK_FILE}" ]]
# 没有额度缓存时不该为了加锁凭空造出一个锁文件——它此后永不删除，等于清理留下了残留。
rm -f "${CLEAN_LOCK_FILE}"
CC_PETS_STATE_DIR="${CLEAN_LOCK_TMP}/state" \
CC_PETS_APPLICATION_SUPPORT_DIR="${CLEAN_LOCK_TMP}/Application Support/CC Pets" \
CC_PETS_BUILD_CACHE_DIR="${CLEAN_LOCK_TMP}/.build/clang-cache" \
  "${PROJECT_DIR}/.build/release/cc-pets" --clean >/dev/null
if [[ -e "${CLEAN_LOCK_FILE}" ]]; then
  print -u2 "没有额度缓存时 --clean 凭空创建了额度写锁"
  exit 1
fi
print "额度缓存清理写锁并发保护测试通过"

UNSAFE_CLEAN_TMP="$(mktemp -d /tmp/cc-pets-unsafe-clean-test.XXXXXX)"
mkdir -p "${UNSAFE_CLEAN_TMP}/state" "${UNSAFE_CLEAN_TMP}/unrelated" \
  "${UNSAFE_CLEAN_TMP}/.build/clang-cache"
print keep > "${UNSAFE_CLEAN_TMP}/unrelated/keep"
print event > "${UNSAFE_CLEAN_TMP}/state/cc-pets-$(id -u)-agent-events.ndjson"
if CC_PETS_STATE_DIR="${UNSAFE_CLEAN_TMP}/state" \
    CC_PETS_APPLICATION_SUPPORT_DIR="${UNSAFE_CLEAN_TMP}/unrelated" \
    CC_PETS_BUILD_CACHE_DIR="${UNSAFE_CLEAN_TMP}/.build/clang-cache" \
    "${PROJECT_DIR}/.build/release/cc-pets" --clean >/dev/null 2>&1; then
  print -u2 "clean 不应接受非 CC Pets 应用数据目录"
  exit 1
fi
[[ -e "${UNSAFE_CLEAN_TMP}/unrelated/keep" ]]
[[ -e "${UNSAFE_CLEAN_TMP}/state/cc-pets-$(id -u)-agent-events.ndjson" ]]

if CC_PETS_STATE_DIR="${UNSAFE_CLEAN_TMP}/state" \
    CC_PETS_APPLICATION_SUPPORT_DIR="${UNSAFE_CLEAN_TMP}/Application Support/CC Pets" \
    CC_PETS_BUILD_CACHE_DIR="${UNSAFE_CLEAN_TMP}/unrelated" \
    "${PROJECT_DIR}/.build/release/cc-pets" --clean >/dev/null 2>&1; then
  print -u2 "clean 不应接受非 .build/clang-cache 构建缓存目录"
  exit 1
fi
[[ -e "${UNSAFE_CLEAN_TMP}/unrelated/keep" ]]
print "清理路径越界保护测试通过"

ACTIVE_CLEAN_TMP="$(mktemp -d /tmp/cc-pets-active-clean-test.XXXXXX)"
ACTIVE_LOCK="${ACTIVE_CLEAN_TMP}/cc-pets-$(id -u).lock"
python3 - "${ACTIVE_LOCK}" "${ACTIVE_CLEAN_TMP}/ready" <<'PY' &
import fcntl, pathlib, sys, time
with open(sys.argv[1], "w") as handle:
    fcntl.flock(handle, fcntl.LOCK_EX)
    pathlib.Path(sys.argv[2]).touch()
    time.sleep(30)
PY
ACTIVE_LOCK_PID=$!
for _ in {1..100}; do
  [[ -e "${ACTIVE_CLEAN_TMP}/ready" ]] && break
  sleep 0.01
done
if CC_PETS_STATE_DIR="${ACTIVE_CLEAN_TMP}" \
    CC_PETS_APPLICATION_SUPPORT_DIR="${ACTIVE_CLEAN_TMP}/support" \
    CC_PETS_BUILD_CACHE_DIR="${ACTIVE_CLEAN_TMP}/cache" \
    "${PROJECT_DIR}/.build/release/cc-pets" --clean >/dev/null 2>&1; then
  print -u2 "桌宠运行时 clean 不应删除正在使用的状态文件"
  kill "${ACTIVE_LOCK_PID}" 2>/dev/null || true
  exit 1
fi
kill "${ACTIVE_LOCK_PID}" 2>/dev/null || true
wait "${ACTIVE_LOCK_PID}" 2>/dev/null || true
[[ -e "${ACTIVE_LOCK}" ]]
print "运行中清理保护测试通过"

STALE_TMP="$(mktemp -d /tmp/cc-pets-stale-state-test.XXXXXX)"
print stale-event > "${STALE_TMP}/cc-pets-$(id -u)-agent-events.ndjson"
print stale-usage > "${STALE_TMP}/cc-pets-$(id -u)-claude-usage.json"
# 写锁创建后 mtime 不再更新，按 7 天判据它总是"过期"的。删掉一个正被持有的锁会让
# 后来者 open 出新 inode，互斥直接失效，所以启动清理必须放过它。
print stale-lock > "${STALE_TMP}/cc-pets-$(id -u)-claude-usage.json.lock"
touch -t 202001010000 "${STALE_TMP}/cc-pets-$(id -u)-agent-events.ndjson" \
  "${STALE_TMP}/cc-pets-$(id -u)-claude-usage.json" \
  "${STALE_TMP}/cc-pets-$(id -u)-claude-usage.json.lock"
clang -fobjc-arc -mmacosx-version-min=13.0 \
  -I"${PROJECT_DIR}/Sources/CCPets" -framework Foundation \
  "${PROJECT_DIR}/Sources/CCPets/CCPetsPaths.m" \
  "${PROJECT_DIR}/Sources/CCPets/CCPetsCleanup.m" \
  "${PROJECT_DIR}/tests/cleanup-harness.m" \
  -o "${STALE_TMP}/cleanup-test"
CC_PETS_STATE_DIR="${STALE_TMP}" \
  "${STALE_TMP}/cleanup-test"
if rg -q 'stale-(event|usage)' "${STALE_TMP}" 2>/dev/null; then
  print -u2 "启动时没有清理超过 7 天的运行状态"
  exit 1
fi
if [[ ! -e "${STALE_TMP}/cc-pets-$(id -u)-claude-usage.json.lock" ]]; then
  print -u2 "启动清理删掉了额度写锁：持锁期间被删会让互斥失效，锁只能在 --clean 时删"
  exit 1
fi
print "过期运行状态启动清理测试通过"

PURGE_TMP="$(mktemp -d /tmp/cc-pets-purge-test.XXXXXX)"
mkdir -p "${PURGE_TMP}/state" "${PURGE_TMP}/Application Support/CC Pets" \
  "${PURGE_TMP}/Applications/CC Pets.app/Contents" "${PURGE_TMP}/zdot" \
  "${PURGE_TMP}/.build/clang-cache"
print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.universewang.cc-pets</string></dict></plist>' \
  > "${PURGE_TMP}/Applications/CC Pets.app/Contents/Info.plist"
print data > "${PURGE_TMP}/Application Support/CC Pets/quota-history.json"
print event > "${PURGE_TMP}/state/cc-pets-$(id -u)-agent-events.ndjson"
print keep > "${PURGE_TMP}/keep"
print 'export KEEP_ME=1' > "${PURGE_TMP}/zdot/.zshrc"
if CODEX_HOME="${PURGE_TMP}/codex" CLAUDE_CONFIG_DIR="${PURGE_TMP}/claude" \
    ZDOTDIR="${PURGE_TMP}/zdot" CC_PETS_SKIP_APP_STOP=1 \
    "${PROJECT_DIR}/scripts/uninstall-shell-integration.sh" --purge </dev/null >/dev/null 2>&1; then
  print -u2 "非交互完整卸载缺少 --yes 时不应继续"
  exit 1
fi
[[ -e "${PURGE_TMP}/Application Support/CC Pets/quota-history.json" ]]
CODEX_HOME="${PURGE_TMP}/codex" CLAUDE_CONFIG_DIR="${PURGE_TMP}/claude" \
ZDOTDIR="${PURGE_TMP}/zdot" CC_PETS_SKIP_APP_STOP=1 \
CC_PETS_STATE_DIR="${PURGE_TMP}/state" \
CC_PETS_APPLICATIONS_DIR="${PURGE_TMP}/Applications" \
CC_PETS_APPLICATION_SUPPORT_DIR="${PURGE_TMP}/Application Support/CC Pets" \
CC_PETS_BUILD_CACHE_DIR="${PURGE_TMP}/.build/clang-cache" \
CC_PETS_PREFERENCES_DOMAIN="com.universewang.cc-pets.tests" \
  "${PROJECT_DIR}/scripts/uninstall-shell-integration.sh" --purge --yes >/dev/null
[[ ! -e "${PURGE_TMP}/Application Support/CC Pets" ]]
[[ ! -e "${PURGE_TMP}/Applications/CC Pets.app" ]]
[[ ! -e "${PURGE_TMP}/state/cc-pets-$(id -u)-agent-events.ndjson" ]]
[[ -e "${PURGE_TMP}/keep" ]]
print "带确认的完整卸载边界测试通过"

FOREIGN_APP_TMP="$(mktemp -d /tmp/cc-pets-foreign-app-test.XXXXXX)"
mkdir -p "${FOREIGN_APP_TMP}/Applications/CC Pets.app/Contents"
print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.foreign</string></dict></plist>' \
  > "${FOREIGN_APP_TMP}/Applications/CC Pets.app/Contents/Info.plist"
print keep > "${FOREIGN_APP_TMP}/Applications/CC Pets.app/keep"
if CC_PETS_APPLICATIONS_DIR="${FOREIGN_APP_TMP}/Applications" CC_PETS_SKIP_APP_STOP=1 \
    "${PROJECT_DIR}/scripts/uninstall-app.sh" >/dev/null 2>&1; then
  print -u2 "uninstall-app 不应删除同名但 Bundle ID 不匹配的应用"
  exit 1
fi
[[ -e "${FOREIGN_APP_TMP}/Applications/CC Pets.app/keep" ]]
print "同名非本项目应用删除保护测试通过"

DECOY_TMP="$(mktemp -d /tmp/cc-pets-decoy-config-test.XXXXXX)"
mkdir -p "${DECOY_TMP}/codex" "${DECOY_TMP}/claude"
print -r -- '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"CODEX_PET_AGENT_HOOK=1 /other/tool --hook"}]}]}}' > "${DECOY_TMP}/codex/hooks.json"
print -r -- '{"statusLine":{"type":"command","command":"CLAUDE_PET_STATUS_LINE=1 /other/status-tool"},"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"CLAUDE_PET_AGENT_HOOK=1 /other/tool --hook"}]}]}}' > "${DECOY_TMP}/claude/settings.json"
CODEX_HOME="${DECOY_TMP}/codex" CLAUDE_CONFIG_DIR="${DECOY_TMP}/claude" \
  node "${PROJECT_DIR}/scripts/uninstall-integrations.mjs" >/dev/null
node -e '
  const fs = require("fs");
  const codex = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const claude = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const codexCommand = codex.hooks.PreToolUse[0].hooks[0].command;
  const claudeCommand = claude.hooks.PreToolUse[0].hooks[0].command;
  if (codexCommand !== "CODEX_PET_AGENT_HOOK=1 /other/tool --hook") process.exit(1);
  if (claudeCommand !== "CLAUDE_PET_AGENT_HOOK=1 /other/tool --hook") process.exit(1);
  if (claude.statusLine.command !== "CLAUDE_PET_STATUS_LINE=1 /other/status-tool") process.exit(1);
' "${DECOY_TMP}/codex/hooks.json" "${DECOY_TMP}/claude/settings.json"
print "同名标记的非 CC Pets 配置保留测试通过"

CLAUDE_USAGE_TMP="$(mktemp -d /tmp/cc-pets-claude-usage-test.XXXXXX)"
ORIGINAL_STATUS="$(print -rn -- 'printf original-status' | /usr/bin/base64)"
STATUS_OUTPUT="$(print -rn -- "{\"model\":{\"display_name\":\"Opus\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":23.5,\"resets_at\":${QUOTA_FUTURE_FIVE}},\"seven_day\":{\"used_percentage\":41.2,\"resets_at\":${QUOTA_FUTURE_WEEK}}}}" | CC_PETS_STATE_DIR="${CLAUDE_USAGE_TMP}" "${PROJECT_DIR}/bin/claude-statusline-with-pet" "${ORIGINAL_STATUS}")"
[[ "${STATUS_OUTPUT}" == "original-status" ]]
node -e '
  const fs = require("fs");
  const files = fs.readdirSync(process.argv[1]);
  const cache = JSON.parse(fs.readFileSync(`${process.argv[1]}/${files.find(name => name.endsWith("claude-usage.json"))}`, "utf8"));
  if (cache.five_hour.used_percentage !== 23.5 || cache.seven_day.used_percentage !== 41.2) process.exit(1);
' "${CLAUDE_USAGE_TMP}"
print "Claude 额度采集与原状态栏转发测试通过"

# 逐窗口的过期判据。倒退的快照被拒绝时不能续期，否则只要还有会话在持续上报，
# 10 分钟的逃生阀就永远到不了，官方真的下调用量时面板会被永久钉在偏高的数字上。
QUOTA_STALE_TMP="$(mktemp -d /tmp/cc-pets-quota-stale-test.XXXXXX)"
QUOTA_STALE_FILE="${QUOTA_STALE_TMP}/cc-pets-$(id -u)-claude-usage.json"
record_quota() {
  print -rn -- "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":$1,\"resets_at\":${2:-${QUOTA_FUTURE_FIVE}}}}}" | \
    CC_PETS_STATE_DIR="${QUOTA_STALE_TMP}" \
    "${PROJECT_DIR}/bin/claude-statusline-with-pet" "${ORIGINAL_STATUS}" >/dev/null
}
record_quota 90
record_quota 60
node -e '
  const fs = require("fs");
  const cache = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (cache.five_hour.used_percentage !== 90) {
    console.error(`倒退的快照没有被拒绝：${cache.five_hour.used_percentage}`);
    process.exit(1);
  }
  if (typeof cache.accepted_at?.five_hour !== "number") {
    console.error("缺少逐窗口的 accepted_at");
    process.exit(1);
  }
' "${QUOTA_STALE_FILE}"
# 被拒绝的那次不许把 accepted_at 推到现在：把它拨回 11 分钟前，若拒绝时续过期，
# 这里读到的就是刚才那一刻，下面的用例也就跟着失去意义。
node -e '
  const fs = require("fs");
  const cache = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const age = Date.now() / 1000 - cache.accepted_at.five_hour;
  if (age > 5) {
    console.error(`accepted_at 不该这么旧：${age}s`);
    process.exit(1);
  }
  cache.accepted_at.five_hour -= 660;
  fs.writeFileSync(process.argv[1], JSON.stringify(cache));
' "${QUOTA_STALE_FILE}"
record_quota 60
node -e '
  const fs = require("fs");
  const cache = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (cache.five_hour.used_percentage !== 60) {
    console.error(`旧快照超过 10 分钟后仍未被顶掉：${cache.five_hour.used_percentage}`);
    process.exit(1);
  }
' "${QUOTA_STALE_FILE}"
print "配额快照逐窗口过期与倒退拒绝测试通过"

# 7 天窗口是滚动的，resets_at 随旧用量滑出窗口不断前移，同一个窗口内前后两次上报差出
# 十几个小时都算正常。旧版判据把"resets_at 变了"一律当成窗口滚动、无条件接受归零，于是
# 一份 used 更低的旧快照就能把面板顶回高剩余（2026-08-19 实测 7 天窗口 93% → 98%，
# 下一次真实响应又改回 93%）。前移不等于滚动：旧窗口没到期就仍按用量单调性判。
QUOTA_ROLL_TMP="$(mktemp -d /tmp/cc-pets-quota-roll-test.XXXXXX)"
QUOTA_ROLL_FILE="${QUOTA_ROLL_TMP}/cc-pets-$(id -u)-claude-usage.json"
record_roll_quota() {  # $1=used_percentage $2=resets_at
  print -rn -- "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":$1,\"resets_at\":$2}}}" | \
    CC_PETS_STATE_DIR="${QUOTA_ROLL_TMP}" \
    "${PROJECT_DIR}/bin/claude-statusline-with-pet" "${ORIGINAL_STATUS}" >/dev/null
}
assert_roll_quota() {  # $1=期望的 used_percentage $2=失败时的说明
  node -e '
    const fs = require("fs");
    const cache = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (cache.five_hour.used_percentage !== Number(process.argv[2])) {
      console.error(`${process.argv[3]}：${cache.five_hour.used_percentage}`);
      process.exit(1);
    }
  ' "${QUOTA_ROLL_FILE}" "$1" "$2"
}
QUOTA_ROLL_NOW="$(date +%s)"
record_roll_quota 40 $(( QUOTA_ROLL_NOW + 3000 ))
record_roll_quota 5 $(( QUOTA_ROLL_NOW + 3600 ))
assert_roll_quota 40 "resets_at 前移的旧快照被当成窗口滚动收下了"

# resets_at 落在一个窗长之外的快照不可能属于当前 5 小时窗口。这种坏值连逃生阀都不能放行：
# 一旦落盘，面板上的剩余额度和重置时间会一起错，而且要等到下一次真实响应才纠得回来。
node -e '
  const fs = require("fs");
  const cache = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  cache.accepted_at.five_hour -= 660;
  fs.writeFileSync(process.argv[1], JSON.stringify(cache));
' "${QUOTA_ROLL_FILE}"
record_roll_quota 5 $(( QUOTA_ROLL_NOW + 72000 ))
assert_roll_quota 40 "resets_at 超出窗长的快照被收下了"
record_roll_quota 5 $(( QUOTA_ROLL_NOW - 60 ))
assert_roll_quota 40 "resets_at 已经过期的快照被收下了"

# 反过来，旧窗口真的到期时归零是真的，必须收下。这里把 accepted_at 拨回当下，
# 确保验的是"旧窗口已过期"这条通路，而不是 10 分钟逃生阀顺手放行。
node -e '
  const fs = require("fs");
  const cache = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  cache.five_hour.resets_at = Math.floor(Date.now() / 1000) - 60;
  cache.accepted_at.five_hour = Date.now() / 1000;
  fs.writeFileSync(process.argv[1], JSON.stringify(cache));
' "${QUOTA_ROLL_FILE}"
record_roll_quota 5 $(( QUOTA_ROLL_NOW + 3000 ))
assert_roll_quota 5 "旧窗口到期后的归零快照被拒绝了"
print "配额快照窗口滚动误判与坏 resets_at 拒绝测试通过"

# 阻塞版 flock 没有超时：一个被 SIGSTOP 或卡在慢速卷上的写者会把之后每一次
# statusline 渲染永久挂住。拿不到锁必须放弃这次写入，并且状态栏照常输出。
#
# 判据是"有没有等满持锁时间"，不是"跑得够不够快"：重试上限只有 1 秒（50 × 20ms），
# 但 CI runner 负载高时进程启动本身就能吃掉好几秒，卡着秒级阈值会周期性误报。
# 所以把持锁拉到 30 秒、阈值放到 10 秒——真退化成阻塞版的话会等满 30 秒，
# 3 倍余量既容得下慢机器，又不会把真正的故障放过去。
QUOTA_LOCK_TMP="$(mktemp -d /tmp/cc-pets-quota-lock-test.XXXXXX)"
QUOTA_LOCK_FILE="${QUOTA_LOCK_TMP}/cc-pets-$(id -u)-claude-usage.json.lock"
python3 - "${QUOTA_LOCK_FILE}" "${QUOTA_LOCK_TMP}/ready" <<'PY' &
import fcntl, pathlib, sys, time
with open(sys.argv[1], "w") as handle:
    fcntl.flock(handle, fcntl.LOCK_EX)
    pathlib.Path(sys.argv[2]).touch()
    time.sleep(30)
PY
QUOTA_LOCK_PID=$!
for _ in {1..100}; do
  [[ -e "${QUOTA_LOCK_TMP}/ready" ]] && break
  sleep 0.01
done
QUOTA_LOCK_START="$(date +%s)"
LOCKED_OUTPUT="$(print -rn -- "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":23.5,\"resets_at\":${QUOTA_FUTURE_FIVE}}}}" | \
  CC_PETS_STATE_DIR="${QUOTA_LOCK_TMP}" \
  "${PROJECT_DIR}/bin/claude-statusline-with-pet" "${ORIGINAL_STATUS}")"
QUOTA_LOCK_ELAPSED=$(( $(date +%s) - QUOTA_LOCK_START ))
kill "${QUOTA_LOCK_PID}" 2>/dev/null || true
wait "${QUOTA_LOCK_PID}" 2>/dev/null || true
if (( QUOTA_LOCK_ELAPSED >= 10 )); then
  print -u2 "锁被别人持有时 statusline 挂了 ${QUOTA_LOCK_ELAPSED}s：flock 必须是非阻塞加有限重试"
  exit 1
fi
[[ "${LOCKED_OUTPUT}" == "original-status" ]]
if [[ -e "${QUOTA_LOCK_TMP}/cc-pets-$(id -u)-claude-usage.json" ]]; then
  print -u2 "拿不到锁时不应无锁写入额度文件"
  exit 1
fi
print "额度写锁非阻塞与放弃写入测试通过"

HISTORY_TMP="$(mktemp -d /tmp/cc-pets-history-test.XXXXXX)"
HISTORY_OUTPUT="$(CC_PETS_APPLICATION_SUPPORT_DIR="${HISTORY_TMP}" \
  "${PROJECT_DIR}/.build/release/cc-pets" --history)"
print -r -- "${HISTORY_OUTPUT}" | node -e '
  let input = "";
  process.stdin.on("data", chunk => input += chunk);
  process.stdin.on("end", () => {
    const history = JSON.parse(input);
    if (history.schemaVersion !== 1 || !Array.isArray(history.samples)) process.exit(1);
  });
'
grep -Fq '15 * 60' "${PET_SOURCES[@]}"
grep -Fq '7 * 24 * 60 * 60' "${PET_SOURCES[@]}"
grep -q 'CCPetsQuotaHistoryEnabled' "${PET_SOURCES[@]}"
print "本地额度历史格式、采样间隔与默认开关测试通过"

# 受限期间官方 rate_limits 仍会返回窗口百分比。一律丢掉的话，长期受限的 provider
# 在 7 天里攒不下一个历史点，趋势曲线只剩"当前"这一个点、画不出线。两个用例各用
# 一个独立的支持目录：RecordQuotaHistory 有 15 分钟采样闸门，同目录跑第二次必被拒。
QUOTA_HISTORY_TMP="$(mktemp -d /tmp/cc-pets-quota-history-test.XXXXXX)"
clang -fobjc-arc -mmacosx-version-min=13.0 \
  -I"${PROJECT_DIR}/Sources/CCPets" \
  -framework Foundation \
  "${PROJECT_DIR}/Sources/CCPets/CCPetsQuotaHistory.m" \
  "${PROJECT_DIR}/Sources/CCPets/CCPetsPaths.m" \
  "${PROJECT_DIR}/tests/quota-history-harness.m" \
  -o "${QUOTA_HISTORY_TMP}/quota-history-test"
CC_PETS_APPLICATION_SUPPORT_DIR="${QUOTA_HISTORY_TMP}/fresh" \
  "${QUOTA_HISTORY_TMP}/quota-history-test" fresh-snapshot
CC_PETS_APPLICATION_SUPPORT_DIR="${QUOTA_HISTORY_TMP}/stale" \
  "${QUOTA_HISTORY_TMP}/quota-history-test" stale-snapshot
rm -rf "${QUOTA_HISTORY_TMP}"

# 趋势列算的是 7 天窗口。exhaustedAt 没有窗口归属（撞墙的通常是 5 小时窗口），拿它
# 一票否决整列，会出现左边 7 天还剩 45%、右边却说"等待官方额度刷新"的自相矛盾。
grep -q 'weekUnknown' "${PET_SOURCES[@]}"
grep -Fq 'exhausted && currentUsed == nil' "${PET_SOURCES[@]}"
print "受限时 7 天趋势仍按官方余量判档测试通过"

# 关掉终端窗口只销毁 pty，claude / codex 是 Node 进程，不一定跟着 SIGHUP 退出，会变成
# 脱离控制终端的孤儿继续活着。只问 kill(pid, 0) 的话 pid 一直在，会话就永久挂在"在线"。
grep -q 'ClientProcessAlive' "${PET_SOURCES[@]}"
grep -q 'e_tdev' "${PET_SOURCES[@]}"
grep -q 'NODEV' "${PET_SOURCES[@]}"
print "客户端存活判定要求控制终端仍匹配测试通过"

DASHBOARD_PREVIEW="${CLAUDE_USAGE_TMP}/dashboard.png"
"${PROJECT_DIR}/.build/release/cc-pets" --render-dashboard "${DASHBOARD_PREVIEW}"
[[ -s "${DASHBOARD_PREVIEW}" ]]
file "${DASHBOARD_PREVIEW}" | grep -q 'PNG image data, 441 x 343'
print "额度面板离屏渲染测试通过"

# "数据刷新" 是相对时间，必须由面板自己的定时器走字，不能依赖别处顺手设的 needsDisplay。
grep -q 'quotaClockTimer' "${PET_SOURCES[@]}"
grep -q 'QuotaClockInterval' "${PET_SOURCES[@]}"
grep -q 'agentStatusColor' "${PET_SOURCES[@]}"
print "额度面板相对时间自刷新与状态配色测试通过"

QUOTA_ONLINE_TMP="$(mktemp -d /tmp/cc-pets-quota-online-test.XXXXXX)"
clang -fobjc-arc -mmacosx-version-min=13.0 \
  -I"${PROJECT_DIR}/Sources/CCPets" \
  -framework Cocoa \
  "${PROJECT_DIR}/Sources/CCPets/QuotaDashboardView.m" \
  "${PROJECT_DIR}/tests/quota-online-harness.m" \
  -o "${QUOTA_ONLINE_TMP}/quota-online-test"
"${QUOTA_ONLINE_TMP}/quota-online-test"
# 直接跑 claude / codex 的客户端没有 pid 文件，必须靠事件活跃度补上，否则会误判离线。
grep -q 'providerActivityAt' "${PET_SOURCES[@]}"
rm -rf "${QUOTA_ONLINE_TMP}"

STATUS_PREVIEW="${CLAUDE_USAGE_TMP}/status-card.png"
"${PROJECT_DIR}/.build/release/cc-pets" --render-status "${STATUS_PREVIEW}"
[[ -s "${STATUS_PREVIEW}" ]]
file "${STATUS_PREVIEW}" | grep -q 'PNG image data, 352 x 70'
print "玻璃 Agent 状态卡片离屏渲染测试通过"

SWITCH_PREVIEW="${CLAUDE_USAGE_TMP}/menu-switches.png"
"${PROJECT_DIR}/.build/release/cc-pets" --render-switches "${SWITCH_PREVIEW}"
[[ -s "${SWITCH_PREVIEW}" ]]
file "${SWITCH_PREVIEW}" | grep -q 'PNG image data, 220 x 72'
print "高对比度菜单开关离屏渲染测试通过"

otool -L "${PROJECT_DIR}/.build/release/cc-pets" | grep -q 'UserNotifications.framework'
grep -q 'CCPetsNotifyCompletion' "${PET_SOURCES[@]}"
grep -q 'CCPetsNotifyFailure' "${PET_SOURCES[@]}"
grep -q 'CCPetsNotifyApproval' "${PET_SOURCES[@]}"
grep -q 'statusTextForState' "${PET_SOURCES[@]}"
grep -Fq 'UpdateLogSizeLimit = 1024 * 1024' "${PET_SOURCES[@]}"
grep -q 'TrimUpdateLog' "${PET_SOURCES[@]}"
grep -q 'addPersistentSwitchToMenu' "${PET_SOURCES[@]}"
grep -q '@interface MenuToggleSwitch' "${PET_SOURCES[@]}"
grep -Fq 'NSColor.controlAccentColor' "${PET_SOURCES[@]}"
grep -Fq 'NSColor.whiteColor' "${PET_SOURCES[@]}"
grep -q 'item.view = row' "${PET_SOURCES[@]}"
if grep -q 'checkboxWithTitle' "${PET_SOURCES[@]}"; then
  print -u2 "设置菜单不应继续使用左侧复选框"
  exit 1
fi
grep -q 'NSVisualEffectMaterialPopover' "${PET_SOURCES[@]}"
grep -Fq 'self.statusPanel.hasShadow = NO' "${PET_SOURCES[@]}"
grep -q 'statusShadow.layer.shadowPath' "${PET_SOURCES[@]}"
grep -Fq 'statusGlassSize.width + 12' "${PET_SOURCES[@]}"
grep -q 'CCPetsStatusBubbleExpanded' "${PET_SOURCES[@]}"
grep -q 'CCPetsStatusBubblePreferenceV2' "${PET_SOURCES[@]}"
# 断言"气泡默认展开"这件事本身，不锁死 registerDefaults 里同时注册了哪几个键。
grep -Fq 'StatusBubbleExpandedKey: @YES' "${PET_SOURCES[@]}"
grep -Fq '[defaults setBool:YES forKey:StatusBubbleExpandedKey]' "${PET_SOURCES[@]}"
grep -q 'liveClientCount' "${PET_SOURCES[@]}"
if grep -q 'unreadStatusCount' "${PET_SOURCES[@]}"; then
  print -u2 "折叠徽标不应再显示含义不清的未读事件数"
  exit 1
fi
# 折叠开关不能再是盖在宠物身上的独立窗口：任何可点击视图都会抢走拖动手势。
if grep -q 'statusTogglePanel' "${PET_SOURCES[@]}"; then
  print -u2 "折叠开关不应再使用独立窗口，它会遮挡宠物的拖动区域"
  exit 1
fi
# 气泡只由菜单开关控制：点击宠物不再切换气泡，避免无提示的隐式交互。
if grep -Fq 'statusToggleRequested' "${PET_SOURCES[@]}"; then
  print -u2 "点击宠物不应再切换消息气泡，气泡只由菜单开关控制"
  exit 1
fi
grep -Fq 'toggleStatusBubbleFromMenu' "${PET_SOURCES[@]}"
# 附属面板通过窗口移动通知同时跟随背景拖动和宠物本体拖动。
grep -Fq 'NSWindowDidMoveNotification' "${PET_SOURCES[@]}"
grep -Fq 'petWindowDidMove' "${PET_SOURCES[@]}"
# 两条命中区：透明背景由 AppKit 拖，宠物本体由 performWindowDragWithEvent: 拖，
# 底层同为窗口服务器拖动；mouseDownCanMoveWindow=NO 保证两者不处理同一次按下。
grep -Fq 'self.panel.movableByWindowBackground = YES' "${PET_SOURCES[@]}"
grep -Fq 'mouseDownCanMoveWindow { return NO; }' "${PET_SOURCES[@]}"
grep -Fq 'performWindowDragWithEvent:' "${PET_SOURCES[@]}"
# 拖动期间主 runloop 处于事件跟踪模式，精灵动画定时器必须注册到 common modes，
# 否则宠物会定格在起手那一帧。
grep -Fq 'addTimer:self.frameTimer forMode:NSRunLoopCommonModes' "${PET_SOURCES[@]}"
# performWindowDragWithEvent: 会立即返回且不保证发送 mouseUp，调用之后不能同步结束
# running 动画；由 mouseUp 快速结束，并用物理按键状态兜底。
grep -Fq 'CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft)' \
  "${PET_SOURCES[@]}"
grep -Fq '[self endPetDrag]' "${PET_SOURCES[@]}"
if sed -n '/performWindowDragWithEvent:event/,/^- (void)endPetDrag/p' \
  Sources/CCPets/PetView.m | grep -Fq 'self.draggingPet = NO'; then
  print -u2 "performWindowDragWithEvent: 返回后不应立即结束奔跑动画"
  exit 1
fi
# PetView 仍需接受非激活窗口的第一次点击。
grep -Fq 'acceptsFirstMouse:' Sources/CCPets/PetView.m
# 拖动一旦退回主线程手工搬窗口，就会重新依赖“事件流完整送达”这个不成立的前提：
# 首次点击被吞、mouseUp 丢失卡死、被其他面板截走事件、与 AppKit 抢 frame。
# 下面这些是那套实现的残留特征，出现即视为回归。
for pattern in 'dragStartWindowOrigin' 'dragOccurred' 'dragReleaseGlobalMonitor' \
  'NSEventMaskLeftMouseUp'; do
  if grep -Fq "${pattern}" "${PET_SOURCES[@]}"; then
    print -u2 "拖动不应回退到手工事件流实现（发现 ${pattern}）"
    exit 1
  fi
done
# 额度面板不覆盖宠物本体。
grep -Fq 'NSMinX(petFrame) - size.width - gap' "${PET_SOURCES[@]}"
grep -Fq 'AgentStatusInactivityInterval = 60.0' "${PET_SOURCES[@]}"
grep -Fq 'afterDelay:AgentStatusInactivityInterval' "${PET_SOURCES[@]}"
grep -q 'cancelPreviousPerformRequestsWithTarget:self' "${PET_SOURCES[@]}"
print "状态气泡与可选系统通知配置测试通过"

zsh -n "${PROJECT_DIR}/bin/codex-with-pet"
zsh -n "${PROJECT_DIR}/bin/claude-with-pet"
zsh -n "${PROJECT_DIR}/bin/claude-statusline-with-pet"
zsh -n "${PROJECT_DIR}/bin/cc-pets"
grep -Fq '"provider":"Codex","state":"starting"' "${PROJECT_DIR}/bin/codex-with-pet"
grep -Fq '"provider":"Claude","state":"starting"' "${PROJECT_DIR}/bin/claude-with-pet"
zsh -n "${PROJECT_DIR}/scripts/install-shell-integration.sh"
zsh -n "${PROJECT_DIR}/scripts/uninstall-shell-integration.sh"
zsh -n "${PROJECT_DIR}/scripts/install-app.sh"
zsh -n "${PROJECT_DIR}/scripts/uninstall-app.sh"
node --check "${PROJECT_DIR}/scripts/uninstall-integrations.mjs"
node --check "${PROJECT_DIR}/scripts/configure-updater.mjs"
grep -Fq 'NODE_EXECUTABLE="${npm_node_execpath:-}"' \
  "${PROJECT_DIR}/scripts/install-shell-integration.sh"
grep -Fq 'export PATH="${NODE_EXECUTABLE:h}:${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"' \
  "${PROJECT_DIR}/scripts/install-shell-integration.sh"
grep -Fq '"${NODE_EXECUTABLE}" "${PROJECT_DIR}/scripts/configure-updater.mjs"' \
  "${PROJECT_DIR}/scripts/install-shell-integration.sh"
[[ "$(node -p "require('${PROJECT_DIR}/package.json').scripts.postinstall")" == "./scripts/install-shell-integration.sh" ]]
[[ "$(node -p "require('${PROJECT_DIR}/package.json').scripts.version")" == "npm test" ]]
print "npm 安装后自动初始化测试通过"
print "npm version 自动验证配置测试通过"
print "CLI 包装器语法测试通过"

WRAPPER_TMP="$(mktemp -d /tmp/cc-pets-wrapper-env-test.XXXXXX)"
mkdir -p "${WRAPPER_TMP}/bin" "${WRAPPER_TMP}/codex-home"
print -r -- '#!/bin/zsh
[[ -z "${HTTP_PROXY:-}" ]]
[[ -z "${HTTPS_PROXY:-}" ]]
[[ -z "${ALL_PROXY:-}" ]]' > "${WRAPPER_TMP}/bin/real-codex"
print -r -- '#!/bin/zsh
exit 0' > "${WRAPPER_TMP}/bin/open"
chmod +x "${WRAPPER_TMP}/bin/real-codex" "${WRAPPER_TMP}/bin/open"
print -r -- 'HTTP_PROXY=http://127.0.0.1:18080
HTTPS_PROXY=http://127.0.0.1:18080
ALL_PROXY=socks5://127.0.0.1:18081' > "${WRAPPER_TMP}/codex-home/.env"
# 包装脚本会发一条 starting 事件。TMPDIR 只能隔离 pid 目录（那是 zsh 里拼的路径），
# 事件文件走 NSTemporaryDirectory()，不认 TMPDIR，必须显式给 CC_PETS_STATE_DIR，
# 否则每跑一次测试都会往用户真实的事件流里灌 SessionStart，把桌宠打回"正在启动"。
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  PATH="${WRAPPER_TMP}/bin:${PATH}" CODEX_HOME="${WRAPPER_TMP}/codex-home" \
  CODEX_REAL_BIN="${WRAPPER_TMP}/bin/real-codex" TMPDIR="${WRAPPER_TMP}/" \
  CC_PETS_STATE_DIR="${WRAPPER_TMP}/state" \
  "${PROJECT_DIR}/bin/codex-with-pet"
print "Codex 包装器不重复加载 .env 测试通过"

mkdir -p "${WRAPPER_TMP}/Applications/CC Pets.app"
print -r -- '#!/bin/zsh
print -r -- "$@" > "${OPEN_LOG}"' > "${WRAPPER_TMP}/bin/open"
chmod +x "${WRAPPER_TMP}/bin/open"
OPEN_LOG="${WRAPPER_TMP}/open.log" PATH="${WRAPPER_TMP}/bin:${PATH}" \
  CC_PETS_APPLICATIONS_DIR="${WRAPPER_TMP}/Applications" "${PROJECT_DIR}/bin/cc-pets"
grep -Fq "${WRAPPER_TMP}/Applications/CC Pets.app" "${WRAPPER_TMP}/open.log"
print "CLI 优先启动已安装应用测试通过"

if grep -q 'liveClients > 0.*managedByCLI = YES' "${PET_SOURCES[@]}"; then
  print -u2 "手动启动的桌宠仍可能被客户端切换为 CLI 托管模式"
  exit 1
fi
grep -q 'liveClients == 0 && self.managedByCLI' "${PET_SOURCES[@]}"
print "桌宠启动模式不会被后续客户端改变测试通过"

# ---- 客户端退出后状态气泡清场 ----
# 包装脚本最后一行是 exec，装不上 EXIT trap，客户端退出时不会补发结束事件。
# 唯一的退出信号是 pid 文件被回收，所以 pid 文件必须带上 provider 名，
# 否则 Codex 全部关闭后桌宠分不清剩下的客户端是谁，会一直显示 "Codex 正在启动"。
LIFECYCLE_TMP="$(mktemp -d /tmp/cc-pets-client-lifecycle-test.XXXXXX)"
mkdir -p "${LIFECYCLE_TMP}/bin" "${LIFECYCLE_TMP}/Applications/CC Pets.app"
print -r -- '#!/bin/zsh
exit 0' > "${LIFECYCLE_TMP}/bin/real-agent"
print -r -- '#!/bin/zsh
exit 0' > "${LIFECYCLE_TMP}/bin/open"
chmod +x "${LIFECYCLE_TMP}/bin/real-agent" "${LIFECYCLE_TMP}/bin/open"

for wrapper provider in codex-with-pet Codex claude-with-pet Claude; do
  run_tmp="${LIFECYCLE_TMP}/${provider}"
  mkdir -p "${run_tmp}"
  env PATH="${LIFECYCLE_TMP}/bin:${PATH}" TMPDIR="${run_tmp}/" \
    CODEX_REAL_BIN="${LIFECYCLE_TMP}/bin/real-agent" \
    CLAUDE_REAL_BIN="${LIFECYCLE_TMP}/bin/real-agent" \
    CODEX_HOME="${run_tmp}/codex-home" \
    CC_PETS_STATE_DIR="${run_tmp}/state" \
    CC_PETS_APPLICATIONS_DIR="${LIFECYCLE_TMP}/Applications" \
    "${PROJECT_DIR}/bin/${wrapper}"
  client_files=("${run_tmp}"/cc-pets-$(id -u)-clients/*(N))
  if (( ${#client_files[@]} != 1 )); then
    print -u2 "${wrapper} 应该恰好写出 1 个客户端 pid 文件，实际 ${#client_files[@]} 个"
    exit 1
  fi
  if [[ "$(<"${client_files[1]}")" != "${provider}" ]]; then
    print -u2 "${wrapper} 的客户端 pid 文件应写入 provider 名 ${provider}，实际是 '$(<"${client_files[1]}")'"
    exit 1
  fi
done
print "包装脚本写入客户端 provider 标记测试通过"

# ---- 大小写写法与 shim 防递归 ----
# 1.2.0 之前用 alias 接管 codex / claude。alias 名区分大小写，而 macOS 文件系统默认
# 不区分：敲 Claude 时 zsh 找不到 alias，直接从 PATH 命中真二进制，桌宠不会被拉起。
# 换成 PATH 前置的 shim 后，任意大小写都落到同一个文件上；代价是包装脚本不能再用
# whence -p 找真二进制——第一个命中的就是 shim 自己，exec 下去会无限递归。
SHIM_TMP="$(mktemp -d /tmp/cc-pets-shim-case-test.XXXXXX)"
mkdir -p "${SHIM_TMP}/bin" "${SHIM_TMP}/shims" "${SHIM_TMP}/Applications/CC Pets.app"
print -r -- '#!/bin/zsh
print -r -- "real-claude $*"' > "${SHIM_TMP}/bin/claude"
print -r -- '#!/bin/zsh
print -r -- "real-codex $*"' > "${SHIM_TMP}/bin/codex"
print -r -- '#!/bin/zsh
exit 0' > "${SHIM_TMP}/bin/open"
chmod +x "${SHIM_TMP}/bin/claude" "${SHIM_TMP}/bin/codex" "${SHIM_TMP}/bin/open"
ln -sfn "${PROJECT_DIR}/bin/claude-with-pet" "${SHIM_TMP}/shims/claude"
ln -sfn "${PROJECT_DIR}/bin/codex-with-pet" "${SHIM_TMP}/shims/codex"

shim_case_index=0
for invocation expected in Claude real-claude CLAUDE real-claude claude real-claude \
                           Codex real-codex CODEX real-codex codex real-codex; do
  # 目录名不能用 invocation：文件系统不区分大小写，Claude 和 claude 会共用一个目录，
  # pid 文件跨轮次累积，断言就失真了。
  (( shim_case_index += 1 ))
  run_tmp="${SHIM_TMP}/run-${shim_case_index}"
  mkdir -p "${run_tmp}"
  # 逻辑写反时表现是无限 exec 自己（不是 fork bomb，但会永久挂住），必须限时。
  env PATH="${SHIM_TMP}/shims:${SHIM_TMP}/bin:${PATH}" \
    CC_PETS_SHIM_DIR="${SHIM_TMP}/shims" TMPDIR="${run_tmp}/" \
    CC_PETS_STATE_DIR="${run_tmp}/state" CODEX_HOME="${run_tmp}/codex-home" \
    CC_PETS_APPLICATIONS_DIR="${SHIM_TMP}/Applications" \
    zsh -c "${invocation} --version" > "${run_tmp}/out.txt" 2>&1 &
  shim_pid=$!
  for _ in {1..100}; do
    kill -0 "${shim_pid}" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "${shim_pid}" 2>/dev/null; then
    kill -9 "${shim_pid}" 2>/dev/null || true
    print -u2 "${invocation} 卡住了：shim 很可能在 exec 自己，未跳过 PATH 里的 shim"
    exit 1
  fi
  wait "${shim_pid}"
  if [[ "$(<"${run_tmp}/out.txt")" != "${expected} --version" ]]; then
    print -u2 "${invocation} 应该经 shim 转到真二进制并输出 '${expected} --version'，实际是 '$(<"${run_tmp}/out.txt")'"
    exit 1
  fi
  client_files=("${run_tmp}"/cc-pets-$(id -u)-clients/*(N))
  if (( ${#client_files[@]} != 1 )); then
    print -u2 "${invocation} 没有走包装脚本：应写出 1 个客户端 pid 文件，实际 ${#client_files[@]} 个"
    exit 1
  fi
done
# CLAUDE_REAL_BIN / CODEX_REAL_BIN 指定的路径优先，不受 shim 过滤影响。
grep -Fq 'REAL_CLAUDE="${CLAUDE_REAL_BIN:-}"' "${PROJECT_DIR}/bin/claude-with-pet"
grep -Fq 'REAL_CODEX="${CODEX_REAL_BIN:-}"' "${PROJECT_DIR}/bin/codex-with-pet"
if grep -q 'whence -p claude' "${PROJECT_DIR}/bin/claude-with-pet" || \
   grep -q 'whence -p codex' "${PROJECT_DIR}/bin/codex-with-pet"; then
  print -u2 "包装脚本仍在用 whence -p，会先命中 PATH 里的 shim 自己"
  exit 1
fi
print "任意大小写调用经 shim 启动桌宠测试通过"

grep -q 'hideAgentStatusIfClientGone' "${PET_SOURCES[@]}"
grep -q 'liveClientProviders' "${PET_SOURCES[@]}"
# 空 pid 文件是 1.0.2 及更早版本留下的，身份不明；只要还有一个就不许清场，
# 否则升级后仍在运行的老客户端会被误判成已退出。
grep -q 'hasUnlabeledClient' "${PET_SOURCES[@]}"
# 不经包装脚本启动的客户端（直接跑 claude / codex）没有 pid 文件，
# 只能靠“最近还在发事件”证明自己活着，所以必须留静默宽限。
grep -q 'AgentStatusOrphanInterval' "${PET_SOURCES[@]}"
if ! grep -q 'lastStatusTimestamp < AgentStatusOrphanInterval' "${PET_SOURCES[@]}"; then
  print -u2 "清场缺少静默宽限，会误清掉未经包装脚本启动的活跃会话"
  exit 1
fi
grep -q 'self.lastStatusProvider = provider' "${PET_SOURCES[@]}"
print "客户端退出后状态气泡清场测试通过"

AGENT_STATUS_TMP="$(mktemp -d /tmp/cc-pets-agent-status-test.XXXXXX)"
clang -fobjc-arc -mmacosx-version-min=13.0 \
  -I"${PROJECT_DIR}/Sources/CCPets" \
  -framework Foundation -framework AppKit \
  "${PROJECT_DIR}/Sources/CCPets/CCPetsPaths.m" \
  "${PROJECT_DIR}/Sources/CCPets/CCPetsEvents.m" \
  "${PROJECT_DIR}/Sources/CCPets/CCPetsTerminalFocus.m" \
  "${PROJECT_DIR}/tests/agent-status-harness.m" \
  -o "${AGENT_STATUS_TMP}/agent-status-test"
"${AGENT_STATUS_TMP}/agent-status-test"
# 终态只能被新一轮真实动作解除，尾巴事件不许改写气泡。
grep -q 'isTrailingRecord' "${PET_SOURCES[@]}"
# "正在启动"超过宽限没有后续事件就落到"待机中"，否则启动态和空闲态长得一模一样。
grep -q 'AgentStartingGraceInterval' "${PET_SOURCES[@]}"
grep -q 'enterIdleStatus' "${PET_SOURCES[@]}"
print "Agent 状态气泡终态保持与待机降级测试通过"

UPDATE_RETRY_TMP="$(mktemp -d /tmp/cc-pets-update-retry-test.XXXXXX)"
clang -fobjc-arc -mmacosx-version-min=13.0 \
  -I"${PROJECT_DIR}/Sources/CCPets" \
  -framework Foundation \
  "${PROJECT_DIR}/Sources/CCPets/CCPetsVersion.m" \
  "${PROJECT_DIR}/tests/update-retry-harness.m" \
  -o "${UPDATE_RETRY_TMP}/update-retry-test"
"${UPDATE_RETRY_TMP}/update-retry-test"
# 暂时性故障要自动重试一次，且重试必须换缓存目录——ETARGET 的成因就是本机缓存里的
# 包元数据还没有这个版本，--prefer-online 命中 304 时依然拿到旧元数据。
grep -q 'UpdateFailureIsTransient' "${PET_SOURCES[@]}"
grep -q 'UpdateRetryDelay' "${PET_SOURCES[@]}"
grep -q 'update-retry-cache' "${PET_SOURCES[@]}"
print "自动更新暂时性故障重试测试通过"

# 这条断言本身失灵是最坏的情况：它会一路绿灯，直到某天真的把用户桌宠打回“正在启动”。
# 先用一个隔离目录验证“写入端确实打了标记、检测确实数得出来”，再去看真实事件流。
LEAK_SELFTEST_TMP="$(mktemp -d /tmp/cc-pets-leak-selftest.XXXXXX)"
LEAK_SELFTEST_LOG="${LEAK_SELFTEST_TMP}/cc-pets-$(id -u)-agent-events.ndjson"
print -n '{"schemaVersion":1,"provider":"Claude","state":"tool","tool":"shell"}' | \
  CC_PETS_STATE_DIR="${LEAK_SELFTEST_TMP}" "${PROJECT_DIR}/.build/release/cc-pets" --provider-event
LEAK_SELFTEST_SIZE="$(wc -c < "${LEAK_SELFTEST_LOG}")"
if [[ "$(marked_event_count "${LEAK_SELFTEST_LOG}" 0)" != "1" ]]; then
  print -u2 "污染检测失灵：测试写出的事件没有带上 ${CC_PETS_TEST_MARK} 标记"
  exit 1
fi
if [[ "$(marked_event_count "${LEAK_SELFTEST_LOG}" "${LEAK_SELFTEST_SIZE}")" != "0" ]]; then
  print -u2 "污染检测失灵：基线偏移之前的记录不应计入"
  exit 1
fi
print "事件流污染检测自检测试通过"

LIVE_EVENT_LEAK="$(marked_event_count "${LIVE_EVENT_LOG}" "${LIVE_EVENT_BASELINE}")"
if (( LIVE_EVENT_LEAK > 0 )); then
  print -u2 "测试污染了用户真实的事件流 ${LIVE_EVENT_LOG}（新增 ${LIVE_EVENT_LEAK} 条带 ${CC_PETS_TEST_MARK} 标记的记录）"
  print -u2 "跑包装脚本或 hook 的用例必须显式设置 CC_PETS_STATE_DIR；TMPDIR 隔离不了事件文件。"
  exit 1
fi
print "测试不污染真实事件流测试通过"

if [[ "$(live_shim_snapshot)" != "${LIVE_SHIM_BASELINE}" ]]; then
  print -u2 "测试动了用户真实的 shim 目录 ${LIVE_SHIM_DIR}："
  print -u2 "跑卸载逻辑的用例必须显式设置 CC_PETS_SHIM_DIR；未设时会回退到真实目录并删除软链。"
  exit 1
fi
print "测试不污染真实 shim 目录测试通过"
