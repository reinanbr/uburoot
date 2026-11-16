#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
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
if [ "$1" = broadcast ]; then
    # Fake receiver: log the caller's uid and every argument, answer like the app.
    # mksh builtins only: the Android PATH in the chroot has no printf.
    { echo "uid=$USER_ID"; for a in "$@"; do print -r -- "[$a]"; done; } >>/data/am-broadcast.log
    case "$*" in
        *FAILME*) echo 'Broadcast completed: result=1, data="no app can open FAILME"' ;;
        *) echo "Broadcast completed: result=-1" ;;
    esac
    exit 0
fi
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
# mount.sh raises fs.inotify.max_user_watches; in a privileged container that
# is the HOST's sysctl, so point it at a file.
export UBU_INOTIFY_FILE=/tmp/inotify_max_user_watches
echo 8192 >"$UBU_INOTIFY_FILE"

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
# aid_net_raw/aid_net_admin act as CAP_NET_RAW/CAP_NET_ADMIN on Android kernels.
not_member() { ! awk -F: -v g="$2" -v u="$1" '$1 == g { n = split($4, m, ","); for (i = 1; i <= n; i++) if (m[i] == u) f = 1 } END { exit !f }' $R/etc/group; }
check "root in aid_net_raw and aid_net_admin" sh -c "grep -q '^aid_net_raw:.*root' $R/etc/group && grep -q '^aid_net_admin:.*root' $R/etc/group"
for g in aid_net_raw aid_net_admin; do
    check "tester not in $g" not_member tester $g
    check "_apt not in $g" not_member _apt $g
done
check "tester in aid_inet and aid_media_rw" sh -c "id_g=\$(chroot $R id -Gn tester); echo \"\$id_g\" | grep -qw aid_inet && echo \"\$id_g\" | grep -qw aid_media_rw"
check "apt hook for the iptables backend" test -x $R/usr/local/sbin/uburoot-iptables-select
check "inotify watches raised (8192 -> 524288)" grep -qx 524288 "$UBU_INOTIFY_FILE"
check "user tester uid 9000" sh -c "awk -F: '\$1==\"tester\"{exit \$3==9000?0:1}' $R/etc/passwd"
check "sudo installed" chroot $R test -x /usr/bin/sudo
check "NOPASSWD sudoers" grep -q 'tester ALL=(ALL:ALL) NOPASSWD: ALL' $R/etc/sudoers.d/90-uburoot-tester
# Older setups put the user in aid_net_raw/aid_net_admin; a re-run drops them.
chroot $R usermod -a -G aid_net_raw,aid_net_admin tester
check "setup is re-runnable" sh -c "$B/setup.sh --user tester --nopasswd --no-apt"
check "re-run removed tester from aid_net_raw/aid_net_admin" sh -c "! chroot $R id -Gn tester | grep -qE 'aid_net_(raw|admin)'"
cp $R/etc/hosts /tmp/hosts.before
echo "DNS_SERVERS='9.9.9.9 2620:fe::fe'" >/data/local/uburoot/uburoot.conf
check "setup.sh --dns-only" $B/setup.sh --dns-only
check "--dns-only wrote the configured servers" sh -c "grep -qx 'nameserver 9.9.9.9' $R/etc/resolv.conf && grep -qx 'nameserver 2620:fe::fe' $R/etc/resolv.conf"
check "--dns-only left /etc/hosts alone" cmp -s /tmp/hosts.before $R/etc/hosts
check "--dns-only rejects a bad server" sh -c "! $B/setup.sh --dns-only --dns '1.1.1.1;reboot'"
rm -f /data/local/uburoot/uburoot.conf
$B/setup.sh --dns-only >/dev/null 2>&1
echo 1000000 >"$UBU_INOTIFY_FILE"
$B/mount.sh 2>/dev/null
check "inotify watches never lowered" grep -qx 1000000 "$UBU_INOTIFY_FILE"
echo 100 >"$UBU_INOTIFY_FILE"
echo "INOTIFY_MAX_WATCHES=0" >/data/local/uburoot/uburoot.conf
$B/mount.sh 2>/dev/null
check "INOTIFY_MAX_WATCHES=0 leaves it alone" grep -qx 100 "$UBU_INOTIFY_FILE"
rm -f /data/local/uburoot/uburoot.conf

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

