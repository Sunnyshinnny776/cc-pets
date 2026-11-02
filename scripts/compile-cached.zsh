# 内部构建助手：仅接受 build.sh / tests/test.sh 使用的 clang 编译并链接参数。
# 不缓存测试结果；缓存放在现有 clean 命令管理的 clang-cache 目录内。
# Mach-O 不能用 cp 原地覆盖：旧 inode 可能仍关联着内核缓存的签名信息。
# 同目录暂存、签名和校验完成后再 rename，让裸 CLI、App 和 harness 都拿到新 inode。
cc_pets_publish_binary() (
  emulate -L zsh
  set -eu
  local source_binary="$1" target_binary="$2"
  local publish_dir="$(mktemp -d "${target_binary:h}/.${target_binary:t}.publish.XXXXXX")"
  trap 'rm -rf -- "$publish_dir"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  local staged_binary="${publish_dir}/${target_binary:t}"
  cp -p "$source_binary" "$staged_binary"
  /usr/bin/codesign --force --sign - "$staged_binary" >/dev/null
  /usr/bin/codesign --verify --strict "$staged_binary"
  mv -f "$staged_binary" "$target_binary"
)

cc_pets_compile() (
  emulate -L zsh
  set -eu
  setopt PIPE_FAIL
  local started=$SECONDS
  local compiler="${commands[clang]:?clang not found}"
  local root="${PROJECT_DIR:?}"
  local cache="${root}/.build/clang-cache/cc-pets"
  local output='' arg source_file key object_file fingerprint sdk
  local -a compile_flags=() link_args=() sources=() object_keys=()
  # framework / library 参数只影响链接；这样不同 harness 能共用相同的目标文件。
  while (( $# )); do
    arg="$1"
    shift
    case "$arg" in
      -o) output="$1"; shift ;;
      -framework) link_args+=("$arg" "$1"); shift ;;
      -l*) link_args+=("$arg") ;;
      *.m) sources+=("$arg"); link_args+=("$arg") ;;
      *) compile_flags+=("$arg"); link_args+=("$arg") ;;
    esac
  done
  [[ -n "$output" && ${#sources} -gt 0 ]] || {
    print -u2 -- 'cc_pets_compile: expected .m inputs and -o output'
    return 1
  }
  if [[ "${CC_PETS_NO_BUILD_CACHE:-0}" == 1 ]]; then
    print -u2 -- '[compile] cache disabled'
    local uncached_work="$(mktemp -d "${output:h}/.${output:t}.compile.XXXXXX")"
    trap 'rm -rf -- "$uncached_work"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    "$compiler" "${link_args[@]}" -o "${uncached_work}/binary"
    cc_pets_publish_binary "${uncached_work}/binary" "$output"
    return
  fi
  print -u2 -- "[compile] ${output:t}: checking ${#sources} sources"

  # 内容摘要避免 checkout、复制或时间戳保留造成的误命中。头文件保守地整体失效，
  # 同时覆盖增删和重命名。工具链、SDK、架构、参数与编译环境变化也必须失效。
  sdk="$(xcrun --show-sdk-path)"
  local -a headers=("${root}"/Sources/CCPets/**/*.(h|inc|def)(N)
                    "${root}"/tests/**/*.(h|inc|def)(N))
  fingerprint="$(
    {
      print -r -- 'cc-pets-compile-cache-v1'
      print -r -- "$root" "$PWD" "$compiler" "$sdk"
      "$compiler" --version
      xcrun --show-sdk-version
      /usr/bin/sw_vers -buildVersion
      /usr/bin/uname -m
      # 只记录会影响编译/链接的环境；HOME、测试隔离目录不影响生成的代码。
      local name
      for name in DEVELOPER_DIR SDKROOT MACOSX_DEPLOYMENT_TARGET CPATH \
          C_INCLUDE_PATH OBJC_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH \
          COMPILER_PATH GCC_EXEC_PREFIX CCC_OVERRIDE_OPTIONS SOURCE_DATE_EPOCH \
          ZERO_AR_DATE RC_ARCHS; do
        print -r -- "$name=${(P)name-}"
      done
      /usr/bin/shasum -a 256 "${root}/scripts/compile-cached.zsh" "${headers[@]}"
      [[ ! -f "${sdk}/SDKSettings.json" ]] || /usr/bin/shasum -a 256 "${sdk}/SDKSettings.json"
    } | /usr/bin/shasum -a 256
  )"
  mkdir -p "${cache}/objects" "${cache}/binaries"
  local work="$(mktemp -d "${cache}/work.XXXXXX")"
  # 只删除本次调用创建的工作目录；失败和中断不会留下可命中的半成品。
  trap 'rm -rf -- "$work"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  local flags_key="$(print -rn -- "${(pj:\0:)compile_flags}" | /usr/bin/shasum -a 256)"
  local built=0 reused=0 index=0
  typeset -A objects=()
  for source_file in "${sources[@]}"; do
    key="$(
      { print -r -- "$fingerprint" "$flags_key" "$source_file"
        /usr/bin/shasum -a 256 "$source_file"
      } | /usr/bin/shasum -a 256
    )"
    key="${key%% *}"
    object_file="${cache}/objects/${key}.o"
    if [[ ! -f "$object_file" ]]; then
      print -u2 -- "[compile] ${output:t}: ${source_file:t}"
      "$compiler" "${compile_flags[@]}" -c "$source_file" -o "${work}/object.o"
      mv -f "${work}/object.o" "$object_file"
      (( ++built ))
    else
      (( ++reused ))
    fi
    objects[$source_file]="$object_file"
    object_keys+=("$key")
  done
  for (( index=1; index<=${#link_args}; ++index )); do
    arg="${link_args[$index]}"
    if (( ${+objects[$arg]} )); then
      link_args[$index]="${objects[$arg]}"
    fi
  done
  key="$(
    { print -r -- "$fingerprint"
      print -rn -- "${(pj:\0:)link_args}" "${(pj:\0:)object_keys}"
    } | /usr/bin/shasum -a 256
  )"
  local binary="${cache}/binaries/${key%% *}"
  local linked='cached'
  if [[ ! -x "$binary" ]]; then
    print -u2 -- "[compile] ${output:t}: linking"
    "$compiler" "${link_args[@]}" -o "${work}/binary"
    mv -f "${work}/binary" "$binary"
    linked='linked'
  fi
  # 不改动缓存原件，也不原地覆盖可能正在被 Hook / CLI 使用的可执行文件。
  cc_pets_publish_binary "$binary" "$output"
  print -u2 -- "[compile] ${output:t}: compiled=${built}, reused=${reused}, ${linked}, $(( SECONDS - started ))s"
)
