# vcpkg：macOS 宿主编译 Android C/C++ 库

> 范围：**宿主 macOS → 目标 Android**。只讨论 C/C++ 依赖库的交叉编译，不包含 APK、Java/Kotlin 或 Android 应用层构建。
> 同一套 vcpkg 也能在 macOS 上编译 iOS/macOS 库，但不在本页范围内。

## 结论

- vcpkg 官方支持 macOS 宿主交叉编译 Android，提供 Android triplet。
- 官方 Android triplet 默认 **API 28**。
- 关联的 Android 仓库在 macOS runner 上对 **10 个常用库**、`arm64-v8a`、API 28 做了实际编译验证。
- 其余清单库只能算“有 port、可作为候选”，不能仅凭包名视为已经支持 Android。

## 支持的 Android target

| Android ABI | vcpkg triplet | 支持情况 |
| --- | --- | --- |
| `arm64-v8a` | `arm64-android` | 官方 CI 测试，推荐用于真机 |
| `armeabi-v7a` | `arm-neon-android` | 官方 CI 测试；NEON 开启 |
| `armeabi-v7a` | `arm-android` | 社区 triplet；NEON 关闭，仅兼容旧设备 |
| `x86_64` | `x64-android` | 官方 CI 测试，用于 x86_64 模拟器 |
| `x86` | `x86-android` | 社区 triplet，仅用于很旧的模拟器 |
| `armeabi` | `armv6-android` | 不推荐；现代 NDK 已基本淘汰 |

vcpkg 的 Android triplet 默认生成静态库：

```cmake
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Android)
set(VCPKG_CMAKE_SYSTEM_VERSION 28)
```

需要其他 API level 时，不要直接改 vcpkg 安装目录，建议使用 overlay triplet，例如 `arm64-android-api21.cmake`。

## macOS 主机要求

- macOS 13 或更高版本；Apple Silicon / Intel 均可。
- Xcode Command Line Tools（`xcode-select --install`）。
- CMake、Ninja、Git、curl、zip、tar。
- Android NDK，建议 r27 或更高版本：

```bash
export ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/27.3.13750724"
```

- 宿主机还需要可用的 C/C++ 编译器，用于构建 vcpkg 的 host tools。
- 不要把 `ANDROID_NDK_HOME` 指向 SDK 根目录，必须指向具体的 NDK 目录。

## 已验证的库

以下 10 个库在 macOS → Android `arm64-v8a` / API 28 上通过 vcpkg 实际编译：

| 库 | vcpkg port | 备注 |
| --- | --- | --- |
| zlib | `zlib` | 无 |
| zstd | `zstd` | 无 |
| libpng | `libpng` | 无 |
| openssl | `openssl` | 无 |
| sqlite3 | `sqlite3` | 无 |
| libcurl | `curl` | vcpkg port 名是 `curl` |
| libuv | `libuv` | 需要 API 28+ |
| libssh2 | `libssh2` | 无 |
| c-ares | `c-ares` | 无 |
| libevent | `libevent` | 无 |

验证记录：

- Linux 宿主 10 库 × 3 后端，30/30 通过：
  https://github.com/edidada/android_c_cpp_library/actions/runs/40522088051
- macOS 宿主 10 库矩阵（vcpkg / Conan / xmake）：
  https://github.com/edidada/android_c_cpp_library/actions/runs/40522088283
- 构建报告：
  https://github.com/edidada/android_c_cpp_library/blob/main/docs/android-support/common10-build.md

验证环境：macOS 14 arm64 runner、NDK r27d、`arm64-v8a` / API 28。

## 清单内其他候选库

下列库在 Android 仓库的 55 库清单中，但**尚未在当前 macOS → Android + vcpkg 流程中逐一验证**。它们大多数有 vcpkg port，能否成功取决于依赖、feature、ABI 和 API。

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

| 清单名 | vcpkg port |
| --- | --- |
| libjpeg | `libjpeg-turbo`（vcpkg 没有独立的 `libjpeg` port） |
| libcurl | `curl` |
| libopus | `opus` |
| libvorbis | `libvorbis` |
| libflac | `flac` |
| libsdl3 | `sdl3` |
| libjpeg-turbo | `libjpeg-turbo` |
| oboe | `oboe`（仅 Android） |

## 在 macOS 上使用

### 方式一：内置 triplet

```bash
export ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/27.3.13750724"
export VCPKG_ROOT="$HOME/vcpkg"

"$VCPKG_ROOT/vcpkg" install zlib:arm64-android --classic
"$VCPKG_ROOT/vcpkg" install libevent:arm64-android --classic
```

### 方式二：固定 API level 的 overlay triplet

创建 `triplets/arm64-android-api28.cmake`：

```cmake
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Android)
set(VCPKG_CMAKE_SYSTEM_VERSION 28)
set(VCPKG_BUILD_TYPE release)
set(VCPKG_CMAKE_CONFIGURE_OPTIONS -DANDROID_ABI=arm64-v8a)
set(VCPKG_MAKE_BUILD_TRIPLET --host=aarch64-linux-android)
```

安装：

```bash
"$VCPKG_ROOT/vcpkg" install zlib:arm64-android-api28 \
  --overlay-triplets=triplets \
  --classic
```

### 在 CMake 工程中消费

```bash
cmake -S . -B build-android \
  -DCMAKE_TOOLCHAIN_FILE="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" \
  -DVCPKG_TARGET_TRIPLET=arm64-android \
  -DVCPKG_CHAINLOAD_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-28
cmake --build build-android
```

## 已知限制

- vcpkg 顶层的 `supports` 只判断当前 port 是否允许该平台，**不保证依赖和默认 features 都能在 Android 上构建**。
- `oboe` 只支持 Android；不要放进 iOS/macOS 目标。
- `libjpeg` 在 vcpkg 中应使用 `libjpeg-turbo`。
- `ffmpeg`、`opencv`、`libsdl3`、`openal-soft`、`icu`、`libiconv`、`libvpx`、`openh264` 等库依赖多、平台分支多，必须逐库验证 feature 和链接方式。
- `vulkan-headers` 本身是 header-only；运行时仍需要 NDK 提供的 `libvulkan.so` 或项目自己的 Vulkan 实现。
- `gtest`、`catch2`、`benchmark` 可以交叉编译，但通常不能在 Android 设备上直接运行；应只作为构建期依赖。
- 在 Apple Silicon 上构建 Android 库时，vcpkg 仍可能调用宿主工具；NDK 的 host tag 通常是 `darwin-x86_64`，由 NDK 自身处理。
- vcpkg 不会自动把 `ANDROID_NDK_HOME` 写进最终产物；消费方仍需在 CMake/NDK 配置中指定相同的 ABI 和 API。

## 建议的验证顺序

1. 先验证 10 个已通过库，确认 NDK、API、triplet 和链接方式正确。
2. 再按依赖关系验证稳定候选：压缩/图像 → 字体/文本 → 网络 → 音频。
3. 最后验证 experimental 库；每个库固定 ABI、API、feature 和静态/动态链接方式。
4. 对每个产物用 NDK `llvm-readelf` 检查架构，例如 arm64 必须是 `AArch64`。
