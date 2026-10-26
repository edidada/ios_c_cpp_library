#!/usr/bin/env python3
"""为 libraries/manifest.json 中的每个库生成 scripts/mac/<library>.sh。

单库入口只固定库名，其余参数（后端、切片、Xcode、产物目录等）全部透传给
scripts/mac/build.sh。清单增删库后重新运行本脚本即可。

用法:
  python3 scripts/lib/generate-library-scripts.py
  python3 scripts/lib/generate-library-scripts.py --check
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Dict

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[1]
OUTPUT_DIR = REPO_ROOT / "scripts" / "mac"
MARKER = "# 由 scripts/lib/generate-library-scripts.py 自动生成，请勿手工修改。"

# 使用 format 模板时保留 shell 的 ${BASH_SOURCE[0]}。
TEMPLATE = """#!/usr/bin/env bash
{marker}
# macOS -> iOS: {name}。
# 固定编译 {name}，其余参数原样传给 scripts/mac/build.sh。
# 用法: bash scripts/mac/{name}.sh [--backends ...] [--slices ...]
set -euo pipefail
script_dir="$(cd "$(dirname "${{BASH_SOURCE[0]}}")" && pwd)"
exec bash "$script_dir/build.sh" "$@" --libs {name}
"""


def render(name: str) -> str:
    return TEMPLATE.format(marker=MARKER, name=name)


def expected_scripts(manifest: Dict[str, object]) -> Dict[str, str]:
    libraries = manifest.get("libraries")
    if not isinstance(libraries, list):
        raise ValueError("清单缺少 libraries 数组")
    scripts: Dict[str, str] = {}
    for item in libraries:
        if not isinstance(item, dict) or not isinstance(item.get("name"), str):
            raise ValueError(f"清单中存在非法库条目: {item!r}")
        name = item["name"]
        scripts[name] = render(name)
    return scripts


def generated_files() -> Dict[str, Path]:
    """返回带有生成标记的现有脚本，避免误删手工维护的文件。"""
    result: Dict[str, Path] = {}
    if not OUTPUT_DIR.is_dir():
        return result
    for path in sorted(OUTPUT_DIR.glob("*.sh")):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        if MARKER in text:
            result[path.stem] = path
    return result


def check(expected: Dict[str, str]) -> int:
    errors = []
    existing = generated_files()

    for name, content in expected.items():
        path = OUTPUT_DIR / f"{name}.sh"
        if not path.is_file():
            errors.append(f"缺少单库入口: {path.relative_to(REPO_ROOT)}")
            continue
        if path.read_text(encoding="utf-8") != content:
            errors.append(f"单库入口内容已过期: {path.relative_to(REPO_ROOT)}")

    for name, path in existing.items():
        if name not in expected:
            errors.append(f"清单中已不存在，但仍保留单库入口: {path.relative_to(REPO_ROOT)}")

    if errors:
        print("单库入口与 libraries/manifest.json 不同步:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        print("请运行: python3 scripts/lib/generate-library-scripts.py", file=sys.stderr)
        return 1

    print(f"OK: {len(expected)} 个单库入口与清单一致")
    return 0


def generate(expected: Dict[str, str]) -> int:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    for name, content in expected.items():
        path = OUTPUT_DIR / f"{name}.sh"
        # 显式写成 LF，避免 Windows 工作区出现 CRLF（.gitattributes 也会强制 LF）。
        path.write_bytes(content.encode("utf-8"))
        try:
            path.chmod(0o755)
        except OSError:
            # Windows 上 chmod 只影响只读位；可执行位由 git update-index 记录。
            pass

    removed = 0
    for name, path in generated_files().items():
        if name not in expected:
            path.unlink()
            removed += 1

    print(f"已生成 {len(expected)} 个单库入口: {OUTPUT_DIR.relative_to(REPO_ROOT)}")
    if removed:
        print(f"已删除 {removed} 个清单中不存在的单库入口")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="生成 scripts/mac/<library>.sh 单库入口")
    parser.add_argument("--check", action="store_true", help="只检查是否与清单同步，不写文件")
    args = parser.parse_args(argv)

    sys.path.insert(0, str(SCRIPT_DIR))
    try:
        from manifest import ManifestError, load_manifest, validate
    except ImportError as exc:
        print(f"error: 无法导入 scripts/lib/manifest.py: {exc}", file=sys.stderr)
        return 2

    try:
        manifest = load_manifest(REPO_ROOT / "libraries" / "manifest.json")
        validate(manifest)
        expected = expected_scripts(manifest)
    except (ManifestError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    return check(expected) if args.check else generate(expected)


if __name__ == "__main__":
    raise SystemExit(main())
