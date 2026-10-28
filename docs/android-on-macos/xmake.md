# xmake：macOS 宿主编译 Android C/C++ 库

> 范围：**宿主 macOS → 目标 Android**。只讨论 C/C++ 依赖库的交叉编译，不包含 APK、Java/Kotlin 或 Android 应用层构建。
> 同一套 xmake 也可以在 macOS 上编译 iOS/macOS 库，但不在本页范围内。

## 结论

- xmake 内置 `android` 平台，使用 NDK 工具链交叉编译。
- 通过 `xmake f -p android -a <ABI> --ndk=<NDK> --ndk_sdkver=<API>` 选择目标。
- 关联的 Android 仓库在 macOS runner 上对 **10 个常用库**、`arm64-v8a`、API 28 做了实际编译验证。
- xmake-repo 的包能否用于 Android 取决于包自身的 `on_install` 平台条件和依赖；包名存在不等于已支持。

## 支持的 Android target

| Android ABI | xmake `-a` 参数 | 说明 |
| --- | --- | --- |
| `arm64-v8a` | `arm64-v8a` | 现代真机主力 ABI |
| `armeabi-v7a` | `armeabi-v7a` | 32 位 ARM，旧设备 |
| `x86_64` | `x86_64` | x86_64 模拟器 |
| `x86` | `x86` | 很旧的模拟器；现代项目一般不需要 |

- 平台固定为 `android`。
- `--ndk` 必须指向具体的 NDK 目录。
- `--ndk_sdkver` 设置目标 API level；`libuv` 需要 28+，Android 仓库的 smoke 构建使用 28。
- Android 仓库的验证产物是 Release 静态库；需要动态库时在 `xmake.lua` 中用 `set_kind("shared")` 或对应包配置显式指定。
- xmake 的 package 解析会同时处理目标包和构建期 host 工具；macOS 上要保证宿主工具链完整。

## macOS 主机要求

- macOS 13 或更高版本；Apple Silicon / Intel 均可。
- Xcode Command Line Tools（`xcode-select --install`）。
- xmake 3.x。
- CMake、Ninja、Git、Python 3；部分包还会用到 `pkg-config`、`autoconf`、`automake`、`libtool`、`meson`。
- Android NDK，建议 r27 或更高版本：

```bash
export ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/27.3.13750724"
```

- 如果使用 Homebrew 安装辅助工具：

```bash
brew install cmake ninja pkg-config autoconf automake libtool meson
```

## 已验证的库

以下 10 个库在 macOS → Android `arm64-v8a` / API 28 上通过 xmake 实际编译：

| 库 | xmake package | 备注 |
| --- | --- | --- |
| zlib | `zlib` | 无 |
| zstd | `zstd` | 无 |
| libpng | `libpng` | 无 |
| openssl | `openssl` | 无 |
| sqlite3 | `sqlite3` | 无 |
| libcurl | `libcurl` | 无 |
| libuv | `libuv` | 需要 API 28+ |
| libssh2 | `libssh2` | 无 |
| c-ares | `c-ares` | 无 |
| libevent | `libevent` | 需要 Android 本地包覆盖，见下文 |

验证记录：

- Linux 宿主 10 库 × 3 后端，30/30 通过：
  https://github.com/edidada/android_c_cpp_library/actions/runs/40522088051
- macOS 宿主 10 库矩阵（vcpkg / Conan / xmake）：
  https://github.com/edidada/android_c_cpp_library/actions/runs/40522088283
- 构建报告：
  https://github.com/edidada/android_c_cpp_library/blob/main/docs/android-support/common10-build.md

验证环境：macOS 14 arm64 runner、NDK r27d、`arm64-v8a` / API 28。

## 清单内其他候选库

下列库在 Android 仓库的 55 库清单中，但**尚未在当前 macOS → Android + xmake 流程中逐一验证**。xmake-repo 有包只代表可以尝试，不代表 Android 安装和编译已经通过。

### 稳定候选（34）

```text
lz4, bzip2, snappy, libjpeg-turbo, libwebp, libtiff, libjpeg, libyuv,
freetype, harfbuzz, mbedtls, libsodium, asio, nlohmann_json, rapidjson,
flatbuffers, fmt, spdlog, glm, eigen, gtest, catch2, benchmark, re2,
libxml2, expat, pcre2, libarchive, libogg, libvorbis, libopus, libflac,
oboe, vulkan-headers
```

### 实验候选（11）

