#!/usr/bin/env bash
# 在 macOS（GitHub Actions / 本地）安装并初始化 xmake + Conan 2 的 iOS 编译环境。
#
# 示例:
#   scripts/setup.sh
#   scripts/setup.sh --slices iphoneos-arm64
#   scripts/setup.sh --xcode /Applications/Xcode.app/Contents/Developer
#   scripts/setup.sh --backends xmake
#
# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
    cat <<'EOF'
用法: scripts/setup.sh [选项]

说明:
  仅支持 macOS + Xcode。安装 xmake / Conan 2，并为每个 iOS 切片生成 Conan host profile。

选项:
  --backends LIST        all（默认）/ xmake / conan / xmake,conan
  --slices LIST          逗号分隔的切片，默认取清单 defaults.slices
                         可选: iphoneos-arm64, iphonesimulator-arm64, iphonesimulator-x86_64
  --ios-version X.Y      iOS deployment target，默认取清单 defaults.iosMinVersion
  --build-type TYPE      Release（默认）/ Debug / RelWithDebInfo / MinSizeRel
  --xcode PATH           指定 Xcode Developer 目录（等价于 DEVELOPER_DIR）
  --conan-version VER    指定 Conan 版本，默认安装最新的 Conan 2.x
  --force                强制重新生成 Conan profile
  --skip-profiles        只安装工具，不生成 Conan profiles
  -h, --help             显示帮助

环境变量:
  DEVELOPER_DIR          Xcode Developer 目录
  CONAN_HOME             默认 ~/.conan2
  CONAN_VENV             未安装 Conan 2 时创建的虚拟环境路径
EOF
}

backends="all"
slices=""
ios_version=""
build_type=""
xcode_dir=""
conan_version=""
force=0
skip_profiles=0

while [ $# -gt 0 ]; do
    case "$1" in
        --backends) [ $# -ge 2 ] || die "--backends 需要一个参数"; backends="$2"; shift 2 ;;
        --slices) [ $# -ge 2 ] || die "--slices 需要一个参数"; slices="$2"; shift 2 ;;
        --ios-version) [ $# -ge 2 ] || die "--ios-version 需要一个参数"; ios_version="$2"; shift 2 ;;
        --build-type) [ $# -ge 2 ] || die "--build-type 需要一个参数"; build_type="$2"; shift 2 ;;
        --xcode) [ $# -ge 2 ] || die "--xcode 需要一个参数"; xcode_dir="$2"; shift 2 ;;
        --conan-version) [ $# -ge 2 ] || die "--conan-version 需要一个参数"; conan_version="$2"; shift 2 ;;
        --force) force=1; shift ;;
        --skip-profiles) skip_profiles=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) die "未知参数: $1（使用 --help 查看用法）" ;;
    esac
done

require_file "$MANIFEST"
require_python
require_macos

[ -n "$slices" ] || slices="$(manifest_default slices)"
[ -n "$ios_version" ] || ios_version="$(manifest_default iosMinVersion)"
[ -n "$build_type" ] || build_type="$(manifest_default buildType)"

for target_slice in $(split_csv "$slices"); do
    valid_slice "$target_slice" || die "非法切片: $target_slice"
done

case "$build_type" in
    Release | Debug | RelWithDebInfo | MinSizeRel) ;;
    *) die "--build-type 非法: $build_type" ;;
esac

want_xmake=0
want_conan=0
case "$backends" in
    all) want_xmake=1; want_conan=1 ;;
    xmake) want_xmake=1 ;;
    conan) want_conan=1 ;;
    *)
        if printf '%s' "$backends" | tr ',' '\n' | grep -qx xmake; then want_xmake=1; fi
        if printf '%s' "$backends" | tr ',' '\n' | grep -qx conan; then want_conan=1; fi
        [ "$want_xmake" -eq 1 ] || [ "$want_conan" -eq 1 ] \
            || die "--backends 非法: ${backends}（可选 all, xmake, conan, xmake,conan）"
        ;;
