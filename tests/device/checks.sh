#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs ON THE DEVICE as root in the global mount namespace (see run.sh).
# Assumes install.sh + setup.sh --user <name> --nopasswd already ran (the
# app's installer does that). The user is TEST_USER, else DEFAULT_USER from
# uburoot.conf, else tester.
# Usage: checks.sh [--reset]   (--reset: also run the real reset at the end)
set -u
B=/data/local/uburoot/bin
R=/data/local/uburoot/rootfs
# shellcheck disable=SC1091 # the config only exists on the device
TU=${TEST_USER:-$( . /data/local/uburoot/uburoot.conf 2>/dev/null; echo "${DEFAULT_USER:-tester}")}
[ "$TU" = root ] && TU=tester
BBX=/data/adb/magisk/busybox
[ -x "$BBX" ] || BBX=/data/adb/ksu/bin/busybox
[ -x "$BBX" ] || BBX=/data/adb/ap/bin/busybox

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }
has() { # has "description" "haystack" "needle"
    case "$2" in *"$3"*) ok "$1" ;; *) bad "$1"; printf '%s\n' "$2" | sed 's/^/       | /' | tail -8 ;; esac
}
check() {
    _d=$1
    shift
    if "$@" >/dev/null 2>&1; then ok "$_d"; else bad "$_d"; fi
}
section() { printf '\n== %s ==\n' "$*"; }
under() { "$BBX" awk -v p="$R" '$2 == p || index($2, p "/") == 1' /proc/self/mounts | wc -l | tr -d ' '; }
total() { wc -l </proc/self/mountinfo | tr -d ' '; }
apex() { grep -c ' /apex/' /proc/self/mountinfo; }

section "environment"
printf '  info: mnt ns self=%s init=%s\n' "$(readlink /proc/self/ns/mnt)" "$(readlink /proc/1/ns/mnt)"
check "running in the global mount namespace" test "$(readlink /proc/self/ns/mnt)" = "$(readlink /proc/1/ns/mnt)"
check "rootfs installed" test -x $R/usr/bin/env

# Sentinels in the REAL storage, checked after every dangerous step.
SENT_DATA=/data/local/tmp/uburoot-sentinel
SENT_SD=/storage/emulated/0/Download/.uburoot-sentinel
echo keep >$SENT_DATA
echo keep >$SENT_SD
sentinels() { [ -f $SENT_DATA ] && [ -f $SENT_SD ] && [ -d /data/data/android ] && [ -x /system/bin/sh ]; }

section "root quality and doctor"
info=$(sh $B/rootinfo.sh 2>/dev/null)
has "rootinfo: full root" "$info" "full_root=yes"
case "$info" in *"schema=0"* | *"schema=1"*) ok "rootinfo: schema reported" ;; *) bad "rootinfo: schema reported" ;; esac
_mi=$(total)
sh $B/doctor.sh >/data/local/tmp/uburoot-doctor.txt 2>&1
check "doctor runs" test "$?" = 0
has "doctor: summary" "$(cat /data/local/tmp/uburoot-doctor.txt)" "summary: "
check "doctor: no FAIL line" sh -c "! grep -q '\[FAIL\]' /data/local/tmp/uburoot-doctor.txt"
check "doctor: changed no mounts" test "$(total)" = "$_mi"
sh $B/doctor.sh --redact >/data/local/tmp/uburoot-doctor.txt 2>&1
check "doctor --redact hides the user" sh -c "! grep -qw '$TU' /data/local/tmp/uburoot-doctor.txt"
rm -f /data/local/tmp/uburoot-doctor.txt

section "mount.sh"
$B/umount.sh >/dev/null 2>&1
base_total=$(total)
base_apex=$(apex)
printf '  info: baseline: %s mounts in ns, %s under /apex\n' "$base_total" "$base_apex"
check "mount.sh" $B/mount.sh
n1=$(under)
$B/mount.sh >/dev/null 2>&1
check "idempotent ($n1 mounts under rootfs, same after re-run)" test "$n1" = "$(under)"
for m in "" /proc /sys /dev /dev/pts /dev/shm /run /sdcard /system /vendor /odm /apex /linkerconfig /data; do
    check "mounted: ${m:-/ (self-bind)}" grep -q " $R$m " /proc/self/mounts
done
check "rootfs self-bind is not nosuid (sudo)" sh -c "! grep ' $R ' /proc/self/mounts | grep -q nosuid"
check "/product mirrored as symlink" test "$(readlink $R/product)" = /system/product
check "no shared mount under rootfs" sh -c "! $BBX awk -v p=$R '(\$5==p||index(\$5,p\"/\")==1){for(i=7;i<=NF&&\$i!=\"-\";i++)if(\$i~/^shared:/)f=1}END{exit !f}' /proc/self/mountinfo"
check "real /apex unchanged while mounted ($base_apex)" test "$(apex)" -ge "$base_apex"

