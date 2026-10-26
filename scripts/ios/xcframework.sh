#!/usr/bin/env bash
# 把设备与模拟器切片合并为 xcframework。
#
# 输入来自 scripts/build.sh 的产物:
#   dist/<库>/iphoneos-arm64/<后端>/
#   dist/<库>/iphonesimulator-arm64/<后端>/
#   dist/<库>/iphonesimulator-x86_64/<后端>/
#
# 输出:
#   dist/<库>/xcframework/<后端>/<静态库名>.xcframework
#
# 示例:
#   scripts/ios/xcframework.sh
#   scripts/ios/xcframework.sh --libs zlib,openssl --backends conan
#
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

usage() {
    cat <<'EOF'
用法: scripts/ios/xcframework.sh [选项]

选项:
  --libs LIST            all（默认）/ 逗号分隔的库名 / preset
  --backends LIST        all（默认）/ xmake / conan / xmake,conan
  --device-slice NAME    设备切片，默认 iphoneos-arm64
  --sim-slices LIST      模拟器切片，默认 iphonesimulator-arm64,iphonesimulator-x86_64
  --experimental MODE    all（默认）/ stable / only
  --out DIR              产物目录，默认 dist/
  -h, --help             显示帮助

说明:
  只处理已成功构建（存在 .ok）的切片与后端；缺少设备或模拟器切片时跳过该静态库。
EOF
}

libs="all"
backends="all"
experimental="all"
device_slice="iphoneos-arm64"
sim_slices="iphonesimulator-arm64,iphonesimulator-x86_64"
dist_dir="${DIST_DIR:-$REPO_ROOT/dist}"

while [ $# -gt 0 ]; do
    case "$1" in
        --libs) [ $# -ge 2 ] || die "--libs 需要一个参数"; libs="$2"; shift 2 ;;
        --backends) [ $# -ge 2 ] || die "--backends 需要一个参数"; backends="$2"; shift 2 ;;
        --device-slice) [ $# -ge 2 ] || die "--device-slice 需要一个参数"; device_slice="$2"; shift 2 ;;
        --sim-slices) [ $# -ge 2 ] || die "--sim-slices 需要一个参数"; sim_slices="$2"; shift 2 ;;
        --experimental) [ $# -ge 2 ] || die "--experimental 需要一个参数"; experimental="$2"; shift 2 ;;
        --out) [ $# -ge 2 ] || die "--out 需要一个参数"; dist_dir="$2"; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        *) die "未知参数: $1（使用 --help 查看用法）" ;;
    esac
done

require_file "$MANIFEST"
require_python
require_macos
have xcodebuild || die "找不到 xcodebuild，请安装 Xcode"
have lipo || die "找不到 lipo，请安装 Xcode"

case "$dist_dir" in
    /*) ;;
    *) dist_dir="$REPO_ROOT/$dist_dir" ;;
esac

valid_slice "$device_slice" || die "非法设备切片: $device_slice"
for target_slice in $(split_csv "$sim_slices"); do
    valid_slice "$target_slice" || die "非法模拟器切片: $target_slice"
    slice_is_device "$target_slice" && die "模拟器切片不能是设备切片: $target_slice"
done
[ "$(slice_sdk "$device_slice")" = "iphoneos" ] || die "--device-slice 必须是 iphoneos-*: $device_slice"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

merged=0
skipped=0
failed=0

# 为某个静态库生成 xcframework。
# $1 = 库名, $2 = 后端, $3 = 设备静态库路径, $4 = 相对路径, $5 = 输出目录
make_one() {
    local name="$1" backend="$2" device_lib="$3" rel="$4" out_dir="$5"
    local headers="" dir sim_lib
    local -a sim_libs=()

    dir="$(dirname "$device_lib")"
    while [ "$dir" != "$dist_dir/$name/$device_slice/$backend" ] && [ "$dir" != "/" ]; do
        if [ -d "$dir/include" ]; then
            headers="$dir/include"
            break
        fi
        dir="$(dirname "$dir")"
    done

    for target_slice in $(split_csv "$sim_slices"); do
        sim_lib="$dist_dir/$name/$target_slice/$backend/$rel"
        [ -f "$sim_lib" ] && sim_libs+=("$sim_lib")
    done
    [ "${#sim_libs[@]}" -gt 0 ] || return 1

    local fat_lib
    fat_lib="$tmp_dir/$(echo "$name-$backend-$rel" | tr '/' '_').a"
    if [ "${#sim_libs[@]}" -eq 1 ]; then
        cp "${sim_libs[0]}" "$fat_lib"
    else
        lipo -create "${sim_libs[@]}" -output "$fat_lib" >/dev/null || return 1
    fi

    local out="$out_dir/$(basename "$rel" .a).xcframework"
    rm -rf "$out"
    if [ -n "$headers" ]; then
        xcodebuild -create-xcframework \
            -library "$device_lib" -headers "$headers" \
            -library "$fat_lib" -headers "$headers" \
            -output "$out" >/dev/null || return 1
    else
        xcodebuild -create-xcframework \
            -library "$device_lib" \
            -library "$fat_lib" \
            -output "$out" >/dev/null || return 1
    fi
    log "生成: $out"
}

while IFS=$'\x1f' read -r name title category is_experimental min_ios xmake_pkg xmake_version xmake_configs conan_ref conan_options headers defines lib_backends; do
    [ -n "$name" ] || continue

    for backend in $(split_csv "$backends"); do
        case " $lib_backends " in
            *" $backend "*) ;;
            *) continue ;;
        esac

        device_root="$dist_dir/$name/$device_slice/$backend"
        [ -d "$device_root" ] || { skipped=$((skipped + 1)); continue; }

        out_dir="$dist_dir/$name/xcframework/$backend"
        mkdir -p "$out_dir"

        while IFS= read -r device_lib; do
            rel="${device_lib#"$device_root"/}"
            if make_one "$name" "$backend" "$device_lib" "$rel" "$out_dir"; then
                merged=$((merged + 1))
            else
                warn "跳过 ${name}/${backend}/${rel}（缺少完整模拟器切片）"
                skipped=$((skipped + 1))
            fi
        done < <(find "$device_root" -type f -name '*.a' | sort)
    done
done < <(manifest list --format tsv --libs "$libs" --backends "$backends" --experimental "$experimental")

log "xcframework 汇总: 生成 $merged 个，跳过 $skipped 个"
[ "$failed" -eq 0 ] || exit 1
