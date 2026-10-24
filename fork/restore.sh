#!/bin/bash
# sudo bash restore.sh [backup-dir]: put back what fork/install.sh replaced (NVAccel.kext, NVRMFB.kext, the Auxiliary
# Kernel Collection, the Metal plugin, the shader translator and nvrm610.conf). install.sh copies this script into its
# backup folder; run that copy, or give the folder. Restart afterwards.
set -uo pipefail
die() { echo "STOP: $*" >&2; exit 1; }
BK=${1:-$(cd "$(dirname "$0")" && pwd)}
EXT=/Library/Extensions; KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
GB=/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS; CONF=/Library/GPUBundles/nvmtl/nvrm610.conf
[ "$(id -u)" = 0 ] || die "run with sudo"
[ -d "$BK/NVAccel.kext" ] && [ -d "$BK/NVRMFB.kext" ] && [ -s "$BK/AuxiliaryKernelExtensions.kc" ] \
  || die "usage: sudo bash restore.sh <nullmoth-fork-backup-... folder>"
for k in NVAccel NVRMFB; do
  rm -rf "$EXT/$k.kext" && ditto "$BK/$k.kext" "$EXT/$k.kext" && chown -R root:wheel "$EXT/$k.kext" || die "restore $k"
done
cp "$BK/AuxiliaryKernelExtensions.kc" "$KC.restore" && chown root:wheel "$KC.restore" && chmod 744 "$KC.restore" \
  && mv -f "$KC.restore" "$KC" || die "restore kernel collection"
for f in NVMTLDriver libnvmtl_translate.dylib; do
  [ -f "$BK/$f" ] || continue
  cp "$BK/$f" "$GB/$f.new.$$" && chown root:wheel "$GB/$f.new.$$" && chmod 755 "$GB/$f.new.$$" && mv -f "$GB/$f.new.$$" "$GB/$f" \
    || die "restore $f"
done
[ -f "$BK/nvrm610.conf" ] && { cp "$BK/nvrm610.conf" "$CONF" && chown root:wheel "$CONF" && chmod 644 "$CONF" || die "restore nvrm610.conf"; }
echo "Restored from $BK. Restart for it to take effect."
