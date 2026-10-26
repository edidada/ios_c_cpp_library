#!/usr/bin/env bash
# macOS 宿主入口：Xcode 工具链编译 iOS 库。
#
# 示例:
#   bash scripts/mac/build.sh
#   bash scripts/mac/build.sh --libs core --slices iphoneos-arm64
#   bash scripts/mac/build.sh --libs all --backends xmake
#
# shellcheck source=../lib/platform.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/platform.sh"

platform_build mac "$@"
