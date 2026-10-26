#!/usr/bin/env bash
# 查看支持 iOS 的 C/C++ 库列表。
#
# 示例:
#   scripts/list-libraries.sh                         # 终端表格
#   scripts/list-libraries.sh --markdown              # Markdown 表格
#   scripts/list-libraries.sh --libs zlib,openssl     # 只看指定库
#   scripts/list-libraries.sh --backends conan        # 只看 Conan 2 可构建的库
#   scripts/list-libraries.sh --matrix                # 输出 GitHub Actions matrix JSON
#   scripts/list-libraries.sh --names                 # 只输出库名
#
# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
    cat <<'EOF'
用法: scripts/list-libraries.sh [选项]

选项:
  --libs LIST           all、core 或逗号分隔的库名 / preset，例如 zlib,openssl
  --backends LIST       all（默认）/ xmake / conan / xmake,conan
  --experimental MODE   all（默认）/ stable（排除实验库）/ only（仅实验库）
  --format FORMAT       table（默认）/ markdown / json / names / matrix / tsv
  --markdown            等价于 --format markdown
  --json                等价于 --format json
  --matrix              等价于 --format matrix
  --names               等价于 --format names
  --validate            只校验清单
  -h, --help            显示帮助

环境变量:
  MANIFEST              自定义清单路径，默认 libraries/manifest.json
EOF
}

libs="all"
backends="all"
experimental="all"
format="table"
validate_only=0

while [ $# -gt 0 ]; do
    case "$1" in
        --libs)
            [ $# -ge 2 ] || die "--libs 需要一个参数"
            libs="$2"
            shift 2
            ;;
        --backends)
            [ $# -ge 2 ] || die "--backends 需要一个参数"
            backends="$2"
            shift 2
            ;;
        --experimental)
            [ $# -ge 2 ] || die "--experimental 需要一个参数"
            experimental="$2"
            shift 2
            ;;
        --format)
            [ $# -ge 2 ] || die "--format 需要一个参数"
            format="$2"
            shift 2
            ;;
        --markdown) format="markdown"; shift ;;
        --json) format="json"; shift ;;
        --matrix) format="matrix"; shift ;;
        --names) format="names"; shift ;;
        --validate) validate_only=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) die "未知参数: $1（使用 --help 查看用法）" ;;
    esac
done

require_file "$MANIFEST"

if [ "$validate_only" -eq 1 ]; then
    manifest validate
    exit 0
fi

manifest list \
    --format "$format" \
    --libs "$libs" \
    --backends "$backends" \
    --experimental "$experimental"