section "enter.sh as root"
out=$($B/enter.sh root 'id; cat /etc/os-release | grep PRETTY; ls -d /sdcard/Download; ls -d /data/data/android' 2>&1)
has "uid 0 with aid_inet group" "$out" "3003(aid_inet)"
has "Ubuntu userland" "$out" 'Ubuntu'
has "/sdcard visible" "$out" "/sdcard/Download"
has "/data visible" "$out" "/data/data/android"
out=$($B/enter.sh root 'timeout 8 bash -c "echo > /dev/tcp/1.1.1.1/53" && echo TCP_OK; getent hosts ports.ubuntu.com >/dev/null && echo DNS_OK' 2>&1)
has "root: TCP (paranoid network)" "$out" TCP_OK
has "root: DNS" "$out" DNS_OK

section "Android wrappers (bionic inside the chroot)"
out=$($B/enter.sh root 'getprop ro.product.model' 2>&1)
has "getprop" "$out" "$(getprop ro.product.model)"
out=$($B/enter.sh root 'pm path android' 2>&1)
has "pm path android" "$out" "package:/system/framework/framework-res.apk"
out=$($B/enter.sh root 'cmd package list packages android | grep -x package:android' 2>&1)
has "cmd package" "$out" "package:android"
out=$($B/enter.sh root 'settings get global adb_enabled' 2>&1)
has "settings get" "$out" "1"
out=$($B/enter.sh root 'dumpsys battery | head -3' 2>&1)
has "dumpsys battery" "$out" "Current Battery Service state"
out=$($B/enter.sh root 'am get-current-user' 2>&1)
has "am get-current-user" "$out" "0"
out=$($B/enter.sh root 'android toybox --version' 2>&1)
has "generic 'android <cmd>' runner" "$out" "toybox"

section "enter.sh as user $TU (uid 9000)"
out=$($B/enter.sh "$TU" 'id; pwd; sudo -n true && echo SUDO_OK' 2>&1)
has "uid 9000" "$out" "uid=9000($TU)"
has "aid_inet via su -" "$out" "3003(aid_inet)"
has "home dir" "$out" "/home/$TU"
has "sudo NOPASSWD" "$out" SUDO_OK
case "$out" in *"unable to resolve"*) bad "no hostname warning" ;; *) ok "no hostname warning" ;; esac
out=$($B/enter.sh "$TU" 'timeout 8 bash -c "echo > /dev/tcp/1.1.1.1/53" && echo TCP_OK' 2>&1)
has "user: TCP (paranoid network)" "$out" TCP_OK
out=$($B/enter.sh "$TU" 'f=/sdcard/Download/.ubu_check; echo x >$f && stat -c "MODE=%g:%a" $f; rm -f $f' 2>&1)
has "user writes /sdcard (group media_rw, group-writable)" "$out" "MODE=1023:664"
out=$(UBU_CWD=/sdcard/Download $B/enter.sh "$TU" pwd 2>&1)
has "UBU_CWD start dir" "$out" /sdcard/Download
out=$($B/enter.sh "$TU" 'getprop ro.product.model' 2>&1)
has "user: getprop" "$out" "$(getprop ro.product.model)"

section "CRITICAL RULE with real mounts: sabotaged umount"
cat >/data/local/tmp/fakebb <<EOF
#!/system/bin/sh
[ "\$1" = umount ] && { echo "sabotaged umount \$*" >&2; exit 1; }
exec $BBX "\$@"
EOF
chmod 755 /data/local/tmp/fakebb
before=$(under)
UBU_BB=/data/local/tmp/fakebb $B/reset.sh --yes >/data/local/tmp/reset-sabotaged.log 2>&1
rc=$?
check "reset aborted (rc=3, got $rc)" test "$rc" = 3
check "mounts untouched ($before)" test "$(under)" = "$before"
check "rootfs intact" test -x $R/usr/bin/env
check "real /data, /sdcard, /system intact" sentinels
rm -f /data/local/tmp/fakebb

section "umount.sh"
check "umount.sh" $B/umount.sh
check "nothing under rootfs" test "$(under)" = 0
check "namespace back to baseline ($base_total mounts)" test "$(total)" = "$base_total"
check "real /apex submounts intact ($base_apex)" test "$(apex)" = "$base_apex"
check "real /data, /sdcard, /system intact" sentinels

if [ "${1:-}" = --reset ]; then
    section "REAL reset with a live session (--kill)"
    $B/enter.sh root 'sleep 600' >/dev/null 2>&1 &
    sleep 3
    check "session running" sh -c "for p in /proc/[0-9]*; do [ \"\$(readlink \$p/root)\" = $R ] && exit 0; done; exit 1"
    check "mounts present before reset" test "$(under)" -gt 0
    $B/reset.sh --yes >/data/local/tmp/reset-real.log 2>&1
    rc=$?
    check "reset.sh (rc=$rc)" test "$rc" = 0
    check "rootfs removed" test ! -e $R
    check "namespace back to baseline" test "$(total)" = "$base_total"
    check "real /data, /sdcard, /system intact" sentinels
fi

rm -f $SENT_DATA $SENT_SD
printf '\ndevice suite: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
