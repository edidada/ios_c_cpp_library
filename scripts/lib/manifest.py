#!/usr/bin/env python3
"""查询 libraries/manifest.json 中的 iOS C/C++ 库列表。

该脚本只依赖 Python 3 标准库，作为 CI 与本地脚本之间的唯一数据入口：
  - list-libraries.sh 使用它输出表格 / Markdown / JSON / GitHub Actions matrix
  - build.sh 使用它输出待编译库的 TSV 列表
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = REPO_ROOT / "libraries" / "manifest.json"

VALID_SLICES = {
    "iphoneos-arm64",
    "iphonesimulator-arm64",
    "iphonesimulator-x86_64",
}
VALID_BUILD_TYPES = {"Release", "Debug", "RelWithDebInfo", "MinSizeRel"}
VALID_BACKENDS = {"xmake", "conan"}
CONAN_REF_RE = re.compile(r"^[^/\s]+/[^\s]+$")
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
IOS_VERSION_RE = re.compile(r"^[0-9]+(\.[0-9]+)*$")


class ManifestError(Exception):
    pass


def load_manifest(path: Path) -> Dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as fp:
            data = json.load(fp)
    except FileNotFoundError as exc:
        raise ManifestError(f"找不到清单文件: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ManifestError(f"清单文件不是合法 JSON: {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise ManifestError("清单顶层必须是 JSON object")
    return data


def _check_ios_version(value: Any, where: str, errors: List[str]) -> None:
    if not isinstance(value, str) or not IOS_VERSION_RE.match(value):
        errors.append(f"{where} 必须是 X.Y 形式的字符串: {value!r}")


def validate(data: Dict[str, Any]) -> None:
    errors: List[str] = []

    if data.get("schemaVersion") != 1:
        errors.append("schemaVersion 必须为 1")

    defaults = data.get("defaults") or {}
    if not isinstance(defaults, dict):
        errors.append("defaults 必须是 object")
        defaults = {}

    _check_ios_version(defaults.get("iosMinVersion", "13.0"), "defaults.iosMinVersion", errors)

    slices = defaults.get("slices", ["iphoneos-arm64"])
    if not isinstance(slices, list) or not slices:
        errors.append("defaults.slices 必须是非空数组")
    else:
        for target_slice in slices:
            if target_slice not in VALID_SLICES:
                errors.append(f"defaults.slices 中含非法切片: {target_slice}")

    build_type = defaults.get("buildType", "Release")
    if build_type not in VALID_BUILD_TYPES:
        errors.append(f"defaults.buildType 非法: {build_type}")

    libraries = data.get("libraries")
    if not isinstance(libraries, list) or not libraries:
        errors.append("libraries 必须是非空数组")
        libraries = []

    seen = set()
    for index, item in enumerate(libraries):
        where = f"libraries[{index}]"
        if not isinstance(item, dict):
            errors.append(f"{where} 必须是 object")
            continue

        name = item.get("name")
        if not isinstance(name, str) or not NAME_RE.match(name):
            errors.append(f"{where}.name 缺失或非法: {name!r}")
        elif name in seen:
            errors.append(f"库名重复: {name}")
        else:
            seen.add(name)
            where = f"{where}({name})"

        if not item.get("category"):
            errors.append(f"{where}.category 不能为空")

        experimental = item.get("experimental", False)
        if not isinstance(experimental, bool):
            errors.append(f"{where}.experimental 必须是布尔值")

        if "minIosVersion" in item:
            _check_ios_version(item["minIosVersion"], f"{where}.minIosVersion", errors)

        for field in ("headers", "defines"):
            value = item.get(field, [])
            if not isinstance(value, list) or any(not isinstance(v, str) or not v for v in value):
                errors.append(f"{where}.{field} 必须是字符串数组")

        xmake = item.get("xmake")
        conan = item.get("conan")
        if not xmake and not conan:
            errors.append(f"{where} 至少需要 xmake 或 conan 之一")
        if xmake is not None:
            if not isinstance(xmake, dict) or not xmake.get("package"):
                errors.append(f"{where}.xmake.package 不能为空")
            else:
                configs = xmake.get("configs", {})
                if not isinstance(configs, dict):
                    errors.append(f"{where}.xmake.configs 必须是 object")
                version = xmake.get("version")
                if version is not None and not isinstance(version, str):
                    errors.append(f"{where}.xmake.version 必须是字符串")
        if conan is not None:
            if not isinstance(conan, dict) or not conan.get("reference"):
                errors.append(f"{where}.conan.reference 不能为空")
            elif not CONAN_REF_RE.match(conan["reference"]):
                errors.append(f"{where}.conan.reference 格式非法: {conan['reference']}")
            else:
                options = conan.get("options", [])
                if not isinstance(options, list) or any(not isinstance(v, str) or not v for v in options):
                    errors.append(f"{where}.conan.options 必须是字符串数组")

    if errors:
        raise ManifestError("清单校验失败:\n  - " + "\n  - ".join(errors))

    presets = data.get("presets", {})
    if not isinstance(presets, dict):
        raise ManifestError("presets 必须是 object")
    for preset_name, preset_libs in presets.items():
        if not isinstance(preset_name, str) or not NAME_RE.match(preset_name):
            raise ManifestError(f"presets 名称非法: {preset_name!r}")
        if not isinstance(preset_libs, list) or not preset_libs:
            raise ManifestError(f"presets.{preset_name} 必须是非空数组")
        for lib in preset_libs:
            if not isinstance(lib, str) or not lib:
                raise ManifestError(f"presets.{preset_name} 中必须是库名字符串")
            if lib not in seen:
                raise ManifestError(f"presets.{preset_name} 引用了不存在的库: {lib}")


def library_backends(item: Dict[str, Any]) -> List[str]:
    return [backend for backend in ("xmake", "conan") if backend in item]


def selected_libraries(
    data: Dict[str, Any],
    libs_spec: str,
    backends_spec: str,
    experimental: str,
) -> List[Dict[str, Any]]:
    requested_backends = list(VALID_BACKENDS) if backends_spec == "all" else [
        value.strip() for value in backends_spec.split(",") if value.strip()
    ]
    unknown_backends = sorted(set(requested_backends) - VALID_BACKENDS)
    if unknown_backends:
        raise ManifestError(f"未知后端: {', '.join(unknown_backends)}（可选: all, xmake, conan）")

    if experimental not in ("all", "stable", "only", "true", "false"):
        raise ManifestError(f"--experimental 取值非法: {experimental}")
    if experimental in ("stable", "false"):
        experimental_mode = "stable"
    elif experimental == "only":
        experimental_mode = "only"
    else:
        experimental_mode = "all"

    libraries = data["libraries"]
    by_name = {item["name"]: item for item in libraries}
    presets = data.get("presets") or {}

    if libs_spec == "all":
        wanted = list(libraries)
    else:
        tokens = [value.strip() for value in libs_spec.split(",") if value.strip()]
        if not tokens:
            raise ManifestError("--libs 不能为空")

        names: List[str] = []
        for token in tokens:
            if token in presets:
                names.extend(presets[token])
            else:
                names.append(token)

        # 去重并保持顺序，便于 preset 与单个库混用。
        unique_names: List[str] = []
        seen_names = set()
        for name in names:
            if name not in seen_names:
                unique_names.append(name)
                seen_names.add(name)

        unknown = [name for name in unique_names if name not in by_name]
        if unknown:
            raise ManifestError(
                f"未知库: {', '.join(unknown)}\n"
                f"可用库: {', '.join(sorted(by_name))}\n"
                f"可用 presets: {', '.join(sorted(presets)) or '(无)'}"
            )
        wanted = [by_name[name] for name in unique_names]

    result: List[Dict[str, Any]] = []
    for item in wanted:
        if experimental_mode == "stable" and item.get("experimental", False):
            continue
        if experimental_mode == "only" and not item.get("experimental", False):
            continue

        available = [backend for backend in library_backends(item) if backend in requested_backends]
        if not available:
            print(
                f"warning: 跳过 {item['name']}，其可用后端 {library_backends(item)} "
                f"与请求的后端 {requested_backends} 无交集",
                file=sys.stderr,
            )
            continue

        entry = dict(item)
        entry["_backends"] = available
        result.append(entry)

    return result


def min_ios(item: Dict[str, Any], defaults: Dict[str, Any]) -> str:
    return str(item.get("minIosVersion", defaults.get("iosMinVersion", "13.0")))


def display_width(value: str) -> int:
    return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in value)


def pad(value: str, width: int) -> str:
    return value + " " * max(0, width - display_width(value))


def table_row(cells: Iterable[str], widths: List[int]) -> str:
    return "  ".join(pad(cell, width) for cell, width in zip(cells, widths)).rstrip()


def render_table(items: List[Dict[str, Any]], defaults: Dict[str, Any]) -> str:
    header = ["库", "分类", "最低 iOS", "xmake", "Conan 2", "状态", "说明"]
    rows: List[List[str]] = []
    for item in items:
        xmake = item.get("xmake") or {}
        conan = item.get("conan") or {}
        rows.append([
            item["name"],
            item.get("category", ""),
            min_ios(item, defaults),
            xmake.get("package", "-"),
            conan.get("reference", "-"),
            "实验" if item.get("experimental", False) else "稳定",
            item.get("description", item.get("title", "")),
        ])

    widths = [display_width(cell) for cell in header]
    for row in rows:
        widths = [max(width, display_width(cell)) for width, cell in zip(widths, row)]

    lines = [table_row(header, widths), table_row(["-" * min(w, 8) for w in widths], widths)]
    lines.extend(table_row(row, widths) for row in rows)
    return "\n".join(lines)


def render_markdown(items: List[Dict[str, Any]], defaults: Dict[str, Any]) -> str:
    def escape(value: str) -> str:
        return str(value).replace("|", "\\|").replace("\n", " ")

    lines = [
        "| 库 | 分类 | 最低 iOS | xmake 包 | Conan 2 引用 | 状态 | 说明 |",
        "| --- | --- | ---: | --- | --- | --- | --- |",
    ]
    for item in items:
        xmake = item.get("xmake") or {}
        conan = item.get("conan") or {}
        lines.append(
            "| {name} | {category} | {ios} | {xmake} | {conan} | {status} | {description} |".format(
                name=escape(item["name"]),
                category=escape(item.get("category", "")),
                ios=min_ios(item, defaults),
                xmake=escape(xmake.get("package", "-")),
                conan=escape(conan.get("reference", "-")),
                status="实验" if item.get("experimental", False) else "稳定",
                description=escape(item.get("description", item.get("title", ""))),
            )
        )
    return "\n".join(lines)


def render_matrix(items: List[Dict[str, Any]]) -> str:
    matrix = [
        {
            "name": item["name"],
            "title": item.get("title", item["name"]),
            "experimental": bool(item.get("experimental", False)),
            "backends": ",".join(item["_backends"]),
        }
        for item in items
    ]
    return json.dumps(matrix, ensure_ascii=False, separators=(",", ":"))


def render_tsv(items: List[Dict[str, Any]], defaults: Dict[str, Any]) -> str:
    """内部字段格式（US 分隔），列顺序必须与 scripts/build.sh 保持一致。

    使用 ASCII Unit Separator (0x1f) 而不是 Tab：Bash 的 read 会把连续 Tab
    当作一个分隔符，导致空字段错位，而 0x1f 不是 IFS 空白字符。
    """

    separator = "\x1f"

    def clean(value: Any) -> str:
        return (
            str(value)
            .replace("\t", " ")
            .replace("\n", " ")
            .replace(separator, " ")
        )

    lines = []
    for item in items:
        xmake = item.get("xmake") or {}
        conan = item.get("conan") or {}
        configs = ";".join(
            f"{key}={'true' if value is True else 'false' if value is False else value}"
            for key, value in (xmake.get("configs") or {}).items()
        )
        options = ";".join(conan.get("options") or [])
        lines.append(separator.join([
            item["name"],
            clean(item.get("title", item["name"])),
            clean(item.get("category", "")),
            "1" if item.get("experimental", False) else "0",
            min_ios(item, defaults),
            clean(xmake.get("package", "")),
            clean(xmake.get("version", "")),
            clean(configs),
            clean(conan.get("reference", "")),
            clean(options),
            clean(",".join(item.get("headers") or [])),
            clean(",".join(item.get("defines") or [])),
            ",".join(item["_backends"]),
        ]))
    return "\n".join(lines)


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="查询 iOS C/C++ 库清单")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    subparsers = parser.add_subparsers(dest="command", required=True)

    list_parser = subparsers.add_parser("list", help="输出库列表")
    list_parser.add_argument(
        "--format",
        choices=("table", "markdown", "json", "names", "matrix", "tsv"),
        default="table",
    )
    list_parser.add_argument("--libs", default="all", help="all 或逗号分隔的库名")
    list_parser.add_argument("--backends", default="all", help="all 或 xmake,conan")
    list_parser.add_argument(
        "--experimental",
        default="all",
        help="all（默认）/ stable（排除实验库）/ only（仅实验库）",
    )

    defaults_parser = subparsers.add_parser("defaults", help="输出默认值")
    defaults_parser.add_argument(
        "--field",
        choices=("slices", "iosMinVersion", "buildType"),
        required=True,
    )

    subparsers.add_parser("validate", help="校验清单")

    args = parser.parse_args(argv)

    try:
        data = load_manifest(args.manifest)
        validate(data)
        defaults = data.get("defaults") or {}

        if args.command == "validate":
            print(f"OK: {len(data['libraries'])} 个库，清单校验通过")
            return 0

        if args.command == "defaults":
            value = defaults.get(
                args.field,
                {
                    "slices": ["iphoneos-arm64"],
                    "iosMinVersion": "13.0",
                    "buildType": "Release",
                }[args.field],
            )
            if isinstance(value, list):
                print(",".join(str(v) for v in value))
            else:
                print(value)
            return 0

        items = selected_libraries(data, args.libs, args.backends, args.experimental)
        if args.format == "table":
            print(render_table(items, defaults))
        elif args.format == "markdown":
            print(render_markdown(items, defaults))
        elif args.format == "json":
            print(json.dumps(items, ensure_ascii=False, indent=2))
        elif args.format == "names":
            print("\n".join(item["name"] for item in items))
        elif args.format == "matrix":
            print(render_matrix(items))
        elif args.format == "tsv":
            print(render_tsv(items, defaults))
        return 0
    except ManifestError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
