#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Installed by android-env into the rootfs as /usr/local/lib/uburoot/uburoot-cmd;
# /usr/local/bin/uburoot-{notify,toast,vibrate,clip,open} and xdg-open link to it.
# Runs inside Ubuntu as any user and hands over to the root helper
# (uburoot-send) through the sudo rule in /etc/sudoers.d/80-uburoot.
SEND=/usr/local/lib/uburoot/uburoot-send

name=${0##*/}
case "$name" in
    xdg-open) cmd=open ;;
    uburoot-*) cmd=${name#uburoot-} ;;
    *)
        cmd=${1:-}
        [ $# -gt 0 ] && shift
        ;;
esac

case "${1:-}" in
    -h | --help)
        case "$cmd" in
            notify) echo "usage: uburoot-notify TITLE [TEXT]    Android notification" ;;
            toast) echo "usage: uburoot-toast TEXT             short message on screen" ;;
            vibrate) echo "usage: uburoot-vibrate [MS]           vibrate (default 300 ms)" ;;
            clip) echo "usage: uburoot-clip [TEXT]            copy TEXT (or stdin) to Android's clipboard" ;;
            open) echo "usage: uburoot-open FILE|URL          open with an Android app (also: xdg-open)" ;;
            *) echo "usage: uburoot-notify|toast|vibrate|clip|open ..." ;;
        esac
        exit 0
        ;;
esac

if [ "$(id -u)" = 0 ]; then
    exec "$SEND" "$cmd" "$@"
fi
if ! command -v sudo >/dev/null 2>&1; then
    echo "uburoot: sudo is not installed (apt install sudo), or run this as root" >&2
    exit 1
fi
exec sudo -n "$SEND" "$cmd" "$@"
