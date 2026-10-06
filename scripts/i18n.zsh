# zsh 脚本的多语言，和 scripts/i18n.mjs 共用 scripts/locales/<语言>.json 与同一套判定规则：
# CC_PETS_LANGUAGE → ~/.cc-pets/language（桌宠菜单里选的语言）→ LC_ALL / LC_MESSAGES / LANG → 英文。
#
#   print "$(cc_pets_t "Built: {path}" path="${BUILD_DIR}/cc-pets")"
#
# 第一个参数是英文原文（也是表的 key），必须是字面量，scripts/check-l10n.mjs 会把它和表对上；
# 变量一律走 {name} 占位，不能直接写进原文，否则 key 每次都不一样，永远查不到。
# 英文直接在 zsh 里替换占位符；其他语言交给 node 查表。没有 node（比如正在报"找不到 Node.js"）
# 时退回英文，总比什么都不说好。

typeset -g _CC_PETS_I18N_DIR="${${(%):-%x}:A:h}"

# 支持的语言：英文加上 locales 下的每个 <语言>.json。
_cc_pets_languages() {
  print -r -- en "${_CC_PETS_I18N_DIR}"/locales/*.json(N:t:r)
}

# 把 zh_CN.UTF-8、zh-Hans-CN 这类写法匹配到支持的语言上；匹配不上输出空。
_cc_pets_match_language() {
  local tag="${${1:l}//_/-}" language
  tag="${tag%%.*}"
  [[ -z "${tag}" || "${tag}" == c || "${tag}" == posix ]] && return 0
  local -a languages=(${=$(_cc_pets_languages)})
  for language in "${languages[@]}"; do
    if [[ "${tag}" == "${language:l}" || "${tag}" == "${language:l}"-* ]]; then
      print -r -- "${language}"
      return 0
    fi
  done
  for language in "${languages[@]}"; do
    if [[ "${tag%%-*}" == "${${language:l}%%-*}" ]]; then
      print -r -- "${language}"
      return 0
    fi
  done
}

cc_pets_language() {
  local match="" value name
  local language_file="${CC_PETS_HOME:-${HOME}/.cc-pets}/language"
  match="$(_cc_pets_match_language "${CC_PETS_LANGUAGE:-}")"
  if [[ -z "${match}" && -r "${language_file}" ]]; then
    value="$(<"${language_file}")"
    match="$(_cc_pets_match_language "${value}")"
  fi
  if [[ -z "${match}" ]]; then
    for name in LC_ALL LC_MESSAGES LANG; do
      match="$(_cc_pets_match_language "${(P)name:-}")"
      [[ -n "${match}" ]] && break
    done
  fi
  print -r -- "${match:-en}"
}

cc_pets_t() {
  local text="$1" pair language
  shift
  language="$(cc_pets_language)"
  if [[ "${language}" != en ]] && (( $+commands[node] )); then
    CC_PETS_LANGUAGE="${language}" node "${_CC_PETS_I18N_DIR}/i18n.mjs" "${text}" "$@" && return 0
  fi
  for pair in "$@"; do
    text="${text//"{${pair%%=*}}"/${pair#*=}}"
  done
  print -r -- "${text}"
}
