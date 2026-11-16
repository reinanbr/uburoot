#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Hang up one terminal session, like closing a terminal window: SIGHUP (then
# SIGCONT) to every process inside the chroot whose controlling terminal is
# that session's pty. Processes started with nohup/setsid survive, as usual.
#
# Usage: hangup.sh PID
#   PID  any process whose stdin is the session's pty (the app passes its own
#        `su` client of that session)
#
# Why not just close the pty: the kernel then signals only the session leader,
# which is util-linux `su -` (enter.sh), and su blocks SIGHUP while it waits
# for its shell. The shell kept running on the device (see CLAUDE.md).
set -u
UBU_BIN_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=common.sh
. "$UBU_BIN_DIR/common.sh"

ubu_require_root
ubu_init

_pid=${1:-}
case "$_pid" in
    '' | *[!0-9]*) ubu_die "usage: hangup.sh PID" ;;
esac

# Device numbers of the pty, through the magic link: right in any mount namespace.
_dev=$(bb stat -L -c '%t %T' "/proc/$_pid/fd/0" 2>/dev/null) || ubu_die "cannot stat stdin of $_pid"
_maj=$(printf '%d' "0x${_dev% *}")
_min=$(printf '%d' "0x${_dev#* }")
# Unix98 pty slaves: majors 136..143 (Documentation/admin-guide/devices.txt).
if [ "$_maj" -lt 136 ] || [ "$_maj" -gt 143 ]; then
    ubu_die "stdin of $_pid is not a pty"
fi
# tty_nr as /proc/PID/stat encodes it (new_encode_dev).
_nr=$(((_maj << 8) | (_min & 255) | ((_min >> 8) << 20)))

_hup=""
for _p in $(ubu_chroot_pids); do
    _s=$(cat "/proc/$_p/stat" 2>/dev/null) || continue
    # Field 7 (tty_nr); comm (field 2) may contain spaces, so cut after its ")".
    _s=${_s##*) }
    # shellcheck disable=SC2086 # split the remaining fields on purpose
    set -- $_s
    [ "${5:-0}" = "$_nr" ] && _hup="$_hup $_p"
done

if [ -z "$_hup" ]; then
    ubu_log "no chroot process on that terminal"
    exit 0
fi
ubu_log "hangup:$_hup"
# shellcheck disable=SC2086 # word splitting of the pid list is intended
kill -HUP $_hup 2>/dev/null
# shellcheck disable=SC2086
kill -CONT $_hup 2>/dev/null
exit 0