```text
opencv, protobuf, boost, abseil, icu, libiconv, openal-soft,
libsdl3, openh264, libvpx, ffmpeg
```

常见名称映射：

| 清单名 | xmake package |
| --- | --- |
| protobuf | `protobuf-cpp` |
| icu | `icu4c` |
| libogg | `libogg` |
| libvorbis | `libvorbis` |
| libopus | `libopus` |
| libflac | `libflac` |
| libsdl3 | `libsdl3` |
| libcurl | `libcurl` |
| libjpeg | `libjpeg` |

## 在 macOS 上使用

### 1. 配置 Android 目标

```bash
xmake f -p android \
  -a arm64-v8a \
  --ndk="$ANDROID_NDK_HOME" \
  --ndk_sdkver=28 \
  -m release
```

### 2. 用最小工程验证一个包

```bash
mkdir -p android-probe
cd android-probe
```

创建 `xmake.lua`：

```lua
add_rules("mode.release")
add_requires("zlib")

target("probe")
    set_kind("static")
    add_files("probe.cpp")
    add_packages("zlib")
```

创建 `probe.cpp`：

```cpp
#include <zlib.h>

int android_library_probe()
{
    return zlibVersion() != nullptr ? 0 : 1;
}
```

配置并编译：

```bash
xmake f -p android \
  -a arm64-v8a \
  --ndk="$ANDROID_NDK_HOME" \
  --ndk_sdkver=28 \
  -m release

xmake -y
xmake require --export --packagedir="$PWD/out" zlib
```

### 3. libevent 的 Android 本地包覆盖

xmake-repo 上游的 `libevent` 包使用 `on_install("!android and ...")` 显式排除了 Android，但 libevent 本身可以通过 NDK 的 CMake 工具链交叉编译。

Android 仓库提供了本地包覆盖：

```text
scripts/android/xmake/repo/packages/l/libevent/xmake.lua
```

覆盖包的关键点：

- 增加 `on_install("android", ...)`。
- 关闭测试、示例、benchmark。
- 关闭未使用的 OpenSSL/MbedTLS 后端。
- 强制静态库。
- 设置 `-DCMAKE_HAVE_LIBC_PTHREAD=ON`，绕过 Bionic 不实现的 `pthread_cancel` 探测。

在工程中引用本地仓库：

```lua
add_repositories("android-libs scripts/android/xmake/repo", {
    rootdir = "/path/to/android_c_cpp_library"
})
add_requires("libevent 2.1.12")
```

没有这个覆盖时，不要直接假设 `add_requires("libevent")` 能在 Android 上安装成功。

## 已知限制

- xmake-repo 的 `libevent` 上游包排除 Android，必须使用本地覆盖。
- `libuv` 使用 API 28；低于 28 会遇到缺少系统接口的问题。
- `harfbuzz`、`openh264` 等使用 Meson 的包在 macOS 上可能触发源码编译 Python 或宿主工具，速度慢且容易失败；优先使用预装工具或改用 Conan/vcpkg。
- `abseil` 新版本在 xmake-repo 中要求 NDK >= 27；Android 清单的 `abseil 20260526.0` 要特别注意。
- `ffmpeg`、`opencv`、`boost`、`protobuf`、`icu`、`libiconv`、`openal-soft`、`sdl`、`openh264`、`libvpx` 等实验库依赖多、可选 feature 多，必须逐库固定版本和 configs。
- `oboe` 只适用于 Android；不要放进 iOS/macOS 目标。
- `vulkan-headers` 是 header-only；运行时仍需要 NDK 的 `libvulkan.so` 或项目自己的 Vulkan 实现。
- `gtest`、`catch2`、`benchmark` 可以交叉编译，但通常不能在 Android 设备上运行；应只作为构建期依赖。
- 包安装成功不等于链接成功；需要同时检查头文件、库架构和最终 App 的 STL/ABI 设置。
- macOS 上没有 Android 设备时只能验证编译和归档架构，不能替代真机运行测试。

## 建议的验证顺序

1. 先验证 10 个已通过库，确认 NDK、API、ABI 和 xmake 配置正确。
2. 再按依赖关系验证稳定候选：压缩/图像 → 字体/文本 → 网络 → 音频。
3. 最后验证 experimental 库；每个库固定 ABI、API、package configs 和静态/动态链接方式。
4. 对每个产物用 NDK `llvm-readelf` 检查架构，例如 arm64 必须是 `AArch64`。
