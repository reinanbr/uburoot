# SPDX-License-Identifier: GPL-3.0-or-later
# Sourced by kernel.sh (uburoot-kernel) and hardware.sh (uburoot-hw): the change log
# that records every change UbuRoot makes to the phone's kernel or hardware state,
# so that Stop all ("kernel.sh -y revert") and "Revert changes" can undo it.
# Not executable on its own. Inside Ubuntu it lives in /usr/local/lib/uburoot/.
#
# The caller sets: MODE (android|ubuntu), STATE (the state directory) and the
# functions die and say. Test-only overrides: UBU_BOOT_ID_FILE, UBU_SYSCTL_DIR,
# UBU_SELINUX_ENFORCE, UBU_PROC_MODULES, UBU_RMMOD, UBU_POWER_DIR, UBU_ACMD.
#
# One line per change, "TYPE NAME ORIGINAL":
#   sysctl NAME VALUE        a /proc/sys setting (kernel.kptr_restrict)
#   selinux - 0|1            the SELinux mode
#   module NAME -            a module loaded through UbuRoot
#   file PATH VALUE          a sysfs file (CPU governor, LED brightness...)
#   node PATH UID:GID:MODE   owner and mode of a device node
#   wakelock NAME -          a kernel wake lock held through UbuRoot
#   takeover CLASS STATE     a device taken from Android (e.g. wifi 1:1)
# Only the first change of a setting is recorded: that holds the true original.
# Nothing persists across reboots: a log from an earlier boot is discarded.

CHANGES="$STATE/changes"
LOCK="$STATE/.lock"
BOOTID_FILE=${UBU_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}
SYSCTL=${UBU_SYSCTL_DIR:-/proc/sys}
ENFORCE=${UBU_SELINUX_ENFORCE:-/sys/fs/selinux/enforce}
PROCMOD=${UBU_PROC_MODULES:-/proc/modules}
RMMOD=${UBU_RMMOD:-rmmod}
POWER=${UBU_POWER_DIR:-/sys/power}

unlock() {
    rm -f "$LOCK/pid" 2>/dev/null
    rmdir "$LOCK" 2>/dev/null
}
# lock: take the change log (wait up to 20 s); lock_try: return 1 if it is taken.
lock() { _lock wait; }
lock_try() { _lock try; }
_lock() {
    mkdir -p "$STATE" 2>/dev/null
    [ "$MODE" = android ] && chmod 700 "$STATE" 2>/dev/null
    _i=0
    until mkdir "$LOCK" 2>/dev/null; do
        # A holder killed by a signal its traps don't cover leaves the lock behind:
        # break it when the recorded owner is gone (Android and Ubuntu share pids).
        _o=$(cat "$LOCK/pid" 2>/dev/null)
        if [ -n "$_o" ] && ! kill -0 "$_o" 2>/dev/null; then
            unlock
            continue
        fi
        [ "$1" = try ] && return 1
        _i=$((_i + 1))
        [ "$_i" -lt 20 ] || die "change log is locked ($LOCK)"
        sleep 1
    done
    printf '%s\n' "$$" >"$LOCK/pid"
    trap unlock EXIT
    # PIPE: "uburoot-kernel status | head" must not leave the lock (dash runs no
    # EXIT trap when a signal kills it).
    trap 'exit 1' INT TERM HUP PIPE
    # A log from an earlier boot describes changes the reboot already undid.
    _now=$(cat "$BOOTID_FILE" 2>/dev/null)
    if [ "$(cat "$STATE/boot_id" 2>/dev/null)" != "$_now" ]; then
        rm -f "$CHANGES"
        printf '%s\n' "$_now" >"$STATE/boot_id"
    fi
    [ -f "$CHANGES" ] || : >"$CHANGES"
}
rec_get() { # TYPE NAME -> recorded original (exit 1 if none)
    bb awk -v t="$1" -v n="$2" '$1 == t && $2 == n { print substr($0, length($1 $2) + 3); f = 1; exit } END { exit !f }' "$CHANGES" 2>/dev/null
}
rec_add() { # TYPE NAME VALUE (only the first time)
    rec_get "$1" "$2" >/dev/null && return 0
    printf '%s %s %s\n' "$1" "$2" "$3" >>"$CHANGES"
}
rec_del() { # TYPE NAME
    bb awk -v t="$1" -v n="$2" '!($1 == t && $2 == n)' "$CHANGES" >"$CHANGES.tmp" && mv -f "$CHANGES.tmp" "$CHANGES"
}
rec_count() { bb awk 'NF' "$CHANGES" 2>/dev/null | bb wc -l | tr -d ' '; }

loaded() { bb awk '{ print $1 }' "$PROCMOD" 2>/dev/null; }