esac

# ---------------------------------------------------------------- xmake

install_xmake() {
    if have xmake; then
        log "xmake 已安装: $(xmake --version 2>/dev/null | head -n 1 | strip_ansi)"
        return 0
    fi

    have curl || die "安装 xmake 需要 curl"
    log "安装 xmake（官方安装脚本）..."
    local script
    script="$(mktemp)"
    curl -fsSL https://xmake.io/shget.text -o "$script" || die "下载 xmake 安装脚本失败"
    # shellcheck disable=SC1090
    bash "$script" || die "xmake 安装失败"
    rm -f "$script"

    append_path_if_dir "$HOME/.local/bin"
    hash -r
    have xmake || die "xmake 安装后仍找不到命令，请检查 \$HOME/.local/bin 是否在 PATH 中"
    log "xmake 安装完成: $(xmake --version 2>/dev/null | head -n 1 | strip_ansi)"
}

# ---------------------------------------------------------------- Conan 2

install_conan() {
    if have conan && conan --version 2>/dev/null | grep -q '^Conan version 2\.'; then
        log "Conan 已安装: $(conan --version 2>/dev/null)"
        return 0
    fi

    have "$PYTHON" || die "安装 Conan 需要 Python 3"
    local venv="${CONAN_VENV:-$HOME/.local/share/ios-c-cpp-library/conan-venv}"
    local venv_bin="$venv/bin"
    local venv_python="$venv/bin/python"
    local spec="conan>=2,<3"
    [ -n "$conan_version" ] && spec="conan==$conan_version"

    log "在虚拟环境中安装 Conan 2: $venv"
    "$PYTHON" -m venv "$venv" || die "创建 Python venv 失败: $venv"
    "$venv_python" -m pip install --upgrade pip >/dev/null
    "$venv_python" -m pip install --upgrade "$spec" || die "安装 $spec 失败"

    append_path_if_dir "$venv_bin"
    hash -r
    have conan || die "Conan 安装后仍找不到命令"
    conan --version 2>/dev/null | grep -q '^Conan version 2\.' \
        || die "当前 Conan 不是 2.x，请检查 PATH 中是否有旧版 conan"
    log "Conan 安装完成: $(conan --version 2>/dev/null)"
}

ensure_conan_remote() {
    if ! conan remote list 2>/dev/null | grep -q '^conancenter'; then
        log "添加 ConanCenter remote..."
        conan remote add conancenter https://center2.conan.io --force
    fi
}

ensure_conan_default_profile() {
    if ! conan profile show -pr:b=default >/dev/null 2>&1; then
        log "生成 Conan 默认 build profile..."
        conan profile detect --force
    fi
}

# ---------------------------------------------------------------- profiles

write_conan_profile() {
    local target_slice="$1"
    local compiler_version="$2"
    local sdk="$3"
    local sdk_version="$4"
    local include_sdk_version="$5"
    local profile_dir
    profile_dir="$(conan_home)/profiles"
    mkdir -p "$profile_dir"

    {
        echo "# Generated by scripts/setup.sh -- do not edit manually."
        echo "[settings]"
        echo "os=iOS"
        echo "arch=$(slice_conan_arch "$target_slice")"
        echo "compiler=apple-clang"
        echo "compiler.version=${compiler_version}"
        echo "compiler.libcxx=libc++"
        echo "compiler.cppstd=17"
        echo "build_type=${build_type}"
        echo "os.version=${ios_version}"
        echo "os.sdk=${sdk}"
        if [ "$include_sdk_version" -eq 1 ] && [ -n "$sdk_version" ]; then
            echo "os.sdk_version=${sdk_version}"
        fi
    } >"$profile_dir/$(conan_profile_name "$target_slice")"
}

