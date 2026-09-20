#!/bin/bash

# INIT SUBMODULES
${SED_INLINE} 's|openssl/openssl|arthenica/openssl|g' "${BASEDIR}"/src/"${LIB_NAME}"/.gitmodules || return 1
${SED_INLINE} 's|tomato42|arthenica|g' "${BASEDIR}"/src/"${LIB_NAME}"/.gitmodules || return 1
${SED_INLINE} 's|warner|arthenica|g' "${BASEDIR}"/src/"${LIB_NAME}"/.gitmodules || return 1
${SED_INLINE} 's|gitlab.com/libidn/gnulib-mirror|github.com/arthenica/gnulib|g' "${BASEDIR}"/src/"${LIB_NAME}"/.gitmodules || return 1
${SED_INLINE} 's|gitlab.com/gnutls/libtasn1|github.com/arthenica/libtasn1|g' "${BASEDIR}"/src/"${LIB_NAME}"/.gitmodules || return 1
${SED_INLINE} 's|gitlab.com/gnutls/nettle|github.com/arthenica/nettle|g' "${BASEDIR}"/src/"${LIB_NAME}"/.gitmodules || return 1
${SED_INLINE} 's|gitlab.com/gnutls/abi-dump|github.com/arthenica/abi-dump|g' "${BASEDIR}"/src/"${LIB_NAME}"/.gitmodules || return 1
${SED_INLINE} 's|gitlab.com/gnutls/cligen|github.com/arthenica/cligen|g' "${BASEDIR}"/src/"${LIB_NAME}"/.gitmodules || return 1
${SED_INLINE} 's|gitlab.com/redhat-crypto/tests/interop|github.com/arthenica/redhat-crypto-tests-interop|g' "${BASEDIR}"/src/"${LIB_NAME}"/.gitmodules || return 1

# UPDATE BUILD FLAGS
export CFLAGS="$(get_cflags ${LIB_NAME}) -I${LIB_INSTALL_BASE}/libiconv/include"
export CXXFLAGS=$(get_cxxflags "${LIB_NAME}")
export LDFLAGS="$(get_ldflags ${LIB_NAME}) -L${LIB_INSTALL_BASE}/libiconv/lib"

export NETTLE_CFLAGS="-I${LIB_INSTALL_BASE}/nettle/include"
export NETTLE_LIBS="-L${LIB_INSTALL_BASE}/nettle/lib -lnettle -L${LIB_INSTALL_BASE}/gmp/lib -lgmp"
export HOGWEED_CFLAGS="-I${LIB_INSTALL_BASE}/nettle/include"
export HOGWEED_LIBS="-L${LIB_INSTALL_BASE}/nettle/lib -lhogweed -L${LIB_INSTALL_BASE}/gmp/lib -lgmp"
export GMP_CFLAGS="-I${LIB_INSTALL_BASE}/gmp/include"
export GMP_LIBS="-L${LIB_INSTALL_BASE}/gmp/lib -lgmp"

# SET BUILD OPTIONS
ASM_OPTIONS=""
case ${ARCH} in
x86)
  ASM_OPTIONS="--disable-hardware-acceleration"
  ;;
*)
  ASM_OPTIONS="--enable-hardware-acceleration"
  ;;
esac

# ALWAYS CLEAN THE PREVIOUS BUILD
make distclean 2>/dev/null 1>/dev/null

# REGENERATE BUILD FILES IF NECESSARY OR REQUESTED
if [[ ! -f "${BASEDIR}"/src/"${LIB_NAME}"/configure ]] || [[ ${RECONF_gnutls} -eq 1 ]]; then
  ./bootstrap --skip-po || return 1
  git submodule update --remote gnulib || return 1
  overwrite_file ./gnulib/lib/fpending.c ./src/gl/fpending.c || return 1
fi

# ⚠️ ac_cv_type_timezone_t=no —— 强制 gnulib 回到「自带 timezone_t 实现」的配置。
#
#    背景：gnulib 的 time_rz 模块用 `AC_CHECK_TYPES([timezone_t])` 只探测**类型**是否存在，
#    存在就认为「系统提供了整套 timezone_t API」，于是既不输出自己的 typedef/声明
#    （gnulib time.in.h: `#if defined _GNU_SOURCE && @GNULIB_TIME_RZ@ && ! @HAVE_TIMEZONE_T@`），
#    也不 AC_LIBOBJ([time_rz])（modules/time_rz）。
#
#    但 NDK r27+ 的 bionic 是不对称的：
#      · `typedef struct __timezone_t* timezone_t;`  —— 无条件声明，不分 API 级别（time.h:52）
#      · `mktime_z` / `tzalloc` / `tzfree` / `localtime_rz` 的声明被包在
#        `#if __BIONIC_AVAILABILITY_GUARD(35)` 里，符号也只在 API 35+ 的 libc 里导出
#        （已逐级核对：API 21–34 全无，35 才有）。
#    ⇒ 定向到 < 35 时：gnulib 以为系统有实现（不编译自己的 time_rz.c），而调用点却找不到
#      任何声明 ⇒ `call to undeclared function 'mktime_z'`（clang 19 下是 error）。
#
#    若只把该错误降级为警告，产物会带上对 API 35 才存在的符号的引用，在老设备上
#    dlopen 直接失败 —— 正是本仓库在消灭的那一类崩溃。所以必须让 gnulib 自带实现。
#
#    HAVE_TIMEZONE_T=0 会同时打开 gnulib 的条件依赖（flexmember / idx / setenv / stdbool /
#    time_r / timegm / tzset / unsetenv），这些文件都已在 src/gl/ 里；time_rz.c 需要的
#    系统符号（setenv / unsetenv / timegm / localtime_r / tzset / mktime）在 API 21 就全部存在。
#    配套的 `-D__timezone_t=tm_zone`（见 function-android.sh 的 gnutls 分支）用来避开
#    bionic 那个无条件的 typedef 与 gnulib 自己的 `typedef struct tm_zone *timezone_t;`
#    之间的「不同型重定义」硬错误。
ac_cv_type_timezone_t=no \
./configure \
  --prefix="${LIB_INSTALL_PREFIX}" \
  --with-pic \
  --with-sysroot="${ANDROID_SYSROOT}" \
  --with-included-libtasn1 \
  --with-included-unistring \
  --without-idn \
  --without-p11-kit \
  ${ASM_OPTIONS} \
  --enable-static \
  --disable-openssl-compatibility \
  --disable-shared \
  --disable-fast-install \
  --disable-code-coverage \
  --disable-doc \
  --disable-manpages \
  --disable-guile \
  --disable-tests \
  --disable-tools \
  --disable-maintainer-mode \
  --disable-full-test-suite \
  --host="${HOST}" || return 1

make -j$(get_cpu_count) || return 1

make install || return 1

# CREATE PACKAGE CONFIG MANUALLY
create_gnutls_package_config "3.7.9" || return 1
