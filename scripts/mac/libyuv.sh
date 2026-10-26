#!/usr/bin/env bash
# 由 scripts/lib/generate-library-scripts.py 自动生成，请勿手工修改。
# macOS -> iOS: libyuv。
# 固定编译 libyuv，其余参数原样传给 scripts/mac/build.sh。
# 用法: bash scripts/mac/libyuv.sh [--backends ...] [--slices ...]
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$script_dir/build.sh" "$@" --libs libyuv
