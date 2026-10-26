#!/usr/bin/env bash
# 公共函数库：路径、日志、Xcode/SDK 解析、iOS 切片映射等。
# 该文件只应被 source，不直接执行。
# shellcheck shell=bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="${MANIFEST:-$REPO_ROOT/libraries/manifest.json}"
MANIFEST_TOOL="$REPO_ROOT/scripts/lib/manifest.py"
PYTHON="${PYTHON:-python3}"
export PYTHONUTF8=1

log() {
    printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"
}

warn() {
    printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2
}

err() {
    printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2
}

die() {
    err "$*"
    exit 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

# 去掉 xmake 等工具输出中的 ANSI 颜色控制符，避免污染 CI summary。
strip_ansi() {
    sed -E 's/\x1b\[[0-9;]*[[:alpha:]]//g'
}

require_file() {
    [ -f "$1" ] || die "缺少文件: $1"
}

require_dir() {
    [ -d "$1" ] || die "缺少目录: $1"
}

require_python() {
    if ! have "$PYTHON"; then
        if have python3; then
            PYTHON="python3"
        elif have python; then
            PYTHON="python"
        else
            die "需要 Python 3（找不到 python3/python）"
        fi
    fi
    "$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' \
        || die "需要 Python >= 3.8"
}

manifest() {
    require_python
    "$PYTHON" "$MANIFEST_TOOL" --manifest "$MANIFEST" "$@"
}

manifest_default() {
    manifest defaults --field "$1"
}

# iOS 二进制只能由 Xcode 工具链生成，因此宿主必须是 macOS。
require_macos() {
    [ "$(uname -s)" = "Darwin" ] \
        || die "iOS 构建需要 macOS + Xcode（当前宿主: $(uname -s)）"
}

normalize_path() {
    printf '%s' "${1//\\//}"
}

xcode_developer_dir() {
    if [ -n "${DEVELOPER_DIR:-}" ] && [ -d "$DEVELOPER_DIR" ]; then
        printf '%s\n' "$(normalize_path "$DEVELOPER_DIR")"
        return 0
    fi
    if [ -x /usr/bin/xcode-select ]; then
        xcode-select -p 2>/dev/null || true
    fi
}

require_xcode() {
    require_macos
    local dev_dir
    dev_dir="$(xcode_developer_dir)"
    [ -n "$dev_dir" ] && [ -d "$dev_dir" ] \
        || die "未找到 Xcode，请安装 Xcode 并运行 sudo xcode-select -s /Applications/Xcode.app"
    export DEVELOPER_DIR="$dev_dir"
}

xcode_sdk_version() {
    local sdk="$1"
    xcrun --sdk "$sdk" --show-sdk-version 2>/dev/null | head -n 1
}

xcode_sdk_path() {
    local sdk="$1"
    xcrun --sdk "$sdk" --show-sdk-path 2>/dev/null | head -n 1
}

# 返回 Apple clang 版本，例如 17.0.0。
xcode_apple_clang_version() {
    xcrun --sdk iphoneos clang --version 2>/dev/null \
        | sed -n '1s/.*[Cc]lang version \([0-9][0-9.]*\).*/\1/p' \
        | head -n 1
}

xcode_apple_clang_major() {
    xcode_apple_clang_version | cut -d. -f1
}

# ------------------------------------------------------------------ slices
# 切片命名: <sdk>-<arch>，例如 iphoneos-arm64 / iphonesimulator-x86_64。

valid_slice() {
    case "$1" in
        iphoneos-arm64 | iphonesimulator-arm64 | iphonesimulator-x86_64) return 0 ;;
        *) return 1 ;;
    esac
}

slice_sdk() {
    case "$1" in
        iphoneos-*) echo "iphoneos" ;;
        iphonesimulator-*) echo "iphonesimulator" ;;
        *) die "未知 iOS 切片: $1" ;;
    esac
}

slice_arch() {
    case "$1" in
        iphoneos-arm64 | iphonesimulator-arm64) echo "arm64" ;;
        iphonesimulator-x86_64) echo "x86_64" ;;
        *) die "未知 iOS 切片: $1" ;;
    esac
}

slice_is_device() {
    [ "$(slice_sdk "$1")" = "iphoneos" ]
}

# xmake 使用 -p iphoneos + --appledev=<iphone|simulator>。
slice_xmake_appledev() {
    if slice_is_device "$1"; then
        echo "iphone"
    else
        echo "simulator"
    fi
}

# Conan 2 的 arch 名称。
slice_conan_arch() {
    case "$(slice_arch "$1")" in
        arm64) echo "armv8" ;;
        x86_64) echo "x86_64" ;;
        *) die "Conan 不支持的切片: $1" ;;
    esac
}

conan_profile_name() {
    printf 'ios-%s\n' "$1"
}

conan_home() {
    if [ -n "${CONAN_HOME:-}" ]; then
        printf '%s\n' "$CONAN_HOME"
    else
        printf '%s\n' "${HOME}/.conan2"
    fi
}

# 取两个 iOS 版本中较大的一个，例如 max_ios_version 13.0 14.0 -> 14.0。
max_ios_version() {
    printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1
}

split_csv() {
    # 输出换行分隔，去掉空白与空项
    printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d'
}

append_path_if_dir() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    case ":${PATH}:" in
        *":${dir}:"*) ;;
        *) export PATH="${dir}:${PATH}" ;;
    esac
    if [ -n "${GITHUB_PATH:-}" ]; then
        printf '%s\n' "$dir" >>"$GITHUB_PATH"
    fi
}

# setup.sh 作为子进程运行时，其 PATH 修改不会自动传给父进程。
# 构建脚本与平台入口调用该函数，把已知的工具链目录加入当前 PATH。
add_toolchain_paths() {
    append_path_if_dir "$HOME/.local/bin"
    append_path_if_dir "$HOME/xmake"

    local venv="${CONAN_VENV:-$HOME/.local/share/ios-c-cpp-library/conan-venv}"
    append_path_if_dir "$venv/bin"

    hash -r 2>/dev/null || true
}

# 在 GitHub Actions 中把 Markdown 追加到当前 job 的 summary。
append_github_summary() {
    local file="$1"
    [ -f "$file" ] || return 0
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        cat "$file" >>"$GITHUB_STEP_SUMMARY"
    fi
}

# 让 tee 保留管道中命令的退出码。
run_logged() {
    local log_file="$1"
    shift
    mkdir -p "$(dirname "$log_file")"
    if "$@" 2>&1 | tee -a "$log_file"; then
        return 0
    fi
    return 1
}

# 打印日志尾部，便于 CI 快速定位失败原因。
print_log_tail() {
    local log_file="$1"
    local lines="${2:-40}"
    [ -f "$log_file" ] || return 0
    err "最近 ${lines} 行日志（${log_file}）："
    tail -n "$lines" "$log_file" >&2 || true
}
