# iOS C/C++ 库构建

使用 **xmake** 与 **Conan 2** 在 macOS 上调用 Xcode 工具链，为 iOS 设备与模拟器编译常用
C/C++ 库，产出静态库、头文件，并可合并为 **xcframework**。仓库本身不包含这些库的源码，
只维护「要构建哪些库」的清单和构建脚本。

- 库清单：`libraries/manifest.json`
- 常用库集合：`presets.core`（libevent、zlib、openssl、sqlite3、libcurl、libuv、libssh2、c-ares）
- 目标切片：
  - `iphoneos-arm64`：真机 arm64
  - `iphonesimulator-arm64`：Apple Silicon 模拟器
  - `iphonesimulator-x86_64`：Intel 模拟器
- 宿主入口：`scripts/mac/`
- 专用后端入口：`scripts/ios/xmake/`、`scripts/ios/conan2/`
- CI：`.github/workflows/ios-libraries.yml`（只负责调用脚本，不包含库列表和编译命令）

> iOS 二进制必须由 Xcode 工具链生成，因此**只能在 macOS 上编译**。
> Linux / Windows 即使安装了 xmake 或 Conan，也无法生成可用的 iOS 产物；本仓库不提供
> Linux / Windows 构建入口。GitHub Actions 侧使用当前 GA 的 `macos-26`（默认，arm64）
> 或 `macos-15`，不使用 `ubuntu-*` / `windows-*` runner。

## 支持的 iOS 库

```bash
bash scripts/list-libraries.sh            # 终端表格
bash scripts/list-libraries.sh --markdown # Markdown 表格
bash scripts/list-libraries.sh --json     # 完整 JSON
bash scripts/list-libraries.sh --names    # 只输出库名
```

当前清单覆盖压缩、图像、字体、密码学、网络、序列化、音视频、XML/文本、数学、测试等方向的
iOS 可用库。常用示例：

```bash
# 核心常用库（libevent 等）
bash scripts/list-libraries.sh --libs core

# 只看指定库
bash scripts/list-libraries.sh --libs zlib,openssl,libcurl

# 只看 Conan 2 能构建的库
bash scripts/list-libraries.sh --backends conan

# 只看非实验库
bash scripts/list-libraries.sh --experimental stable
```

`libraries/manifest.json` 中同时给出 xmake 包名和 Conan 2 引用；两者名称不一致的库（例如
Opus、FLAC、SDL3、protobuf）已分别配置。标记为 `"experimental": true` 的库通常是体积大、
依赖多或 iOS 适配仍不稳定的库，CI 允许它们失败而不影响整个工作流。
`--libs` 除库名外也接受 `presets` 中的集合名，例如 `core`，也可以与库名混用：`core,ffmpeg`。

清单允许某个库只声明一种后端，缺少的后端会在构建时自动跳过：

- `openssl` 的 xmake 侧使用 `openssl3` 包。xmake-repo 里的 `openssl` 包停留在 1.1.1（已 EOL），
  默认解析会得到 1.1.1-w，因此这里显式改用 `openssl3 3.6.5`。
- `libssh2`、`opencv`、`libvpx`、`libjpeg-turbo`、`libarchive` 只提供 Conan 2 后端：
  xmake-repo 中这些包不支持 `iphoneos` 平台，在 iOS 上会直接报 unsupported package。
- `recipes/libvpx/` 维护了一份补丁版 Conan recipe。Conan 2.29+ 在 Apple 平台上会把
  `-arch`、`-mios-simulator-version-min` 写入 `ASFLAGS`，而 libvpx 会把 `ASFLAGS` 原样传给
  yasm，导致 x86_64 模拟器切片报 `yasm: FATAL: unrecognized architecture`。补丁在 Apple
  x86_64 下清空 `ASFLAGS`，`scripts/setup.sh` 与 `scripts/build.sh` 会自动导出该 recipe。

与 Android 清单相比，本清单移除了 Android 专属的 `oboe`，并为 iOS 增加了 `minIosVersion`、
`slices` 与 xcframework 合并流程。

## 平台入口脚本

iOS 目标固定，宿主只能是 macOS：

```bash
bash scripts/mac/build.sh
```

默认编译 `presets.core`，也可以指定库、切片和后端：