section "app bridge: uburoot-* commands (fake am)"
: >/data/am-broadcast.log
bl() { cat /data/am-broadcast.log; }
check "commands installed (+ xdg-open)" sh -c "[ -x $R/usr/local/bin/uburoot-notify ] && [ -x $R/usr/local/bin/xdg-open ] && [ -x $R/usr/local/lib/uburoot/uburoot-send ]"
check "sudo rule installed (0440)" sh -c "[ \"\$(stat -c %a $R/etc/sudoers.d/80-uburoot)\" = 440 ]"
check "uburoot-notify as the user" $B/enter.sh tester 'uburoot-notify "Hi there" "body text"'
check "broadcast sent as root to the receiver" sh -c "bl() { cat /data/am-broadcast.log; }; bl | grep -qx uid=0 && bl | grep -qx '\[com.reinanbr.uburoot/.bridge.CommandReceiver\]' && bl | grep -qx '\[Hi there\]' && bl | grep -qx '\[body text\]'"
: >/data/am-broadcast.log
check "uburoot-clip from stdin" $B/enter.sh tester 'printf "line1\nline2\n" | uburoot-clip'
check "clip text kept its newline" sh -c "grep -qx '\[line1' /data/am-broadcast.log && grep -qx 'line2\]' /data/am-broadcast.log"
check "xdg-open URL" $B/enter.sh tester 'xdg-open https://example.com/x'
check "URL passed as url extra" grep -qx '\[https://example.com/x\]' /data/am-broadcast.log
check "app error reaches the user (rc != 0)" sh -c "! $B/enter.sh tester 'uburoot-toast FAILME'"
out=$($B/enter.sh tester 'uburoot-toast FAILME' 2>&1)
check "app error message shown" sh -c "printf '%s' \"\$1\" | grep -q 'no app can open FAILME'" _ "$out"
check "vibrate rejects non-numbers" sh -c "! $B/enter.sh tester 'uburoot-vibrate abc'"
: >/data/am-broadcast.log
$B/enter.sh tester 'echo HELLO-OPEN >~/doc.txt && uburoot-open doc.txt' >/dev/null 2>&1
oid=$(grep -A1 -x '\[id\]' /data/am-broadcast.log | tail -1 | tr -d '[]')
check "uburoot-open: id + name sent" sh -c "printf '%s' '$oid' | grep -qE '^[0-9a-f]{16}\$' && grep -qx '\[doc.txt\]' /data/am-broadcast.log"
check "outbox file root-only with the content" sh -c "[ \"\$(stat -c '%u %a' $R/var/lib/uburoot/outbox/$oid)\" = '0 600' ] && grep -qx HELLO-OPEN $R/var/lib/uburoot/outbox/$oid"
: >/tmp/taken && chmod 600 /tmp/taken
check "bridge.sh take" $B/bridge.sh take "$oid" /tmp/taken
check "take copied and emptied the outbox" sh -c "grep -qx HELLO-OPEN /tmp/taken && [ ! -e $R/var/lib/uburoot/outbox/$oid ]"
check "take rejects a bad id" sh -c "! $B/bridge.sh take ../../etc/passwd /tmp/taken"
n0=$(find $R/var/lib/uburoot/outbox -type f | wc -l)
check "open refuses what the user can't read" sh -c "! $B/enter.sh tester 'uburoot-open /etc/shadow'"
check "no outbox file left by the refused open" test "$(find $R/var/lib/uburoot/outbox -type f | wc -l)" = "$n0"
echo "DEFAULT_USER='tester'" >/data/local/uburoot/uburoot.conf
echo SHARED-DATA >/tmp/share.bin
out=$($B/bridge.sh import /tmp/share.bin "my file.txt" 2>/dev/null)
check "bridge.sh import prints ~/Shared" test "$out" = /home/tester/Shared
check "imported file owned by the user" sh -c "[ \"\$(stat -c %u '$R/home/tester/Shared/my file.txt')\" = 9000 ] && grep -qx SHARED-DATA '$R/home/tester/Shared/my file.txt'"
$B/bridge.sh import /tmp/share.bin "my file.txt" >/dev/null 2>&1
check "second import gets a new name" test -f "$R/home/tester/Shared/1-my file.txt"
# A symlinked ~/Shared must not let root write outside the chroot.
mkdir -p /hostonly && chmod 777 /hostonly
$B/enter.sh tester 'rm -rf ~/Shared && ln -s /hostonly ~/Shared' >/dev/null 2>&1
$B/bridge.sh import /tmp/share.bin evil >/dev/null 2>&1
check "symlinked ~/Shared: nothing written on the host" test -z "$(ls -A /hostonly)"
$B/enter.sh tester 'rm -f ~/Shared' >/dev/null 2>&1
check "bridge.sh cwd: the user's home" $B/bridge.sh cwd /home/tester
check "bridge.sh cwd: /sdcard (bind-mounted)" $B/bridge.sh cwd /sdcard/Download
check "bridge.sh cwd: /root refused for the user" sh -c "! $B/bridge.sh cwd /root"
check "bridge.sh cwd: relative path refused" sh -c "! $B/bridge.sh cwd home/tester"
rm -f /data/local/uburoot/uburoot.conf

