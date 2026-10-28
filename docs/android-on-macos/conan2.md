# Conan 2：macOS 宿主编译 Android C/C++ 库

> 范围：**宿主 macOS → 目标 Android**。只讨论 C/C++ 依赖库的交叉编译，不包含 APK、Java/Kotlin 或 Android 应用层构建。
> 同一套 Conan 2 profile 也可以在 macOS 上生成 iOS/macOS 包，但不在本页范围内。

## 结论

- Conan 2 本身不绑定目标平台；Android 支持由 **host/build profile + Android NDK** 提供。
- 关键设置是 `os=Android`、`compiler=clang`、`os.api_level` 和 `tools.android:ndk_path`。
- 关联的 Android 仓库在 macOS runner 上对 **10 个常用库**、`arm64-v8a`、API 28 做了实际编译验证。
- Conan Center 有配方不等于已支持 Android；其余清单库只能作为候选，必须逐库验证。

## 支持的 Android target

| Android ABI | Conan `arch` | 生成的 profile 名 |
| --- | --- | --- |
| `arm64-v8a` | `armv8` | `android-arm64-v8a` |
| `armeabi-v7a` | `armv7` | `android-armeabi-v7a` |
| `x86_64` | `x86_64` | `android-x86_64` |
| `x86` | `x86` | `android-x86` |

- 目标 OS 固定为 `Android`。
- `os.api_level` 最小 21；`libuv` 需要 28+。Android 仓库的 smoke 构建使用 API 28。
- `compiler` 使用 NDK 的 Clang，`compiler.version` 取 NDK Clang 的主版本号。
- 默认使用 `compiler.libcxx=c++_static`；如果应用需要多个共享库共用 `libc++_shared.so`，所有依赖必须统一改成 `c++_shared`。
- `build_type` 通常为 `Release`。

## macOS 主机要求

- macOS 13 或更高版本；Apple Silicon / Intel 均可。
- Xcode Command Line Tools（`xcode-select --install`）。
- Python 3.8+、`pip`、CMake、Ninja、Git。
- Conan 2（建议装在独立 venv 中）。
- Android NDK，建议 r27 或更高版本：

```bash
export ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/27.3.13750724"
```

- `ANDROID_NDK_HOME` 必须指向具体的 NDK 目录，而不是 Android SDK 根目录。
- 宿主 profile 由 `conan profile detect` 生成；目标 profile 需要单独创建。

## 已验证的库

以下 10 个库在 macOS → Android `arm64-v8a` / API 28 上通过 Conan 2 实际编译：

| 库 | Android 清单中的 reference | 备注 |
| --- | --- | --- |
| zlib | `zlib/1.3.2` | 无 |
| zstd | `zstd/1.5.7` | 无 |
| libpng | `libpng/1.6.59` | 无 |
| openssl | `openssl/4.0.3` | 无 |
| sqlite3 | `sqlite3/3.54.0` | 无 |
| libcurl | `libcurl/8.23.0` | 无 |
| libuv | `libuv/1.53.0` | 需要 API 28+ |
| libssh2 | `libssh2/1.11.1` | 无 |
| c-ares | `c-ares/1.34.9` | 无 |
| libevent | `libevent/2.1.12` | Android 上需要额外的 pthread CMake 变量，见下文 |

验证记录：

- Linux 宿主 10 库 × 3 后端，30/30 通过：
  https://github.com/edidada/android_c_cpp_library/actions/runs/40522088051
- macOS 宿主 10 库矩阵（vcpkg / Conan / xmake）：
  https://github.com/edidada/android_c_cpp_library/actions/runs/40522088283
- 构建报告：
  https://github.com/edidada/android_c_cpp_library/blob/main/docs/android-support/common10-build.md

验证环境：macOS 14 arm64 runner、NDK r27d、`arm64-v8a` / API 28。

## 清单内其他候选库

下列库在 Android 仓库的 55 库清单中，但**尚未在当前 macOS → Android + Conan 2 流程中逐一验证**。Conan Center 有配方只代表可以尝试，不代表 Android 构建已经通过。

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

