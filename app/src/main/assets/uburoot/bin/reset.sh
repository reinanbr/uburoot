#!/system/bin/sh
# Remove the Ubuntu rootfs. This is the ONLY removal path, and it enforces
# the critical rule:
#   umount.sh --kill -> verify /proc/self/mounts has nothing under ROOTFS
#   -> abort on any leftover -> only then rm -rf (inside ubu_safe_rm).
# Usage: reset.sh --yes
# Exit codes: 0 removed, 1 usage/umount error, 3 refused by the safety rule.
set -u
UBU_BIN_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=common.sh
. "$UBU_BIN_DIR/common.sh"

ubu_require_root
ubu_init

[ "${1:-}" = --yes ] || ubu_die "refusing without --yes (this deletes the whole Ubuntu system)"

if [ ! -e "$ROOTFS" ] && [ ! -e "$ROOTFS.partial" ]; then
    ubu_log "nothing to remove"
    exit 0
fi

if ! "$UBU_SH" "$UBU_BIN_DIR/umount.sh" --kill; then
    ubu_log "ABORTED: umount.sh failed; NOTHING was deleted"
    exit 3
fi

_rc=0
ubu_safe_rm "$ROOTFS" || _rc=$?
if [ "$_rc" -ne 0 ]; then
    ubu_log "ABORTED: rootfs NOT deleted (safety rule)"
    exit 3
fi
ubu_safe_rm "$ROOTFS.partial" || exit 3
ubu_log "Ubuntu removed"
exit 0
