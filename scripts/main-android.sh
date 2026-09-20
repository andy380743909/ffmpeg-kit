#!/bin/bash

if [[ -z ${ARCH} ]]; then
  echo -e "\n(*) ARCH not defined\n"
  exit 1
fi

if [[ -z ${API} ]]; then
  echo -e "\n(*) API not defined\n"
  exit 1
fi

if [[ -z ${BASEDIR} ]]; then
  echo -e "\n(*) BASEDIR not defined\n"
  exit 1
fi

if [[ -z ${TOOLCHAIN} ]]; then
  echo -e "\n(*) TOOLCHAIN not defined\n"
  exit 1
fi

if [[ -z ${TOOLCHAIN_ARCH} ]]; then
  echo -e "\n(*) TOOLCHAIN_ARCH not defined\n"
  exit 1
fi

echo -e "\nBuilding ${ARCH} platform on API level ${API}\n"
echo -e "\nINFO: Starting new build for ${ARCH} on API level ${API} at $(date)\n" 1>>"${BASEDIR}"/build.log 2>&1

# SET BASE INSTALLATION DIRECTORY FOR THIS ARCHITECTURE
export LIB_INSTALL_BASE="${BASEDIR}/prebuilt/$(get_build_directory)"

# CREATE PACKAGE CONFIG DIRECTORY FOR THIS ARCHITECTURE
PKG_CONFIG_DIRECTORY="${LIB_INSTALL_BASE}/pkgconfig"
if [ ! -d "${PKG_CONFIG_DIRECTORY}" ]; then
  mkdir -p "${PKG_CONFIG_DIRECTORY}" || return 1
fi

# FILTER WHICH EXTERNAL LIBRARIES WILL BE BUILT
# NOTE THAT BUILT-IN LIBRARIES ARE FORWARDED TO FFMPEG SCRIPT WITHOUT ANY PROCESSING
enabled_library_list=()
for library in {1..50}; do
  if [[ ${!library} -eq 1 ]]; then
    ENABLED_LIBRARY=$(get_library_name $((library - 1)))
    enabled_library_list+=(${ENABLED_LIBRARY})

    echo -e "INFO: Enabled library ${ENABLED_LIBRARY} will be built\n" 1>>"${BASEDIR}"/build.log 2>&1
  fi
done

# BUILD LTS SUPPORT LIBRARY FOR API < 18
if [[ -n ${FFMPEG_KIT_LTS_BUILD} ]] && [[ ${API} -lt 18 ]]; then
  build_android_lts_support
fi

# BUILD ENABLED LIBRARIES AND THEIR DEPENDENCIES
let completed=0

