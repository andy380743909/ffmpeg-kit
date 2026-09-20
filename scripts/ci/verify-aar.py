#!/usr/bin/env python3
"""
verify-aar.py —— ffmpeg-kit AAR 出厂验收：孤儿符号 + 16KB 页对齐。

为什么需要这个脚本
------------------
这份 AAR 曾被两类「构建期看不出来、运行时才炸」的问题咬过：

1. **孤儿未定义符号（orphan UND）**：`libavdevice.so` 里曾有 17 个
   `PLATFORM_hid_*` 强符号（binding=GLOBAL），源头上游是 SDL2 的 joystick
   HIDAPI 后端。ffmpeg 只要检测到 SDL2 就会给 libavdevice 编出 `sdl2` 输出设备
   （CONFIG_SDL2_OUTDEV），于是 libavdevice 静态链入 SDL2，而这些符号全包内无人
   提供。因为它带 `DT_FLAGS = SYMBOLIC|BIND_NOW`（立即绑定），`dlopen` 阶段就
   必须解析全部重定位 ⇒ 真机一启动就
   `dlopen failed: cannot locate symbol "PLATFORM_hid_write"`。
   **判据**：这些符号的 binding 必须是 WEAK（linker 对弱符号宽容）或者干脆不存在。
   构建时用 `--disable-lib-sdl` 从源头拔掉；本脚本负责事后证伪。

2. **16KB 页对齐**：16KB 页设备（Android 15+）要求 **64 位** .so 的每个 LOAD 段
   满足 `p_align >= 16384`（`0x4000`）。NDK r28 的 64 位预编译默认就是 `0x4000`。
   ⚠️ **判据必须分位宽**：32 位 .so 的 LOAD 段 `p_align` 常是 `0x4`/`0x5`/`0x6`
   —— 那是「无对齐约束」的合法写法（而且是 32 位构建的常态，现有 AAR 亦然），
   **不是** 4KB 对齐（那才写作 `0x1000`）；何况 16KB 页内核跑不了 AArch32，
   32 位库与这条要求无关。只看「所有 LOAD 的 p_align 最小值」会得到假阴性。

用法
----
    verify-aar.py <aar 或含 .so 的目录> [--prefix PLATFORM_] [--require-16k [ABI,...]]

退出码
------
    0 = 通过；1 = 有硬失败（孤儿强符号，或 --require-16k 指定的 ABI 未达 16KB）。
"""

import argparse
import struct
import sys
import zipfile
from pathlib import Path

SHN_UNDEF = 0
SHT_DYNSYM = 11
PT_LOAD = 1
STB_NAMES = {0: "LOCAL", 1: "GLOBAL", 2: "WEAK"}
PAGE_16K = 16384

# 每个 ABI 必须齐备的库（按**前缀**匹配）。用前缀而不是全名，是因为 armeabi-v7a
# 走的是另一套命名：libavcodec_neon.so / libffmpegkit_armv7a_neon.so。
# 判据来源：android/jni/ffmpeg/neon/Android.mk 与 android/jni/Android.mk 的
# LOCAL_MODULE —— 也就是「构建脚本打算产出什么」。
REQUIRED_SO_PREFIXES = (
    "libavcodec", "libavdevice", "libavfilter", "libavformat",
    "libavutil", "libswresample", "libswscale",
)
ALWAYS_REQUIRED_SO = ("libc++_shared.so", "libffmpegkit_abidetect.so")


def missing_required_so(so_names):
    """返回该 ABI 缺了哪些必备库（空列表 = 齐备）。

    为什么值得单独查：产物缺一个 .so 是**静默**的 —— Gradle 照常打 AAR，Java 侧
    直到运行时 loadLibrary 才炸，而且炸在用户手里。更麻烦的是，库脚本里任何一处
    「跳过」逻辑的 bug 都长成这样（本仓的 keep-going 就会跳过依赖不可用的库）。
    """
    lack = [p + "*.so" for p in REQUIRED_SO_PREFIXES
            if not any(n.startswith(p) for n in so_names)]
    lack += [n for n in ALWAYS_REQUIRED_SO if n not in so_names]
    # 实现库（64 位是 libffmpegkit.so，32 位 NEON 是 libffmpegkit_armv7a_neon.so）
    # 必须有一个，否则 FFmpegKitConfig 加载不到实现。
    if not any(n.startswith("libffmpegkit") and not n.startswith("libffmpegkit_abidetect")
               for n in so_names):
        lack.append("libffmpegkit*.so（实现库）")
    return lack


