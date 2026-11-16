#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs INSIDE an interactive UbuRoot session, typed in the app's terminal, as
# the default (non-root) user. It covers what only a real app session has:
# su -> enter.sh -> setsid --ctty -> su - user, with a tty and job control.
#
#   sh /tmp/uburoot-session-test.sh 2>&1 | tee /tmp/uburoot-session-test.log
#
# Needs network (apt installs curl, ca-certificates and iputils-ping) and
# passwordless sudo for the user.
PASS=0
FAIL=0
OUT=/tmp/.uburoot-session-test.out

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }
# t "description" cmd...: pass when cmd succeeds; show its output otherwise.
t() {
    _d=$1
    shift
    if "$@" >"$OUT" 2>&1; then ok "$_d"; else bad "$_d" && sed 's/^/       | /' "$OUT" | tail -6; fi
}

section "identity"
t "non-root user with uid < 10000 (netd exempts only those)" \
    sh -c '[ "$(id -u)" -gt 0 ] && [ "$(id -u)" -lt 10000 ]'
for g in aid_inet aid_media_rw sudo; do
    t "member of $g" sh -c "id -Gn | tr ' ' '\n' | grep -qx $g"
done
# On Android kernels these two act as CAP_NET_RAW / CAP_NET_ADMIN.
for g in aid_net_raw aid_net_admin; do
    t "not a member of $g (no packet capture without sudo)" sh -c "! id -Gn | tr ' ' '\n' | grep -qx $g"
done

section "terminal"
t "stdin is a tty" test -t 0
# /proc/<pid>/stat after "(comm) ": state ppid pgrp session tty_nr tpgid
t "job control: our process group is the tty's foreground group" sh -c '
    set -- $(sed "s/^.*) //" /proc/$$/stat)
    [ "$5" != 0 ] && [ "$6" = "$3" ]'
t "TERM=xterm-256color with 256 colors" sh -c '[ "$TERM" = xterm-256color ] && [ "$(tput colors)" -ge 256 ]'
t "UTF-8 locale" sh -c '[ "$(locale charmap)" = UTF-8 ]'

section "privileges"
t "sudo without password" sudo -n true
t "setuid works: rootfs is not mounted nosuid" sh -c '! awk "\$2 == \"/\" { print \$4 }" /proc/self/mounts | grep -q nosuid'

section "network (as the user unless noted)"
t "DNS: ports.ubuntu.com" getent hosts ports.ubuntu.com
t "apt-get update (root, _apt sandbox)" sudo -n apt-get -qq update
t "apt-get install curl ca-certificates iputils-ping" \
    sudo -n env DEBIAN_FRONTEND=noninteractive apt-get -qq install -y curl ca-certificates iputils-ping
t "HTTPS: cdimage.ubuntu.com" curl -fsSI --max-time 20 https://cdimage.ubuntu.com/ubuntu-base/releases/
t "ICMP ping 1.1.1.1" ping -c 1 -W 5 1.1.1.1

section "shared storage"
F=/sdcard/Download/.uburoot-session-test
t "write /sdcard/Download" sh -c "echo uburoot > $F"
t "file is group media_rw (1023), group-writable" sh -c "[ \"\$(stat -c %g:%a $F)\" = 1023:664 ]"
rm -f "$F"

section "Android system stays protected"
t "user cannot list other apps' data (/data/data)" sh -c '! ls /data/data >/dev/null 2>&1'
t "root (sudo) can list /data/data" sudo -n sh -c 'ls /data/data >/dev/null'
for p in /system /vendor /apex/com.android.runtime; do
    t "$p is read-only even for root" sudo -n sh -c "! touch $p/.uburoot-write-test 2>/dev/null"
done

section "Android commands (bionic inside the chroot; stdin is the tty)"
# Binder commands must work with the terminal as stdin (system_server may
# not use the app's pty; the wrappers hand it pipes instead).
t "getprop ro.build.version.sdk" sh -c 'getprop ro.build.version.sdk | grep -qE "^[0-9]+$"'
t "user: pm path android" sh -c 'pm path android | grep -q framework-res.apk'
t "user: cmd package list packages" sh -c '[ "$(cmd package list packages | grep -c ^package:)" -gt 20 ]'
t "exit status is kept (pm path on a missing package fails)" sh -c '! pm path no.such.package.uburoot'
t "root: settings get global adb_enabled" sh -c '[ "$(sudo -n settings get global adb_enabled)" = 1 ]'
t "root: dumpsys battery" sh -c 'sudo -n dumpsys battery | grep -q "level:"'
t "root: am get-current-user" sh -c '[ "$(sudo -n am get-current-user)" = 0 ]'
t "generic runner: android cmd (binder) and toybox" sh -c '
    android cmd package list packages android | grep -qx package:android &&
    [ "$(android toybox uname -m)" = aarch64 ]'

section "Ubuntu integrity"
t "dpkg --audit: no broken packages" sh -c '[ -z "$(dpkg --audit 2>&1)" ]'
t "apt-get check: dependencies consistent" sudo -n apt-get -qq check
# dpkg -V flags conffiles with "c"; only those may differ (setup.sh edits
# some, e.g. apt sources). Files the minimized image drops on purpose
# (path-exclude in /etc/dpkg/dpkg.cfg.d, e.g. man pages) show up as
# "missing" and are fine. Anything else is a changed or missing file.
t "dpkg -V: every packaged non-config file intact" sudo -n sh -c '
    excl=$(cat /etc/dpkg/dpkg.cfg.d/* 2>/dev/null | sed -n "s/^path-exclude=//p")
    set -f # the patterns must not be expanded against the filesystem
    bad=$(dpkg -V 2>&1 | grep -v "^..5...... c /" | while IFS= read -r line; do
        case "$line" in
            missing*)
                p=${line##* }
                for e in $excl; do
                    case "$p" in $e) continue 2 ;; esac
                done
                ;;
        esac
        printf "%s\n" "$line"
    done)
    [ -z "$bad" ] || { printf "%s\n" "$bad"; exit 1; }'

rm -f "$OUT"
printf '\nsession suite: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
