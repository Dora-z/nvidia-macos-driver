#!/bin/bash
# fork/build.sh [out-dir]: build this fork's NVAccel, NVRMFB, Metal plugin and shader translator on this Mac.
#   OGKM=<open-gpu-kernel-modules checkout at tag 615.78.08>   (required, kernel headers for the two kexts)
#   VKH=<Vulkan-Headers checkout>                              (required, include/vulkan for the plugin)
#   cargo on PATH (rustup)                                     (for the translator)
# Output: <out-dir>/NVAccel.kext, NVRMFB.kext, NVMTLDriver, libnvmtl_translate.dylib (default fork/out).
# macOS 15 Sequoia, x86_64 only: the macOS 26 accelerator (NM_TAHOE) is not built or tested here.
set -uo pipefail
die() { echo "STOP: $*" >&2; exit 1; }
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$REPO/fork/out}; mkdir -p "$OUT" && OUT=$(cd "$OUT" && pwd)
OGKM=${OGKM:?set OGKM to an open-gpu-kernel-modules checkout (tag 615.78.08)}
VKH=${VKH:?set VKH to a Vulkan-Headers checkout}
[ -d "$OGKM/src/nvidia" ] || die "OGKM=$OGKM is not an open-gpu-kernel-modules checkout"
[ -f "$VKH/include/vulkan/vulkan.h" ] || die "VKH=$VKH has no include/vulkan/vulkan.h"
export PATH="$HOME/.cargo/bin:$PATH"

SDK=$(xcrun --show-sdk-path); KHDR="$SDK/System/Library/Frameworks/Kernel.framework/Headers"
NV="$OGKM/src/nvidia"; KMS="$OGKM/src/nvidia-modeset"
RMINC=( -I"$NV/arch/nvalloc/unix/include" -I"$NV/arch/nvalloc/common/inc" -I"$NV/arch/nvalloc/common/inc/gsp"
  -I"$OGKM/src/common/sdk/nvidia/inc" -I"$OGKM/src/common/sdk/nvidia/inc/hw" -I"$OGKM/src/common/inc"
  -I"$OGKM/src/common/shared/inc" -I"$NV/inc" -I"$NV/inc/os" -I"$NV/inc/kernel" -I"$NV/kernel/inc" -I"$NV/interface"
  -I"$OGKM/src/common/nvlink/interface" -I"$OGKM/src/common/inc/swref" -I"$OGKM/src/common/inc/swref/published"
  -I"$NV/inc/libraries" -I"$NV/src/libraries" -I"$NV/generated" -I"$NV/src/mm/uvm/interface"
  -I"$OGKM/src/common/uproc/os/libos-v2.0.0/include" -I"$OGKM/src/common/uproc/os/common/include"
  -I"$OGKM/src/common/inc/displayport" -I"$OGKM/src/common/nvlink/inband/interface" )
KMSINC=( -I"$KMS/os-interface/include" -I"$KMS/kapi/interface" -I"$KMS/kapi/include" -I"$OGKM/src/common/unix/nvidia-push/interface"
  -I"$KMS/interface" -I"$KMS/include" -I"$OGKM/src/common/unix/common/inc" -I"$OGKM/src/common/modeset"
  -I"$OGKM/src/common/unix/common/utils/interface" )
KFLAGS=( -arch x86_64 -fapple-kext -mkernel -nostdinc -I"$KHDR" "${RMINC[@]}" "${KMSINC[@]}"
  -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT -DNVCPU_X86_64 -D_LANGUAGE_C
  -std=c++17 -fno-rtti -fno-exceptions -fno-builtin -fno-common
  -Wall -Wno-unused-parameter -Wno-inconsistent-missing-override -Wno-unused-function -O2 )
LINK=( -arch x86_64 -fapple-kext -nostdlib -Xlinker -kext -lkmodc++ -lkmod -lcc_kext )

echo "1/4 NVAccel"
S="$REPO/kexts/NVRM"; mkdir -p "$OUT/NVAccel.kext/Contents/MacOS"
xcrun clang++ "${KFLAGS[@]}" -I"$S" -I"$S/accel" -I"$S/accel/iofam" -I"$S/accel/re" -c "$S/accel/nvrm-accel.cpp" \
  -o "$OUT/nvrm-accel.o" 2>"$OUT/accel.log" || { grep error "$OUT/accel.log" | head; die "NVAccel did not compile"; }