| 清单名 | Conan 包名 |
| --- | --- |
| libogg | `ogg` |
| libvorbis | `vorbis` |
| libopus | `opus` |
| libflac | `flac` |
| libsdl3 | `sdl` |
| icu | `icu` |
| libcurl | `libcurl` |
| libjpeg | `libjpeg` |

## 在 macOS 上使用

### 1. 安装 Conan 2

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install 'conan>=2,<3'
conan profile detect --force
```

### 2. 创建 Android 目标 profile

创建 `profiles/android-arm64-v8a`：

```ini
[settings]
os=Android
arch=armv8
compiler=clang
compiler.version=18
compiler.libcxx=c++_static
build_type=Release
os.api_level=28

[conf]
tools.android:ndk_path=/Users/you/Library/Android/sdk/ndk/27.3.13750724
```

`compiler.version` 要与 NDK 自带的 Clang 主版本一致；NDK r27 通常是 18，NDK r28 通常是 19。可以用下面的命令确认：

```bash
"$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/clang" --version
```

### 3. 安装单个库

```bash
conan install --requires=zlib/1.3.2 \
  -pr:h=profiles/android-arm64-v8a \
  -pr:b=default \
  --build=missing
```

- `-pr:h`：目标 Android profile。
- `-pr:b`：宿主 macOS profile；不指定时 Conan 可能无法正确找到宿主工具。
- `--build=missing`：没有匹配的二进制包时从源码构建。

### 4. 在 CMake 工程中消费

```bash
conan install . \
  --output-folder=build-android \
  -pr:h=profiles/android-arm64-v8a \
  -pr:b=default \
  --build=missing

cd build-android
cmake --preset conan-release
cmake --build --preset conan-release
```

具体 preset 名称取决于工程和 `build_type`；如果工程没有使用 `CMakePresets.json`，把 Conan 生成的 toolchain 传给 CMake 即可。

### 5. libevent 的 Android 额外配置

在已验证的 smoke 构建中，libevent 需要关闭 Android/Bionic 不实现的 `pthread_cancel` 探测：

```bash
conan install --requires=libevent/2.1.12 \
  -pr:h=profiles/android-arm64-v8a \
  -pr:b=default \
  --build=missing \
  -c:h 'tools.cmake.cmaketoolchain:extra_variables={"CMAKE_HAVE_LIBC_PTHREAD": True}'
```

这不是所有 Conan 配方都需要；只在对应库的 CMake 探测报错时使用。

## 已知限制

- Conan Center 的配方可能只在 Linux/Windows 上验证过；`os=Android` 能配置成功，不代表源码一定能编译。
- `libuv` 使用 API 28；低于 28 会遇到缺少系统接口的问题。
- `libevent` 在 Android 上可能需要 `CMAKE_HAVE_LIBC_PTHREAD=True`。
- `ffmpeg`、`opencv`、`boost`、`protobuf`、`abseil`、`icu`、`libiconv`、`sdl`、`openal-soft`、`openh264`、`libvpx` 等实验库依赖多、可选 feature 多，必须逐库固定 options 和版本。
- `abseil` 新版本要求较新的 NDK；使用前先确认 NDK 版本。
- `oboe` 只适用于 Android；不要放进 iOS/macOS profile。
- `vulkan-headers` 是 header-only；运行时仍需要 NDK 的 `libvulkan.so` 或项目自己的 Vulkan 实现。
- `gtest`、`catch2`、`benchmark` 可以交叉编译，但通常不能在 Android 设备上运行；应只作为构建期依赖。
- `compiler.libcxx` 必须和最终 App 的 STL 选择一致；不要在同一次链接中混用 `c++_static` 和 `c++_shared`。
- macOS 上没有 Android 设备时只能验证编译和归档架构，不能替代真机运行测试。

## 建议的验证顺序

1. 先验证 10 个已通过库，确认 profile、NDK、API 和 STL 配置正确。
2. 再按依赖关系验证稳定候选：压缩/图像 → 字体/文本 → 网络 → 音频。
3. 最后验证 experimental 库；每个库固定 ABI、API、options 和静态/动态链接方式。
4. 对每个产物用 NDK `llvm-readelf` 检查架构，例如 arm64 必须是 `AArch64`。
