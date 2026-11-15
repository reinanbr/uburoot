#!/bin/sh
# Runs INSIDE a privileged ubuntu container (see run.sh). Builds a fake
# Android layout with real (shared) mounts and drives the real scripts:
#   install -> setup (real apt) -> mount (x2) -> enter -> wrappers
#   -> sabotaged reset (must abort, data intact) -> umount -> reset (+ --kill)
set -u
TARBALL=$1
SHA=$2

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }
check() { # check "description" command...
    _d=$1
    shift
    if "$@" >/dev/null 2>&1; then ok "$_d"; else bad "$_d"; fi
}
section() { printf '\n== %s ==\n' "$*"; }
mounted_under() { awk -v p="$1" '$2 == p || index($2, p "/") == 1' /proc/self/mounts | wc -l; }

section "container prerequisites"
export DEBIAN_FRONTEND=noninteractive
if ! { apt-get update -qq >/dev/null && apt-get install -y -qq mksh busybox-static >/dev/null; }; then
    echo "cannot install mksh/busybox-static"
    exit 2
fi
ok "mksh + busybox-static installed"

section "fake Android layout (shared mounts, like Android init)"
mount --make-rshared /
mkdir -p /data && mount -t tmpfs -o size=4g tmpfs /data && mount --make-shared /data
mkdir -p /data/precious /data/adb/magisk /data/system/environ /data/local/uburoot/bin
echo "PRECIOUS app db" >/data/precious/app.db
cp /bin/busybox /data/adb/magisk/busybox
printf 'export SYSTEMSERVERCLASSPATH /system/framework/services.jar\n' >/data/system/environ/classpath

mkdir -p /system/bin /system/product /vendor/lib64 /linkerconfig
cp /usr/bin/mksh /system/bin/sh # like Android: sh lives in /system
cat >/system/bin/am <<'EOF'
#!/system/bin/sh
echo "AM_OK BCP=$BOOTCLASSPATH SSCP=$SYSTEMSERVERCLASSPATH LD=${LD_LIBRARY_PATH:-unset} args=$*"
EOF
chmod 755 /system/bin/am
ln -s /system/product /product
echo vendor >/vendor/lib64/marker
mkdir -p /apex && mount -t tmpfs tmpfs /apex && mount --make-shared /apex
mkdir -p /apex/com.android.runtime && mount -t tmpfs tmpfs /apex/com.android.runtime
echo linker >/apex/com.android.runtime/marker
mkdir -p /storage/emulated/0/Download /storage/emulated/0/Android
echo "PRECIOUS photo" >/storage/emulated/0/Download/photo.jpg
printf '#!/bin/sh\necho test/fingerprint/1\n' >/usr/local/bin/getprop && chmod 755 /usr/local/bin/getprop
export BOOTCLASSPATH=/apex/com.android.art/javalib/core-oj.jar:/system/framework/framework.jar
ok "layout ready"

