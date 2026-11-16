#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# uburoot-kernel: change the phone's kernel state, with every change recorded
# so that Stop all (and "Revert changes") can undo it.
#
# The same file runs on both sides:
#   Android: /data/local/uburoot/bin/kernel.sh (the app, Stop all, adb)
#   Ubuntu:  /usr/local/sbin/uburoot-kernel and uburoot-kmod (mount.sh installs
#            them with KERNEL_ACCESS=1 and binds the change log into the chroot)
#
# Usage: uburoot-kernel [-y] COMMAND
#   status                          key=value summary (machine-readable)
#   sysctl NAME [VALUE]             read a /proc/sys setting, or write it
#   devmode on|off                  kernel addresses readable by root only
#                                   (kptr_restrict=1); off restores the original
#   selinux [enforcing|permissive]  show or switch the whole phone's SELinux mode
#   module list                     loaded modules (* = loaded through UbuRoot)
#   module load FILE.ko|NAME [PARAM=VALUE...]
#   module unload NAME [--force]    --force: a module UbuRoot did not load
#   lastlog                         the previous boot's kernel log (pstore/last_kmsg)
#   revert                          undo every recorded change, newest first
#   uburoot-kmod load|unload|list ...   same as "uburoot-kernel module ..."
#   -y                              don't ask for confirmation (the app asks)
#
# Changes are lost at reboot anyway: the log records the boot id, and a log
# from an earlier boot is discarded. Nothing here persists across reboots.
set -u

_self=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
if [ -f "$_self/common.sh" ]; then
    MODE=android
    # shellcheck source=common.sh
    . "$_self/common.sh"
    ubu_detect_busybox
    ubu_load_config
    STATE=$UBU_STATE
    ACCESS=$KERNEL_ACCESS
else
    MODE=ubuntu
    bb() { "$@"; }
    STATE=${UBU_STATE:-/run/uburoot/state}
    # Kernel access is on when mount.sh bound the change log into the chroot.
    ACCESS=0
    awk -v p="$STATE" '$2 == p { f = 1 } END { exit !f }' /proc/self/mounts 2>/dev/null && ACCESS=1
fi
# Test-only overrides (never set by the app).
SYSCTL=${UBU_SYSCTL_DIR:-/proc/sys}
ENFORCE=${UBU_SELINUX_ENFORCE:-/sys/fs/selinux/enforce}
PROCMOD=${UBU_PROC_MODULES:-/proc/modules}
BOOTID_FILE=${UBU_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}
INSMOD=${UBU_INSMOD:-insmod}
RMMOD=${UBU_RMMOD:-rmmod}
MODPROBE=${UBU_MODPROBE:-modprobe}

CHANGES="$STATE/changes"
LOCK="$STATE/.lock"

die() { printf 'uburoot-kernel: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

YES=0
if [ "${1:-}" = -y ]; then
    YES=1
    shift
fi
case "${0##*/}" in
    uburoot-kmod) set -- module "$@" ;;
esac

[ "$(id -u)" = 0 ] || die "must run as root (sudo uburoot-kernel ...)"

confirm() {
    [ "$YES" = 1 ] && return 0
    [ -t 0 ] || die "refusing without confirmation (no terminal); pass -y"
    printf '%s [y/N] ' "$1" >&2
    read -r _a || return 1
    case "$_a" in y | Y | yes | YES) return 0 ;; esac
    die "cancelled"
}

need_access() {
    [ "$ACCESS" = 1 ] && return 0
    if [ "$MODE" = ubuntu ]; then
        die "kernel access is off. Turn on Settings > Kernel access in the app, then Repair mounts."
    fi
    die "kernel access is off (KERNEL_ACCESS=0 in uburoot.conf)"
}

