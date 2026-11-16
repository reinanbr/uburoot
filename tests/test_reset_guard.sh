#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Critical safety rule test, no root needed.
# Uses dummy directories, a fake mount table (UBU_MOUNTS_FILE) and a fake
# busybox whose umount can be sabotaged, to prove that reset.sh / ubu_safe_rm
# NEVER delete while anything is (or looks) mounted under the rootfs.
# safe_rm sources common.sh in a subshell on purpose (isolation).
# shellcheck disable=SC2030,SC2031
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../app/src/main/assets/uburoot/bin" && pwd)

T=$(mktemp -d "${TMPDIR:-/tmp}/uburoot-guard.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }

# Fake busybox: umount/mount controlled by env, everything else passes through.
cat >"$T/fakebb" <<'EOF'
#!/bin/sh
case "$1" in
    umount) echo "fakebb: umount $*" >>"$FAKE_LOG"; exit "${FAKE_UMOUNT_RC:-1}" ;;
    mount) echo "fakebb: mount $*" >>"$FAKE_LOG"; exit 1 ;;
    *) exec "$@" ;;
esac
EOF
chmod +x "$T/fakebb"

export UBU_BASE="$T/base"
export ROOTFS="$T/base/rootfs"
export UBU_MOUNTS_FILE="$T/mounts"
export UBU_MOUNTINFO_FILE="$T/no-mountinfo"
export UBU_BB="$T/fakebb"
export UBU_ALLOW_NONROOT=1
export FAKE_LOG="$T/fakebb.log"

# Build a dummy rootfs where rootfs/data and rootfs/sdcard hold "phone data",
# exactly what they would expose if /data and /sdcard were bind-mounted.
make_rootfs() {
    rm -rf "$T/base"
    mkdir -p "$ROOTFS/usr/bin" "$ROOTFS/bin" "$ROOTFS/etc" "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev" \
        "$ROOTFS/data" "$ROOTFS/sdcard" "$T/base/keep"
    printf '#!/bin/sh\n' >"$ROOTFS/usr/bin/env"
    printf '#!/bin/sh\n' >"$ROOTFS/bin/bash"
    chmod +x "$ROOTFS/usr/bin/env" "$ROOTFS/bin/bash"
    echo "keep me" >"$T/base/keep/sibling.txt"
    : >"$UBU_MOUNTS_FILE"
}
phone_data() {
    echo "PRECIOUS photo" >"$ROOTFS/sdcard/DCIM.jpg"
    echo "PRECIOUS app db" >"$ROOTFS/data/app.db"
}
mounted() { printf '%s\n' "$@" >>"$UBU_MOUNTS_FILE"; }
precious_intact() { [ -f "$ROOTFS/sdcard/DCIM.jpg" ] && [ -f "$ROOTFS/data/app.db" ]; }

run_reset() { sh "$BIN/reset.sh" --yes >"$T/out" 2>&1; echo $?; }
# Call ubu_safe_rm directly, bypassing umount.sh.
safe_rm() {
    (
        # shellcheck source=app/src/main/assets/uburoot/bin/common.sh
        . "$BIN/common.sh"
        ubu_init
        ubu_safe_rm "$1"
    ) >"$T/out" 2>&1
    echo $?
}

echo "== critical rule: reset must abort while mounts exist =="

make_rootfs
phone_data
mounted "/dev/block/dm-5 $ROOTFS/data f2fs rw 0 0" "/dev/fuse $ROOTFS/sdcard fuse rw 0 0"
export FAKE_UMOUNT_RC=1
rc=$(run_reset)
if [ "$rc" = 3 ] && precious_intact; then ok "umount fails -> reset aborts (rc=3), data intact"; else bad "umount fails: rc=$rc"; cat "$T/out"; fi

make_rootfs
phone_data
mounted "/dev/block/dm-5 $ROOTFS/data f2fs rw 0 0"
export FAKE_UMOUNT_RC=0
rc=$(run_reset)
if [ "$rc" = 3 ] && precious_intact && grep -q 'still mounted' "$T/out"; then
    ok "umount 'succeeds' but mount remains in /proc/mounts -> abort, data intact"
else
    bad "lying umount: rc=$rc"
    cat "$T/out"
fi

make_rootfs
phone_data
mounted "/dev/block/dm-5 $ROOTFS/data f2fs rw 0 0"
rc=$(safe_rm "$ROOTFS")
if [ "$rc" = 3 ] && precious_intact; then ok "ubu_safe_rm called directly while mounted -> refused"; else bad "direct safe_rm: rc=$rc"; fi