section "boot autostart (boot.sh, module service.sh)"
$B/umount.sh --kill >/dev/null 2>&1
check "BOOT_START off: boot.sh does nothing" $B/boot.sh
check "BOOT_START off: nothing mounted" test "$(mounted_under $R)" = 0
out=$($B/boot.sh --status 2>/dev/null)
check "status: no module" test "$out" = "$(printf 'module=missing\nboot_start=0')"
mkdir -p /tmp/fakeadb/modules/uburoot
check "status: module enabled" sh -c "UBU_MODULES=/tmp/fakeadb $B/boot.sh --status | grep -qx module=enabled"
touch /tmp/fakeadb/modules/uburoot/disable
check "status: module disabled" sh -c "UBU_MODULES=/tmp/fakeadb $B/boot.sh --status | grep -qx module=disabled"
mkdir -p /tmp/fakeadb/modules_update/uburoot
check "status: module pending (reboot)" sh -c "UBU_MODULES=/tmp/fakeadb $B/boot.sh --status | grep -qx module=pending"
rm -rf /tmp/fakeadb
mkdir -p $R/etc/uburoot-boot.d
D=$R/etc/uburoot-boot.d
printf '#!/bin/sh\necho "$(id -u) $(id -G) $HOME $(pwd)" >/tmp/boot-10\n' >$D/10-hello
printf '#!/bin/sh\nsetsid sleep 500 </dev/null >/dev/null 2>&1 &\necho started >/tmp/boot-20\n' >$D/20-daemon
printf '#!/bin/sh\nsleep 8\necho late >/tmp/boot-30\n' >$D/30-slow
printf '#!/bin/sh\nexit 3\n' >$D/40-fail
printf '#!/bin/sh\necho ran >/tmp/boot-50\n' >$D/50-last
printf '#!/bin/sh\necho ran >/tmp/boot-readme\n' >$D/README.sh
printf '#!/bin/sh\necho ran >/tmp/boot-noexec\n' >$D/60-noexec
chmod 755 $D/10-hello $D/20-daemon $D/30-slow $D/40-fail $D/50-last $D/README.sh
chmod 644 $D/60-noexec
ln -s 10-hello $D/70-link
printf "BOOT_START='1'\nBOOT_SCRIPT_TIMEOUT='2'\n" >/data/local/uburoot/uburoot.conf
$B/boot.sh >/tmp/boot.log 2>&1
rc=$?
check "boot.sh exit 1 when a script fails (got $rc)" test "$rc" = 1
check "mounted at boot" test "$(mounted_under $R)" -gt 0
check "scripts run as root with the session env" sh -c "grep -q '^0 .*3003.* /root /root\$' $R/tmp/boot-10"
check "groups include aid_inet" grep -qw 3003 $R/tmp/boot-10
check "forked daemon survives its script" sh -c "for p in /proc/[0-9]*; do [ \"\$(readlink \$p/root)\" = $R ] && tr '\\0' ' ' <\$p/cmdline 2>/dev/null | grep -q 'sleep 500' && exit 0; done; exit 1"
check "slow script left running, next ones started" sh -c "grep -q '30-slow still running' /tmp/boot.log && [ -f $R/tmp/boot-50 ] && [ ! -f $R/tmp/boot-30 ]"
check "failure logged" grep -q '40-fail: failed (exit 3)' /tmp/boot.log
check "name order kept" sh -c "awk '/starting/ {print \$NF}' /tmp/boot.log | tr '\n' ' ' | grep -qx '10-hello 20-daemon 30-slow 40-fail 50-last '"
check "README.sh, non-executable and symlinked scripts skipped" sh -c "[ ! -e $R/tmp/boot-readme ] && [ ! -e $R/tmp/boot-noexec ] && ! grep -q 70-link /tmp/boot.log"
sleep 7
check "slow script finished on its own" test -f $R/tmp/boot-30
# service.sh as the root manager runs it, with getprop saying the boot completed.
mkdir -p /tmp/svcbin /tmp/mod
printf '#!/bin/sh\n[ "$1" = sys.boot_completed ] && echo 1 || echo test/fingerprint/1\n' >/tmp/svcbin/getprop
chmod 755 /tmp/svcbin/getprop
cp /src/app/src/module/service.sh /tmp/mod/service.sh
rm -f $R/tmp/boot-* /data/local/uburoot/boot.log /data/local/uburoot/boot.log.old
echo old >/data/local/uburoot/boot.log
PATH=/tmp/svcbin:$PATH sh /tmp/mod/service.sh
check "service.sh ran boot.sh (log written)" grep -q 'boot scripts done' /data/local/uburoot/boot.log
check "service.sh kept the previous log" grep -qx old /data/local/uburoot/boot.log.old
check "service.sh: scripts ran" test -f $R/tmp/boot-50
rm -f $R/tmp/boot-*
chmod 777 $B/boot.sh
PATH=/tmp/svcbin:$PATH sh /tmp/mod/service.sh
check "service.sh refuses a world-writable boot.sh" test ! -e $R/tmp/boot-10
chmod 755 $B/boot.sh
check "boot.sh --now runs with BOOT_START off" sh -c "echo \"BOOT_START='0'\" >/data/local/uburoot/uburoot.conf; $B/boot.sh --now; [ -f $R/tmp/boot-10 ]"
rm -rf $D $R/tmp/boot-* /tmp/mod /tmp/svcbin /data/local/uburoot/boot.log /data/local/uburoot/boot.log.old
rm -f /data/local/uburoot/uburoot.conf
$B/umount.sh --kill >/dev/null 2>&1
check "boot daemons stopped by umount.sh --kill" test "$(mounted_under $R)" = 0

