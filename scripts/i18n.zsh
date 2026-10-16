# zsh 脚本的多语言，和 App 共用 Resources/<语言>.lproj/Localizable.strings：
#
#   print "$(cc_pets_t "Built: {path}" path="${BUILD_DIR}/cc-pets")"
#
# 第一个参数是英文原文（也是表的 key），必须是字面量，tests/check-l10n.mjs 会把它和表对上；
# 变量一律走 {name} 占位，不能直接写进原文，否则 key 每次都不一样，永远查不到。
# 查表和选语言交给原生程序（cc-pets --localize），规则与其他命令行输出一致：
# CC_PETS_LANGUAGE → ~/.cc-pets/language（桌宠菜单里选的语言）→ LC_ALL / LC_MESSAGES / LANG → 系统。
# 原生程序还没构建出来时（首次安装、构建失败）退回英文，总比什么都不说好。

typeset -g _CC_PETS_BINARY="${${(%):-%x}:A:h:h}/.build/release/cc-pets"

cc_pets_t() {
  local text="$1" pair
  shift
  if [[ -x "${_CC_PETS_BINARY}" ]]; then
    "${_CC_PETS_BINARY}" --localize "${text}" "$@" && return 0
  fi
  for pair in "$@"; do
    text="${text//"{${pair%%=*}}"/${pair#*=}}"
  done
  print -r -- "${text}"
}
