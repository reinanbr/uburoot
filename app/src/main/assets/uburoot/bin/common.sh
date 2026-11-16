# shellcheck shell=sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Variables defined here are consumed by the scripts that source this file.
# shellcheck disable=SC2034
# UbuRoot common definitions. Sourced by every script; never executed directly.
# POSIX sh only: these run under Android's mksh (/system/bin/sh).

# ---------------------------------------------------------------------------
# Paths (the env overrides exist for tests only; the app never sets them)
# ---------------------------------------------------------------------------
UBU_BASE="${UBU_BASE:-/data/local/uburoot}"
UBU_BIN="${UBU_BIN:-$UBU_BASE/bin}"
ROOTFS="${ROOTFS:-$UBU_BASE/rootfs}"
UBU_CONFIG="${UBU_CONFIG:-$UBU_BASE/uburoot.conf}"
UBU_MOUNTS_FILE="${UBU_MOUNTS_FILE:-/proc/self/mounts}"
UBU_MOUNTINFO_FILE="${UBU_MOUNTINFO_FILE:-/proc/self/mountinfo}"
UBU_INOTIFY_FILE="${UBU_INOTIFY_FILE:-/proc/sys/fs/inotify/max_user_watches}"

# Directories inside the rootfs that only ever serve as bind-mount targets.
# They must be empty (rmdir-able) before the rootfs may be deleted.
UBU_BIND_TARGETS="data sdcard system vendor product system_ext odm apex linkerconfig"
# Android partitions bound recursively at the same path inside the rootfs.
UBU_ANDROID_PARTS="/system /vendor /product /system_ext /odm /apex /linkerconfig"

if [ -x /system/bin/sh ]; then UBU_SH=/system/bin/sh; else UBU_SH="sh"; fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
ubu_log() { printf '[uburoot] %s\n' "$*" >&2; }
ubu_warn() { printf '[uburoot] WARNING: %s\n' "$*" >&2; }
ubu_die() { printf '[uburoot] ERROR: %s\n' "$*" >&2; exit 1; }

ubu_require_root() {
    [ "${UBU_ALLOW_NONROOT:-0}" = 1 ] && return 0
    [ "$(id -u)" = 0 ] || ubu_die "must run as root (use: su --mount-master -c ...)"
}

# ---------------------------------------------------------------------------
# Config: defaults, then the app-written file (root-owned shell assignments)
# ---------------------------------------------------------------------------
ubu_load_config() {
    MOUNT_SDCARD=1
    ANDROID_INTEGRATION=1
    DNS_SERVERS="1.1.1.1 9.9.9.9"
    DEFAULT_USER=""
    INIT_COMMAND=""
    UBU_HOSTNAME="uburoot"
    SDCARD_SOURCE=""
    INOTIFY_MAX_WATCHES=524288
    BOOT_START=0
    BOOT_SCRIPT_TIMEOUT=60
    if [ -f "$UBU_CONFIG" ]; then
        # shellcheck source=/dev/null
        . "$UBU_CONFIG"
    fi
}