xcrun clang++ "${LINK[@]}" "$OUT/nvrm-accel.o" -o "$OUT/NVAccel.kext/Contents/MacOS/NVAccel" || die "NVAccel did not link"
cp "$S/accel/Info.plist" "$OUT/NVAccel.kext/Contents/Info.plist"

echo "2/4 NVRMFB"
S="$REPO/kexts/NVRMFB"; mkdir -p "$OUT/NVRMFB.kext/Contents/MacOS"
xcrun clang++ "${KFLAGS[@]}" -DNV_MACINTOSH -I"$S" -I"$S/fb" -c "$S/fb/nvrm-fb.cpp" \
  -o "$OUT/nvrm-fb.o" 2>"$OUT/fb.log" || { grep error "$OUT/fb.log" | head; die "NVRMFB did not compile"; }
xcrun clang++ "${LINK[@]}" "$OUT/nvrm-fb.o" -o "$OUT/NVRMFB.kext/Contents/MacOS/NVRMFB" || die "NVRMFB did not link"

echo "3/4 Metal plugin (NVMTLDriver)"
(cd "$REPO/plugin" && xcrun clang -arch x86_64 -mmacosx-version-min=15.0 -bundle -fobjc-arc -O1 -DNVMTL_RELEASE=1 \
  -Wno-protocol -Wno-incomplete-implementation -Werror=unguarded-availability-new -I"$VKH/include" \
  -o "$OUT/NVMTLDriver" NVMTLDevice.m -framework Foundation -framework Metal -framework IOSurface -framework IOKit \
  -framework CoreFoundation 2>"$OUT/plugin.log") || { grep ' error:' "$OUT/plugin.log" | head; die "plugin did not compile"; }
codesign -f -s - "$OUT/NVMTLDriver" 2>/dev/null || die "cannot sign the plugin"

echo "4/4 shader translator (libnvmtl_translate.dylib)"
command -v cargo >/dev/null || die "cargo not found (install Rust with rustup)"
# a copy of translator/ so cargo's lock file and target folder never touch the checkout
T="$OUT/translator-src"; rm -rf "$T"; mkdir -p "$T" && cp -R "$REPO/translator/." "$T/" && rm -rf "$T"/*/target
# source paths remapped as upstream's release build does, so the dylib names no folder of this Mac
CH=${CARGO_HOME:-$HOME/.cargo}
# (CARGO_ENCODED_RUSTFLAGS, separated by 0x1f: the paths may hold spaces, which RUSTFLAGS would split)
CARGO_ENCODED_RUSTFLAGS="--remap-path-prefix=$T=/src"$'\x1f'"--remap-path-prefix=$CH=/cargo"$'\x1f'"--remap-path-prefix=$HOME=/build" \
cargo build --release --manifest-path "$T/wrapper/Cargo.toml" --target-dir "$OUT/cargo-target" >"$OUT/translator.log" 2>&1 \
  || { grep -A6 '^error' "$OUT/translator.log" | head -30; die "translator did not build"; }
D="$OUT/libnvmtl_translate.dylib"
cp "$OUT/cargo-target/release/libnvmtl_translate.dylib" "$D" && strip -S "$D" \
  && install_name_tool -id @rpath/libnvmtl_translate.dylib "$D" 2>/dev/null && codesign -f -s - "$D" 2>/dev/null || die "cannot finish the translator"
left=$(strings -a "$D" | grep -cF "$HOME/" || true)
[ "$left" = 0 ] || echo "note: $left path(s) under $HOME left in the translator"

echo
echo "built into $OUT:"
echo "  NVAccel     md5 $(md5 -q "$OUT/NVAccel.kext/Contents/MacOS/NVAccel")"
echo "  NVRMFB      md5 $(md5 -q "$OUT/NVRMFB.kext/Contents/MacOS/NVRMFB")"
echo "  NVMTLDriver sha256 $(shasum -a 256 "$OUT/NVMTLDriver" | cut -c1-16)"
echo "  translator  sha256 $(shasum -a 256 "$D" | cut -c1-16)"
echo "next: sudo bash fork/install.sh $OUT"
