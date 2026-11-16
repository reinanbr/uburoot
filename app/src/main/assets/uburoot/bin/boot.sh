#!/system/bin/sh
# Autostart at boot (Phase 5). Run by the root module's service.sh after
# sys.boot_completed, in the global mount namespace, in the background.
# Does nothing unless BOOT_START=1 in uburoot.conf (Settings → Start at boot).
#   1. waits until the shared storage is decrypted (first unlock), if /sdcard
#      is wanted inside Ubuntu;
#   2. mount.sh;
#   3. runs every executable /etc/uburoot-boot.d/NAME inside Ubuntu as root,
#      in name order (NAME: letters, digits, _ and - only, like run-parts, so
#      README, *.dpkg-old or *.disabled are skipped). Each one gets
#      BOOT_SCRIPT_TIMEOUT seconds; one still running after that is left
#      running and the next one starts (daemons should fork, e.g. sshd).
# Output goes to $UBU_BASE/boot.log (the previous boot's is boot.log.old).
# Usage: boot.sh [--now | --status]
#   --now     don't wait for the unlock, ignore BOOT_START (Settings → Run now)
#   --status  print module=enabled|disabled|removing|pending|missing and
#             boot_start=0|1 (the module dir is the same for Magisk, KernelSU
#             and APatch: /data/adb/modules/uburoot)
set -u
UBU_BIN_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=common.sh
. "$UBU_BIN_DIR/common.sh"

ubu_require_root
ubu_init
ubu_load_config

NOW=0
STATUS=0
for _a in "$@"; do
    case "$_a" in
        --now) NOW=1 ;;
        --status) STATUS=1 ;;
        *) ubu_die "unknown option: $_a" ;;
    esac
done

BOOT_START=${BOOT_START:-0}
BOOT_SCRIPT_TIMEOUT=${BOOT_SCRIPT_TIMEOUT:-60}
case "$BOOT_SCRIPT_TIMEOUT" in
    '' | *[!0-9]*) BOOT_SCRIPT_TIMEOUT=60 ;;
esac
R=$ROOTFS
BOOT_D="$R/etc/uburoot-boot.d"

UBU_MODULES=${UBU_MODULES:-/data/adb}
if [ "$STATUS" = 1 ]; then
    _m="$UBU_MODULES/modules/uburoot"
    if [ -d "$UBU_MODULES/modules_update/uburoot" ]; then
        _s=pending # installed, active after the next reboot
    elif [ ! -d "$_m" ]; then
        _s=missing
    elif [ -e "$_m/remove" ]; then
        _s=removing
    elif [ -e "$_m/disable" ]; then
        _s=disabled
    else
        _s=enabled
    fi
    printf 'module=%s\nboot_start=%s\n' "$_s" "$BOOT_START"
    exit 0
fi

stamp() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null; }
say() { printf '%s %s\n' "$(stamp)" "$*" >&2; }

if [ "$NOW" = 0 ] && [ "$BOOT_START" != 1 ]; then
    exit 0
fi
[ -x "$R/usr/bin/env" ] || ubu_die "Ubuntu is not installed ($R)"

if [ "$NOW" = 0 ] && [ "$MOUNT_SDCARD" = 1 ]; then
    # Up to 6 hours: a phone may sit at the lock screen after a reboot.
    _n=0
    while ! ubu_sdcard_source >/dev/null && [ $_n -lt 4320 ]; do
        [ $_n = 0 ] && say "waiting for the shared storage (unlock the phone)"
        sleep 5
        _n=$((_n + 1))
    done
fi

say "mounting"
"$UBU_SH" "$UBU_BIN_DIR/mount.sh" || ubu_die "mount.sh failed; boot scripts not run"

if [ ! -d "$BOOT_D" ]; then
    say "no $BOOT_D; nothing to start"
    exit 0
fi
_failed=0
for _f in "$BOOT_D"/*; do
    _name=${_f##*/}
    case "$_name" in
        '*' | *[!A-Za-z0-9_-]*) continue ;;
    esac
    if [ -L "$_f" ] || [ ! -f "$_f" ] || [ ! -x "$_f" ]; then
        continue
    fi
    say "starting $_name"
    # enter.sh: the same clean environment and groups as a root session.
    "$UBU_SH" "$UBU_BIN_DIR/enter.sh" root "/etc/uburoot-boot.d/$_name" </dev/null &
    _pid=$!
    _t=0
    while kill -0 "$_pid" 2>/dev/null && [ $_t -lt "$BOOT_SCRIPT_TIMEOUT" ]; do
        sleep 1
        _t=$((_t + 1))
    done
    if kill -0 "$_pid" 2>/dev/null; then
        say "$_name still running after ${BOOT_SCRIPT_TIMEOUT}s; left running, going on"
        continue
    fi
    if wait "$_pid"; then
        say "$_name: ok"
    else
        say "$_name: failed (exit $?)"
        _failed=1
    fi
done
say "boot scripts done"
exit $_failed
