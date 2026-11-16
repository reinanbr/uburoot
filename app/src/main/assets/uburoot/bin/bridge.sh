#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Android side of the app <-> Ubuntu bridge (Phase 4). Called by the app.
# Usage:
#   bridge.sh take ID DEST
#       Move a file that uburoot-open put in the rootfs outbox into DEST, a
#       file the app created in its own cache (so owner and SELinux label are
#       the app's). ID is the hex id from the broadcast.
#   bridge.sh import SRC NAME
#       Copy SRC (a file the app received through "Open in UbuRoot") into
#       ~/Shared/NAME of the default user, and print that directory (a path
#       inside Ubuntu). The copy runs INSIDE the chroot as that user, so a
#       symlink in the user's home can't make root write outside it.
#   bridge.sh cwd DIR
#       Exit 0 if DIR (a path inside Ubuntu, e.g. /sdcard/Download) is a
#       directory the default user can enter; mounts first, as a session would.
set -u
UBU_BIN_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=common.sh
. "$UBU_BIN_DIR/common.sh"

ubu_require_root
ubu_init
ubu_load_config

R=$ROOTFS
OUTBOX="$R/var/lib/uburoot/outbox"

# Mounts as enter.sh does and sets the default user's uid/gid/home.
mount_and_set_user() {
    _user=${DEFAULT_USER:-root}
    case "$_user" in
        *[!a-z0-9_-]* | '') ubu_die "invalid user name: $_user" ;;
    esac
    "$UBU_SH" "$UBU_BIN_DIR/mount.sh" >/dev/null || ubu_die "mount.sh failed"
    _pw=$(bb awk -F: -v u="$_user" '$1 == u { print $3 ":" $4 ":" $6; exit }' "$R/etc/passwd")
    [ -n "$_pw" ] || ubu_die "user '$_user' does not exist in the rootfs"
    _uid=${_pw%%:*}
    _rest=${_pw#*:}
    _gid=${_rest%%:*}
    _home=${_rest#*:}
}

# as_user CMD...: run CMD inside the chroot as the default user, clean env.
as_user() {
    set -- /usr/bin/env -i PATH=/usr/bin:/bin "HOME=$_home" "$@"
    if [ "$_uid" != 0 ]; then
        set -- /usr/bin/setpriv --reuid="$_uid" --regid="$_gid" --init-groups -- "$@"
    fi
    bb chroot "$R" "$@"
}

case "${1:-}" in
    take)
        [ $# -eq 3 ] || ubu_die "usage: bridge.sh take ID DEST"
        _id=$2
        _dest=$3
        case "$_id" in
            '' | *[!0-9a-f]*) ubu_die "bad id: $_id" ;;
        esac
        [ "${#_id}" -eq 16 ] || ubu_die "bad id: $_id"
        _src="$OUTBOX/$_id"
        # The outbox is root-only (0700), written by uburoot-send as root.
        if [ -L "$_src" ] || [ ! -f "$_src" ]; then
            ubu_die "no such outbox file: $_id"
        fi
        if [ -L "$_dest" ] || [ ! -f "$_dest" ]; then
            ubu_die "destination must be an existing regular file: $_dest"
        fi
        cat "$_src" >"$_dest" || ubu_die "copy failed"
        rm -f "$_src"
        ;;
    import)
        [ $# -eq 3 ] || ubu_die "usage: bridge.sh import SRC NAME"
        _src=$2
        _name=${3##*/}
        case "$_name" in
            '' | . | ..) _name=shared-file ;;
        esac
        [ -f "$_src" ] || ubu_die "no such file: $_src"
        mount_and_set_user
        # Inside the chroot, as the user: mkdir ~/Shared, pick a free name, write
        # stdin there and print the directory. The name travels as an argument.
        # shellcheck disable=SC2016 # expanded by the shell inside the chroot
        _script='set -e
d="$HOME/Shared"
mkdir -p "$d"
n=$1
i=1
while [ -e "$d/$n" ] || [ -L "$d/$n" ]; do
    n="$i-$1"
    i=$((i + 1))
done
cat >"$d/$n"
printf "%s\n" "$d"'
        as_user /bin/sh -c "$_script" sh "$_name" <"$_src" || ubu_die "import failed"
        ;;
    cwd)
        [ $# -eq 2 ] || ubu_die "usage: bridge.sh cwd DIR"
        case "$2" in
            /*) ;;
            *) ubu_die "not an absolute path: $2" ;;
        esac
        mount_and_set_user
        as_user /bin/sh -c '[ -d "$1" ] && [ -x "$1" ]' sh "$2" </dev/null
        exit $?
        ;;
    *) ubu_die "usage: bridge.sh take ID DEST | import SRC NAME | cwd DIR" ;;
esac
exit 0