```bash
bash scripts/mac/build.sh --libs all
bash scripts/mac/build.sh --libs core --slices iphoneos-arm64
bash scripts/mac/build.sh --libs libevent --skip-setup   # 已手动执行过 setup
bash scripts/mac/build.sh --libs zlib --backends conan
```

## 独立的 xmake / Conan 2 入口

如果只需要某一种后端，可以直接使用：

```bash
# xmake，target = iOS，默认 presets.core
bash scripts/ios/xmake/build.sh --libs libevent,zlib --slices iphoneos-arm64

# Conan 2，target = iOS，默认 presets.core
bash scripts/ios/conan2/build.sh --libs libevent,zlib --slices iphoneos-arm64
```

## 本地构建

需要 macOS、Xcode、Bash、Python 3、curl。Xcode 需完成首次启动并安装 iOS SDK：

```bash
# 方式一：平台入口（自动安装 xmake / Conan 2 / 生成 profiles）
bash scripts/mac/build.sh --libs core

# 方式二：手动分步
bash scripts/setup.sh --slices iphoneos-arm64,iphonesimulator-arm64,iphonesimulator-x86_64
bash scripts/list-libraries.sh
bash scripts/ios/xmake/build.sh  --libs libevent,zlib
bash scripts/ios/conan2/build.sh --libs libevent,zlib
```

常用参数：

```bash
# 全部库、两种后端、全部切片
bash scripts/build.sh

# 只构建一个库的 Conan 包
bash scripts/build.sh --libs libcurl --backends conan

# 只构建真机切片
bash scripts/build.sh --libs ffmpeg --slices iphoneos-arm64

# 指定 Xcode，清理后重建
bash scripts/build.sh --xcode /Applications/Xcode.app/Contents/Developer --clean

# 构建失败立即停止
bash scripts/build.sh --fail-fast
```

### 环境变量

| 变量 | 作用 |
| --- | --- |
| `DEVELOPER_DIR` | Xcode Developer 目录，等价于 `--xcode` |
| `CONAN_HOME` | Conan 2 缓存目录，默认 `~/.conan2` |
| `CONAN_VENV` | 自动安装 Conan 时使用的 Python venv |
| `DIST_DIR` / `WORK_DIR` | 自定义产物目录 / 临时构建目录 |

## 产物结构与 xcframework

```text
dist/
├── summary.md                 # 总体构建摘要
├── summary.tsv
└── <库名>/
    ├── summary.md             # 单库摘要
    ├── summary.tsv
    ├── logs/
    │   ├── iphoneos-arm64-xmake.log
    │   └── iphoneos-arm64-conan.log
    ├── iphoneos-arm64/
    │   ├── xmake/             # xmake require --export 导出的包（含依赖）
    │   └── conan/             # Conan full_deploy 部署的包（含依赖）
    ├── iphonesimulator-arm64/
    ├── iphonesimulator-x86_64/
    └── xcframework/
        └── <后端>/
            └── lib*.xcframework
```

- xmake 产物来自 `xmake require --export`，按 `包名/版本/配置哈希` 组织。
- Conan 产物来自内置 `full_deploy` deployer，可以直接作为离线依赖目录使用。
- `scripts/ios/xcframework.sh` 会扫描设备与模拟器切片中的同名静态库，用 `lipo` 合并模拟器
  arm64/x86_64，再通过 `xcodebuild -create-xcframework` 生成 xcframework。缺少设备或模拟器
  切片的库会被跳过。

```bash
bash scripts/ios/xcframework.sh --libs zlib,openssl
bash scripts/ios/xcframework.sh --libs all --backends conan
```

## GitHub Actions

`.github/workflows/ios-libraries.yml` 只调用 `scripts/`，不硬编码库列表，也**没有定时任务**：

1. **查看支持的 iOS 库列表**：校验清单，输出库列表到 job summary，并展开构建矩阵。
2. **构建**：每个库一个 job，在 macOS runner 上按所选后端和切片编译，把
   `dist/<库名>/` 打包成单个 `ios-<库名>-<后端>.tar.gz` 上传（避免大库数万文件导致
   upload-artifact OOM），并把每个库的构建结果写入 job summary。

触发方式：

- push 到 `main`（仅当 `libraries/`、`scripts/`、工作流或 README 变化时）
- pull request
- `workflow_dispatch` 手动触发

