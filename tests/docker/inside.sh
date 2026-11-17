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
has() { printf '%s\n' "$1" | grep -qx "$2"; }
check "rootinfo: full root (privileged container root)" has "$info" full_root=yes
check "rootinfo: schema 0 before install" has "$info" schema=0
check "rootinfo: a dropped capability means full_root=no" sh -c "setpriv --bounding-set -sys_module /system/bin/sh $B/rootinfo.sh 2>/dev/null | grep -qx full_root=no"
check "rootinfo: no_new_privs means full_root=no" sh -c "setpriv --no-new-privs /system/bin/sh $B/rootinfo.sh 2>/dev/null | grep -qx full_root=no"
check "install rejects a wrong SHA256" sh -c "! $B/install.sh '$TARBALL' $(printf '%064d' 0)"
check "install rejects a malformed SHA256" sh -c "! $B/install.sh '$TARBALL' 0000 && ! $B/install.sh '$TARBALL' zz$(printf '%062d' 0)"
printf 'not an archive\n' >/tmp/junk.tar.gz
check "install rejects a file that is not .tar.gz/.tar.xz" sh -c "! $B/install.sh /tmp/junk.tar.gz && [ ! -e $R ] && [ ! -e $R.partial ]"
# An arm64 rootfs on this amd64 CPU: dpkg's ELF e_machine says so.
mkdir -p /tmp/fakearm/usr/bin
cp /usr/bin/dpkg /tmp/fakearm/usr/bin/dpkg && cp /usr/bin/dpkg /tmp/fakearm/usr/bin/env
printf '\267\000' | dd of=/tmp/fakearm/usr/bin/dpkg bs=1 seek=18 conv=notrunc 2>/dev/null
tar -C /tmp/fakearm -czf /tmp/fakearm.tar.gz usr
check "install refuses a rootfs for another CPU" sh -c "$B/install.sh /tmp/fakearm.tar.gz 2>&1 | grep -q 'is for arm64'"
check "  ... and leaves nothing behind" sh -c "[ ! -e $R ] && [ ! -e $R.partial ]"
if command -v xz >/dev/null 2>&1 || apt-get install -y -qq xz-utils >/dev/null 2>&1; then
    gzip -dc "$TARBALL" | xz -1 -T0 >/tmp/ubuntu-base.tar.xz
    XSHA=$(sha256sum /tmp/ubuntu-base.tar.xz | cut -d' ' -f1 | tr a-f A-F)
    check "install from .tar.xz (SHA256 in upper case)" $B/install.sh /tmp/ubuntu-base.tar.xz "$XSHA"
    check "  ... rootfs in place" test -x $R/usr/bin/dpkg
    check "reset of the unmounted .tar.xz rootfs" $B/reset.sh --yes
    rm -f /tmp/ubuntu-base.tar.xz
else
    bad "xz-utils for the .tar.xz test"
fi
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

section "rootfs schema and migrations"
REL=$R/etc/uburoot-release
check "uburoot-release: SCHEMA=3" grep -qx SCHEMA=3 $REL
check "uburoot-release: UBUNTU and INSTALLED" sh -c "grep -q '^UBUNTU=.' $REL && grep -q '^INSTALLED=[0-9]' $REL"
check "rootinfo: schema=3" sh -c "/system/bin/sh $B/rootinfo.sh 2>/dev/null | grep -qx schema=3"
check "--migrate on a current rootfs is a no-op" sh -c "$B/setup.sh --migrate 2>&1 | grep -q 'up to date'"
# What a rootfs set up by 0.2.x looks like: no release file, older or missing
# integration files.
cp $R/etc/passwd /tmp/passwd.before
cp $R/etc/apt/sources.list.d/ubuntu.sources /tmp/sources.before
rm -f $REL $R/usr/local/sbin/uburoot-iptables-select
echo '# old hook' >$R/etc/profile.d/uburoot.sh
chroot $R gpasswd -d root aid_net_raw >/dev/null 2>&1
check "rootinfo: schema=0 on an old rootfs" sh -c "/system/bin/sh $B/rootinfo.sh 2>/dev/null | grep -qx schema=0"
if $B/setup.sh --migrate >/tmp/migrate.log 2>&1; then ok "setup.sh --migrate"; else bad "setup.sh --migrate"; tail -20 /tmp/migrate.log; fi
check "migrated: SCHEMA=3" grep -qx SCHEMA=3 $REL
check "migrated: profile hook rewritten (DISPLAY, gpu.env)" sh -c "grep -q UBU_CWD $R/etc/profile.d/uburoot.sh && grep -q DISPLAY=:0 $R/etc/profile.d/uburoot.sh && grep -q gpu.env $R/etc/profile.d/uburoot.sh"
check "migrated: iptables selector back" test -x $R/usr/local/sbin/uburoot-iptables-select
check "migrated: APT never picks snap packages" test -f $R/etc/apt/preferences.d/80uburoot-no-snap
check "APT: firefox (a snap transitional deb) has no candidate" sh -c "$B/enter.sh root 'apt-cache policy firefox' 2>/dev/null | grep -q 'Candidate: (none)'"
check "APT: other packages still install candidates" sh -c "$B/enter.sh root 'apt-cache policy dillo' 2>/dev/null | grep -q 'Candidate: [0-9]'"
check "migrated: root back in aid_net_raw" sh -c "chroot $R id -Gn root | grep -qw aid_net_raw"
check "migrated: users and APT sources untouched" sh -c "cmp -s /tmp/passwd.before $R/etc/passwd && cmp -s /tmp/sources.before $R/etc/apt/sources.list.d/ubuntu.sources"
sed -i 's/^SCHEMA=.*/SCHEMA=99/' $REL
check "--migrate leaves a newer rootfs alone" sh -c "$B/setup.sh --migrate 2>&1 | grep -q newer && grep -qx SCHEMA=99 $REL"
sed -i 's/^SCHEMA=.*/SCHEMA=3/' $REL
mv $R/etc/uburoot-setup.done /tmp/setup.done
check "--migrate refuses before setup has run" sh -c "! $B/setup.sh --migrate"
mv /tmp/setup.done $R/etc/uburoot-setup.done

section "APT mirror (setup.sh --sources-only)"
SRC=$R/etc/apt/sources.list.d/ubuntu.sources
echo "APT_MIRROR='http://mirror.example.org/ubuntu/'" >/data/local/uburoot/uburoot.conf
check "--sources-only with APT_MIRROR" $B/setup.sh --sources-only
check "release suites from the mirror" grep -qx 'URIs: http://mirror.example.org/ubuntu/' $SRC
check "security still from Canonical" grep -qx 'URIs: http://security.ubuntu.com/ubuntu/' $SRC
for m in https://mirror.example.org/ubuntu/ 'http://x/;reboot/' http://mirror.example.org/ubuntu; do
    echo "APT_MIRROR='$m'" >/data/local/uburoot/uburoot.conf
    check "rejected mirror: $m (sources unchanged)" sh -c "! $B/setup.sh --sources-only && grep -q mirror.example.org $SRC"
done
rm -f /data/local/uburoot/uburoot.conf
check "no APT_MIRROR: back to the default sources" sh -c "$B/setup.sh --sources-only && cmp -s /tmp/sources.before $SRC"

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