cp /src/app/src/main/assets/uburoot/bin/* /data/local/uburoot/bin/
chmod 755 /data/local/uburoot/bin/*
B=/data/local/uburoot/bin
R=/data/local/uburoot/rootfs
export UBU_ALLOW_ANY_ARCH=1 # container is x86_64; the app enforces arm64

section "control experiment: why rslave matters"
mkdir -p /tmp/ctl && mount --rbind /apex /tmp/ctl
umount /tmp/ctl/com.android.runtime 2>/dev/null
if grep -q ' /apex/com.android.runtime ' /proc/self/mounts; then
    echo "  info: this kernel did not propagate the umount (no hazard demonstrated)"
else
    echo "  info: unmounting the shared rbind COPY unmounted the REAL /apex/com.android.runtime"
    mount -t tmpfs tmpfs /apex/com.android.runtime && echo linker >/apex/com.android.runtime/marker
fi
umount -R /tmp/ctl 2>/dev/null || umount -l /tmp/ctl
grep -q ' /apex/com.android.runtime ' /proc/self/mounts || mount -t tmpfs tmpfs /apex/com.android.runtime
[ -f /apex/com.android.runtime/marker ] || echo linker >/apex/com.android.runtime/marker

section "rootinfo / install"
info=$(/system/bin/sh $B/rootinfo.sh 2>&1)
check "rootinfo detects Magisk-path busybox" sh -c "printf '%s' \"\$1\" | grep -qx 'busybox=/data/adb/magisk/busybox'" _ "$info"
check "install rejects a wrong SHA256" sh -c "! $B/install.sh '$TARBALL' 0000"
check "install with correct SHA256" $B/install.sh "$TARBALL" "$SHA"
check "rootfs installed, no .partial left" sh -c "[ -x $R/usr/bin/env ] && [ ! -e $R.partial ]"
check "second install refused" sh -c "! $B/install.sh '$TARBALL' '$SHA'"

section "setup (real apt over the network)"
if $B/setup.sh --user tester --nopasswd >/tmp/setup.log 2>&1; then ok "setup.sh"; else bad "setup.sh"; tail -30 /tmp/setup.log; fi
check "resolv.conf has 1.1.1.1" grep -q 'nameserver 1.1.1.1' $R/etc/resolv.conf
check "group aid_inet=3003" grep -q '^aid_inet:x:3003:' $R/etc/group
check "group aid_net_raw=3004" grep -q '^aid_net_raw:x:3004:' $R/etc/group
check "group aid_net_admin=3005" grep -q '^aid_net_admin:x:3005:' $R/etc/group
check "_apt primary group is aid_inet" sh -c "awk -F: '\$1==\"_apt\"{exit \$4==3003?0:1}' $R/etc/passwd"
check "user tester uid 9000" sh -c "awk -F: '\$1==\"tester\"{exit \$3==9000?0:1}' $R/etc/passwd"
check "sudo installed" chroot $R test -x /usr/bin/sudo
check "NOPASSWD sudoers" grep -q 'tester ALL=(ALL:ALL) NOPASSWD: ALL' $R/etc/sudoers.d/90-uburoot-tester
check "setup is re-runnable" sh -c "$B/setup.sh --user tester --nopasswd --no-apt"

section "mount.sh"
n1=$(mounted_under $R)
$B/mount.sh 2>/dev/null
n2=$(mounted_under $R)
check "idempotent ($n1 mounts, same after re-run)" test "$n1" = "$n2"
for m in "" /proc /sys /dev /dev/pts /dev/shm /run /sdcard /system /vendor /apex /apex/com.android.runtime /linkerconfig /data; do
    check "mounted: ${m:-/ (self-bind)}" grep -q " $R$m " /proc/self/mounts
done
check "/product mirrored as symlink" sh -c "[ \"\$(readlink $R/product)\" = /system/product ]"
check "no shared mount under rootfs" sh -c "! awk -v p=$R '(\$5==p||index(\$5,p\"/\")==1){for(i=7;i<=NF&&\$i!=\"-\";i++)if(\$i~/^shared:/)f=1}END{exit !f}' /proc/self/mountinfo"
check "rootfs/data is non-recursive (no mounts seen through it)" test ! -e $R/data/local/uburoot/rootfs/proc/self

section "enter.sh"
out=$($B/enter.sh root 'id; ls /sdcard/Download; cat /data/precious/app.db; am start -a X; echo LANG=$LANG TERM=$TERM' 2>&1)
check "root: uid 0" sh -c "printf '%s' \"\$1\" | grep -q 'uid=0(root)'" _ "$out"
check "root: aid_inet supplementary group" sh -c "printf '%s' \"\$1\" | grep -q '3003(aid_inet)'" _ "$out"
check "root: /sdcard visible" sh -c "printf '%s' \"\$1\" | grep -q photo.jpg" _ "$out"
check "root: /data visible" sh -c "printf '%s' \"\$1\" | grep -q 'PRECIOUS app db'" _ "$out"
check "am wrapper: Android env (BOOTCLASSPATH)" sh -c "printf '%s' \"\$1\" | grep -q 'AM_OK BCP=/apex/com.android.art'" _ "$out"
check "am wrapper: classpath file fallback" sh -c "printf '%s' \"\$1\" | grep -q 'SSCP=/system/framework/services.jar'" _ "$out"
check "am wrapper: no glibc env leak, args passed" sh -c "printf '%s' \"\$1\" | grep -q 'LD=unset args=start -a X'" _ "$out"
check "clean env: LANG/TERM" sh -c "printf '%s' \"\$1\" | grep -q 'LANG=C.UTF-8 TERM=xterm-256color'" _ "$out"
check "android.env has fingerprint" grep -q '^# fingerprint=test/fingerprint/1' $R/etc/android.env
out=$($B/enter.sh tester 'id -u; pwd; sudo -n true && echo SUDO_OK' 2>&1)
check "user: uid 9000, home dir, sudo" sh -c "printf '%s' \"\$1\" | tr '\n' ' ' | grep -q '^9000 /home/tester SUDO_OK'" _ "$out"
check "no hostname resolution warning" sh -c "! printf '%s' \"\$1\" | grep -q 'unable to resolve'" _ "$out"
out=$(UBU_CWD=/sdcard/Download $B/enter.sh tester 'pwd' 2>&1)
check "UBU_CWD start dir" sh -c "printf '%s' \"\$1\" | grep -qx /sdcard/Download" _ "$out"
echo "INIT_COMMAND='echo INIT_RAN_\$USER'" >/data/local/uburoot/uburoot.conf
out=$(echo 'echo INTERACTIVE_OK; exit' | $B/enter.sh tester 2>&1)
check "login shell + INIT_COMMAND" sh -c "printf '%s' \"\$1\" | tr '\n' ' ' | grep -q 'INIT_RAN_tester INTERACTIVE_OK'" _ "$out"
rm -f /data/local/uburoot/uburoot.conf
check "invalid user rejected" sh -c "! $B/enter.sh 'bad;user' true"

section "CRITICAL RULE with real mounts: sabotaged umount"
cat >/tmp/fakebb <<'EOF'
#!/bin/sh
[ "$1" = umount ] && { echo "sabotaged umount $*" >&2; exit 1; }
exec /data/adb/magisk/busybox "$@"
EOF
chmod 755 /tmp/fakebb
before=$(mounted_under $R)
UBU_BB=/tmp/fakebb $B/reset.sh --yes >/tmp/reset1.log 2>&1
rc=$?
check "reset aborted (rc=3, got $rc)" test "$rc" = 3
check "mounts still in place ($before)" test "$(mounted_under $R)" = "$before"
check "real /data data intact" grep -q PRECIOUS /data/precious/app.db
check "real /sdcard data intact" grep -q PRECIOUS /storage/emulated/0/Download/photo.jpg
check "rootfs intact" test -x $R/usr/bin/env
check "/system intact" test -x /system/bin/am

section "umount.sh"
check "umount.sh succeeds" $B/umount.sh
check "nothing left under rootfs" test "$(mounted_under $R)" = 0
check "real /apex submount survived (no propagation)" grep -q ' /apex/com.android.runtime ' /proc/self/mounts
check "real /apex marker readable" test -f /apex/com.android.runtime/marker
check "real /dev/pts still mounted" grep -q ' /dev/pts ' /proc/self/mounts
check "real /data still mounted" grep -q ' /data ' /proc/self/mounts
check "umount.sh idempotent" $B/umount.sh

section "reset with a live session (--kill)"
$B/enter.sh root 'sleep 600' >/dev/null 2>&1 &
sleep 3
check "session running in chroot" sh -c "for p in /proc/[0-9]*; do [ \"\$(readlink \$p/root)\" = $R ] && exit 0; done; exit 1"
$B/reset.sh --yes >/tmp/reset2.log 2>&1
rc=$?
if [ "$rc" = 0 ]; then ok "reset.sh succeeded"; else bad "reset.sh rc=$rc"; cat /tmp/reset2.log; fi
check "rootfs removed" test ! -e $R
check "nothing mounted under rootfs" test "$(mounted_under $R)" = 0
check "real /data data intact" grep -q PRECIOUS /data/precious/app.db
check "real /sdcard data intact" grep -q PRECIOUS /storage/emulated/0/Download/photo.jpg
check "real /system, /vendor, /apex intact" sh -c "[ -x /system/bin/am ] && [ -f /vendor/lib64/marker ] && [ -f /apex/com.android.runtime/marker ]"
check "scripts dir kept" test -f $B/common.sh

printf '\ndocker suite: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
