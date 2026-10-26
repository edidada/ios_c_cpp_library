#!/usr/bin/env bash
# 使用 Conan 2 为 iOS 编译清单中的库（固定 target = iOS）。
# 默认编译 presets.core，可通过 --libs 覆盖。
#
# 示例:
#   scripts/ios/conan2/build.sh
#   scripts/ios/conan2/build.sh --libs libevent,zlib --slices iphoneos-arm64
#   scripts/ios/conan2/build.sh --libs all
#
# shellcheck source=../../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/common.sh"

usage() {
    cat <<'EOF'
用法: scripts/ios/conan2/build.sh [选项]

固定使用 Conan 2 后端，目标平台为 iOS，默认编译 presets.core。

选项:
  --libs LIST           core（默认）/ all / 逗号分隔的库名或 preset
  其余参数直接透传给 scripts/build.sh:
  --slices LIST --ios-version X.Y --build-type TYPE --experimental MODE
  --xcode PATH --jobs N --out DIR --clean --fail-fast --no-header-check
EOF
}

libs="core"
build_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --libs)
            [ $# -ge 2 ] || die "--libs 需要一个参数"
            libs="$2"
            shift 2
            ;;
        --backends)
            die "该脚本固定使用 Conan 2，请不要再传 --backends"
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            build_args+=("$1")
            shift
            ;;
    esac
done

exec bash "$REPO_ROOT/scripts/build.sh" \
    --libs "$libs" \
    --backends conan \
    ${build_args[@]+"${build_args[@]}"}