# keep-going 模式（FFMPEG_KIT_KEEP_GOING=1）：某个库失败时不再 exit 1，而是记下它、
# 把它标成「已完成」让依赖它的库继续跑，最后一次性列出本轮所有失败的库。
# 起因：`-d --lts --full --enable-gpl` 实际启用 52 个库，而默认的「第一个失败就退」
# 意味着「还剩多少个没验证过的库」就等于「还要烧多少轮 CI」。本仓当前有 26 个库
# 从未构建过（见 build-logs 的取证），一轮一轮试是不可接受的。
FFMPEG_KIT_KEEP_GOING_FAILURES=""
FFMPEG_KIT_UNSUPPORTED_LIBRARIES=""
# 用来探测「这一轮有没有任何进展」，见循环末尾的收敛判据。
let FFMPEG_KIT_LAST_COMPLETED=-1
while [ ${#enabled_library_list[@]} -gt $completed ]; do
  for library in "${enabled_library_list[@]}"; do
    let run=0
    case $library in
    fontconfig)
      if [[ $OK_libuuid -eq 1 ]] && [[ $OK_expat -eq 1 ]] && [[ $OK_libiconv -eq 1 ]] && [[ $OK_freetype -eq 1 ]]; then
        run=1
      fi
      ;;
    freetype)
      if [[ $OK_libpng -eq 1 ]]; then
        run=1
      fi
      ;;
    gnutls)
      if [[ $OK_nettle -eq 1 ]] && [[ $OK_gmp -eq 1 ]] && [[ $OK_libiconv -eq 1 ]]; then
        run=1
      fi
      ;;
    harfbuzz)
      if [[ $OK_fontconfig -eq 1 ]] && [[ $OK_freetype -eq 1 ]]; then
        run=1
      fi
      ;;
    lame)
      if [[ $OK_libiconv -eq 1 ]]; then
        run=1
      fi
      ;;
    leptonica)
      if [[ $OK_giflib -eq 1 ]] && [[ $OK_jpeg -eq 1 ]] && [[ $OK_libpng -eq 1 ]] && [[ $OK_tiff -eq 1 ]] && [[ $OK_libwebp -eq 1 ]]; then
        run=1
      fi
      ;;
    libass)
      if [[ $OK_libuuid -eq 1 ]] && [[ $OK_expat -eq 1 ]] && [[ $OK_libiconv -eq 1 ]] && [[ $OK_freetype -eq 1 ]] && [[ $OK_fribidi -eq 1 ]] && [[ $OK_fontconfig -eq 1 ]] && [[ $OK_libpng -eq 1 ]] && [[ $OK_harfbuzz -eq 1 ]]; then
        run=1
      fi
      ;;
    libtheora)
      if [[ $OK_libvorbis -eq 1 ]] && [[ $OK_libogg -eq 1 ]]; then
        run=1
      fi
      ;;
    libvorbis)
      if [[ $OK_libogg -eq 1 ]]; then
        run=1
      fi
      ;;
    libvpx)
      if [[ $OK_cpu_features -eq 1 ]]; then
        run=1
      fi
      ;;
    libwebp)
      if [[ $OK_giflib -eq 1 ]] && [[ $OK_jpeg -eq 1 ]] && [[ $OK_libpng -eq 1 ]] && [[ $OK_tiff -eq 1 ]]; then
        run=1
      fi
      ;;
    libxml2)
      if [[ $OK_libiconv -eq 1 ]]; then
        run=1
      fi
      ;;
    nettle)
      if [[ $OK_gmp -eq 1 ]]; then
        run=1
      fi
      ;;
    openh264)
      if [[ $OK_cpu_features -eq 1 ]]; then
        run=1
      fi
      ;;
    rubberband)
      if [[ $OK_libsndfile -eq 1 ]] && [[ $OK_libsamplerate -eq 1 ]]; then
        run=1
      fi
      ;;
    srt)
      if [[ $OK_openssl -eq 1 ]]; then
        run=1
      fi
      ;;
    tesseract)
      if [[ $OK_leptonica -eq 1 ]]; then
        run=1
      fi
      ;;
    tiff)
      if [[ $OK_jpeg -eq 1 ]]; then
        run=1
      fi
      ;;
    twolame)
      if [[ $OK_libsndfile -eq 1 ]]; then
        run=1
      fi
      ;;
    *)
      run=1
      ;;
    esac

    # DEFINE SOME FLAGS TO MANAGE DEPENDENCIES AND REBUILD OPTIONS
    BUILD_COMPLETED_FLAG=$(echo "OK_${library}" | sed "s/\-/\_/g")
    REBUILD_FLAG=$(echo "REBUILD_${library}" | sed "s/\-/\_/g")
    DEPENDENCY_REBUILT_FLAG=$(echo "DEPENDENCY_REBUILT_${library}" | sed "s/\-/\_/g")
    # 「本架构不支持」必须有一个**独立于 OK_**的旗标：它不能让 OK_ 成立（依赖它的库
    # 要能被跳过），但又必须让 while 循环不再重复处理它。详见下面 RC=200 的分支。
    UNSUPPORTED_FLAG=$(echo "UNSUPPORTED_${library}" | sed "s/\-/\_/g")

    if [[ $run -eq 1 ]] && [[ "${!BUILD_COMPLETED_FLAG}" != "1" ]] && [[ "${!UNSUPPORTED_FLAG}" != "1" ]]; then
      LIBRARY_IS_INSTALLED=$(library_is_installed "${LIB_INSTALL_BASE}" "${library}")

      echo -e "INFO: Flags detected for ${library}: already installed=${LIBRARY_IS_INSTALLED}, rebuild requested by user=${!REBUILD_FLAG}, will be rebuilt due to dependency update=${!DEPENDENCY_REBUILT_FLAG}\n" 1>>"${BASEDIR}"/build.log 2>&1

      # CHECK IF BUILD IS NECESSARY OR NOT
      if [[ ${LIBRARY_IS_INSTALLED} -ne 1 ]] || [[ ${!REBUILD_FLAG} -eq 1 ]] || [[ ${!DEPENDENCY_REBUILT_FLAG} -eq 1 ]]; then

        echo -n "${library}: "

        "${BASEDIR}"/scripts/run-android.sh "${library}" 1>>"${BASEDIR}"/build.log 2>&1

        RC=$?

        # SET SOME FLAGS AFTER THE BUILD
        if [ $RC -eq 0 ]; then
          ((completed += 1))
          declare "$BUILD_COMPLETED_FLAG=1"
          check_if_dependency_rebuilt "${library}"
          echo "ok"
        elif [ $RC -eq 200 ]; then
          # 「本架构不支持」是一条**永久**事实，不是一次失败。android 上只有 openssl
          # 会返回它（openssl.sh 对 x86 直接 `return 200`），所以：
          #
          #   · 绝不能设 OK_ —— 否则依赖它的库会以为依赖已满足。srt 的判据就是
          #     `[[ $OK_openssl -eq 1 ]]`；一旦被误设，srt 会在 x86 上被强行构建，
          #     然后必然死在 find_package(OpenSSL)（本仓 run #6 的实测）。
          #   · 也绝不能中止本轮。上游这里是 `exit 1`，代价是「x86 + openssl 这个
          #     组合根本产不出 AAR」；上游自己的绕法是给 Android 构建加
          #     `--disable-lib-srt`（见其 periodic-builds-android.yml），那是绕过症状
          #     而不是修复 —— 代价是 arm64 / x86-64 上连 srt 一起失去。
          #   · 但要防重复处理（while 的条件是 completed 数），所以标一个独立的
          #     UNSUPPORTED_ 旗标并推进 completed。
          ((completed += 1))
          declare "$UNSUPPORTED_FLAG=1"
          FFMPEG_KIT_UNSUPPORTED_LIBRARIES+="${library} "
          echo -e "not supported\n\nSee build.log for details\n"
          echo -e "INFO: ${library} is not supported on ${ARCH}, skipping it (its dependents will be skipped too)\n" 1>>"${BASEDIR}"/build.log 2>&1
        elif [ -n "${FFMPEG_KIT_KEEP_GOING}" ]; then
          # 记下失败，并把它标成「已完成」——「失败」是暂时的（修好就过），标了才能让
          # 依赖它的库继续跑，一轮把整条链上的问题全暴露出来。标旗也才能推进 while
          # 循环、不至于死循环。
          ((completed += 1))
          declare "$BUILD_COMPLETED_FLAG=1"
          FFMPEG_KIT_KEEP_GOING_FAILURES+="${library} "
          echo -e "failed\n\nSee build.log for details\n"
          echo -e "INFO: [keep-going] ${library} failed (rc=${RC}), continuing with the remaining libraries\n" 1>>"${BASEDIR}"/build.log 2>&1
        else
          echo -e "failed\n\nSee build.log for details\n"
          exit 1
        fi
      else
        ((completed += 1))
        declare "$BUILD_COMPLETED_FLAG=1"
        echo "${library}: already built"
      fi
    else
      echo -e "INFO: Skipping $library, dependencies built=$run, already built=${!BUILD_COMPLETED_FLAG}\n" 1>>"${BASEDIR}"/build.log 2>&1
    fi
  done

  # ⚠️ 收敛判据：一轮下来一个库都没能推进 ⇒ 剩下的全是「依赖在本架构上不可用」
  #    （x86 上的 srt 之于 openssl 就是这一类），再转一圈不会改变任何东西。
  #    没有这一条 while 会永远空转 —— 因为 completed 只在真正处理过某个库时才 +1，
  #    而「依赖不可用」的库永远不会被处理。
  if [ $completed -eq $FFMPEG_KIT_LAST_COMPLETED ]; then
    echo -e "INFO: No progress in this pass; the remaining libraries have unavailable dependencies\n" 1>>"${BASEDIR}"/build.log 2>&1
    break
  fi
  FFMPEG_KIT_LAST_COMPLETED=$completed
