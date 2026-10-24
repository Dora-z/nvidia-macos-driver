#!/bin/bash
# The plugin's switches in /Library/GPUBundles/nvmtl/nvrm610.conf (each line KEY=VALUE becomes an environment variable
# of every process that loads the Metal plugin; WindowServer reads it once, at boot).
#   bash fork/conf.sh                       show the current switches
#   sudo bash fork/conf.sh KEY VALUE        set one, e.g. NVMTL_ASYNC_SURFIN 1, NVMTL_ANGLE_METAL "Claude Helper"
#   sudo bash fork/conf.sh KEY off          remove it
# Takes effect for apps started afterwards; restart for WindowServer.
set -uo pipefail
die() { echo "STOP: $*" >&2; exit 1; }
CONF=/Library/GPUBundles/nvmtl/nvrm610.conf
[ -f "$CONF" ] || die "$CONF not found (is NullMoth installed?)"
if [ $# = 0 ]; then grep -v '^#' "$CONF" | grep .; exit 0; fi
[ $# = 2 ] || die "usage: sudo bash fork/conf.sh KEY VALUE|off"
[ "$(id -u)" = 0 ] || die "run with sudo"
KEY=$1; VAL=$2
printf '%s' "$KEY" | grep -Eq '^[A-Z][A-Z0-9_]*$' || die "KEY must look like NVMTL_SOMETHING"
case "$VAL" in *$'\n'*) die "VALUE must be one line";; esac
T=$(mktemp) || die "temp file"
grep -v "^$KEY=" "$CONF" > "$T"
[ "$VAL" = off ] || echo "$KEY=$VAL" >> "$T"
chown root:wheel "$T" && chmod 644 "$T" && mv -f "$T" "$CONF" || { rm -f "$T"; die "cannot write $CONF"; }
[ "$VAL" = off ] && echo "$KEY removed" || echo "$KEY=$VAL"
echo "quit and reopen apps to use it; restart for WindowServer"