# Where /sdcard comes from: SDCARD_SOURCE, else the first candidate that looks
# real. Before the user's first unlock (file-based encryption) the names in
# /data/media/0 are encrypted, so none matches yet (boot.sh waits for it).
ubu_sdcard_source() {
    if [ -n "$SDCARD_SOURCE" ]; then
        printf '%s' "$SDCARD_SOURCE"
        return 0
    fi
    # /data/media/0 first: the FUSE view (/storage/emulated/0) returns EFAULT
    # to every non-root uid that isn't an app (MediaProvider can't map it to a
    # package), so the chroot user couldn't use it. Group aid_media_rw (1023)
    # gives the user access; the cost is no MediaStore notification.
    for _s in /data/media/0 /storage/emulated/0 /mnt/user/0/emulated/0; do
        if [ -d "$_s/Android" ] || [ -d "$_s/Download" ]; then
            printf '%s' "$_s"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Busybox / toybox
#   Magisk, KernelSU and APatch each ship a full busybox; fall back to toybox
#   (Android's /system/bin applets) when none is found.
# ---------------------------------------------------------------------------
BB=""
BB_KIND="none"
UBU_TOYBOX_APPLETS=""

ubu_detect_busybox() {
    if [ -n "${UBU_BB:-}" ]; then
        if [ "$UBU_BB" = none ]; then BB=""; BB_KIND=none; else BB="$UBU_BB"; BB_KIND=busybox; fi
        return 0
    fi
    for _c in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
        if [ -x "$_c" ]; then
            BB="$_c"
            BB_KIND=busybox
            return 0
        fi
    done
    if command -v toybox >/dev/null 2>&1; then
        BB=toybox
        BB_KIND=toybox
        UBU_TOYBOX_APPLETS=" $(toybox 2>/dev/null | tr '\n' ' ') "
    fi
}

# bb APPLET ARGS... : run an applet through the detected busybox/toybox.
bb() {
    case "$BB_KIND" in
        busybox) "$BB" "$@" ;;
        toybox)
            case "$UBU_TOYBOX_APPLETS" in
                *" $1 "*) toybox "$@" ;;
                *) "$@" ;;
            esac
            ;;
        *) "$@" ;;
    esac
}

# ---------------------------------------------------------------------------
# Root implementation (Magisk / KernelSU / APatch). All three accept
# -M/--mount-master (verified in their su sources; see CLAUDE.md).
# ---------------------------------------------------------------------------
ubu_detect_root_impl() {
    UBU_ROOT_IMPL=unknown
    UBU_ROOT_VERSION=""
    _v=$(su -v 2>/dev/null) || _v=""
    case "$_v" in
        *:MAGISKSU*) UBU_ROOT_IMPL=magisk ;;
        *:KernelSU*) UBU_ROOT_IMPL=kernelsu ;;
        *:APatch*) UBU_ROOT_IMPL=apatch ;;
    esac
    if [ "$UBU_ROOT_IMPL" != unknown ]; then
        UBU_ROOT_VERSION=${_v%%:*}
        return 0
    fi
    if [ -d /data/adb/ksu ]; then
        UBU_ROOT_IMPL=kernelsu
    elif [ -d /data/adb/ap ]; then
        UBU_ROOT_IMPL=apatch
    elif [ -d /data/adb/magisk ]; then
        UBU_ROOT_IMPL=magisk
    fi
}
UBU_MOUNT_MASTER_FLAG="--mount-master"

# ---------------------------------------------------------------------------
# Path validation
# ---------------------------------------------------------------------------
# Canonicalize an existing directory (resolves symlinks). Prints nothing on failure.
ubu_canon_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