class NotElf(Exception):
    pass


class Elf:
    """只解析验收需要的三样东西：PT_LOAD 对齐、.dynsym、.dynstr。"""

    def __init__(self, data):
        if data[:4] != b"\x7fELF":
            raise NotElf("not an ELF file")
        self.data = data
        self.is64 = data[4] == 2
        self.e = "<" if data[5] == 1 else ">"
        d, e, is64 = data, self.e, self.is64
        if is64:
            self.phoff, = struct.unpack_from(e + "Q", d, 0x20)
            self.shoff, = struct.unpack_from(e + "Q", d, 0x28)
            self.phentsize, self.phnum = struct.unpack_from(e + "HH", d, 0x36)
            self.shentsize, self.shnum = struct.unpack_from(e + "HH", d, 0x3A)
        else:
            self.phoff, = struct.unpack_from(e + "I", d, 0x1C)
            self.shoff, = struct.unpack_from(e + "I", d, 0x20)
            self.phentsize, self.phnum = struct.unpack_from(e + "HH", d, 0x2A)
            self.shentsize, self.shnum = struct.unpack_from(e + "HH", d, 0x2E)
        if self.shnum == 0:
            raise NotElf("ELF 没有 section header table（无法解析 .dynsym）")

    def load_segments(self):
        """返回 [(p_offset, p_vaddr, p_align), ...]。"""
        out = []
        for i in range(self.phnum):
            p = self.phoff + i * self.phentsize
            p_type, = struct.unpack_from(self.e + "I", self.data, p)
            if p_type != PT_LOAD:
                continue
            if self.is64:
                off, vaddr, _pa, _fs, _ms, align = struct.unpack_from(
                    self.e + "QQQQQQ", self.data, p + 8)
            else:
                off, vaddr, _pa, _fs, _ms, align = struct.unpack_from(
                    self.e + "IIIIII", self.data, p + 4)
            out.append((off, vaddr, align))
        return out

    def _section(self, i):
        """返回 (sh_type, sh_offset, sh_size, sh_link, sh_entsize)。"""
        s = self.shoff + i * self.shentsize
        e, d, is64 = self.e, self.data, self.is64
        sh_type, = struct.unpack_from(e + "I", d, s + 4)
        if is64:
            sh_offset, sh_size = struct.unpack_from(e + "QQ", d, s + 0x18)
            sh_link, = struct.unpack_from(e + "I", d, s + 0x28)
            sh_entsize, = struct.unpack_from(e + "Q", d, s + 0x38)
        else:
            sh_offset, sh_size = struct.unpack_from(e + "II", d, s + 0x10)
            sh_link, = struct.unpack_from(e + "I", d, s + 0x18)
            sh_entsize, = struct.unpack_from(e + "I", d, s + 0x24)
        return sh_type, sh_offset, sh_size, sh_link, sh_entsize

    def dynsym(self):
        """产出 (name, bind, shndx)。"""
        for i in range(self.shnum):
            sh_type, sh_offset, sh_size, sh_link, sh_entsize = self._section(i)
            if sh_type != SHT_DYNSYM:
                continue
            _, str_off, str_size, _, _ = self._section(sh_link)
            strtab = self.data[str_off:str_off + str_size]
            # Elf64_Sym=24B: st_name(4) st_info(1) st_other(1) st_shndx(2) st_value(8) st_size(8)
            # Elf32_Sym=16B: st_name(4) st_value(4) st_size(4) st_info(1) st_other(1) st_shndx(2)
            info_at, shndx_at, size = (4, 6, 24) if self.is64 else (12, 14, 16)
            if sh_entsize:
                size = sh_entsize
            for off in range(sh_offset, sh_offset + sh_size - size + 1, size):
                st_name, = struct.unpack_from(self.e + "I", self.data, off)
                st_info = self.data[off + info_at]
                st_shndx, = struct.unpack_from(self.e + "H", self.data, off + shndx_at)
                if st_name >= len(strtab):
                    raise NotElf("st_name 越界（ELF 结构疑似损坏）")
                end = strtab.find(b"\0", st_name)
                name = strtab[st_name:end if end >= 0 else len(strtab)].decode(
                    "utf-8", "replace")
                yield name, st_info >> 4, st_shndx
            return
        raise NotElf("没有 .dynsym 段")