section "doctor.sh (read-only report)"
mkdir -p /vendor/lib/modules
printf '\000vermagic=4.9.337 SMP preempt mod_unload aarch64\000name=fake\000' >/vendor/lib/modules/fake.ko
echo "DEFAULT_USER='tester'" >/data/local/uburoot/uburoot.conf
n1=$(mounted_under $R)
/system/bin/sh $B/doctor.sh --app-version test >/tmp/doctor.txt 2>&1
rc=$?
check "doctor runs (rc=$rc)" test "$rc" = 0
check "doctor: every section" sh -c "for s in Root Android Kernel Hardware Storage Mounts Network Config; do grep -qx \"== \$s ==\" /tmp/doctor.txt || exit 1; done"
check "doctor: summary line" grep -q '^summary: [0-9]* failed' /tmp/doctor.txt
check "doctor: full root ok" grep -q '^full root: *\[ok\]' /tmp/doctor.txt
check "doctor: schema ok" grep -q '^integration schema: *\[ok\] 3' /tmp/doctor.txt
check "doctor: vendor module vermagic" grep -q '^vendor vermagic: *4.9.337 SMP preempt mod_unload aarch64 (fake.ko)' /tmp/doctor.txt
check "doctor: changed no mounts" test "$(mounted_under $R)" = "$n1"
check "doctor (plain) names the user" grep -qw tester /tmp/doctor.txt
/system/bin/sh $B/doctor.sh --redact >/tmp/doctor-r.txt 2>&1
check "redacted: no user name" sh -c "! grep -qw tester /tmp/doctor-r.txt"
check "redacted: no kernel hostname" sh -c "! grep -qwF \"\$(cat /proc/sys/kernel/hostname)\" /tmp/doctor-r.txt"
check "redacted: marked as such" grep -q '^redacted: *yes' /tmp/doctor-r.txt
# Same keys in the same order (values differ: that's the point). Not the summary: a
# network check (DNS from the container) can fail in one run and not the other.
grep -v '^summary:' /tmp/doctor.txt | cut -c1-25 >/tmp/doctor.keys
grep -v '^summary:' /tmp/doctor-r.txt | cut -c1-25 >/tmp/doctor-r.keys
if cmp -s /tmp/doctor.keys /tmp/doctor-r.keys; then ok "redacted: same report shape"; else
    bad "redacted: same report shape"
    diff /tmp/doctor.keys /tmp/doctor-r.keys | head -20
    grep -H 'FAIL\]' /tmp/doctor.txt /tmp/doctor-r.txt
fi
setpriv --bounding-set -sys_module /system/bin/sh $B/doctor.sh >/tmp/doctor-x.txt 2>&1
check "doctor: restricted root reported as FAIL" grep -q '^full root: *\[FAIL\]' /tmp/doctor-x.txt
rm -f /data/local/uburoot/uburoot.conf /vendor/lib/modules/fake.ko

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

