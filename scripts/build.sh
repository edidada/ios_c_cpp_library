#!/usr/bin/env bash
# 为 iOS 编译清单中的 C/C++ 库（xmake 与 Conan 2 两种后端）。
#
# 设备切片: iphoneos-arm64
# 模拟器切片: iphonesimulator-arm64、iphonesimulator-x86_64
#
# 示例:
#   scripts/build.sh                                              # 全部库 × 默认切片
#   scripts/build.sh --libs zlib,openssl --slices iphoneos-arm64
#   scripts/build.sh --backends conan --libs all
#   scripts/build.sh --libs ffmpeg --fail-fast
#
# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
    cat <<'EOF'
用法: scripts/build.sh [选项]

选项:
  --libs LIST           all（默认）、core 或逗号分隔的库名 / preset
  --backends LIST       all（默认）/ xmake / conan / xmake,conan
  --slices LIST         逗号分隔的切片，默认取清单 defaults.slices
                        可选: iphoneos-arm64, iphonesimulator-arm64, iphonesimulator-x86_64
  --ios-version X.Y     iOS deployment target，默认取清单 defaults.iosMinVersion
  --build-type TYPE     Release（默认）/ Debug / RelWithDebInfo / MinSizeRel
  --experimental MODE   all（默认）/ stable（排除实验库）/ only（仅实验库）
  --xcode PATH          指定 Xcode Developer 目录
  --jobs N              并行编译任务数，默认 CPU 核数
  --out DIR             产物目录，默认 dist/
  --clean               构建前删除 dist/ 与 build/
  --fail-fast           任一库失败后立即停止
  --no-header-check     探针不 include 头文件（只验证包能编译）
  -h, --help            显示帮助

环境变量:
  DEVELOPER_DIR         Xcode Developer 目录
  DIST_DIR / WORK_DIR   自定义产物目录 / 临时构建目录
  GITHUB_STEP_SUMMARY   GitHub Actions 会追加构建摘要
EOF
}

libs="all"
backends="all"
slices=""
ios_version=""
build_type=""
experimental="all"
xcode_dir=""
jobs=""
dist_dir="${DIST_DIR:-$REPO_ROOT/dist}"
work_root="${WORK_DIR:-$REPO_ROOT/build}"
clean=0
fail_fast=0
header_check=1

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
        --out) [ $# -ge 2 ] || die "--out 需要一个参数"; dist_dir="$2"; shift 2 ;;
        --clean) clean=1; shift ;;
        --fail-fast) fail_fast=1; shift ;;
        --no-header-check) header_check=0; shift ;;
        -h | --help) usage; exit 0 ;;
        *) die "未知参数: $1（使用 --help 查看用法）" ;;
    esac
done

require_file "$MANIFEST"
require_python
require_macos
manifest validate >/dev/null

if [ -n "$xcode_dir" ]; then
    [ -d "$xcode_dir" ] || die "--xcode 目录不存在: $xcode_dir"
    export DEVELOPER_DIR="$(normalize_path "$xcode_dir")"
fi
require_xcode

# 兼容 setup.sh 在子进程安装工具后 PATH 未传递到当前 shell 的情况。
add_toolchain_paths