def iter_so(target):
    """产出 (abi, 显示名, 字节)。同时支持 .aar/.zip 与目录树。"""
    p = Path(target)
    if p.is_file() and zipfile.is_zipfile(p):
        with zipfile.ZipFile(p) as z:
            for n in sorted(z.namelist()):
                parts = n.split("/")
                if len(parts) == 3 and parts[0] == "jni" and n.endswith(".so"):
                    yield parts[1], parts[2], z.read(n)
    elif p.is_dir():
        for f in sorted(p.rglob("*.so")):
            yield f.parent.name, f.name, f.read_bytes()
    else:
        raise SystemExit("无法识别目标（既不是 zip/aar，也不是目录）：%s" % target)


def analyse(data, prefixes):
    elf = Elf(data)
    strong, weak, names = 0, 0, []
    for name, bind, shndx in elf.dynsym():
        if shndx != SHN_UNDEF:
            continue
        if not any(name.startswith(x) for x in prefixes):
            continue
        if bind == 2:                       # STB_WEAK
            weak += 1
        else:
            strong += 1
            names.append(name)
    aligns = [a for _, _, a in elf.load_segments()]
    return strong, weak, sorted(set(names)), set(aligns), elf.is64


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="ffmpeg-kit AAR 验收：孤儿符号 + 16KB 页对齐")
    ap.add_argument("target", help=".aar / .zip，或含 .so 的目录")
    ap.add_argument("--prefix", action="append", default=[],
                    help="视为「必须弱化/不得为强」的符号前缀，可重复（默认 PLATFORM_）")
    ap.add_argument("--require-16k", nargs="?", const="arm64-v8a,x86_64", default=None,
                    metavar="ABI[,ABI]",
                    help="要求这些 ABI 的每个 .so LOAD 段都按 16KB 对齐（缺省 arm64-v8a,x86_64）")
    ap.add_argument("--expect-abis", default=None, metavar="ABI[,ABI]",
                    help="断言产物**恰好**含这些 ABI —— 直传 workflow 的 BUILD_ABIS。"
                         "逗号或空格分隔；不给则只清点、不校验。")
    ap.add_argument("--quiet", action="store_true", help="只打印表格与结论")
    args = ap.parse_args(argv)

    prefixes = args.prefix or ["PLATFORM_"]
    strict_16k = [x.strip() for x in args.require_16k.split(",")] if args.require_16k else []
    # 逗号与空格都接受：workflow 里 BUILD_ABIS="arm64-v8a x86 x86_64"，用的是 **Gradle
    # 的 ABI 名**，而它与 jni/<abi>/ 的目录名逐字相同，所以可以原样吃进来。
    expect_abis = [x for x in (args.expect_abis or "").replace(",", " ").split() if x]

    per_abi = {}
    for abi, name, data in iter_so(args.target):
        try:
            strong, weak, names, aligns, is64 = analyse(data, prefixes)
        except NotElf as exc:
            print("跳过 %s/%s：%s" % (abi, name, exc), file=sys.stderr)
            continue
        rec = per_abi.setdefault(
            abi, {"files": 0, "strong": 0, "weak": 0, "names": [], "aligns": set(),
                  "is64": False, "bad16k": [], "so": set()})
        rec["files"] += 1
        rec["strong"] += strong
        rec["weak"] += weak
        rec["names"].extend("%s:%s" % (name, s) for s in names)
        rec["aligns"] |= aligns
        rec["so"].add(name)
        rec["is64"] = rec["is64"] or is64
        if is64 and any(a < PAGE_16K for a in aligns):
            rec["bad16k"].append(
                "%s(%s)" % (name, ",".join(sorted("0x%x" % a for a in aligns))))

    if not per_abi:
        print("✗ 没找到任何 jni/<abi>/*.so —— 这个包看着不像 ffmpeg-kit AAR")
        return 1

    # ---- 判据二：ABI 集合与必备库齐备 --------------------------------------
    # 「构建哪几个 ABI」在 workflow 里只是**声明**（BUILD_ABIS），产物里实际有几个
    # 从来没人查过 —— 本仓出过一次「承诺 3 个 ABI、实际并不是」的事，而那种包在
    # declare-only 的 ABI 上会直接 loadLibrary 失败。这里把声明与产物钉在一起。
    set_bad = []
    if expect_abis:
        for miss in sorted(set(expect_abis) - set(per_abi)):
            set_bad.append("缺少：%s（声明要构建，产物里没有）" % miss)
        for extra in sorted(set(per_abi) - set(expect_abis)):
            set_bad.append("多出：%s（产物里有，但没声明要构建）" % extra)
    so_lack = {}
    for abi in sorted(per_abi):
        lack = missing_required_so(per_abi[abi]["so"])
        if lack:
            so_lack[abi] = lack

    print("目标: %s" % args.target)
    print("判据: 非 WEAK 的 UND 符号不得以 %s 开头%s" % (
        ", ".join(prefixes),
        "；且 %s 的每个 LOAD 段 p_align >= 0x4000" % ",".join(strict_16k) if strict_16k else ""))
    if expect_abis:
        print("      ABI 集合必须恰好是 %s" % ",".join(expect_abis))
    print()
    hdr = "%-14s %5s %17s %17s %-22s %-20s %s" % (
        "ABI", "库数", "强UND(%s)" % prefixes[0], "弱UND(%s)" % prefixes[0],
        "LOAD p_align", "16KB", "必备库")
    print(hdr)
    print("-" * (len(hdr) + 12))
    failed = False
    for abi in sorted(per_abi):
        r = per_abi[abi]
        needs16k = abi in strict_16k
        aligns_txt = ",".join(sorted("0x%x" % a for a in r["aligns"]))
        if not r["is64"]:
            ok16k, tag = True, "n/a（32 位，不受约束）"
        elif r["bad16k"]:
            ok16k = False
            tag = "✗ 含 <0x4000" + ("" if needs16k else "（未强制）")
        else:
            ok16k, tag = True, "✓ 全部 ≥0x4000"
        so_tag = "✗ 缺 %d 个" % len(so_lack[abi]) if abi in so_lack else "✓ 齐备"
        print("%-14s %5d %17d %17d %-22s %-20s %s" % (
            abi, r["files"], r["strong"], r["weak"], aligns_txt, tag, so_tag))
        if r["strong"]:
            failed = True
        if needs16k and not ok16k:
            failed = True
    if set_bad or so_lack:
        failed = True

    if failed:
        print()
        print("=" * 72)
        for msg in set_bad:
            print("✗ ABI 集合不符：%s" % msg)
        if set_bad:
            print("    修法：查 workflow 的 ABI 开关。android.sh 的判据是"
                  "`ENABLED_ARCHITECTURES[ARCH_ARM_V7A] || ENABLED_ARCHITECTURES[ARCH_ARM_V7A_NEON]`，"
                  "所以关 armeabi-v7a 必须**两个都禁**（--disable-arm-v7a "
                  "--disable-arm-v7a-neon），否则 APP_ABI 里仍会有它。")
        for abi in sorted(so_lack):
            print("✗ %s: 缺少必备库：" % abi)
            for s in so_lack[abi]:
                print("    - %s" % s)
        for abi in sorted(per_abi):
            r = per_abi[abi]
            if r["strong"]:
                print("✗ %s: %d 个未弱化的目标前缀符号：" % (abi, r["strong"]))
                for s in r["names"]:
                    print("    - %s" % s)
            if abi in strict_16k and r["bad16k"]:
                print("✗ %s: 以下库未达 16KB 对齐（LOAD p_align 含 <0x4000）：" % abi)
                for s in r["bad16k"]:
                    print("    - %s" % s)
        print("=" * 72)
        print("结论：不通过。")
        print("  · 孤儿强符号会在 dlopen 阶段直接抛 cannot locate symbol"
              "（这些库带 DT_FLAGS=BIND_NOW，立即绑定）。")
        print("    修法：构建时用 --disable-lib-sdl 从源头拔掉（android.sh 的 sdl 分支），"
              "而不是事后改字节。")
        print("  · 16KB 未达标：给链接器加 -Wl,-z,max-page-size=16384；"
              "32 位的 libc++_shared.so 由 scripts/android/relink-libcxx-16kb.sh 重链。")
        print("  · ABI / 必备库缺项：这类包会静默装进 APK，直到运行时 loadLibrary 才炸。"
              "先查有没有库被跳过（build.log 里的 SKIPPED_LIBRARIES / "
              "UNSUPPORTED_LIBRARIES）。")
        return 1

    print()
    print("结论：通过 —— 没有未弱化的目标前缀孤儿符号%s%s。" % (
        "，且 %s 均达 16KB 对齐" % ",".join(strict_16k) if strict_16k else "",
        "，且 ABI 集合与必备库齐备" if expect_abis else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