section "kernel access (KERNEL_ACCESS=1)"
# Kernel filesystems like Android's: configfs at /config, the rest in /sys.
mkdir -p /config
for m in configfs:none:/config debugfs:debugfs:/sys/kernel/debug tracefs:tracefs:/sys/kernel/tracing \
    bpf:bpf:/sys/fs/bpf pstore:pstore:/sys/fs/pstore; do
    t=${m%%:*}
    p=${m##*:}
    grep -q " $p " /proc/self/mounts || mount -t "$t" "$t" "$p" 2>/dev/null || echo "  info: no $t here"
done
outside() { awk -v r="$R" '$5 != r && index($5, r "/") != 1 { print $5, $9, $10 }' /proc/self/mountinfo | sort; }
outside >/tmp/kbase.txt
KV=$(uname -r)
echo "KERNEL_ACCESS=1" >/data/local/uburoot/uburoot.conf
$B/mount.sh >/tmp/kmount.log 2>&1
check "mount.sh with KERNEL_ACCESS=1" grep -q . /proc/self/mounts
for t in configfs:/sys/kernel/config debugfs:/sys/kernel/debug tracefs:/sys/kernel/tracing bpf:/sys/fs/bpf cgroup2:/sys/fs/cgroup pstore:/sys/fs/pstore; do
    if awk -v t="${t%%:*}" '$3 == t && index($2, "/data/") != 1 { f = 1 } END { exit !f }' /proc/self/mounts; then
        check "kernel fs in Ubuntu: ${t%%:*} at ${t#*:}" grep -q " $R${t#*:} ${t%%:*} " /proc/self/mounts
    else
        echo "  info: the container has no ${t%%:*}; skipped"
    fi
done
check "host configfs (/config) is what Ubuntu sees" sh -c "[ \"\$(stat -c %i /config)\" = \"\$(stat -c %i $R/sys/kernel/config)\" ]"
check "no shared mount under rootfs" sh -c "! awk -v p=$R '(\$5==p||index(\$5,p\"/\")==1){for(i=7;i<=NF&&\$i!=\"-\";i++)if(\$i~/^shared:/)f=1}END{exit !f}' /proc/self/mountinfo"
check "change log bound at /run/uburoot/state" grep -q " $R/run/uburoot/state " /proc/self/mounts
check "uburoot-kernel, uburoot-kmod, uburoot-kbuild installed" sh -c "[ -x $R/usr/local/sbin/uburoot-kernel ] && [ -L $R/usr/local/sbin/uburoot-kmod ] && [ -x $R/usr/local/sbin/uburoot-kbuild ]"
n1=$(mounted_under $R)
$B/mount.sh >/dev/null 2>&1
check "idempotent with kernel access ($n1 mounts)" test "$(mounted_under $R)" = "$n1"
if [ -d /vendor_dlkm/lib/modules/kernel ]; then
    MD=$R/usr/lib/modules/$KV
    check "ROM modules bound read-only" sh -c "grep -q ' $MD/uburoot/vendor_dlkm_lib_modules ' /proc/self/mounts && ! touch $MD/uburoot/vendor_dlkm_lib_modules/x 2>/dev/null"
    check "depmod wrote modules.dep into the rootfs" test -s "$MD/modules.dep"
    mod=$(awk -F: 'NR == 1 { n = $1; sub(/.*\//, "", n); sub(/\.ko.*/, "", n); print n }' "$MD/modules.dep")
    check "modinfo $mod inside Ubuntu" sh -c "chroot $R modinfo -F vermagic $mod | grep -q '^$KV '"
    check "modprobe --dry-run $mod resolves the bound file" sh -c "chroot $R modprobe -n -v $mod 2>&1 | grep -q 'uburoot/vendor_dlkm_lib_modules/'"
else
    echo "  info: no host modules for $KV; module binds skipped"
fi

# uburoot-kernel against fake kernel files (never the real kernel: it is the host's).
K=$R/tmp/k
CH=/data/local/uburoot/state/changes
mkdir -p $K/sys/kernel/random
echo 2 >$K/sys/kernel/kptr_restrict
echo 1 >$K/sys/kernel/dmesg_restrict
echo 3 >$K/sys/kernel/perf_event_paranoid
echo 1 >$K/enforce
echo "boot-1" >$K/boot_id
printf 'vendor_wlan 16384 0 - Live 0x0\n' >$K/modules
printf '#!/bin/sh\nn=$(basename "$1"); n=${n%%%%.ko*}\n{ echo "$n 16384 0 - Live 0x0"; cat "$UBU_PROC_MODULES"; } >"$UBU_PROC_MODULES.t" && mv "$UBU_PROC_MODULES.t" "$UBU_PROC_MODULES"\n' >$K/insmod
printf '#!/bin/sh\ngrep -v "^$1 " "$UBU_PROC_MODULES" >"$UBU_PROC_MODULES.t"; mv "$UBU_PROC_MODULES.t" "$UBU_PROC_MODULES"\n' >$K/rmmod
chmod 755 $K/insmod $K/rmmod
: >$K/fake.ko
kin() { # uburoot-kernel inside Ubuntu
    chroot $R env UBU_SYSCTL_DIR=/tmp/k/sys UBU_SELINUX_ENFORCE=/tmp/k/enforce UBU_PROC_MODULES=/tmp/k/modules \
        UBU_BOOT_ID_FILE=/tmp/k/boot_id UBU_INSMOD=/tmp/k/insmod UBU_RMMOD=/tmp/k/rmmod /usr/local/sbin/uburoot-kernel "$@"
}
kout() { # kernel.sh on the Android side (the app, Stop all)
    env UBU_SYSCTL_DIR=$K/sys UBU_SELINUX_ENFORCE=$K/enforce UBU_PROC_MODULES=$K/modules \
        UBU_BOOT_ID_FILE=$K/boot_id UBU_INSMOD=$K/insmod UBU_RMMOD=$K/rmmod /system/bin/sh $B/kernel.sh "$@"
}
val() { cat "$K/$1"; }
k_access() { kin status | grep -qx access=on; }
k_devmode() { kin -y devmode on >/dev/null && [ "$(val sys/kernel/kptr_restrict)" = 1 ]; }
k_sysctl() { kin sysctl kernel.dmesg_restrict 0 >/dev/null && grep -qx 'sysctl kernel.dmesg_restrict 1' $CH; }
k_sysctl2() { kin sysctl kernel.dmesg_restrict 2 >/dev/null && [ "$(grep -c kernel.dmesg_restrict $CH)" = 1 ] && grep -qx 'sysctl kernel.dmesg_restrict 1' $CH; }
k_badname() { ! kin sysctl ../../etc/passwd x 2>/dev/null; }
k_noconfirm() { ! kin selinux permissive </dev/null 2>/dev/null && [ "$(val enforce)" = 1 ]; }
k_selinux() { kin -y selinux permissive >/dev/null && [ "$(val enforce)" = 0 ] && grep -qx 'selinux - 1' $CH; }
k_load() { kin -y module load /tmp/k/fake.ko >/dev/null && grep -q '^fake ' $K/modules && grep -qx 'module fake -' $CH; }
k_list() {
    chroot $R env UBU_PROC_MODULES=/tmp/k/modules UBU_BOOT_ID_FILE=/tmp/k/boot_id /usr/local/sbin/uburoot-kmod list | grep -qx '\* fake'
}
k_notours() { ! kin -y module unload vendor_wlan 2>/dev/null && grep -q '^vendor_wlan ' $K/modules; }
k_changes() { kout status | grep -qx "changes=$1"; }
check "Ubuntu side: access=on" k_access
check "status | grep -q (SIGPIPE) leaves no lock" test ! -d /data/local/uburoot/state/.lock
k_stale() {
    mkdir /data/local/uburoot/state/.lock && echo 999999 >/data/local/uburoot/state/.lock/pid &&
        kout status | grep -q '^changes=' && [ ! -d /data/local/uburoot/state/.lock ]
}
check "a lock left by a dead process is broken" k_stale
check "devmode on: kptr_restrict 2 -> 1" k_devmode
check "sysctl write records the original" k_sysctl
check "a second write keeps the first original" k_sysctl2
check "sysctl rejects a path outside /proc/sys" k_badname
check "SELinux permissive needs -y without a terminal" k_noconfirm
check "SELinux permissive recorded" k_selinux
check "module load (file) recorded" k_load
check "uburoot-kmod list marks ours" k_list
check "unloading a module UbuRoot did not load is refused" k_notours
check "Android side sees the same 4 changes" k_changes 4
# Stop all: umount --kill, then revert (the app runs exactly this).
$B/umount.sh --kill >/dev/null 2>&1
kout -y revert >/tmp/krevert.log 2>&1
rc=$?
check "Stop all: revert (rc=$rc)" test "$rc" = 0
k_reverted() {
    [ "$(val sys/kernel/kptr_restrict)" = 2 ] && [ "$(val sys/kernel/dmesg_restrict)" = 1 ] && [ "$(val enforce)" = 1 ] &&
        ! grep -q '^fake ' $K/modules && grep -q '^vendor_wlan ' $K/modules
}
check "reverted: kptr_restrict 2, dmesg_restrict 1, enforcing, module gone" k_reverted
# Recorded: kptr_restrict, dmesg_restrict, SELinux, module -> reverted newest first.
check "revert order: newest first (module ... kptr_restrict)" sh -c "head -1 /tmp/krevert.log | grep -q 'module fake' && sed -n 2p /tmp/krevert.log | grep -q selinux && tail -1 /tmp/krevert.log | grep -q kernel.kptr_restrict"
check "change log empty" k_changes 0
check "nothing left under rootfs" test "$(mounted_under $R)" = 0
outside >/tmp/kafter.txt
check "container mount table identical (kernel fs sources survive)" cmp -s /tmp/kbase.txt /tmp/kafter.txt
kout -y sysctl kernel.kptr_restrict 1 >/dev/null 2>&1
echo boot-2 >$K/boot_id
check "a change log from an earlier boot is discarded" k_changes 0
echo 2 >$K/sys/kernel/kptr_restrict
rm -f /data/local/uburoot/uburoot.conf
k_off() { ! kout -y sysctl kernel.kptr_restrict 1 2>/dev/null && [ "$(val sys/kernel/kptr_restrict)" = 2 ]; }
check "changes refused with KERNEL_ACCESS=0" k_off
$B/mount.sh >/dev/null 2>&1
check "KERNEL_ACCESS=0 mounts no kernel fs" sh -c "! grep -qE ' $R/(sys/kernel/config|sys/fs/bpf|run/uburoot/state) ' /proc/self/mounts"
$B/umount.sh >/dev/null 2>&1

section "hardware access (HARDWARE_ACCESS=1)"
outside >/tmp/hbase.txt
printf 'HARDWARE_ACCESS=1\n' >/data/local/uburoot/uburoot.conf
$B/mount.sh >/tmp/hmount.log 2>&1
check "change log bound with hardware access only" grep -q " $R/run/uburoot/state " /proc/self/mounts
check "uburoot-hw and changes.sh installed" sh -c "[ -x $R/usr/local/sbin/uburoot-hw ] && [ -f $R/usr/local/lib/uburoot/changes.sh ]"
check "Ubuntu-side tools run with Ubuntu's /bin/sh" sh -c "head -n 1 $R/usr/local/sbin/uburoot-hw | grep -qx '#!/bin/sh'"
check "access file: kernel 0, hardware 1" sh -c "grep -qx KERNEL_ACCESS=0 $R/run/uburoot/access && grep -qx HARDWARE_ACCESS=1 $R/run/uburoot/access"
check "no kernel filesystems with KERNEL_ACCESS=0" sh -c "! grep -qE ' $R/(sys/kernel/config|sys/fs/bpf) ' /proc/self/mounts"
check "uburoot-kernel refuses changes (kernel access off)" sh -c "! chroot $R env UBU_SYSCTL_DIR=/tmp/k/sys UBU_BOOT_ID_FILE=/tmp/k/boot_id /usr/local/sbin/uburoot-kernel -y devmode on 2>/dev/null"
# A fake device tree: never the container's real /dev or /sys.
H=$R/tmp/hw
rm -rf $H
# The same path on both sides, as /dev and /sys are on a phone.
ln -sfn $H /tmp/hw
mkdir -p $H/dev $H/sys/devices/system/cpu/cpufreq/policy0 $H/sys/devices/system/cpu/cpu1 $H/sys/class/leds/test \
    $H/sys/class/ieee80211/phy0 $H/sys/bus/i2c/devices/1-0066 $H/sys/bus/i2c/devices/2-0020 $H/power $H/wifi
mknod $H/dev/ttyACM0 c 1 3 && chmod 600 $H/dev/ttyACM0
mknod $H/dev/i2c-1 c 1 3 && chmod 600 $H/dev/i2c-1
mknod $H/dev/i2c-2 c 1 3 && chmod 600 $H/dev/i2c-2
echo max77705-charger >$H/sys/bus/i2c/devices/1-0066/name
echo touchscreen >$H/sys/bus/i2c/devices/2-0020/name
P=$H/sys/devices/system/cpu/cpufreq/policy0
echo 0-3 >$P/related_cpus; echo schedutil >$P/scaling_governor; echo 300000 >$P/scaling_min_freq
echo 1800000 >$P/scaling_max_freq; echo 300000 >$P/cpuinfo_min_freq; echo 1800000 >$P/cpuinfo_max_freq
echo "performance powersave schedutil" >$P/scaling_available_governors
echo "300000 1000000 1800000" >$P/scaling_available_frequencies
echo 1 >$H/sys/devices/system/cpu/cpu1/online
echo 0-3 >$H/sys/devices/system/cpu/online
echo 0 >$H/sys/class/leds/test/brightness
: >$H/power/wake_lock; : >$H/power/wake_unlock
echo 1 >$H/wifi/enabled; echo 1 >$H/wifi/scan
# A configfs gadget like the S9's: g1 bound, adb linked as f1, Android's instances.
GD=$H/gadget/g1
mkdir -p $GD/configs/b.1 $GD/functions/ffs.adb $GD/functions/ncm.0 $GD/functions/acm.0 $GD/functions/mass_storage.0/lun.0
echo dummy_udc.0 >$GD/UDC; echo usb0 >$GD/functions/ncm.0/ifname; echo 0 >$GD/functions/acm.0/port_num
: >$GD/functions/mass_storage.0/lun.0/file; echo 1 >$GD/functions/mass_storage.0/lun.0/ro
ln -s /tmp/hw/gadget/g1/functions/ffs.adb $GD/configs/b.1/f1
dd if=/dev/zero of=$H/disk.img bs=1024 count=64 2>/dev/null
cat >$H/acmd <<'EOF2'
#!/bin/sh
# Fake Android tools: cmd wifi, settings (state in $UBU_FAKE_WIFI).
W=$UBU_FAKE_WIFI
case "$*" in
    "cmd wifi status") if [ "$(cat $W/enabled)" = 1 ]; then echo "Wifi is enabled"; else echo "Wifi is disabled"; fi ;;
    "settings get global wifi_scan_always_enabled") cat $W/scan ;;
    "cmd wifi set-wifi-enabled enabled") echo 1 >$W/enabled ;;
    "cmd wifi set-wifi-enabled disabled") echo 0 >$W/enabled ;;
    "cmd wifi set-scan-always-available enabled") echo 1 >$W/scan ;;
    "cmd wifi set-scan-always-available disabled") echo 0 >$W/scan ;;
    *) echo "fake acmd: $*" >&2; exit 1 ;;