case "$dist_dir" in
    /*) ;;
    *) dist_dir="$REPO_ROOT/$dist_dir" ;;
esac
case "$work_root" in
    /*) ;;
    *) work_root="$REPO_ROOT/$work_root" ;;
esac

[ -n "$slices" ] || slices="$(manifest_default slices)"
[ -n "$ios_version" ] || ios_version="$(manifest_default iosMinVersion)"
[ -n "$build_type" ] || build_type="$(manifest_default buildType)"
[ -n "$jobs" ] || jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"

for target_slice in $(split_csv "$slices"); do
    valid_slice "$target_slice" || die "非法切片: $target_slice"
done
case "$build_type" in
    Release | Debug | RelWithDebInfo | MinSizeRel) ;;
    *) die "--build-type 非法: $build_type" ;;
esac
case "$ios_version" in
    '' | *[!0-9.]*) die "--ios-version 必须是形如 13.0 的版本号: $ios_version" ;;
esac

if [ "$clean" -eq 1 ]; then
    log "清理: $dist_dir, $work_root"
    rm -rf "$dist_dir" "$work_root"
fi

mkdir -p "$dist_dir" "$work_root"

if printf '%s' "$backends" | tr ',' '\n' | grep -qx xmake || [ "$backends" = "all" ]; then
    have xmake || die "找不到 xmake，请先运行 scripts/setup.sh"
fi
if printf '%s' "$backends" | tr ',' '\n' | grep -qx conan || [ "$backends" = "all" ]; then
    have conan || die "找不到 conan，请先运行 scripts/setup.sh"
    for target_slice in $(split_csv "$slices"); do
        profile="$(conan_home)/profiles/$(conan_profile_name "$target_slice")"
        [ -f "$profile" ] || die "缺少 Conan profile: $profile
请先运行: scripts/setup.sh --slices $slices --ios-version $ios_version"
    done
fi

log "Xcode: $(xcodebuild -version 2>/dev/null | head -n 1)"
log "切片: $slices"
log "iOS deployment target: $ios_version"
log "构建类型: $build_type"
log "后端: $backends"
log "并行任务: $jobs"

log "待编译库列表:"
manifest list --format table --libs "$libs" --backends "$backends" --experimental "$experimental"

# ------------------------------------------------------------------ helpers

to_lua_value() {
    local value="$1"
    case "$value" in
        true | false) printf '%s' "$value" ;;
        nil) printf 'nil' ;;
        *)
            if [[ "$value" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
                printf '%s' "$value"
            else
                value="${value//\\/\\\\}"
                value="${value//\"/\\\"}"
                printf '"%s"' "$value"
            fi
            ;;
    esac
}

render_lua_configs() {
    local configs="$1"
    [ -n "$configs" ] || return 0
    local pair key value rendered="" sep=""
    local -a pairs
    IFS=';' read -r -a pairs <<<"$configs"
    for pair in "${pairs[@]}"; do
        [ -n "$pair" ] || continue
        key="${pair%%=*}"
        value="${pair#*=}"
        rendered+="${sep}${key} = $(to_lua_value "$value")"
        sep=", "
    done
    printf '%s' "$rendered"
}

xmake_mode() {
    case "$build_type" in
        Debug) echo "debug" ;;
        *) echo "release" ;;
    esac
}

write_probe_project() {
    local dir="$1"
    local xmake_pkg="$2"
    local xmake_version="$3"
    local xmake_configs="$4"
    local headers="$5"
    local defines="$6"
    local package_spec="$xmake_pkg"
    local lua_configs=""

    if [ -n "$xmake_version" ]; then
        package_spec="$xmake_pkg $xmake_version"
    fi
    if [ -n "$xmake_configs" ]; then
        lua_configs="$(render_lua_configs "$xmake_configs")"
        lua_configs=", {configs = {${lua_configs}}}"
    fi

    {
        printf 'add_rules("mode.release", "mode.debug")\n'
        printf 'add_requires("%s"%s)\n\n' "$package_spec" "$lua_configs"
        printf 'target("probe")\n'
        printf '    set_kind("static")\n'
        printf '    add_files("probe.cpp")\n'
        printf '    set_languages("c++17")\n'
        printf '    add_packages("%s")\n' "$xmake_pkg"
    } >"$dir/xmake.lua"

    {
        echo "// Generated by scripts/build.sh -- only used to verify the package."
        if [ -n "$defines" ]; then
            local define dname dvalue
            for define in $(split_csv "$defines"); do
                dname="${define%%=*}"
                dvalue=""
                case "$define" in
                    *=*) dvalue="${define#*=}" ;;
                esac
                echo "#ifndef $dname"
                if [ -n "$dvalue" ]; then
                    echo "#define $dname $dvalue"
                else
                    echo "#define $dname"
                fi
                echo "#endif"
            done
        fi
        if [ "$header_check" -eq 1 ] && [ -n "$headers" ]; then
            local header
            for header in $(split_csv "$headers"); do
                echo "#include <$header>"
            done
        fi
        echo "int ios_library_probe() { return 0; }"
    } >"$dir/probe.cpp"
}

build_with_xmake() {
    local name="$1" target_slice="$2" lib_ios="$3"
    local xmake_pkg="$4" xmake_version="$5" xmake_configs="$6"
    local headers="$7" defines="$8"
    local arch appledev work artifact log_file mode
    work="$work_root/$name/$target_slice/xmake"
    artifact="$dist_dir/$name/$target_slice/xmake"
    log_file="$dist_dir/$name/logs/$target_slice-xmake.log"

    arch="$(slice_arch "$target_slice")"
    appledev="$(slice_xmake_appledev "$target_slice")"
    mode="$(xmake_mode)"

    rm -rf "$work"
    mkdir -p "$work" "$artifact" "$(dirname "$log_file")"
    : >"$log_file"
    write_probe_project "$work" "$xmake_pkg" "$xmake_version" "$xmake_configs" "$headers" "$defines"

    log "[$name][$target_slice][xmake] 配置 (xmake 包: $xmake_pkg, $appledev/$arch, iOS $lib_ios)"
    if ! run_logged "$log_file" \
        xmake f -y -P "$work" -p iphoneos -a "$arch" -k static \
        --appledev="$appledev" --target_minver="$lib_ios" \
        -m "$mode" -o "$work/build"; then
        print_log_tail "$log_file"
        return 1
    fi

    log "[$name][$target_slice][xmake] 编译"
    if ! run_logged "$log_file" xmake -y -P "$work" -j "$jobs"; then
        print_log_tail "$log_file"
        return 1
    fi

    log "[$name][$target_slice][xmake] 导出产物"
    if ! run_logged "$log_file" \
        xmake require --export --packagedir="$artifact" -P "$work" "$xmake_pkg"; then
        print_log_tail "$log_file"
        return 1
    fi

    touch "$artifact/.ok"
    return 0
}

build_with_conan() {
    local name="$1" target_slice="$2" lib_ios="$3"
    local conan_ref="$4" conan_options="$5"
    local work="$work_root/$name/$target_slice/conan"
    local artifact="$dist_dir/$name/$target_slice/conan"
    local log_file="$dist_dir/$name/logs/$target_slice-conan.log"
    local profile
    local -a option_args=()

    profile="$(conan_profile_name "$target_slice")"
    rm -rf "$work"
    mkdir -p "$work" "$artifact" "$(dirname "$log_file")"
    : >"$log_file"

    if [ -n "$conan_options" ]; then
        local opt pkg_name="${conan_ref%%/*}"
        local -a options
        IFS=';' read -r -a options <<<"$conan_options"
        for opt in "${options[@]}"; do
            [ -n "$opt" ] || continue
            case "$opt" in
                *:*) ;;
                *) opt="$pkg_name:$opt" ;;
            esac
            option_args+=("-o" "$opt")
        done
    fi

    log "[$name][$target_slice][conan] 安装/编译 (引用: $conan_ref, iOS $lib_ios)"
    if ! run_logged "$log_file" \
        conan install --requires="$conan_ref" \
        -pr:h="$profile" -pr:b=default \
        -s:h "build_type=$build_type" \
        -s:h "os.version=$lib_ios" \
        -c:h "tools.build:jobs=$jobs" \
        ${option_args[@]+"${option_args[@]}"} \
        --build=missing \
        --deployer=full_deploy \
        --deployer-folder="$artifact" \
        -of "$work/out"; then
        print_log_tail "$log_file"
        return 1
    fi

    touch "$artifact/.ok"
    return 0
}

# ------------------------------------------------------------------ summary

write_summary() {
    local title="$1" status="$2"
    local summary_md="$dist_dir/$name/summary.md"
    local summary_tsv="$dist_dir/$name/summary.tsv"
    local xmake_version_text="n/a"
    local conan_version_text="n/a"

    if have xmake; then
        xmake_version_text="$(xmake --version 2>/dev/null | head -n 1 | strip_ansi)"
    fi
    if have conan; then
        conan_version_text="$(conan --version 2>/dev/null)"
    fi

    {
        echo "### iOS 构建: $name ($title)"
        echo
        echo "- 结果: $status"
        echo "- Xcode: \`$(xcodebuild -version 2>/dev/null | head -n 1)\`"
        echo "- 切片: \`$slices\`"
        echo "- iOS deployment target: ${ios_version}（单库最低要求会取最大值）"
        echo "- 构建类型: $build_type"
        echo "- xmake: ${xmake_version_text}"
        echo "- Conan: ${conan_version_text}"
        echo
        echo "| 切片 | 后端 | 状态 | 耗时 | 产物 |"
        echo "| --- | --- | --- | ---: | --- |"
        local row
        while IFS=$'\t' read -r _r_slice _r_backend _r_status _r_seconds _r_artifact _r_log; do
            local icon="✅"
            [ "$_r_status" = "ok" ] || icon="❌"
            echo "| $_r_slice | $_r_backend | $icon | ${_r_seconds}s | \`$_r_artifact\` |"
        done <"$summary_tsv"
    } >"$summary_md"

    cat "$summary_md"
    append_github_summary "$summary_md"
}

# ------------------------------------------------------------------ main loop

summary_tsv_root="$dist_dir/summary.tsv"
: >"$summary_tsv_root"

total=0
failed=0
skipped=0

while IFS=$'\x1f' read -r name title category is_experimental min_ios xmake_pkg xmake_version xmake_configs conan_ref conan_options headers defines lib_backends; do
    [ -n "$name" ] || continue

    lib_dir="$dist_dir/$name"
    mkdir -p "$lib_dir/logs"
    lib_summary="$lib_dir/summary.tsv"
    : >"$lib_summary"

    lib_ios="$(max_ios_version "$ios_version" "$min_ios")"

    log "================================================================"
    log "编译 $name ($title) | 切片: $slices | 最低 iOS: $lib_ios | 后端: $lib_backends"
    log "================================================================"

    lib_failed=0
    for target_slice in $(split_csv "$slices"); do
        for backend in $(split_csv "$lib_backends"); do
            total=$((total + 1))
            started="$(date +%s)"
            status="ok"

            case "$backend" in
                xmake)
                    [ -n "$xmake_pkg" ] || {
                        warn "$name 没有 xmake 包信息，跳过 $target_slice/xmake"
                        skipped=$((skipped + 1))
                        continue
                    }
                    if ! build_with_xmake "$name" "$target_slice" "$lib_ios" \
                        "$xmake_pkg" "$xmake_version" "$xmake_configs" "$headers" "$defines"; then
                        status="failed"
                    fi
                    artifact="$dist_dir/$name/$target_slice/xmake"
                    log_file="$dist_dir/$name/logs/$target_slice-xmake.log"
                    ;;
                conan)
                    [ -n "$conan_ref" ] || {
                        warn "$name 没有 Conan 引用，跳过 $target_slice/conan"
                        skipped=$((skipped + 1))
                        continue
                    }
                    if ! build_with_conan "$name" "$target_slice" "$lib_ios" "$conan_ref" "$conan_options"; then
                        status="failed"
                    fi
                    artifact="$dist_dir/$name/$target_slice/conan"
                    log_file="$dist_dir/$name/logs/$target_slice-conan.log"
                    ;;
                *)
                    warn "未知后端: $backend"
                    skipped=$((skipped + 1))
                    continue
                    ;;
            esac

            elapsed=$(($(date +%s) - started))
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$target_slice" "$backend" "$status" "$elapsed" "$artifact" "$log_file" >>"$lib_summary"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$name" "$target_slice" "$backend" "$status" "$elapsed" "$artifact" "$log_file" >>"$summary_tsv_root"

            if [ "$status" = "ok" ]; then
                log "[$name][$target_slice][$backend] 成功（${elapsed}s）"
            else
                err "[$name][$target_slice][$backend] 失败（${elapsed}s），日志: $log_file"
                lib_failed=1
                failed=$((failed + 1))
                if [ "$fail_fast" -eq 1 ]; then
                    break 3
                fi
            fi
        done
    done

    if [ "$lib_failed" -eq 0 ]; then
        write_summary "$name" "成功"
    else
        write_summary "$name" "失败（允许实验库失败时为 continue-on-error）"
    fi
done < <(manifest list --format tsv --libs "$libs" --backends "$backends" --experimental "$experimental")

# 汇总所有库。
overall_md="$dist_dir/summary.md"
{
    echo "## iOS C/C++ 库构建汇总"
    echo
    echo "- 总计: ${total}，失败: ${failed}，跳过: $skipped"
    echo "- 切片: \`$slices\`，iOS: ${ios_version}，构建类型: $build_type"
    echo
    echo "| 库 | 切片 | 后端 | 状态 | 耗时 | 日志 |"
    echo "| --- | --- | --- | --- | ---: | --- |"
    while IFS=$'\t' read -r r_name r_slice r_backend r_status r_seconds r_artifact r_log; do
        icon="✅"
        [ "$r_status" = "ok" ] || icon="❌"
        echo "| $r_name | $r_slice | $r_backend | $icon | ${r_seconds}s | \`$r_log\` |"
    done <"$summary_tsv_root"
} >"$overall_md"

log "构建汇总: $overall_md"
append_github_summary "$overall_md"

if [ "$failed" -gt 0 ]; then
    err "有 $failed 个构建任务失败"
    exit 1
fi

log "全部构建任务完成（共 $total 个）"