done

# BUILD CUSTOM LIBRARIES
for custom_library_index in "${CUSTOM_LIBRARIES[@]}"; do
  library_name="CUSTOM_LIBRARY_${custom_library_index}_NAME"

  echo -e "\nDEBUG: Custom library ${!library_name} will be built\n" 1>>"${BASEDIR}"/build.log 2>&1

  # DEFINE SOME FLAGS TO REBUILD OPTIONS
  REBUILD_FLAG=$(echo "REBUILD_${!library_name}" | sed "s/\-/\_/g")
  LIBRARY_IS_INSTALLED=$(library_is_installed "${LIB_INSTALL_BASE}" "${!library_name}")

  echo -e "INFO: Flags detected for custom library ${!library_name}: already installed=${LIBRARY_IS_INSTALLED}, rebuild requested by user=${!REBUILD_FLAG}\n" 1>>"${BASEDIR}"/build.log 2>&1

  if [[ ${LIBRARY_IS_INSTALLED} -ne 1 ]] || [[ ${!REBUILD_FLAG} -eq 1 ]]; then

    echo -n "${!library_name}: "

    "${BASEDIR}"/scripts/run-android.sh "${!library_name}" 1>>"${BASEDIR}"/build.log 2>&1

    RC=$?

    # SET SOME FLAGS AFTER THE BUILD
    if [ $RC -eq 0 ]; then
      echo "ok"
    elif [ $RC -eq 200 ]; then
      echo -e "not supported\n\nSee build.log for details\n"
      exit 1
    else
      echo -e "failed\n\nSee build.log for details\n"
      exit 1
    fi
  else
    echo "${!library_name}: already built"
  fi
