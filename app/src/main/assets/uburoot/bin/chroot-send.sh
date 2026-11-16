#!/bin/sh
# Installed by android-env into the rootfs as /usr/local/lib/uburoot/uburoot-send.
# Runs INSIDE the chroot, as root: the uburoot-* commands call it through a
# sudo rule that allows exactly this file. It sends one command to the UbuRoot
# app with `am broadcast` (only root, system or the app itself may: the
# receiver is protected by a signature permission, and a chroot user's uid
# holds no Android permission at all).
#
# Usage: uburoot-send notify TITLE [TEXT] | toast TEXT | vibrate [MS]
#                     | clip [TEXT] (stdin without TEXT) | open FILE|URL
#
# Files are read with the CALLER's identity (setpriv), never as root, so a user
# can't open what they can't read. A file is copied into a root-only outbox
# (/var/lib/uburoot/outbox) and the app takes it from there (bridge.sh take).
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

APP=com.reinanbr.uburoot
OUTBOX=/var/lib/uburoot/outbox
MAX_TEXT=100000 # bytes; a broadcast travels in one binder transaction (1 MB)

die() {
    printf 'uburoot: %s\n' "$*" >&2
    exit 1
}

[ "$(id -u)" = 0 ] || die "uburoot-send must run as root (the uburoot-* commands call it through sudo)"
[ $# -ge 1 ] || die "usage: uburoot-send notify|toast|vibrate|clip|open ARGS..."
cmd=$1
shift

# Who asked: sudo sets SUDO_UID/SUDO_GID; unset when root calls it directly.
uid=${SUDO_UID:-0}
gid=${SUDO_GID:-0}
case "$uid$gid" in
    *[!0-9]*) die "bad SUDO_UID/SUDO_GID" ;;
esac

as_caller() {
    if [ "$uid" = 0 ]; then
        "$@"
    else
        setpriv --reuid="$uid" --regid="$gid" --init-groups -- "$@"
    fi
}

check_text() {
    [ "$(printf '%s' "$1" | wc -c)" -le "$MAX_TEXT" ] || die "text longer than $MAX_TEXT bytes"
}

# send EXTRA_ARGS... : broadcast to the app's receiver and wait for its answer.
send() {
    _opts="--user 0 --receiver-foreground"
    if [ "$cmd" = open ]; then
        # Android 10+ blocks activity starts from the background; this option
        # (root may use it) lets the receiver open the viewer anyway.
        _sdk=$(getprop ro.build.version.sdk 2>/dev/null) || _sdk=0
        case "$_sdk" in
            '' | *[!0-9]*) _sdk=0 ;;
        esac
        if [ "$_sdk" -ge 29 ]; then _opts="$_opts --allow-background-activity-starts"; fi
    fi
    [ -x /usr/local/bin/am ] || die "Android integration is off (no am in Ubuntu); turn it on in the app's settings"
    # shellcheck disable=SC2086 # _opts is a list of fixed options
    _out=$(am broadcast $_opts -a "$APP.CMD" -n "$APP/.bridge.CommandReceiver" --es cmd "$cmd" "$@" 2>&1) ||
        die "am broadcast failed: $_out"
    # The receiver answers RESULT_OK (-1), or an error message as result data.
    case "$_out" in
        *"result=-1"*) return 0 ;;
        *'data="'*)
            _msg=${_out#*data=\"}
            die "${_msg%\"*}"
            ;;
        *) die "the UbuRoot app did not answer (is it installed?)" ;;
    esac
}

case "$cmd" in
    notify)
        if [ $# -lt 1 ] || [ $# -gt 2 ]; then die "usage: uburoot-notify TITLE [TEXT]"; fi
        check_text "$1${2:-}"
        send --es title "$1" --es text "${2:-}"
        ;;
    toast)
        [ $# -eq 1 ] || die "usage: uburoot-toast TEXT"
        check_text "$1"
        send --es text "$1"
        ;;
    vibrate)
        [ $# -le 1 ] || die "usage: uburoot-vibrate [MS]   (default 300, at most 10000)"
        _ms=${1:-300}
        case "$_ms" in
            '' | *[!0-9]*) die "usage: uburoot-vibrate [MS]   (milliseconds)" ;;
        esac
        if [ "$_ms" -lt 1 ] || [ "$_ms" -gt 10000 ]; then die "vibrate: 1..10000 ms"; fi
        send --es ms "$_ms"
        ;;
    clip)
        [ $# -le 1 ] || die "usage: uburoot-clip [TEXT]   (reads stdin without TEXT)"
        if [ $# -eq 1 ]; then
            _text=$1
        else
            # $(...) drops trailing newlines, as copying a command's output should.
            _text=$(head -c $((MAX_TEXT + 1)))
        fi
        check_text "$_text"
        send --es text "$_text"
        ;;
    open)
        if [ $# -ne 1 ] || [ -z "$1" ]; then die "usage: uburoot-open FILE|URL"; fi
        case "$1" in
            [a-zA-Z]*://* | mailto:* | tel:* | geo:* | sms:*)
                send --es url "$1"
                exit 0
                ;;
            file://*) _path=${1#file://} ;;
            *) _path=$1 ;;
        esac
        as_caller test -f "$_path" || die "open: not a readable file: $_path"
        as_caller test -r "$_path" || die "open: permission denied: $_path"
        mkdir -p "$OUTBOX"
        chmod 700 /var/lib/uburoot "$OUTBOX"
        # Leftovers the app never took (app gone, phone rebooted...).
        find "$OUTBOX" -type f -mmin +1440 -delete 2>/dev/null || true
        _id=$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')
        # Removed again on any failure; on success the app takes it (bridge.sh take).
        trap 'rm -f "$OUTBOX/$_id"' EXIT
        # Read as the caller, written by root into the root-only outbox.
        as_caller cat -- "$_path" >"$OUTBOX/$_id" || die "open: cannot read $_path"
        _mime=""
        if command -v file >/dev/null 2>&1; then
            _mime=$(file -b --mime-type "$OUTBOX/$_id" 2>/dev/null) || _mime=""
        fi
        send --es id "$_id" --es name "${_path##*/}" --es mime "$_mime"
        trap - EXIT
        ;;
    *) die "unknown command: $cmd (notify, toast, vibrate, clip, open)" ;;
esac