参数：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `libraries` | `core` | `all` / `core` / 逗号分隔的库名（push/PR 默认跑 `core`） |
| `slices` | 三个切片 | `iphoneos-arm64`、`iphonesimulator-arm64`、`iphonesimulator-x86_64` |
| `backends` | `all` | `all`、`xmake` 或 `conan` |
| `ios_version` | `13.0` | iOS deployment target |
| `runner` | `macos-26` | `macos-26` 或 `macos-15`（GitHub Actions 当前 GA 的 macOS 版本） |
| `include_experimental` | `true` | 是否构建 experimental 库 |
| `build_xcframework` | `true` | 构建后是否合并 xcframework |

## 添加新库

编辑 `libraries/manifest.json`，在 `libraries` 数组中加入条目：

```json
{
  "name": "mylib",
  "title": "MyLib",
  "category": "utility",
  "description": "示例库",
  "experimental": false,
  "minIosVersion": "13.0",
  "headers": ["mylib.h"],
  "defines": [],
  "xmake": {
    "package": "mylib",
    "version": "1.2.3",
    "configs": { "shared": false }
  },
  "conan": {
    "reference": "mylib/1.2.3",
    "options": ["mylib/*:shared=False"]
  }
}
```

字段说明见 `libraries/manifest.schema.json`。

- `name` 必须唯一，用作目录名和 CI 参数。
- `xmake` 与 `conan` 至少提供一个；只提供一个时，构建脚本会自动跳过缺失的后端。
- `xmake.package` 是 [xmake-repo](https://github.com/xmake-io/xmake-repo) 中的包名；
  `xmake.version` 建议显式固定，避免默认解析到意外版本。
- `conan.reference` 是 ConanCenter 中的完整引用，必须带版本。
- `conan.options` 推荐使用 Conan 2 的包模式写法 `pkg/*:opt=value`；`pkg:opt=value` 和
  `opt=value` 也会被自动规范化。
- `headers` 用于编译探针，校验头文件是否可用；不写则只验证包能编译。
- `defines` 会以 `#define` 形式加入探针，例如 PCRE2 需要 `PCRE2_CODE_UNIT_WIDTH=8`。
- `minIosVersion` 不写时使用 `defaults.iosMinVersion`（当前 13.0）。
- `experimental: true` 时 CI 对该库使用 `continue-on-error`。

修改后先校验：

```bash
bash scripts/list-libraries.sh --validate
bash scripts/mac/build.sh --libs mylib --slices iphoneos-arm64
```

## 构建方式说明

每个库、每个切片、每个后端都会创建一个最小探针工程：

- **xmake**：探针工程通过 `add_requires()` / `add_packages()` 拉取包，使用
  `xmake f -p iphoneos -a <arch> --appledev=<iphone|simulator> --target_minver=<ios>`
  配置，编译后 `xmake require --export` 导出头文件与库。
- **Conan 2**：使用 `scripts/setup.sh` 生成的 `ios-<slice>` host profile，
  `conan install --requires=<ref> --build=missing` 从源码构建，`full_deploy` deployer 收集产物。

探针默认会 include 清单中的头文件，从而同时验证编译参数和头文件可用性；可用
`--no-header-check` 关闭。

## 相关文件

```text
.github/workflows/ios-libraries.yml            全库矩阵构建（macOS，无定时任务）
libraries/manifest.json                        库清单 + presets
libraries/manifest.schema.json                 清单 JSON Schema
scripts/setup.sh                               安装 xmake / Conan 2，生成 iOS Conan profiles
scripts/list-libraries.sh                      查看支持的 iOS 库列表
scripts/build.sh                               通用编译入口
scripts/mac/build.sh                           macOS 宿主入口
scripts/ios/xmake/build.sh                     xmake iOS 专用入口
scripts/ios/conan2/build.sh                    Conan 2 iOS 专用入口
scripts/ios/xcframework.sh                     合并设备/模拟器切片为 xcframework
scripts/lib/common.sh                          Xcode / SDK / 切片 / 日志等公共函数
scripts/lib/platform.sh                       平台入口公共实现
scripts/lib/manifest.py                       清单解析、校验、preset / matrix / TSV 输出
```