esac
EOF2
chmod 755 $H/acmd
echo boot-3 >$K/boot_id
hin() { # uburoot-hw inside Ubuntu
    chroot $R env UBU_HW_ROOT=/tmp/hw UBU_POWER_DIR=/tmp/hw/power UBU_ACMD=/tmp/hw/acmd UBU_FAKE_WIFI=/tmp/hw/wifi UBU_GADGET_DIR=/tmp/hw/gadget \
        UBU_BOOT_ID_FILE=/tmp/k/boot_id /usr/local/sbin/uburoot-hw "$@"
}
hout() { # hardware.sh on the Android side
    env UBU_HW_ROOT=/tmp/hw UBU_POWER_DIR=/tmp/hw/power UBU_ACMD=/tmp/hw/acmd UBU_FAKE_WIFI=/tmp/hw/wifi UBU_GADGET_DIR=/tmp/hw/gadget \
        UBU_BOOT_ID_FILE=$K/boot_id /system/bin/sh $B/hardware.sh "$@"
}
kout2() { # Stop all's revert, with the fakes the hardware records need
    env UBU_POWER_DIR=/tmp/hw/power UBU_ACMD=/tmp/hw/acmd UBU_FAKE_WIFI=/tmp/hw/wifi UBU_GADGET_DIR=/tmp/hw/gadget UBU_BOOT_ID_FILE=$K/boot_id \
        UBU_SYSCTL_DIR=$K/sys UBU_SELINUX_ENFORCE=$K/enforce UBU_PROC_MODULES=$K/modules UBU_RMMOD=$K/rmmod \
        /system/bin/sh $B/kernel.sh "$@"
}
running() { # REGEX: a process whose command line matches ([x] keeps grep itself out)
    for _p in /proc/[0-9]*; do
        tr '\0' ' ' <"$_p/cmdline" 2>/dev/null | grep -q "$1" && return 0
    done
    return 1
}
h_nowatch() { ! running 'uburoot-hw [w]atch'; }
h_watching() { running 'uburoot-hw [w]atch'; }
h_status() { hin status | grep -qx access=on && hin status | grep -q '^class=serial|direct|available|1|dialout|'; }
h_grant() {
    hin grant serial tester >/dev/null && grep -q '^dialout:.*tester' $R/etc/group &&
        [ "$(stat -c '%g %a' $H/dev/ttyACM0)" = "20 660" ] && grep -qx "node /tmp/hw/dev/ttyACM0 0:0:600" $CH
}
h_hotplug() {
    mknod $H/dev/ttyUSB0 c 1 3 && chmod 600 $H/dev/ttyUSB0
    i=0
    while [ $i -lt 8 ]; do
        [ "$(stat -c '%g %a' $H/dev/ttyUSB0)" = "20 660" ] && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}