section "hangup.sh (closing one terminal tab)"
# A real pty, as the app's sessions have: script(1) runs enter.sh on one.
sleep 600 | script -qfc "$B/enter.sh tester" /dev/null >/dev/null 2>&1 &
setsid chroot $R sleep 700 </dev/null >/dev/null 2>&1 &
sleep 4
tty_pids() { # chroot pids with a controlling terminal
    for p in /proc/[0-9]*; do
        [ "$(readlink "$p/root")" = "$R" ] || continue
        s=$(cat "$p/stat" 2>/dev/null) || continue
        s=${s##*) }
        # shellcheck disable=SC2086 # split the stat fields
        set -- $s
        [ "$5" != 0 ] && echo "${p#/proc/}"
    done
}
shell=$(tty_pids | head -1)
check "session shell on a pty" test -n "$shell"
check "hangup.sh" $B/hangup.sh "$shell"
sleep 2
check "session processes gone after hangup" test -z "$(tty_pids)"
check "process without that terminal survives" sh -c "for p in /proc/[0-9]*; do [ \"\$(readlink \$p/root)\" = $R ] && grep -q '^sleep' \$p/comm && exit 0; done; exit 1"
check "hangup.sh rejects a non-pty stdin" sh -c "! $B/hangup.sh \$\$ </dev/null"
pkill -f 'sleep 700' 2>/dev/null; pkill -f 'sleep 600' 2>/dev/null

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
