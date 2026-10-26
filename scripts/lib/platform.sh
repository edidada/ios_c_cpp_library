#!/usr/bin/env bash
# 平台入口公共实现：scripts/mac/build.sh 调用 platform_build。
# iOS 目标只能由 macOS + Xcode 构建，因此这里只有一个宿主入口。
# shellcheck shell=bash

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

platform_usage() {
    cat <<'EOF'
用法: scripts/mac/build.sh [选项]

说明:
  在 macOS 宿主机上使用 Xcode 工具链编译 iOS 库。
  默认编译 manifest 中 presets.core 的常用库，目标为 iOS 设备 + 模拟器切片。

选项:
  --libs LIST           core（默认）/ all / 逗号分隔的库名或 preset
  --backends LIST       all（默认）/ xmake / conan / xmake,conan
  --slices LIST         逗号分隔的切片，默认取清单 defaults.slices
  --ios-version X.Y     iOS deployment target，默认取清单 defaults.iosMinVersion
  --build-type TYPE     Release（默认）/ Debug / RelWithDebInfo / MinSizeRel
  --experimental MODE   all（默认）/ stable / only
  --xcode PATH          指定 Xcode Developer 目录
  --jobs N              并行编译任务数
  --out DIR             产物目录，默认 dist/
  --clean               构建前删除 dist/ 与 build/
  --fail-fast           任一库失败后立即停止
  --no-header-check     探针不 include 头文件
  --skip-setup          跳过 xmake/Conan/profile 初始化
  -h, --help            显示帮助
EOF
}

platform_build() {
    local platform="$1"
    shift

    local libs="core"
    local backends="all"
    local slices=""
    local ios_version=""
    local build_type=""
    local experimental="all"
    local xcode_dir=""
    local jobs=""
    local out=""
    local clean=0
    local fail_fast=0
    local header_check=1
    local skip_setup=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --libs) [ $# -ge 2 ] || die "--libs 需要一个参数"; libs="$2"; shift 2 ;;
            --backends) [ $# -ge 2 ] || die "--backends 需要一个参数"; backends="$2"; shift 2 ;;
            --slices) [ $# -ge 2 ] || die "--slices 需要一个参数"; slices="$2"; shift 2 ;;
            --ios-version) [ $# -ge 2 ] || die "--ios-version 需要一个参数"; ios_version="$2"; shift 2 ;;
            --build-type) [ $# -ge 2 ] || die "--build-type 需要一个参数"; build_type="$2"; shift 2 ;;
            --experimental) [ $# -ge 2 ] || die "--experimental 需要一个参数"; experimental="$2"; shift 2 ;;
            --xcode) [ $# -ge 2 ] || die "--xcode 需要一个参数"; xcode_dir="$2"; shift 2 ;;
            --jobs) [ $# -ge 2 ] || die "--jobs 需要一个参数"; jobs="$2"; shift 2 ;;
            --out) [ $# -ge 2 ] || die "--out 需要一个参数"; out="$2"; shift 2 ;;
            --clean) clean=1; shift ;;
            --fail-fast) fail_fast=1; shift ;;
            --no-header-check) header_check=0; shift ;;
            --skip-setup) skip_setup=1; shift ;;
            -h | --help) platform_usage; exit 0 ;;
            *) die "未知参数: $1（使用 --help 查看用法）" ;;
        esac
    done

    [ "$platform" = "mac" ] || die "未知平台: $platform"
    require_macos

    [ -n "$slices" ] || slices="$(manifest_default slices)"
    [ -n "$ios_version" ] || ios_version="$(manifest_default iosMinVersion)"
    [ -n "$build_type" ] || build_type="$(manifest_default buildType)"

    log "宿主平台: macOS ($(sw_vers -productVersion 2>/dev/null || echo unknown))"
    log "目标平台: iOS"
    log "库: $libs"
    log "后端: $backends"
    log "切片: $slices"
    log "iOS deployment target: $ios_version"

    # 如果工具已安装在默认目录，先加入 PATH，方便 setup 复用。
    add_toolchain_paths

    if [ "$skip_setup" -eq 0 ]; then
        local -a setup_args=(--backends "$backends" --slices "$slices" --ios-version "$ios_version")
        if [ -n "$xcode_dir" ]; then
            setup_args+=(--xcode "$xcode_dir")
        fi
        if [ -n "$build_type" ]; then
            setup_args+=(--build-type "$build_type")
        fi
        log "初始化 xmake / Conan 2 / iOS SDK 环境..."
        bash "$REPO_ROOT/scripts/setup.sh" "${setup_args[@]}"
    fi

    # setup.sh 在子进程中运行，重新把安装目录加入当前 PATH。
    add_toolchain_paths

    local -a build_args=(
        --libs "$libs"
        --backends "$backends"
        --slices "$slices"
        --ios-version "$ios_version"
        --experimental "$experimental"
    )
    if [ -n "$xcode_dir" ]; then
        build_args+=(--xcode "$xcode_dir")
    fi
    if [ -n "$build_type" ]; then
        build_args+=(--build-type "$build_type")
    fi
    if [ -n "$jobs" ]; then
        build_args+=(--jobs "$jobs")
    fi
    if [ -n "$out" ]; then
        build_args+=(--out "$out")
    fi
    if [ "$clean" -eq 1 ]; then
        build_args+=(--clean)
    fi
    if [ "$fail_fast" -eq 1 ]; then
        build_args+=(--fail-fast)
    fi
    if [ "$header_check" -eq 0 ]; then
        build_args+=(--no-header-check)
    fi

    log "开始编译 iOS 库..."
    bash "$REPO_ROOT/scripts/build.sh" "${build_args[@]}"
}