h_usb() { hin grant usb tester >/dev/null && grep -q '^aid_usb:x:1018:.*tester' $R/etc/group; }
h_badgrant() { ! hin grant wifi tester 2>/dev/null && ! hin grant usb nosuchuser 2>/dev/null; }
h_gov() { hin cpu governor policy0 performance >/dev/null && [ "$(cat $P/scaling_governor)" = performance ] && grep -qx "file /tmp/hw/sys/devices/system/cpu/cpufreq/policy0/scaling_governor schedutil" $CH; }
h_badfreq() { ! hin cpu max policy0 2500000 2>/dev/null && [ "$(cat $P/scaling_max_freq)" = 1800000 ]; }
h_freq() { hin cpu max policy0 1000000 >/dev/null && [ "$(cat $P/scaling_max_freq)" = 1000000 ]; }
h_boost() { # a hardware limit missing from the table (a boost frequency)
    echo 2000000 >$P/cpuinfo_max_freq && hin cpu max policy0 2000000 >/dev/null && [ "$(cat $P/scaling_max_freq)" = 2000000 ] &&
        hin cpu max policy0 1000000 >/dev/null && echo 1800000 >$P/cpuinfo_max_freq
}
h_cpu0() { ! hin cpu online 0 0 2>/dev/null; }
h_offline() { hin cpu online 1 0 >/dev/null && [ "$(cat $H/sys/devices/system/cpu/cpu1/online)" = 0 ]; }
h_wake() { hin wakelock on >/dev/null && grep -qx uburoot_hw $H/power/wake_lock && grep -qx 'wakelock uburoot_hw -' $CH; }
h_led() { hin set /sys/class/leds/test/brightness 5 >/dev/null && [ "$(cat $H/sys/class/leds/test/brightness)" = 5 ]; }
h_ledbad() { ! hin set /sys/class/power_supply/battery/batt_tune_float_voltage 4400 2>/dev/null; }
h_pmic() { ! hin -y allow /dev/i2c-1 2>/dev/null && [ "$(stat -c %a $H/dev/i2c-1)" = 600 ]; }
h_bus() { hin -y allow /dev/i2c-2 >/dev/null && [ "$(stat -c %a $H/dev/i2c-2)" = 660 ] && grep -q '^uburoot-bus:' $R/etc/group; }
h_take() {
    hin -y takeover wifi >/dev/null && [ "$(cat $H/wifi/enabled)$(cat $H/wifi/scan)" = 00 ] && grep -qx 'takeover wifi 1:1' $CH
}
h_release() {
    # A stand-in whose executable is Ubuntu's /usr/sbin/wpa_supplicant (dash ignores argv0).
    cp $R/usr/bin/dash $R/usr/sbin/wpa_supplicant
    chroot $R /usr/sbin/wpa_supplicant -c 'while :; do sleep 1; done' </dev/null >/dev/null 2>&1 &
    sleep 1
    running 'wpa_supplicant [-]c' || return 1
    hin release wifi >/dev/null && sleep 1 && [ "$(cat $H/wifi/enabled)$(cat $H/wifi/scan)" = 11 ] &&
        ! grep -q '^takeover wifi' $CH && ! running 'wpa_supplicant [-]c'
}
check "uburoot-hw status (Ubuntu side)" h_status
check "grant serial: group dialout, existing node 0660, original recorded" h_grant
check "a new serial device gets the rule (watcher)" h_hotplug
check "grant usb: group aid_usb (gid 1018)" h_usb
check "grant refuses a class without a group and an unknown user" h_badgrant
check "cpu governor recorded" h_gov
check "cpu max outside the frequency table refused" h_badfreq
check "cpu max from the table" h_freq
check "cpu max: cpuinfo_max_freq accepted even outside the table" h_boost
check "cpu0 can't go offline" h_cpu0
check "cpu1 offline recorded" h_offline
check "wake lock recorded" h_wake
check "LED brightness recorded" h_led
check "only LED files can be set (no battery/charger knobs)" h_ledbad
check "a PMIC/charger bus node is refused" h_pmic
check "a bus node opened to uburoot-bus" h_bus
h_gon() {
    hin -y gadget on ncm >/dev/null && hin -y gadget on acm >/dev/null &&
        [ "$(readlink $GD/configs/b.1/uburoot.ncm)" = /tmp/hw/gadget/g1/functions/ncm.0 ] &&
        [ -L $GD/configs/b.1/uburoot.acm ] && [ -L $GD/configs/b.1/f1 ] &&
        [ "$(cat $GD/UDC)" = dummy_udc.0 ] && grep -qx 'takeover gadget g1:dummy_udc.0' $CH
}
h_ghid() {
    hin -y gadget on hid >/dev/null && [ -L $GD/configs/b.1/uburoot.hidkbd ] && [ -L $GD/configs/b.1/uburoot.hidmouse ] &&
        [ "$(wc -c <$GD/functions/hid.uburootkbd/report_desc)" = 63 ] &&
        [ "$(wc -c <$GD/functions/hid.uburootmouse/report_desc)" = 52 ] &&
        [ "$(cat $GD/functions/hid.uburootkbd/protocol)" = 1 ] && [ "$(cat $GD/functions/hid.uburootmouse/report_length)" = 4 ]
}
h_gdev() { ! hin -y gadget on storage /dev/sda 2>/dev/null && ! hin -y gadget on storage tmp/x.img 2>/dev/null; }
h_gdisk() {
    hin -y gadget on storage /tmp/hw/disk.img >/dev/null && [ "$(cat $GD/functions/mass_storage.0/lun.0/file)" = /tmp/hw/disk.img ] &&
        [ "$(cat $GD/functions/mass_storage.0/lun.0/ro)" = 1 ] && [ -L $GD/configs/b.1/uburoot.storage ]
}
h_gstatus() { hin gadget status | grep -q 'UbuRoot: ncm.0 interface usb0' && hin gadget status | grep -q 'Android: ffs.adb'; }
check "gadget on ncm, acm: Android's instances linked next to adb, recorded" h_gon
check "gadget on hid: keyboard (63-byte) and mouse (52-byte) descriptors" h_ghid
check "gadget storage refuses a device node and a relative path" h_gdev
check "gadget storage: the image, read-only by default" h_gdisk
check "gadget status names Android's and UbuRoot's functions" h_gstatus
check "takeover wifi: Android Wi-Fi and scanning off, recorded" h_take
check "release wifi: restored, Ubuntu's wpa_supplicant stopped" h_release
hin -y takeover wifi >/dev/null 2>&1
check "the rule watcher runs inside Ubuntu" h_watching
h_seen() { hout status | grep -q '^changes=[1-9]'; }
h_taken() { hout status | grep -q '^class=wifi|takeover|taken|'; }
check "Android side sees the hardware changes" h_seen
check "Android side: wifi taken" h_taken
# Bridges: the token file, and the client against a fake app (perl, abstract socket).
SOCK=uburoot.0123abcd.audio
h_pub() {
    echo feedbeef | hout bridge publish audio $SOCK >/dev/null &&
        [ "$(stat -c '%u %g %a' $R/run/uburoot-bridge/audio)" = "0 1005 640" ] &&
        grep -qx "socket=$SOCK" $R/run/uburoot-bridge/audio && grep -qx token=feedbeef $R/run/uburoot-bridge/audio &&
        hout status | grep -qx 'bridge=audio|on'
}
h_badpub() {
    ! echo feedbeef | hout bridge publish audio uburoot.x.camera 2>/dev/null &&
        ! echo 'feed beef' | hout bridge publish camera uburoot.01.camera 2>/dev/null &&
        ! echo feedbeef | hout bridge publish disk uburoot.01.disk 2>/dev/null
}
cat >$R/tmp/fake-app.pl <<'EOF'
use Socket;
socket(my $l, AF_UNIX, SOCK_STREAM, 0) or die; bind($l, pack_sockaddr_un("\0$ARGV[0]")) or die "bind: $!"; listen($l, 5);
open(my $r, '>', '/tmp/fake-app.ready'); close $r;
for (1 .. 3) {
    accept(my $c, $l) or die;
    my $line = '';
    while (sysread($c, my $ch, 1)) { last if $ch eq "\n"; $line .= $ch; }
    my ($t, $cmd, @a) = split / /, $line;
    if ($t ne 'feedbeef') { syswrite($c, "ERR refused\n"); close $c; next; }
    if ($cmd eq 'record') { syswrite($c, "OK\nPCM:@a"); close $c; next; }
    syswrite($c, "OK\n");
    my $all = '';
    while (sysread($c, my $b, 4096)) { $all .= $b; }
    open(my $f, '>', '/tmp/played'); print $f "@a:$all"; close $f; close $c;
}
EOF
rm -f $R/tmp/fake-app.ready $R/tmp/played
chroot $R timeout 60 perl /tmp/fake-app.pl $SOCK &
for _i in 1 2 3 4 5 6 7 8 9 10; do [ -f $R/tmp/fake-app.ready ] && break; sleep 1; done
h_rec() { [ "$($B/enter.sh root 'UBU_RATE=16000 uburoot-audio record' 2>/dev/null)" = "PCM:16000 1" ]; }
h_play() { $B/enter.sh root 'printf abc | uburoot-audio play' && [ "$(cat $R/tmp/played)" = "48000 2:abc" ]; }
h_badtok() {
    sed -i s/token=feedbeef/token=0bad/ $R/run/uburoot-bridge/audio
    out=$($B/enter.sh root 'uburoot-audio record' 2>&1) && return 1
    printf '%s' "$out" | grep -q refused
}
h_nouser() {
    out=$($B/enter.sh tester 'uburoot-audio record' 2>&1) && return 1
    printf '%s' "$out" | grep -q 'grant'
}
h_unpub() { hout bridge unpublish all && [ ! -e $R/run/uburoot-bridge/audio ] && hout status | grep -qx 'bridge=audio|off'; }
h_onewatch() {
    _n=0
    for _p in /proc/[0-9]*; do
        if tr '\0' ' ' <"$_p/cmdline" 2>/dev/null | grep -q '^/bin/sh /usr/local/sbin/uburoot-hw watch'; then _n=$((_n + 1)); fi
    done
    [ "$_n" = 1 ]
}
check "bridge publish: token file 0640 root:aid_audio, in status" h_pub
check "bridge publish refuses a bad socket name, token or bridge" h_badpub
check "uburoot-audio record: the app's stream to stdout" h_rec
check "uburoot-audio play: stdin to the app" h_play
check "bridge client: the app's ERR (wrong token)" h_badtok
check "bridge client: a user without the grant is told so" h_nouser
check "bridge unpublish all" h_unpub
check "sessions started no second rule watcher" h_onewatch
check "uburoot-camera usage" sh -c "! $B/enter.sh root 'uburoot-camera snap' 2>/dev/null"
# Stop all: umount --kill (stops the watcher too), then revert.
$B/umount.sh --kill >/dev/null 2>&1
check "watcher stopped by umount" h_nowatch
kout2 -y revert >/tmp/hrevert.log 2>&1
check "Stop all: revert" grep -q 'reverted: takeover wifi' /tmp/hrevert.log
h_reverted() {
    [ "$(stat -c '%u:%g %a' $H/dev/ttyACM0)" = "0:0 600" ] && [ "$(stat -c '%u:%g %a' $H/dev/ttyUSB0)" = "0:0 600" ] &&
        [ "$(stat -c %a $H/dev/i2c-2)" = 600 ] && [ "$(cat $P/scaling_governor)" = schedutil ] &&
        [ "$(cat $P/scaling_max_freq)" = 1800000 ] && [ "$(cat $H/sys/devices/system/cpu/cpu1/online)" = 1 ] &&
        grep -qx uburoot_hw $H/power/wake_unlock && [ "$(cat $H/sys/class/leds/test/brightness)" = 0 ] &&
        [ "$(cat $H/wifi/enabled)$(cat $H/wifi/scan)" = 11 ]
}
check "reverted: nodes, CPU, wake lock, LED, Wi-Fi" h_reverted
h_greverted() {
    [ -z "$(ls -d $GD/configs/b.1/uburoot.* 2>/dev/null)" ] && [ -L $GD/configs/b.1/f1 ] &&
        [ "$(cat $GD/UDC)" = dummy_udc.0 ] && [ -z "$(cat $GD/functions/mass_storage.0/lun.0/file)" ] &&
        [ -d $GD/functions/ncm.0 ] && [ -d $GD/functions/hid.uburootkbd ]
}
check "reverted gadget: our links gone, image ejected, bound again, no instance removed" h_greverted
check "change log empty" k_changes 0
check "nothing left under rootfs" test "$(mounted_under $R)" = 0
outside >/tmp/hafter.txt
check "container mount table identical" cmp -s /tmp/hbase.txt /tmp/hafter.txt
rm -f /data/local/uburoot/uburoot.conf
h_off() { ! hout -y cpu governor policy0 performance 2>/dev/null && [ "$(cat $P/scaling_governor)" = schedutil ]; }
check "changes refused with HARDWARE_ACCESS=0" h_off
rm -f $R/usr/sbin/wpa_supplicant $R/etc/uburoot/hw-rules /tmp/hw

