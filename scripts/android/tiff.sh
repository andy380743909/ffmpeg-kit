#!/bin/bash

# ALWAYS CLEAN THE PREVIOUS BUILD
make distclean 2>/dev/null 1>/dev/null

# REGENERATE BUILD FILES IF NECESSARY OR REQUESTED
if [[ ! -f "${BASEDIR}"/src/"${LIB_NAME}"/configure ]] || [[ ${RECONF_tiff} -eq 1 ]]; then
  autoreconf_library "${LIB_NAME}" 1>>"${BASEDIR}"/build.log 2>&1 || return 1
fi

# ⚠️ 强制关掉 HAVE_FSEEKO。这一条只影响一个**用不到的**工具（tools/tiff2pdf.c），
#    对产出的 libtiff.a 零影响 —— 判据是：全仓 `HAVE_FSEEKO` 只被 libtiff/tiffiop.h
#    用来定义 `#define fseek(...) fseeko(...)`，而该宏的唯一消费方是 tools/tiff2pdf.c
#    （已 grep：libtiff/*.c 一处未用）。
#
# 为什么必须关：在 ILP32（x86 / arm-v7a）上 autoconf 的 AC_SYS_LARGEFILE 会把
# `_FILE_OFFSET_BITS 64` **写进 config.h**，而 bionic 的 stdio.h 一旦看到
# __USE_FILE_OFFSET64 就走
#     `#if __BIONIC_AVAILABILITY_GUARD(24) ... fseeko ...`
# 这个分支 —— 而该守卫展开成 `__ANDROID_MIN_SDK_VERSION__ >= 24`，我们是 21 ⇒
# **fseeko 的声明被隐藏**（符号本身在 API 21 的 libc 里是有的，符号能用 ≠ 声明可见）。
#
# 而 autoconf 的探测（`AC_FUNC_FSEEKO`，CI 日志里的
# `checking for declarations of fseeko and ftello... yes`）**不带 config.h** 跑，
# 所以看到的是未守卫的 `#else` 分支 ⇒ 误判为「可用」。LP64（arm64 / x86-64）
# 上 off_t 本来就是 64 位、不需要那个宏，才没踩到。
#
# 不选「让它编译过」的修法：在 API < 24 且开了 LFS 时，bionic 的 `fseeko` 是**不带
# `__RENAME(fseeko64)`** 的旧原型（Bionic 到 API 24 才补上重命名），照着 64 位 off_t
# 去调它会打错 ABI。所以这里答「不可用」不仅是能让它编过，而且是唯一正确的答案。
# 附：两个 cache 变量名都要给 —— 2.70 起是 ac_cv_func_fseeko_ftello，更老的
# autoconf 用 ac_cv_func_fseeko。
./configure \
  ac_cv_func_fseeko_ftello=no \
  ac_cv_func_fseeko=no \
  --prefix="${LIB_INSTALL_PREFIX}" \
  --with-pic \
  --with-sysroot="${ANDROID_SYSROOT}" \
  --with-jpeg-include-dir="${LIB_INSTALL_BASE}"/jpeg/include \
  --with-jpeg-lib-dir="${LIB_INSTALL_BASE}"/jpeg/lib \
  --enable-static \
  --disable-shared \
  --disable-fast-install \
  --disable-maintainer-mode \
  --disable-cxx \
  --disable-win32-io \
  --disable-lzma \
  --host="${HOST}" || return 1

make -j$(get_cpu_count) || return 1

make install || return 1

# MANUALLY COPY PKG-CONFIG FILES
cp ./*.pc "${INSTALL_PKG_CONFIG_DIR}" || return 1
