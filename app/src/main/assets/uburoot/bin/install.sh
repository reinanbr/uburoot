#!/system/bin/sh
# Extract an Ubuntu Base tarball into ROOTFS.
# Usage: install.sh <ubuntu-base-*.tar.gz> [expected-sha256]
# Checks: root, arm64, >= 3 GB free, SHA256 (when given), empty target.
# Extracts into ROOTFS.partial first and renames it on success, so an
# interrupted install never leaves a half-populated ROOTFS.
set -u
UBU_BIN_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=common.sh
. "$UBU_BIN_DIR/common.sh"

ubu_require_root
ubu_init

MIN_FREE_KB=$((3 * 1024 * 1024))

[ $# -ge 1 ] || ubu_die "usage: install.sh <ubuntu-base.tar.gz> [sha256]"
TARBALL=$1
SHA=${2:-}
[ -f "$TARBALL" ] || ubu_die "tarball not found: $TARBALL"

_arch=$(uname -m)
if [ "$_arch" != aarch64 ] && [ "${UBU_ALLOW_ANY_ARCH:-0}" != 1 ]; then
    ubu_die "unsupported CPU architecture '$_arch' (arm64/aarch64 required)"
fi

if ubu_rootfs_installed; then
    ubu_die "a rootfs is already installed at $ROOTFS (use reset.sh first)"
fi

mkdir -p "$UBU_BASE" || ubu_die "cannot create $UBU_BASE"
ubu_validate_paths

_free=$(bb df -Pk "$UBU_BASE" | bb awk 'NR == 2 { print $4 }')
case "$_free" in
    '' | *[!0-9]*) ubu_warn "could not determine free space" ;;
    *)
        if [ "$_free" -lt "$MIN_FREE_KB" ]; then
            ubu_die "not enough free space: $((_free / 1024)) MB available, 3072 MB required"
        fi
        ;;
esac

if [ -n "$SHA" ]; then
    ubu_log "verifying SHA256"
    _got=$(bb sha256sum "$TARBALL" | bb cut -d' ' -f1)
    [ "$_got" = "$SHA" ] || ubu_die "SHA256 mismatch: expected $SHA, got $_got"
fi

PARTIAL="$ROOTFS.partial"
# Leftovers from an interrupted install go through the safety rule as well.
ubu_safe_rm "$PARTIAL" || ubu_die "cannot clean $PARTIAL"
if [ -e "$ROOTFS" ]; then
    rmdir "$ROOTFS" 2>/dev/null || ubu_die "$ROOTFS exists and is not empty (use reset.sh)"
fi

mkdir -p "$PARTIAL" || ubu_die "cannot create $PARTIAL"
ubu_log "extracting $(basename "$TARBALL")"
if ! bb tar --numeric-owner -xpzf "$TARBALL" -C "$PARTIAL"; then
    ubu_safe_rm "$PARTIAL"
    ubu_die "extraction failed"
fi
[ -x "$PARTIAL/usr/bin/env" ] || {
    ubu_safe_rm "$PARTIAL"
    ubu_die "tarball does not look like an Ubuntu rootfs"
}
mv "$PARTIAL" "$ROOTFS" || ubu_die "cannot rename $PARTIAL"
chmod 755 "$ROOTFS"
ubu_log "rootfs installed at $ROOTFS"
exit 0