section "x11.sh (Linux GUI apps, fake Termux:X11)"
# A fake app_process: listens on $TMPDIR/.X11-unix/X0 like Termux:X11's X server.
cat >/tmp/fake-app-process <<'EOF'
#!/system/bin/sh
exec perl -MSocket -e 'mkdir "$ENV{TMPDIR}/.X11-unix"; socket(S, AF_UNIX, SOCK_STREAM, 0) or die;
    bind(S, pack_sockaddr_un("$ENV{TMPDIR}/.X11-unix/X0")) or die "bind: $!"; listen(S, 5); sleep 600' uburoot-x11
EOF
chmod 755 /tmp/fake-app-process
xo() { env UBU_X11_APK=/fake/base.apk UBU_APP_PROCESS=/tmp/fake-app-process /system/bin/sh $B/x11.sh "$@"; }
A=$R/usr/share/applications
mkdir -p $A $R/usr/share/icons/hicolor/48x48/apps $R/usr/share/X11/xkb $R/home/tester/.local/share/applications
printf '[Desktop Entry]\nType=Application\nName=Fake GUI\nExec=sh -c "echo \\$DISPLAY \\$(id -un) >/tmp/gui-ran" %%U\nIcon=fakegui\n' >$A/fakegui.desktop
printf '[Desktop Entry]\nType=Application\nName=Hidden\nExec=true\nNoDisplay=true\n' >$A/hidden.desktop
printf '[Desktop Entry]\nType=Application\nName=Term\nExec=true\nTerminal=true\n' >$A/term.desktop
printf '[Desktop Entry]\nType=Application\nName=Xfce only\nExec=true\nOnlyShowIn=XFCE;\n' >$A/xfceonly.desktop
printf '[Desktop Entry]\nType=Application\nName=Mine\nExec=true\n[Desktop Action x]\nName=Other\n' >$R/home/tester/.local/share/applications/mine.desktop
printf '[Desktop Entry]\nType=Application\nName=Outside\nExec=true\n' >/tmp/outside.desktop
ln -sf /tmp/outside.desktop $R/home/tester/.local/share/applications/outside.desktop
printf 'PNGDATA' >$R/usr/share/icons/hicolor/48x48/apps/fakegui.png
h_xnoxkb() {
    rmdir $R/usr/share/X11/xkb
    ! xo start 2>/dev/null && [ ! -e $R/etc/uburoot/x11 ] && mkdir $R/usr/share/X11/xkb
}
h_xmissing() { xo status | grep -qx x11=stopped && xo status | grep -qx wm=missing; }
h_xapps() {
    [ "$(xo apps tester | cut -d'|' -f1 | tr '\n' ' ')" = "fakegui mine " ] &&
        xo apps tester | grep -qx 'fakegui|Fake GUI|fakegui'
}
h_xicons() { [ "$(xo icons tester)" = "fakegui|$(printf PNGDATA | base64)" ]; }
h_xbadid() { ! xo run tester '../x' 2>/dev/null && ! xo run tester nosuch 2>/dev/null && ! xo run 'a;b' fakegui 2>/dev/null; }
h_xrun() {
    rm -f $R/tmp/gui-ran
    xo run tester fakegui >/dev/null 2>&1 || return 1
    for _i in 1 2 3 4 5 6 7 8 9 10; do [ -s $R/tmp/gui-ran ] && break; sleep 1; done
    [ "$(cat $R/tmp/gui-ran)" = ":0 tester" ] && [ -S $R/tmp/.X11-unix/X0 ] && xo status | grep -qx x11=running &&
        [ -z "$(find $R/run/uburoot-x11 -name 'run.*' 2>/dev/null)" ]
}
h_xdisplay() { [ "$($B/enter.sh tester 'echo $DISPLAY' 2>/dev/null)" = ":0" ]; }
h_xumount() {
    _xp=$(cat /data/local/uburoot/state/x11.pid) && kill -0 "$_xp" || return 1
    $B/umount.sh --kill >/dev/null 2>&1
    ! kill -0 "$_xp" 2>/dev/null && [ ! -e $R/tmp/.X11-unix/X0 ] && test "$(mounted_under $R)" = 0
}
check "x11.sh status: stopped, no window manager" h_xmissing
check "x11.sh apps: GUI entries only (no hidden/terminal/OnlyShowIn), user's own, no symlink out" h_xapps
check "x11.sh icons: hicolor PNG as base64" h_xicons
check "x11.sh run refuses bad ids and users" h_xbadid
check "x11.sh start refuses without xkb-data" h_xnoxkb
check "x11.sh run: server up, app started as the user with DISPLAY=:0" h_xrun
check "login shells get DISPLAY=:0 once the display was used" h_xdisplay
# A fake wmctrl: the window list of `-l -x`, every other call logged.
cat >$R/usr/bin/wmctrl <<'EOF'
#!/bin/sh
if [ "$*" = "-l -x" ]; then
    echo '0x00400003  1 fakegui.Fakegui  host Fake | window'
    echo '0x00500001 -1 xfce4-panel.Xfce4-panel  host xfce4-panel'
    echo '0x00600002  0 org.example.Mine.Mine  host Mine doc'
    echo '0x00700002  0 unknown.Unknown  host Something'
    echo '0x00800001  0 special.SpecialWM  host Special'
    exit 0
