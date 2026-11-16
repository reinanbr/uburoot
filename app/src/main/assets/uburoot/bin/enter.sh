#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Enter the Ubuntu chroot with a clean environment.
# Usage: enter.sh [user] [command...]
#   user     Ubuntu user (default: DEFAULT_USER from config, else root)
#   command  run it non-interactively instead of a login shell
# Environment (optional, set by the app):
#   UBU_CWD  start directory (path inside the chroot, e.g. /sdcard/Download)
set -u
UBU_BIN_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=common.sh
. "$UBU_BIN_DIR/common.sh"

ubu_require_root
ubu_init
ubu_load_config
"$UBU_SH" "$UBU_BIN_DIR/mount.sh" || ubu_die "mount.sh failed; not entering"

R=$ROOTFS
_user=${DEFAULT_USER:-root}
if [ $# -gt 0 ]; then
    [ -n "$1" ] && _user=$1
    shift
fi
_cmd="$*"

case "$_user" in
    [a-z_]*) ;;
    *) ubu_die "invalid user name: $_user" ;;
esac
case "$_user" in
    *[!a-z0-9_-]*) ubu_die "invalid user name: $_user" ;;
esac
_home=$(bb awk -F: -v u="$_user" '$1 == u { print $6; exit }' "$R/etc/passwd")
[ -n "$_home" ] || ubu_die "user '$_user' does not exist in the rootfs"

# Make sure the login hook exists even on rootfs set up by older versions.
ubu_ensure_profile_hook "$R" || ubu_warn "could not write /etc/profile.d/uburoot.sh"

_cwd=${UBU_CWD:-$_home}
_init=""
[ -z "$_cmd" ] && _init=$INIT_COMMAND
_path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if [ -n "$BB" ] && [ "$BB_KIND" = busybox ]; then
    set -- "$BB" chroot "$R"
else
    set -- chroot "$R"
fi
# Magisk's su hands the root process our tty but setsid()s it without making
# it the controlling terminal (seen on a device: tty_nr=0 while fd 0 is the
# terminal's pts). bash then has no job control, and Ctrl+C goes to the su
# client's process group. util-linux setsid --ctty starts a new session and
# takes the tty over (TIOCSCTTY with force, allowed for root).
if [ -t 0 ] && [ -x "$R/usr/bin/setsid" ]; then
    set -- "$@" /usr/bin/setsid --ctty --wait
fi
set -- "$@" /usr/bin/env -i \
    TERM=xterm-256color COLORTERM=truecolor LANG=C.UTF-8 PATH="$_path" \
    UBU_CWD="$_cwd" UBU_INIT="$_init"

if [ "$_user" = root ]; then
    set -- "$@" HOME="$_home" USER=root LOGNAME=root SHELL=/bin/bash
    # setpriv --init-groups gives root its supplementary groups from
    # /etc/group (aid_inet etc., needed under ANDROID_PARANOID_NETWORK).
    if [ -x "$R/usr/bin/setpriv" ]; then
        set -- "$@" /usr/bin/setpriv --reuid=0 --regid=0 --init-groups --
    fi
    if [ -n "$_cmd" ]; then
        exec "$@" /bin/bash -lc "$_cmd"
    fi
    exec "$@" /bin/bash -l
fi

# Non-root: su - (PAM, initgroups). -w keeps our variables across the env reset.
# Interactive shells must NOT use su -c: it calls setsid() and loses job control.
set -- "$@" /bin/su -w UBU_CWD,UBU_INIT,COLORTERM -l "$_user"
if [ -n "$_cmd" ]; then
    exec "$@" -c "$_cmd"
fi
exec "$@"
