#!/bin/bash

# ALWAYS CLEAN THE PREVIOUS BUILD
git clean -dfx 2>/dev/null 1>/dev/null

# OVERRIDE SYSTEM PROCESSOR
SYSTEM_PROCESSOR=""
case ${ARCH} in
arm-v7a | arm-v7a-neon)
  SYSTEM_PROCESSOR="armv7-a"
  ;;
arm64-v8a)
  SYSTEM_PROCESSOR="aarch64"
  ;;
x86)
  SYSTEM_PROCESSOR="i686"
  ;;
x86-64)
  SYSTEM_PROCESSOR="x86_64"
  ;;
esac

# WORKAROUND TO GENERATE BASE BUILD FILES
./configure || echo "" 2>/dev/null 1>/dev/null

# ⚠️ CMAKE_SYSTEM_VERSION 必须夹到 21，不能直接用 ${API}（LTS 构建里是 16）。
#
# 本脚本是全仓唯一设 CMAKE_SYSTEM_NAME=Android 的库脚本，这会走 CMake **内置**的
# Android 平台支持（Modules/Platform/Android-Determine.cmake），而那条路对 API
# 级别的检查是**硬失败**（不是抬升）：
#
#   CMake Error at .../Modules/Platform/Android-Determine.cmake:502 (message):
#     Android: The API level 16 is not supported by the NDK.
#     Choose one in the range of [21, 35].
#
# 注意别跟 NDK 自带的 toolchain 混淆：NDK 的 build/cmake/adjust_api_level.cmake
# 对过低的 API 只打一条 STATUS 并把值抬到 NDK_MIN_PLATFORM_LEVEL（我们已核对过
# 源码），所以「ndk-build 能把 APP_PLATFORM 从 android-16 抬到 android-21」这条
# 经验**不适用于** CMake 的 Android 平台路径。其它库脚本用
# CMAKE_SYSTEM_NAME=Generic，压根不触发这项校验，因此只有 srt 会中招。
#
# 夹到 21 与全项目实际使用的 API 一致：编译器 wrapper 本身就是
# get_toolchain_clang_api() 算出来的（...androideabi21-clang），ndk-build 也会把
# APP_PLATFORM 抬到 21。所以这里不是特例，而是把它对齐到既有事实。
cmake -Wno-dev \
 -DUSE_ENCLIB=openssl \
 -DCMAKE_VERBOSE_MAKEFILE=0 \
 -DCMAKE_C_FLAGS="${CFLAGS}" \
 -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
 -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}" \
 -DCMAKE_SYSROOT="${ANDROID_SYSROOT}" \
 -DCMAKE_FIND_ROOT_PATH="${ANDROID_SYSROOT}" \
 -DCMAKE_BUILD_TYPE=Release \
 -DCMAKE_INSTALL_PREFIX="${LIB_INSTALL_PREFIX}" \
 -DCMAKE_SYSTEM_NAME=Android \
 -DCMAKE_SYSTEM_VERSION=$(get_toolchain_clang_api) \
 -DCMAKE_ANDROID_NDK=${ANDROID_NDK_ROOT} \
 -DCMAKE_CXX_COMPILER="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/${TOOLCHAIN}/bin/$CXX" \
 -DCMAKE_C_COMPILER="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/${TOOLCHAIN}/bin/$CC" \
 -DCMAKE_LINKER="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/${TOOLCHAIN}/bin/$LD" \
 -DCMAKE_AR="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/${TOOLCHAIN}/bin/$AR" \
 -DCMAKE_AS="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/${TOOLCHAIN}/bin/$AS" \
 -DCMAKE_SYSTEM_LOADED=1 \
 -DCMAKE_SYSTEM_PROCESSOR="${SYSTEM_PROCESSOR}" \
 -DENABLE_STDCXX_SYNC=1 \
 -DENABLE_MONOTONIC_CLOCK=1 \
 -DENABLE_STDCXX_SYNC=1 \
 -DENABLE_CXX11=1 \
 -DUSE_OPENSSL_PC=1 \
 -DENABLE_DEBUG=0 \
 -DENABLE_LOGGING=0 \
 -DENABLE_HEAVY_LOGGING=0 \
 -DENABLE_APPS=0 \
 -DENABLE_SHARED=0 "${BASEDIR}"/src/"${LIB_NAME}" || return 1

make -j$(get_cpu_count) || return 1

make install || return 1

# CREATE PACKAGE CONFIG MANUALLY
create_srt_package_config "1.5.2" || return 1