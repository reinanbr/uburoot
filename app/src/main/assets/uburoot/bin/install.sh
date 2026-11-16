#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Extract an Ubuntu Base tarball (.tar.gz or .tar.xz) into ROOTFS.
# Usage: install.sh <ubuntu-base-*.tar.gz|.tar.xz> [expected-sha256]
# Checks: root, arm64, >= 3 GB free, SHA256 (when given), empty target, and
# that the rootfs is for this CPU (a local file may not be).
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
SHA=$(printf '%s' "${2:-}" | tr 'A-F' 'a-f')
case "$SHA" in
    '' | ????????????????????????????????????????????????????????????????) ;;
    *) ubu_die "SHA256 must be 64 hex digits" ;;
esac
case "$SHA" in *[!0-9a-f]*) ubu_die "SHA256 must be 64 hex digits" ;; esac
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

# The format comes from the content, not the name: a file picked in the app
# arrives under a cache name.
case "$(bb od -An -tx1 -N6 "$TARBALL" 2>/dev/null | tr -d ' \n')" in
    1f8b*) _z=z ;;
    fd377a585a00) _z=J ;;
    *) ubu_die "not a .tar.gz or .tar.xz file: $TARBALL" ;;
esac

mkdir -p "$PARTIAL" || ubu_die "cannot create $PARTIAL"
ubu_log "extracting $(basename "$TARBALL")"
if ! bb tar --numeric-owner -xp${_z}f "$TARBALL" -C "$PARTIAL"; then
    ubu_safe_rm "$PARTIAL"
    ubu_die "extraction failed"
fi
fail_partial() {
    ubu_safe_rm "$PARTIAL"
    ubu_die "$*"
}
if [ ! -x "$PARTIAL/usr/bin/env" ] || [ ! -x "$PARTIAL/usr/bin/dpkg" ]; then
    fail_partial "the archive does not look like an Ubuntu rootfs"
fi
# A local file can be for another CPU: dpkg is a plain ELF binary in Ubuntu Base.
_want=$(ubu_native_arch) || _want=""
_got=$(ubu_elf_arch "$PARTIAL/usr/bin/dpkg") || _got=""
# Always enforced (UBU_ALLOW_ANY_ARCH only lets tests run on a non-arm64 CPU).
if [ -n "$_want" ] && [ -n "$_got" ] && [ "$_got" != "$_want" ]; then
    fail_partial "the rootfs is for $_got, this phone runs $_want"
fi
mv "$PARTIAL" "$ROOTFS" || ubu_die "cannot rename $PARTIAL"
chmod 755 "$ROOTFS"
ubu_log "rootfs installed at $ROOTFS"
exit 0
