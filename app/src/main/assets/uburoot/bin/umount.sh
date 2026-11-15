#!/system/bin/sh
# Unmount everything at or below ROOTFS, deepest first, reading /proc/self/mounts.
# Falls back to lazy umount (-l). Exit 0 only if nothing is left mounted.
# Usage: umount.sh [--kill]
#   --kill  first terminate processes whose root is inside the chroot
set -u
UBU_BIN_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=common.sh
. "$UBU_BIN_DIR/common.sh"

ubu_require_root
ubu_init

KILL=0
for _a in "$@"; do
    case "$_a" in
        --kill) KILL=1 ;;
        *) ubu_die "unknown option: $_a" ;;
    esac
done

R=$ROOTFS

if [ "$KILL" = 1 ]; then
    _pids=$(ubu_chroot_pids)
    if [ -n "$_pids" ]; then
        ubu_log "stopping chroot processes: $(printf '%s' "$_pids" | tr '\n' ' ')"
        # HUP too: interactive shells ignore TERM but exit on a hangup.
        # shellcheck disable=SC2086 # word splitting of the pid list is intended
        kill -HUP $_pids 2>/dev/null
        # shellcheck disable=SC2086
        kill -TERM $_pids 2>/dev/null
        _n=0
        while [ $_n -lt 10 ] && [ -n "$(ubu_chroot_pids)" ]; do
            sleep 0.3 2>/dev/null || sleep 1
            _n=$((_n + 1))
        done
        _pids=$(ubu_chroot_pids)
        # shellcheck disable=SC2086
        [ -n "$_pids" ] && kill -KILL $_pids 2>/dev/null
    fi
fi

# Cut every propagation link first, so no umount below can reach the real
# mounts (an rbind copy of /apex that is still shared would otherwise
# unmount the real /apex/* submounts).
# --make-rprivate is recursive, so only the topmost mounts need it (normally
# just the rootfs self-bind). The check right below still aborts if anything
# under the rootfs is left shared.
_top=""
for _mp in $(ubu_mounts_under "$R" | bb sort -u); do
    case "$_mp" in *\\*) _mp=$(ubu_unescape "$_mp") ;; esac
    _covered=0
    for _t in $_top; do
        case "$_mp" in "$_t"/*) _covered=1 ;; esac
    done
    [ "$_covered" = 1 ] && continue
    bb mount --make-rprivate "$_mp" 2>/dev/null || bb mount -o rprivate "$_mp" 2>/dev/null
    _top="$_top $_mp"
done
if ubu_any_shared_under "$R"; then
    ubu_die "mounts under $R are still shared and propagation could not be changed; NOT unmounting (reboot to clear)"
fi

_pass=0
while [ $_pass -lt 5 ]; do
    _list=$(ubu_mounts_under "$R")
    [ -z "$_list" ] && break
    for _mp in $_list; do
        case "$_mp" in *\\*) _mp=$(ubu_unescape "$_mp") ;; esac
        ubu_is_mounted "$_mp" || continue
        if ! bb umount "$_mp" 2>/dev/null; then
            bb umount -l "$_mp" 2>/dev/null || ubu_warn "could not unmount $_mp"
        fi
    done
    _pass=$((_pass + 1))
done

_left=$(ubu_mounts_under "$R")
if [ -n "$_left" ]; then
    ubu_log "ERROR: still mounted under $R:"
    printf '%s\n' "$_left" | sed 's/^/[uburoot]   /' >&2
    exit 1
fi
ubu_log "all mounts under $R released"
exit 0