# --- Change log -----------------------------------------------------------------------
# One line per change: "sysctl NAME ORIGINAL", "selinux - ORIGINAL", "module NAME -".
# Only the first change of a setting is recorded: that holds the true original.
unlock() { rmdir "$LOCK" 2>/dev/null; }
lock() {
    mkdir -p "$STATE" 2>/dev/null
    [ "$MODE" = android ] && chmod 700 "$STATE" 2>/dev/null
    _i=0
    until mkdir "$LOCK" 2>/dev/null; do
        _i=$((_i + 1))
        [ "$_i" -lt 20 ] || die "change log is locked ($LOCK)"
        sleep 1
    done
    trap unlock EXIT
    trap 'exit 1' INT TERM HUP
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

# --- sysctl -------------------------------------------------------------------------------
sysctl_path() { # NAME (kernel.kptr_restrict or kernel/kptr_restrict) -> file
    case "$1" in
        '' | *..* | /* | *[!A-Za-z0-9_./-]*) die "invalid sysctl name: $1" ;;
    esac
    _f="$SYSCTL/$(printf '%s' "$1" | tr '.' '/')"
    [ -f "$_f" ] || die "no such sysctl: $1"
    printf '%s' "$_f"
}
sysctl_key() { printf '%s' "$1" | tr '/' '.'; }
sysctl_set() { # NAME VALUE
    _f=$(sysctl_path "$1") || exit 1
    _k=$(sysctl_key "$1")
    case "$2" in *"
"*) die "the value must be one line" ;; esac
    _orig=$(cat "$_f") || die "cannot read $_k"
    if [ "$_orig" = "$2" ]; then
        say "$_k = $2 (unchanged)"
        return 0
    fi
    printf '%s\n' "$2" >"$_f" 2>/dev/null || die "the kernel refused $_k = $2"
    _new=$(cat "$_f")
    if _rec=$(rec_get sysctl "$_k"); then
        [ "$_new" = "$_rec" ] && rec_del sysctl "$_k"
    else
        rec_add sysctl "$_k" "$_orig"
    fi
    say "$_k = $_new (was $_orig)"
}

# --- SELinux ------------------------------------------------------------------------------
selinux_mode() {
    case "$(cat "$ENFORCE" 2>/dev/null)" in
        1) say enforcing ;;
        0) say permissive ;;
        *) say absent ;;
    esac
}
selinux_set() { # 0|1
    [ -f "$ENFORCE" ] || die "SELinux is not available here"
    _cur=$(cat "$ENFORCE")
    [ "$_cur" = "$1" ] && { say "SELinux: $(selinux_mode) (unchanged)"; return 0; }
    if [ "$1" = 0 ]; then
        confirm "Switch SELinux to PERMISSIVE for the whole phone? Every app loses SELinux protection until Stop all, Revert changes or a reboot."
    fi
    printf '%s' "$1" >"$ENFORCE" 2>/dev/null || die "the kernel refused the SELinux switch"
    [ "$(cat "$ENFORCE")" = "$1" ] || die "SELinux mode did not change"
    if _rec=$(rec_get selinux -); then
        [ "$1" = "$_rec" ] && rec_del selinux -
    else
        rec_add selinux - "$_cur"
    fi
    say "SELinux: $(selinux_mode)"
}

# --- Modules ------------------------------------------------------------------------------
loaded() { bb awk '{ print $1 }' "$PROCMOD" 2>/dev/null; }
explain_load_error() { # stderr text
    case "$1" in
        *"Key was rejected"* | *"Required key not available"* | *"key"*"rejected"*)
            say "The kernel only loads modules signed with its own key (CONFIG_MODULE_SIG_FORCE). Phone vendors don't publish that key." >&2 ;;
        *"Invalid module format"* | *"Exec format error"*)
            say "The module was built for another kernel (vermagic or symbol versions differ). 'dmesg | tail' says which; uburoot-kbuild check lists what must match." >&2 ;;
        *"Unknown symbol"*)
            say "The module needs symbols this kernel doesn't export to it (on GKI kernels: protected symbols)." >&2 ;;
    esac
}
module_load() { # ARG [PARAMS...]
    need_access
    _arg=$1
    shift
    _before=$(loaded)
    if [ -f "$_arg" ]; then
        confirm "Load $_arg into the phone's kernel?"
        _err=$("$INSMOD" "$_arg" "$@" 2>&1 >/dev/null)
    else
        case "$_arg" in *[!A-Za-z0-9_-]* | '') die "not a file or a module name: $_arg" ;; esac
        [ "$MODE" = ubuntu ] || die "load by name inside Ubuntu (modprobe needs /lib/modules), or pass a .ko file"
        confirm "Load module $_arg (and what it depends on) into the phone's kernel?"
        _err=$("$MODPROBE" "$_arg" "$@" 2>&1 >/dev/null)
    fi
    _rc=$?
    _new=$(loaded | bb awk -v b="$_before" 'BEGIN { n = split(b, a, "\n"); for (i = 1; i <= n; i++) old[a[i]] = 1 } !($1 in old)')
    # /proc/modules lists the newest first: record in load order.
    for _m in $(printf '%s\n' "$_new" | bb awk '{ l[NR] = $0 } END { for (i = NR; i > 0; i--) print l[i] }'); do
        rec_add module "$_m" -
        say "loaded $_m"
    done
    if [ "$_rc" != 0 ]; then
        [ -n "$_err" ] && printf '%s\n' "$_err" >&2
        explain_load_error "$_err"
        exit 1
    fi
    [ -n "$_new" ] || say "nothing new was loaded (already loaded?)"
}
module_unload() { # NAME [--force]
    case "$1" in '' | *[!A-Za-z0-9_-]*) die "invalid module name: $1" ;; esac
    loaded | bb grep -qx "$1" || die "$1 is not loaded"
    if rec_get module "$1" >/dev/null; then
        "$RMMOD" "$1" || die "cannot unload $1"
        rec_del module "$1"
    elif [ "${2:-}" = --force ]; then
        need_access
        confirm "$1 was not loaded by UbuRoot (Android or the ROM loaded it). Unloading it can break the phone, and Revert will NOT load it back. Unload it?"
        "$RMMOD" "$1" || die "cannot unload $1"
    else
        die "$1 was not loaded by UbuRoot; pass --force to unload it anyway"
    fi
    say "unloaded $1"
}

# --- Revert -------------------------------------------------------------------------------
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
        _ok=1
        case "$_t" in
            module)
                if loaded | bb grep -qx "$_n"; then
                    "$RMMOD" "$_n" 2>/dev/null || { say "could not unload $_n (in use?)" >&2; _ok=0; }
                fi
                ;;
            sysctl)
                _f="$SYSCTL/$(printf '%s' "$_n" | tr '.' '/')"
                if printf '%s\n' "$_v" >"$_f" 2>/dev/null; then
                    :
                elif [ "$_n" = kernel.kptr_restrict ] && [ "$_v" -gt 2 ] 2>/dev/null &&
                    printf '2\n' >"$_f" 2>/dev/null; then
                    # Some kernels boot with a value above 2 (the S9: 4) that a write
                    # can't set again (0-2 only); the kernel treats >= 2 alike: hidden.
                    say "kernel.kptr_restrict: $_v can't be written back; set 2 (same effect)"
                else
                    say "could not restore $_n = $_v" >&2
                    _ok=0
                fi
                ;;
            selinux)
                printf '%s' "$_v" >"$ENFORCE" 2>/dev/null || { say "could not restore SELinux" >&2; _ok=0; }
                ;;
            *) ;;
        esac
        if [ "$_ok" = 1 ]; then
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
        say "$(bb wc -l <"$CHANGES" | tr -d ' ') change(s) could not be reverted" >&2
        return 1
    fi
    [ "$_done" -gt 0 ] || say "nothing to revert"
    return 0
}

status() {
    say "mode=$MODE"
    if [ "$ACCESS" = 1 ]; then say "access=on"; else say "access=off"; fi
    say "selinux=$(selinux_mode)"
    for _s in kernel/kptr_restrict kernel/dmesg_restrict kernel/perf_event_paranoid kernel/unprivileged_bpf_disabled; do
        _v=$(cat "$SYSCTL/$_s" 2>/dev/null) || continue
        say "$(sysctl_key "$_s")=$_v"
    done
    if rec_get sysctl kernel.kptr_restrict >/dev/null; then say "devmode=on"; else say "devmode=off"; fi
    say "modules_loaded=$(loaded | bb wc -l | tr -d ' ')"
    while read -r _t _n _v; do
        [ -n "$_t" ] && say "change=$_t $_n $_v"
    done <"$CHANGES"
    say "changes=$(bb awk 'NF' "$CHANGES" | bb wc -l | tr -d ' ')"
}

[ $# -ge 1 ] || die "usage: uburoot-kernel [-y] status|sysctl|devmode|selinux|module|lastlog|revert ..."
_cmd=$1
shift
case "$_cmd" in
    status)
        lock
        status
        ;;
    sysctl)
        [ $# -ge 1 ] || die "usage: uburoot-kernel sysctl NAME [VALUE]"
        if [ $# = 1 ]; then
            cat "$(sysctl_path "$1")"
        else
            need_access
            lock
            sysctl_set "$1" "$2"
        fi
        ;;
    devmode)
        need_access
        lock
        case "${1:-}" in
            on)
                _cur=$(cat "$SYSCTL/kernel/kptr_restrict" 2>/dev/null) || die "no kptr_restrict"
                if [ "$_cur" -gt 1 ] 2>/dev/null; then
                    sysctl_set kernel.kptr_restrict 1
                else
                    say "kernel.kptr_restrict = $_cur (already readable by root)"
                fi
                say "Root (and only root) can now read kernel addresses (/proc/kallsyms). dmesg and perf already work for root: dmesg_restrict and perf_event_paranoid only limit apps."
                ;;
            off)
                if _o=$(rec_get sysctl kernel.kptr_restrict); then
                    sysctl_set kernel.kptr_restrict "$_o"
                else
                    say "developer mode is off"
                fi
                ;;
            *) die "usage: uburoot-kernel devmode on|off" ;;
        esac
        ;;
    selinux)
        case "${1:-}" in
            '') selinux_mode ;;
            enforcing) lock && selinux_set 1 ;;
            permissive) need_access && lock && selinux_set 0 ;;
            *) die "usage: uburoot-kernel selinux [enforcing|permissive]" ;;
        esac
        ;;
    module)
        _sub=${1:-list}
        [ $# -gt 0 ] && shift
        case "$_sub" in
            list)
                lock
                for _m in $(loaded); do
                    if rec_get module "$_m" >/dev/null; then say "* $_m"; else say "  $_m"; fi
                done
                ;;
            load)
                [ $# -ge 1 ] || die "usage: uburoot-kmod load FILE.ko|NAME [PARAM=VALUE...]"
                lock
                module_load "$@"
                ;;
            unload)
                [ $# -ge 1 ] || die "usage: uburoot-kmod unload NAME [--force]"
                lock
                module_unload "$@"
                ;;
            *) die "usage: uburoot-kmod list|load|unload ..." ;;
        esac
        ;;
    lastlog)
        for _f in /sys/fs/pstore/console-ramoops-0 /sys/fs/pstore/console-ramoops /proc/last_kmsg; do
            if [ -s "$_f" ]; then
                cat "$_f"
                exit 0
            fi
        done
        die "no log of the previous boot (no pstore console or /proc/last_kmsg)"
        ;;
    revert)
        lock
        revert
        ;;
    *) die "unknown command: $_cmd" ;;
esac