generate_conan_profiles() {
    local clang_major
    clang_major="$(xcode_apple_clang_major)"
    [ -n "$clang_major" ] || die "无法识别 Xcode Apple clang 版本"
    log "Apple clang 主版本: $clang_major"

    local target_slice sdk sdk_version
    for target_slice in $(split_csv "$slices"); do
        local profile
        profile="$(conan_profile_name "$target_slice")"

        if [ "$force" -eq 0 ] && [ -f "$(conan_home)/profiles/$profile" ]; then
            log "Conan profile 已存在: ${profile}（--force 可覆盖）"
            continue
        fi

        sdk="$(slice_sdk "$target_slice")"
        sdk_version="$(xcode_sdk_version "$sdk")"
        [ -n "$sdk_version" ] || die "无法读取 $sdk SDK 版本"

        # 部分 Xcode SDK 版本尚未写入 Conan settings.yml，先尝试带 sdk_version，
        # 再退化为不指定 sdk_version；compiler.version 同样逐级回退。
        local version include_sdk_version sdk_ok
        version="$clang_major"
        include_sdk_version=1
        sdk_ok=0
        while [ "$version" -ge 13 ]; do
            write_conan_profile "$target_slice" "$version" "$sdk" "$sdk_version" "$include_sdk_version"
            if conan profile show -pr:h="$profile" >/dev/null 2>&1; then
                sdk_ok=1
                break
            fi
            if [ "$include_sdk_version" -eq 1 ]; then
                # 先尝试去掉 os.sdk_version，保留当前 compiler.version。
                include_sdk_version=0
                write_conan_profile "$target_slice" "$version" "$sdk" "$sdk_version" "$include_sdk_version"
                if conan profile show -pr:h="$profile" >/dev/null 2>&1; then
                    sdk_ok=1
                    break
                fi
                include_sdk_version=1
            fi
            warn "Conan settings 不支持 apple-clang ${version} 或 SDK ${sdk_version}，尝试 $((version - 1))"
            version=$((version - 1))
        done

        [ "$sdk_ok" -eq 1 ] \
            || die "无法为切片 $target_slice 生成 Conan profile（Apple clang ${clang_major}, SDK ${sdk_version}）"

        log "生成 Conan profile: ${profile}（apple-clang ${version}, ${sdk} ${sdk_version}, iOS ${ios_version}）"
    done
}

# ---------------------------------------------------------------- main

log "仓库根目录: $REPO_ROOT"
log "目标切片: $slices"
log "iOS deployment target: $ios_version"
log "构建类型: $build_type"

if [ "$want_xmake" -eq 1 ]; then
    install_xmake
fi
if [ "$want_conan" -eq 1 ]; then
    install_conan
fi

if [ "$skip_profiles" -eq 0 ]; then
    if [ -n "$xcode_dir" ]; then
        [ -d "$xcode_dir" ] || die "--xcode 目录不存在: $xcode_dir"
        export DEVELOPER_DIR="$(normalize_path "$xcode_dir")"
    fi

    require_xcode
    log "Xcode: $(xcodebuild -version 2>/dev/null | head -n 1)"

    for target_slice in $(split_csv "$slices"); do
        sdk="$(slice_sdk "$target_slice")"
        sdk_path="$(xcode_sdk_path "$sdk")"
        sdk_version="$(xcode_sdk_version "$sdk")"
        [ -n "$sdk_path" ] && [ -d "$sdk_path" ] || die "找不到 $sdk SDK，请检查 Xcode 安装"
        log "SDK $sdk: $sdk_version ($sdk_path)"
    done

    if [ "$want_conan" -eq 1 ]; then
        ensure_conan_remote
        ensure_conan_default_profile
        export_local_recipes
        generate_conan_profiles
    fi
fi

log "环境准备完成"
if have xmake; then
    log "  xmake: $(xmake --version 2>/dev/null | head -n 1 | strip_ansi)"
fi
if have conan; then
    log "  conan: $(conan --version 2>/dev/null)"
fi
if [ -n "${DEVELOPER_DIR:-}" ]; then
    log "  Xcode: $DEVELOPER_DIR"
fi