done

# 报告两类「没设 OK_」的库。它们必须被显式说出来 —— 静默就等于凭空消失了几个库。
#   · 本架构不支持（openssl on x86）：这是 by design 的缺席。
#   · 因依赖不可用而没跑（srt on x86）：上游对这种情况是直接 exit 1，所以从没有人
#     见过它长什么样；在我们的语义下它必须出现在结论里，否则「52 个库全绿」这句话
#     会被误读成「52 个库都构建了」。
if [[ -n "${FFMPEG_KIT_UNSUPPORTED_LIBRARIES}" ]]; then
  echo -e "\nUNSUPPORTED_LIBRARIES: ${ARCH} -> ${FFMPEG_KIT_UNSUPPORTED_LIBRARIES}\n"
  echo -e "INFO: [build] not supported on ${ARCH}: ${FFMPEG_KIT_UNSUPPORTED_LIBRARIES}\n" 1>>"${BASEDIR}"/build.log 2>&1
fi

FFMPEG_KIT_SKIPPED_LIBRARIES=""
for library in "${enabled_library_list[@]}"; do
  SKIPPED_COMPLETED_FLAG=$(echo "OK_${library}" | sed "s/\-/\_/g")
  SKIPPED_UNSUPPORTED_FLAG=$(echo "UNSUPPORTED_${library}" | sed "s/\-/\_/g")
  if [[ "${!SKIPPED_COMPLETED_FLAG}" != "1" ]] && [[ "${!SKIPPED_UNSUPPORTED_FLAG}" != "1" ]]; then
    FFMPEG_KIT_SKIPPED_LIBRARIES+="${library} "
  fi
done
if [[ -n "${FFMPEG_KIT_SKIPPED_LIBRARIES}" ]]; then
  echo -e "\nSKIPPED_LIBRARIES: ${ARCH} -> ${FFMPEG_KIT_SKIPPED_LIBRARIES}\n"
  echo -e "INFO: [build] skipped on ${ARCH} (dependency unavailable): ${FFMPEG_KIT_SKIPPED_LIBRARIES}\n" 1>>"${BASEDIR}"/build.log 2>&1
fi

# keep-going 模式：有**真失败**时不要再往下建 ffmpeg —— 缺库时它必然失败，几百行
# configure 噪音只会把结论淹掉。直接在这一趟收工，把清单交出去。
# （注意判据只看真失败：只有「不支持」时应当继续，否则 x86 永远走不到 ffmpeg。）
if [[ -n "${FFMPEG_KIT_KEEP_GOING_FAILURES}" ]]; then
  echo -e "\nKEEP_GOING_FAILED_LIBRARIES: ${FFMPEG_KIT_KEEP_GOING_FAILURES}\n"
  echo -e "INFO: [keep-going] failed libraries on ${ARCH} (API ${API}): ${FFMPEG_KIT_KEEP_GOING_FAILURES}\n" 1>>"${BASEDIR}"/build.log 2>&1

  # ⚠️ 用 return 而不是 exit：本脚本由 android.sh 以 `. scripts/main-android.sh` 引入，
  # exit 会把 android.sh 一起终止。return 让外层的 `|| exit 1` 拿到非零 rc。
  return 1 2>/dev/null || exit 1
fi

# SKIP TO SPEED UP THE BUILD
if [[ ${SKIP_ffmpeg} -ne 1 ]]; then

  # BUILD FFMPEG
  source "${BASEDIR}"/scripts/android/ffmpeg.sh

  if [[ $? -ne 0 ]]; then
    exit 1
  fi
else
  echo -e "\nffmpeg: skipped"
fi

echo -e "\nINFO: Completed build for ${ARCH} on API level ${API} at $(date)\n" 1>>"${BASEDIR}"/build.log 2>&1
