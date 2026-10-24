#!/bin/bash
# sudo bash fork/install.sh [build-dir]: put this fork's NVAccel, NVRMFB, Metal plugin and shader translator over an
# installed NullMoth 2.5.3 or 2.5.4 (installed with the 1401 app). Everything else of the driver stays as it is.
#   1. test-builds the Auxiliary Kernel Collection with the two kexts (nothing changes if that fails)
#   2. backs up what it replaces to ~/nullmoth-fork-backup-<date> (with a restore.sh)
#   3. installs, publishes the new kernel collection; restart afterwards
# build-dir: the output of fork/build.sh (default fork/out).
set -uo pipefail
die() { echo "STOP: $*" >&2; exit 1; }
REPO=$(cd "$(dirname "$0")/.." && pwd); IN=${1:-$REPO/fork/out}; U=${SUDO_USER:-$(stat -f %Su /dev/console)}
EXT=/Library/Extensions; KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
KB=/System/Library/KernelCollections/BootKernelExtensions.kc; KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
K=/System/Library/Kernels/kernel; KARG=(--allow-missing-kdk); [ -f "$K" ] && KARG+=(--kernel "$K")
GB=/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS; CONF=/Library/GPUBundles/nvmtl/nvrm610.conf
KEXTS="NVRM NVAccel NVRMFB NVRMAGDC"

[ "$(id -u)" = 0 ] || die "run with sudo"
[ "$(sw_vers -productVersion | cut -d. -f1)" = 15 ] || die "this fork is built and tested on macOS 15 only"
for f in NVAccel.kext/Contents/MacOS/NVAccel NVRMFB.kext/Contents/MacOS/NVRMFB NVMTLDriver libnvmtl_translate.dylib; do
  [ -f "$IN/$f" ] || die "$IN/$f missing: run fork/build.sh first"
done
codesign -v "$IN/NVMTLDriver" 2>/dev/null && codesign -v "$IN/libnvmtl_translate.dylib" 2>/dev/null || die "plugin or translator not signed"
for k in $KEXTS; do [ -d "$EXT/$k.kext" ] || die "$k.kext missing: install NullMoth 2.5.3 or 2.5.4 with 1401 first"; done
ver=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$EXT/NVRM.kext/Contents/Info.plist" 2>/dev/null)
case "$ver" in 2.5.3|2.5.4) ;; *) die "installed NullMoth is '$ver'; this fork needs 2.5.3 or 2.5.4";; esac
[ -f "$GB/NVMTLDriver" ] && [ -f "$GB/libnvmtl_translate.dylib" ] || die "the NullMoth Metal plugin is not installed"

echo "1. test kernel collection with the fork's NVAccel and NVRMFB (nothing installed yet)"
T=$(mktemp -d /var/tmp/nullmoth-fork.XXXX) || die "temp dir"
mkdir -p "$T/repo" && for x in "$EXT"/*.kext; do ditto "$x" "$T/repo/$(basename "$x")" || die "stage $x"; done
cp "$IN/NVAccel.kext/Contents/MacOS/NVAccel" "$T/repo/NVAccel.kext/Contents/MacOS/NVAccel" \
  && cp "$IN/NVRMFB.kext/Contents/MacOS/NVRMFB" "$T/repo/NVRMFB.kext/Contents/MacOS/NVRMFB" || die "stage binaries"
chown -R root:wheel "$T/repo" && chmod -R go-w "$T/repo" || die "stage permissions"
kmutil create -n aux --volume-root / "${KARG[@]}" -B $KB -S $KS --repository "$T/repo" -A "$T/aux.kc" -z >"$T/kmutil.log" 2>&1 \
  || { tail -20 "$T/kmutil.log"; die "test kernel collection build failed; nothing changed"; }
INS=$(kmutil inspect -a x86_64 -A "$T/aux.kc" 2>/dev/null) || die "cannot inspect the test collection; nothing changed"
for k in $KEXTS; do printf '%s\n' "$INS" | grep -Fq "com.nullmoth.$k" || die "com.nullmoth.$k missing from the test collection; nothing changed"; done
echo "   ok"

BK="/Users/$U/nullmoth-fork-backup-$(date +%Y%m%d-%H%M%S)"
echo "2. back up -> $BK"
mkdir -p "$BK" && ditto "$EXT/NVAccel.kext" "$BK/NVAccel.kext" && ditto "$EXT/NVRMFB.kext" "$BK/NVRMFB.kext" \
  && cp -p "$KC" "$BK/AuxiliaryKernelExtensions.kc" && cp -p "$GB/NVMTLDriver" "$BK/NVMTLDriver" \
  && cp -p "$GB/libnvmtl_translate.dylib" "$BK/libnvmtl_translate.dylib" && { [ ! -f "$CONF" ] || cp -p "$CONF" "$BK/nvrm610.conf"; } \
  && cp "$REPO/fork/restore.sh" "$BK/restore.sh" || die "backup failed; nothing changed"
chown -R "$U" "$BK"

echo "3. install"
for b in "NVAccel:$IN/NVAccel.kext/Contents/MacOS/NVAccel" "NVRMFB:$IN/NVRMFB.kext/Contents/MacOS/NVRMFB"; do
  k=${b%%:*}; src=${b#*:}; dst="$EXT/$k.kext/Contents/MacOS/$k"
  cp "$src" "$dst" && chown root:wheel "$dst" && chmod 755 "$dst" || die "copy $k failed: sudo bash '$BK/restore.sh'"
done
NEWKC="$KC.fork-new"; rm -f "$NEWKC"
kmutil create -n aux --volume-root / "${KARG[@]}" -B $KB -S $KS --repository "$EXT" -A "$NEWKC" -z >"$T/kmutil2.log" 2>&1 \
  || { tail -20 "$T/kmutil2.log"; die "kernel collection build failed: sudo bash '$BK/restore.sh'"; }
INS=$(kmutil inspect -a x86_64 -A "$NEWKC" 2>/dev/null) || die "cannot inspect the new collection: sudo bash '$BK/restore.sh'"
for k in $KEXTS; do printf '%s\n' "$INS" | grep -Fq "com.nullmoth.$k" || die "com.nullmoth.$k missing: sudo bash '$BK/restore.sh'"; done
mv -f "$NEWKC" "$KC" || die "cannot publish the collection: sudo bash '$BK/restore.sh'"
# user-space files are replaced by rename: running apps and WindowServer keep the old file mapped
for f in NVMTLDriver libnvmtl_translate.dylib; do
  cp "$IN/$f" "$GB/$f.new.$$" && chown root:wheel "$GB/$f.new.$$" && chmod 755 "$GB/$f.new.$$" && mv -f "$GB/$f.new.$$" "$GB/$f" \
    || { rm -f "$GB/$f.new.$$"; die "install $f failed: sudo bash '$BK/restore.sh'"; }
done
rm -rf "$T"
echo
echo "DONE. Backup: $BK"
echo "Restart now. To undo: sudo bash '$BK/restore.sh', then restart"
echo "(if the desktop does not come up: boot into Safe Mode, run the restore there)"