fi
echo "$DISPLAY $*" >>/tmp/wmctrl.log
EOF
chmod 755 $R/usr/bin/wmctrl
printf '[Desktop Entry]\nType=Application\nName=Special\nExec=true\nStartupWMClass=SpecialWM\n' >$A/sw.desktop
h_xwindows() {
    [ "$(xo windows tester)" = "0x00400003|fakegui|Fake / window
0x00600002|mine|Mine doc
0x00700002||Something
0x00800001|sw|Special" ] && xo status | grep -qx switch=yes
}
h_xreuse() {
    rm -f $R/tmp/wmctrl.log $R/tmp/gui-ran
    xo run tester fakegui 2>&1 | grep -q 'switched to fakegui' &&
        [ "$(cat $R/tmp/wmctrl.log)" = ":0 -i -a 0x00400003" ] && sleep 2 && [ ! -e $R/tmp/gui-ran ]
}
h_xfocus() {
    rm -f $R/tmp/wmctrl.log
    ! xo focus 'x;y' 2>/dev/null && ! xo focus 0xzz 2>/dev/null && ! xo close 0x 2>/dev/null &&
        xo focus 0x00800001 && xo close 0x00600002 &&
        [ "$(cat $R/tmp/wmctrl.log)" = ":0 -i -a 0x00800001
:0 -i -c 0x00600002" ]
}
h_xdesktop() {
    xo status | grep -qx desktop=missing || return 1
    if xo desktop tester 2>/dev/null; then return 1; fi
    printf '#!/bin/sh\necho "$DISPLAY $(id -un) $DBUS_SESSION_BUS_ADDRESS" >/tmp/desk-ran\n' >$R/usr/bin/startxfce4
    chmod 755 $R/usr/bin/startxfce4
    xo desktop tester 2>&1 | grep -q 'desktop started as tester' || return 1
    for _i in 1 2 3 4 5; do [ -s $R/tmp/desk-ran ] && break; sleep 1; done
    xo status | grep -qx desktop=ready && grep -q '^:0 tester' $R/tmp/desk-ran
}
h_xmozilla() {
    xo status | grep -qx firefox=missing || return 1
    if ! xo mozilla >/tmp/moz.log 2>&1; then
        tail -5 /tmp/moz.log
        return 1
    fi
    for _f in etc/apt/keyrings/packages.mozilla.org.asc etc/apt/sources.list.d/mozilla.sources etc/apt/preferences.d/80uburoot-mozilla; do
        [ "$(stat -c %u:%a $R/$_f)" = 0:644 ] || return 1
    done
    _pol=$($B/enter.sh root 'apt-cache policy firefox' 2>/dev/null)
    echo "$_pol" | grep -q 'packages.mozilla.org' && ! echo "$_pol" | grep 'Candidate:' | grep -q -e snap -e '(none)'
}
check "x11.sh windows: open windows matched to their apps (WM_CLASS), panels left out" h_xwindows
check "x11.sh run of an open app brings its window back (no second start)" h_xreuse
check "x11.sh focus/close: window ids checked, wmctrl called" h_xfocus
check "x11.sh desktop: refused without XFCE, then startxfce4 as the user" h_xdesktop
check "x11.sh mozilla: key/source/pin root-owned, firefox from packages.mozilla.org" h_xmozilla
rm -f $R/usr/bin/wmctrl $R/usr/bin/startxfce4 $A/sw.desktop $R/tmp/wmctrl.log $R/tmp/desk-ran \
    $R/etc/apt/keyrings/packages.mozilla.org.asc $R/etc/apt/sources.list.d/mozilla.sources $R/etc/apt/preferences.d/80uburoot-mozilla
check "umount.sh stops the X server" h_xumount
rm -rf $R/usr/share/X11/xkb $A/fakegui.desktop $A/hidden.desktop $A/term.desktop $A/xfceonly.desktop $R/home/tester/.local /tmp/outside.desktop $R/etc/uburoot/x11 \
    $R/usr/share/icons/hicolor/48x48/apps/fakegui.png /data/local/uburoot/state/x11.prefs

section "gpu.sh (GPU driver, fake Adreno)"
mkdir -p /tmp/kgsl-sys /tmp/gpu-ok/usr/local/lib/uburoot/gpu /tmp/gpu-ok/usr/local/share/vulkan/icd.d
echo Adreno630v2 >/tmp/kgsl-sys/gpu_model
: >/tmp/kgsl-dev
go() { env UBU_KGSL_DEV=/tmp/kgsl-dev UBU_KGSL_SYS=/tmp/kgsl-sys /system/bin/sh $B/gpu.sh "$@"; }
printf 'ELF-fake' >/tmp/gpu-ok/usr/local/lib/uburoot/gpu/libvulkan_freedreno_kgsl.so
printf 'mesa=26.0.8-test\nkmds=kgsl\n' >/tmp/gpu-ok/usr/local/lib/uburoot/gpu/BUILDINFO
echo '{"ICD":{}}' >/tmp/gpu-ok/usr/local/share/vulkan/icd.d/uburoot_freedreno_kgsl_icd.json
tar -C /tmp/gpu-ok -czf /tmp/gpu-ok.tgz usr
# Bad archives: an extra file, a symlink in place of the library, a path out of it.
cp -a /tmp/gpu-ok /tmp/gpu-extra && echo x >/tmp/gpu-extra/usr/local/lib/uburoot/gpu/evil
tar -C /tmp/gpu-extra -czf /tmp/gpu-extra.tgz usr
cp -a /tmp/gpu-ok /tmp/gpu-link && ln -sf /etc/shadow /tmp/gpu-link/usr/local/lib/uburoot/gpu/libvulkan_freedreno_kgsl.so
tar -C /tmp/gpu-link -czf /tmp/gpu-link.tgz usr
tar -P -C /tmp/gpu-ok -czf /tmp/gpu-dots.tgz usr ../kgsl-sys/gpu_model
sha() { sha256sum "$1" | cut -d' ' -f1; }
h_gstat() { go status | grep -qx gpu=adreno && go status | grep -qx model=Adreno630v2 && go status | grep -qx driver=missing; }
h_gnone() { env UBU_KGSL_DEV=/nonexistent /system/bin/sh $B/gpu.sh status | grep -qx gpu=none; }
h_gbadsha() { ! go install /tmp/gpu-ok.tgz "$(printf '%064d' 0)" 2>/dev/null && ! go install /tmp/gpu-ok.tgz xyz 2>/dev/null && ! test -e $R/usr/local/lib/uburoot/gpu/BUILDINFO; }
h_gbad() {
    for _t in extra link dots; do
        go install /tmp/gpu-$_t.tgz "$(sha /tmp/gpu-$_t.tgz)" >/dev/null 2>&1 && return 1
    done
    [ ! -e $R/usr/local/lib/uburoot/gpu/libvulkan_freedreno_kgsl.so ] && [ ! -e $R/usr/local/lib/uburoot/gpu/evil ]
}
h_ginst() {
    go install /tmp/gpu-ok.tgz "$(sha /tmp/gpu-ok.tgz | tr a-f A-F)" >/dev/null 2>&1 &&
        [ "$(stat -c '%u:%g %a' $R/usr/local/lib/uburoot/gpu/libvulkan_freedreno_kgsl.so)" = "0:0 755" ] &&
        [ "$(stat -c '%u:%g %a' $R/usr/local/share/vulkan/icd.d/uburoot_freedreno_kgsl_icd.json)" = "0:0 644" ] &&
        go status | grep -qx driver=installed && go status | grep -qx mesa=26.0.8-test && go status | grep -qx zink=on
}
h_genv() { [ "$($B/enter.sh tester 'echo $MESA_LOADER_DRIVER_OVERRIDE' 2>/dev/null)" = zink ]; }
h_gzoff() { go zink off && go status | grep -qx zink=off && [ -z "$($B/enter.sh tester 'echo $MESA_LOADER_DRIVER_OVERRIDE' 2>/dev/null)" ] && go zink on; }
h_grend() { go renderer tester | grep -qx 'vulkan=?' && ! go renderer 'a;b' 2>/dev/null; }
h_grm() { go remove && go status | grep -qx driver=missing && go status | grep -qx zink=off && [ ! -e $R/usr/local/lib/uburoot/gpu ] && ! go zink on 2>/dev/null; }
check "gpu.sh status: Adreno model, no driver" h_gstat
check "gpu.sh status: gpu=none without KGSL" h_gnone
check "gpu.sh install refuses a wrong or malformed SHA256" h_gbadsha
check "gpu.sh install refuses extra files, symlinks, paths out of it" h_gbad
check "gpu.sh install: root-owned files, zink on (SHA256 any case)" h_ginst
check "login shells get MESA_LOADER_DRIVER_OVERRIDE=zink" h_genv
check "gpu.sh zink off/on" h_gzoff
check "gpu.sh renderer runs as the user (no tools: ?), bad user refused" h_grend
check "gpu.sh remove" h_grm
rm -rf /tmp/gpu-ok /tmp/gpu-extra /tmp/gpu-link /tmp/kgsl-sys /tmp/kgsl-dev /tmp/gpu-*.tgz

section "uburoot-kbuild (fake kernel tree)"
mkdir -p /tmp/ksrc
cat >/tmp/ksrc/Makefile <<'EOF'
VERSION = 9
PATCHLEVEL = 9
SUBLEVEL = 9
EXTRAVERSION =
olddefconfig modules_prepare:
	@echo "$@ done"
kernelrelease:
	@. ./.config; echo "$(VERSION).$(PATCHLEVEL).$(SUBLEVEL)$(EXTRAVERSION)$$CONFIG_LOCALVERSION"
EOF
printf 'CONFIG_MODULES=y\nCONFIG_SMP=y\nCONFIG_PREEMPT=y\nCONFIG_MODULE_UNLOAD=y\nCONFIG_MODVERSIONS=y\nCONFIG_MODULE_SIG=y\nCONFIG_MODULE_SIG_FORCE=y\nCONFIG_LOCALVERSION="-old"\n' | gzip >/tmp/kconfig.gz
command -v make >/dev/null 2>&1 || apt-get install -y -qq make gcc bc flex bison >/dev/null 2>&1
kb() { env UBU_KCONFIG=/tmp/kconfig.gz UBU_KBUILD_STATE=/tmp/kbstate sh /src/app/src/main/assets/uburoot/bin/kbuild.sh "$@"; }
out=$(kb check 2>&1)
check "check: expected vermagic" sh -c "printf '%s' \"\$1\" | grep -q \"expected vermagic: *$KV SMP preempt mod_unload modversions\"" _ "$out"
check "check: signature enforcement explained" sh -c "printf '%s' \"\$1\" | grep -q 'ENFORCED'" _ "$out"
check "prepare refuses a source of another version" sh -c "! kb prepare /tmp/ksrc 2>/dev/null"
base=$(printf '%s' "$KV" | sed 's/^\([0-9]*\.[0-9]*\.[0-9]*\).*/\1/')
sed -i "s/^VERSION = .*/VERSION = ${base%%.*}/; s/^PATCHLEVEL = .*/PATCHLEVEL = $(echo "$base" | cut -d. -f2)/; s/^SUBLEVEL = .*/SUBLEVEL = ${base##*.}/" /tmp/ksrc/Makefile
check "prepare: config + LOCALVERSION so kernelrelease = uname -r" kb prepare /tmp/ksrc
check "prepare: LOCALVERSION is the release suffix" grep -qx "CONFIG_LOCALVERSION=\"${KV#"$base"}\"" /tmp/ksrc/.config

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