# Refuse paths that could ever point at real device data.
ubu_validate_paths() {
    _ws=$(printf ' \t\n_'); _ws=${_ws%_}
    case "$UBU_BASE$ROOTFS" in
        *[$_ws]*) ubu_die "paths must not contain whitespace" ;;
    esac
    case "$UBU_BASE" in
        /*/*) ;;
        *) ubu_die "UBU_BASE must be an absolute path at least two levels deep: '$UBU_BASE'" ;;
    esac
    case "$ROOTFS" in
        "$UBU_BASE"/?*) ;;
        *) ubu_die "ROOTFS ($ROOTFS) must be inside UBU_BASE ($UBU_BASE)" ;;
    esac
    case "/$UBU_BASE/$ROOTFS/" in
        */../* | */./*) ubu_die "paths must not contain '.' or '..' components" ;;
    esac
    # Resolve symlinks so that comparisons against /proc/self/mounts are exact.
    if [ -d "$UBU_BASE" ]; then
        _c=$(ubu_canon_dir "$UBU_BASE") && [ -n "$_c" ] && UBU_BASE=$_c
    fi
    if [ -d "$ROOTFS" ]; then
        _c=$(ubu_canon_dir "$ROOTFS") && [ -n "$_c" ] && ROOTFS=$_c
        case "$ROOTFS" in
            "$UBU_BASE"/?*) ;;
            *) ubu_die "ROOTFS resolves outside UBU_BASE: $ROOTFS" ;;
        esac
    fi
}

ubu_rootfs_installed() { [ -x "$ROOTFS/usr/bin/env" ] && [ -x "$ROOTFS/bin/bash" ]; }

# ---------------------------------------------------------------------------
# Mount table helpers (paths in /proc/self/mounts escape ' ' as \040 etc.;
# our paths are validated whitespace-free, so raw comparison is exact)
# ---------------------------------------------------------------------------
ubu_unescape() {
    case "$1" in
        *\\*) printf '%b' "$(printf '%s' "$1" | sed 's/\\\([0-7][0-7][0-7]\)/\\0\1/g')" ;;
        *) printf '%s' "$1" ;;
    esac
}

# One awk instead of a shell read loop: with Magisk's Zygisk the mount table
# has ~2000 lines (magic mount binds every file of /system/lib*).
ubu_is_mounted() {
    bb awk -v p="$1" '$2 == p { f = 1; exit } END { exit !f }' "$UBU_MOUNTS_FILE"
}

# Mountpoints equal to or below $1, deepest first (stacked mounts repeat).
ubu_mounts_under() {
    bb awk -v p="$1" '$2 == p || index($2, p "/") == 1 { n = gsub("/", "/", $2); print n " " $2 }' \
        "$UBU_MOUNTS_FILE" | bb sort -rn | bb cut -d' ' -f2-
}

ubu_count_mounts_under() { ubu_mounts_under "$1" | bb wc -l | tr -d ' '; }

# Exit 0 if any mount at/below $1 is still in a shared peer group.
ubu_any_shared_under() {
    [ -r "$UBU_MOUNTINFO_FILE" ] || return 1
    bb awk -v p="$1" '
        $5 == p || index($5, p "/") == 1 {
            for (i = 7; i <= NF && $i != "-"; i++) if ($i ~ /^shared:/) found = 1
        }
        END { exit found ? 0 : 1 }' "$UBU_MOUNTINFO_FILE"
}

# ubu_set_propagation private|rprivate|slave|rslave TARGET
# Verified through mountinfo: no mount at/below TARGET may remain shared.
ubu_set_propagation() {
    bb mount --make-"$1" "$2" 2>/dev/null || bb mount -o "$1" "$2" 2>/dev/null || return 1
    if ubu_any_shared_under "$2"; then return 1; fi
    return 0
}

# ubu_mount_fs TYPE SOURCE TARGET [OPTIONS]  (idempotent)
ubu_mount_fs() {
    if ubu_is_mounted "$3"; then return 0; fi
    mkdir -p "$3" || return 1
    if [ -n "${4:-}" ]; then
        bb mount -t "$1" -o "$4" "$2" "$3"
    else
        bb mount -t "$1" "$2" "$3"
    fi
}

# ubu_bind bind|rbind SOURCE TARGET  (idempotent; result is always rslave)
# If the propagation change fails we must NOT unmount: on an rbind tree that
# is still shared, the umount itself would propagate to the real mounts.
ubu_bind() {
    if ubu_is_mounted "$3"; then return 0; fi
    if [ -d "$2" ]; then
        mkdir -p "$3" || return 1
    else
        mkdir -p "${3%/*}" && { [ -e "$3" ] || : >"$3"; } || return 1
    fi
    bb mount -o "$1" "$2" "$3" || return 1
    ubu_set_propagation rslave "$3" ||
        ubu_die "bound $2 at $3 but could not make it rslave; NOT unmounting (unsafe). Reboot to clear it."
}

# ---------------------------------------------------------------------------
# CRITICAL SAFETY RULE
#   Never rm -rf anything under UBU_BASE while mounts exist below it: with
#   /data and /sdcard bind-mounted inside, that would erase the phone's real
#   data. This is the ONLY function allowed to delete under UBU_BASE.
#   Exit codes: 0 deleted (or absent), 3 refused.
# ---------------------------------------------------------------------------
ubu_safe_rm() {
    _target=$1
    if [ -L "$_target" ]; then
        ubu_log "REFUSED: $_target is a symlink"
        return 3
    fi
    [ -e "$_target" ] || return 0
    _canon=$(ubu_canon_dir "$_target")
    [ -n "$_canon" ] || { ubu_log "REFUSED: cannot resolve $_target"; return 3; }
    case "$_canon" in
        "$UBU_BASE"/?*) ;;
        *)
            ubu_log "REFUSED: $_canon is not strictly inside $UBU_BASE"
            return 3
            ;;
    esac

    # 1) Nothing may be mounted at or below the target.
    _left=$(ubu_mounts_under "$_canon")
    if [ -n "$_left" ]; then
        ubu_log "REFUSED to delete $_canon: still mounted:"
        printf '%s\n' "$_left" | sed 's/^/[uburoot]   /' >&2
        return 3
    fi

    # 2) Bind targets must be removable with rmdir (rmdir never deletes content).
    for _d in $UBU_BIND_TARGETS; do
        _p="$_canon/$_d"
        [ -L "$_p" ] && continue
        [ -d "$_p" ] || continue
        if ! rmdir "$_p" 2>/dev/null; then
            ubu_log "REFUSED to delete $_canon: mountpoint $_p is not empty"
            ubu_log "  (it may be a live mount in another namespace or hold your files)"
            return 3
        fi
    done

    # 3) Markers of live kernel filesystems / the real /dev.
    for _m in proc/self sys/kernel dev/block dev/binder; do
        if [ -e "$_canon/$_m" ]; then
            ubu_log "REFUSED to delete $_canon: $_canon/$_m exists (live mount?)"
            return 3
        fi
    done

    # 4) Re-check right before deleting.
    if [ "$(ubu_count_mounts_under "$_canon")" != 0 ]; then
        ubu_log "REFUSED to delete $_canon: a mount appeared under it"
        return 3
    fi

    ubu_log "deleting $_canon"
    bb rm -rf "$_canon"
}

# ubu_ensure_profile_hook ROOTFS: login hook that applies UBU_CWD / UBU_INIT
# (start directory and initial command chosen by the app), then unsets them.
ubu_ensure_profile_hook() {
    _f="$1/etc/profile.d/uburoot.sh"
    [ -f "$_f" ] && return 0
    mkdir -p "$1/etc/profile.d" || return 1
    cat >"$_f" <<'EOF'
# UbuRoot login hook: start directory and initial command chosen by the app.
if [ -n "${UBU_CWD:-}" ]; then
    cd "$UBU_CWD" 2>/dev/null || cd "$HOME" 2>/dev/null || cd /
fi
unset UBU_CWD
if [ -n "${UBU_INIT:-}" ]; then
    _ubu_init=$UBU_INIT
    unset UBU_INIT
    eval "$_ubu_init"
    unset _ubu_init
fi
EOF
}

# ---------------------------------------------------------------------------
# Processes chrooted into the rootfs (their /proc/PID/root points inside it).
# One ls + awk instead of a readlink per process: ~600 forks took ~12 s when
# run from the app, whose root shells share its (background-limited) cgroup.
ubu_chroot_pids() {
    # shellcheck disable=SC2012 # symlink targets of /proc/*/root: no odd file names here
    ls -l /proc/[0-9]*/root 2>/dev/null | bb awk -v r="$ROOTFS" '
        $(NF - 1) == "->" && ($NF == r || index($NF, r "/") == 1) {
            split($(NF - 2), a, "/")
            print a[3]
        }'
}

ubu_init() {
    ubu_detect_busybox
    ubu_validate_paths
}