make_rootfs
phone_data
mounted "$ROOTFS $ROOTFS none rw,bind 0 0"
rc=$(safe_rm "$ROOTFS")
if [ "$rc" = 3 ] && precious_intact; then ok "self-bind on ROOTFS itself -> refused"; else bad "self-bind: rc=$rc"; fi

make_rootfs
phone_data
mounted "proc $ROOTFS/data/deep/nested/mount proc rw 0 0"
rc=$(safe_rm "$ROOTFS")
if [ "$rc" = 3 ] && precious_intact; then ok "deeply nested mount -> refused"; else bad "nested: rc=$rc"; fi

echo "== defense in depth (no mounts listed) =="

make_rootfs
phone_data
rc=$(safe_rm "$ROOTFS")
if [ "$rc" = 3 ] && precious_intact && grep -q 'not empty' "$T/out"; then
    ok "non-empty bind target (mount invisible here) -> refused by rmdir guard"
else
    bad "rmdir guard: rc=$rc"
fi

make_rootfs
mkdir -p "$ROOTFS/proc/self"
rc=$(safe_rm "$ROOTFS")
if [ "$rc" = 3 ] && [ -d "$ROOTFS" ]; then ok "proc/self marker -> refused"; else bad "marker: rc=$rc"; fi

# Kernel access (KERNEL_ACCESS=1): configfs with the USB gadget, cgroups and
# bpffs live under sys/fs and sys/kernel; the change log is bound at run/uburoot.
for m in sys/fs/cgroup sys/kernel/config/usb_gadget run/uburoot/state; do
    make_rootfs
    mkdir -p "$ROOTFS/$m"
    rc=$(safe_rm "$ROOTFS")
    if [ "$rc" = 3 ] && [ -d "$ROOTFS/$m" ]; then ok "$m marker -> refused"; else bad "$m marker: rc=$rc"; fi
done

make_rootfs
mkdir -p "$ROOTFS/usr/lib/modules/4.9.337/uburoot/vendor_lib_modules"
echo "vendor module" >"$ROOTFS/usr/lib/modules/4.9.337/uburoot/vendor_lib_modules/wlan.ko"
rc=$(safe_rm "$ROOTFS")
if [ "$rc" = 3 ] && [ -f "$ROOTFS/usr/lib/modules/4.9.337/uburoot/vendor_lib_modules/wlan.ko" ]; then
    ok "non-empty module bind target (vendor modules) -> refused"
else
    bad "module bind target: rc=$rc"
fi

make_rootfs
rc=$(safe_rm "$T")
if [ "$rc" = 3 ] && [ -d "$ROOTFS" ]; then ok "path outside UBU_BASE -> refused"; else bad "outside: rc=$rc"; fi

make_rootfs
rc=$(safe_rm "$UBU_BASE")
if [ "$rc" = 3 ] && [ -d "$ROOTFS" ]; then ok "UBU_BASE itself -> refused"; else bad "base: rc=$rc"; fi

make_rootfs
ln -s "$T/base/keep" "$T/base/link"
rc=$(safe_rm "$T/base/link")
if [ "$rc" = 3 ] && [ -f "$T/base/keep/sibling.txt" ]; then ok "symlink target -> refused"; else bad "symlink: rc=$rc"; fi

make_rootfs
rc=$(ROOTFS="$T/base/x/../rootfs" sh "$BIN/reset.sh" --yes >"$T/out" 2>&1; echo $?)
if [ "$rc" != 0 ] && [ -d "$ROOTFS" ]; then ok "ROOTFS with '..' -> rejected"; else bad "dotdot: rc=$rc"; fi

make_rootfs
rc=$(sh "$BIN/reset.sh" >"$T/out" 2>&1; echo $?)
if [ "$rc" != 0 ] && [ -d "$ROOTFS" ]; then ok "reset without --yes -> refused"; else bad "no --yes: rc=$rc"; fi

echo "== clean state: deletion is allowed =="

make_rootfs
mounted "/dev/block/dm-5 ${ROOTFS}2/data f2fs rw 0 0" "/dev/block/dm-5 ${ROOTFS}.old f2fs rw 0 0"
export FAKE_UMOUNT_RC=0
rc=$(run_reset)
if [ "$rc" = 0 ] && [ ! -e "$ROOTFS" ] && [ -f "$T/base/keep/sibling.txt" ]; then
    ok "no mounts under ROOTFS (similar-prefix mounts ignored) -> rootfs deleted, siblings kept"
else
    bad "clean reset: rc=$rc"
    cat "$T/out"
fi

echo
echo "reset guard: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