# An Android tool (cmd, settings, svc...): directly on the Android side, through
# the bionic wrappers inside Ubuntu.
acmd() {
    if [ -n "${UBU_ACMD:-}" ]; then
        "$UBU_ACMD" "$@"
    elif [ "$MODE" = android ]; then
        "$@"
    else
        /usr/local/bin/android "$@"
    fi
}

# Processes started from Ubuntu's own binaries (never Android's /vendor ones of the
# same name): their executable ends in /usr/sbin/NAME (or /usr/bin/NAME).
kill_ubuntu_exe() { # NAME...
    for _p in /proc/[0-9]*; do
        _e=$(readlink "$_p/exe" 2>/dev/null) || continue
        for _x in "$@"; do
            case "$_e" in
                */usr/sbin/"$_x" | */usr/bin/"$_x") kill "${_p#/proc/}" 2>/dev/null ;;
            esac
        done
    done
}

# Wi-Fi given back to Android. STATE is "WIFI:SCAN" as it was before the takeover.
wifi_release() { # STATE
    kill_ubuntu_exe wpa_supplicant hostapd dhclient dhcpcd iwd
    _w=${1%%:*}
    _s=${1#*:}
    _ok=0
    if [ "$_s" = 1 ]; then acmd cmd wifi set-scan-always-available enabled >/dev/null 2>&1 || _ok=1; fi
    if [ "$_w" = 1 ]; then acmd cmd wifi set-wifi-enabled enabled >/dev/null 2>&1 || _ok=1; fi
    return "$_ok"
}

revert_one() { # TYPE NAME VALUE -> 0 if undone
    case "$1" in
        module)
            if loaded | bb grep -qx "$2"; then
                "$RMMOD" "$2" 2>/dev/null || { say "could not unload $2 (in use?)" >&2; return 1; }
            fi
            ;;
        sysctl)
            _f="$SYSCTL/$(printf '%s' "$2" | tr '.' '/')"
            if printf '%s\n' "$3" >"$_f" 2>/dev/null; then
                :
            elif [ "$2" = kernel.kptr_restrict ] && [ "$3" -gt 2 ] 2>/dev/null &&
                printf '2\n' >"$_f" 2>/dev/null; then
                # Some kernels boot with a value above 2 (the S9: 4) that a write
                # can't set again (0-2 only); the kernel treats >= 2 alike: hidden.
                say "kernel.kptr_restrict: $3 can't be written back; set 2 (same effect)"
            else
                say "could not restore $2 = $3" >&2
                return 1
            fi
            ;;
        selinux)
            printf '%s' "$3" >"$ENFORCE" 2>/dev/null || { say "could not restore SELinux" >&2; return 1; }
            ;;
        file)
            # Gone (an unplugged device, an offline CPU's files) = nothing to restore.
            [ -e "$2" ] || return 0
            printf '%s\n' "$3" >"$2" 2>/dev/null || { say "could not restore $2 = $3" >&2; return 1; }
            ;;
        node)
            [ -e "$2" ] || return 0
            if ! { chown "${3%:*}" "$2" 2>/dev/null && chmod "${3##*:}" "$2" 2>/dev/null; }; then
                say "could not restore $2 ($3)" >&2
                return 1
            fi
            ;;
        wakelock)
            printf '%s\n' "$2" >"$POWER/wake_unlock" 2>/dev/null
            ;;
        takeover)
            case "$2" in
                wifi) wifi_release "$3" || { say "could not give Wi-Fi back to Android" >&2; return 1; } ;;
                *) say "unknown takeover $2" >&2 ;;
            esac
            ;;
        *) ;;
    esac
    return 0
}

# Undo every recorded change, newest first. Changes that can't be undone stay.
revert() {
    _left=""
    _done=0
    _lines=$(bb awk '{ l[NR] = $0 } END { for (i = NR; i > 0; i--) print l[i] }' "$CHANGES")
    _ifs=$IFS
    IFS='
'
    for _l in $_lines; do
        IFS=$_ifs
        _t=${_l%% *}
        _r=${_l#* }
        _n=${_r%% *}
        _v=${_r#* }
        if revert_one "$_t" "$_n" "$_v"; then
            _done=$((_done + 1))
            say "reverted: $_t $_n"
        else
            _left="$_l
$_left"
        fi
    done
    IFS=$_ifs
    printf '%s' "$_left" | bb awk 'NF' >"$CHANGES"
    if [ -s "$CHANGES" ]; then
        say "$(rec_count) change(s) could not be reverted" >&2
        return 1
    fi
    [ "$_done" -gt 0 ] || say "nothing to revert"
    return 0
}

# What mount.sh granted, from /run/uburoot/access inside Ubuntu (KEY=0|1 lines).
ubuntu_access() { # KEY -> 0|1
    bb awk -F= -v k="$1" '$1 == k { v = $2 } END { print (v == "1" ? 1 : 0) }' "${UBU_ACCESS_FILE:-/run/uburoot/access}" 2>/dev/null || echo 0
}
