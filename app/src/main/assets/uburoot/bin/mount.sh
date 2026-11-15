#!/system/bin/sh
# Mount everything the chroot needs. Idempotent: every mount is skipped when
# its target already appears in /proc/self/mounts.
# Must run in the global mount namespace (su --mount-master) so that all
# sessions see the same mounts.
# Usage: mount.sh
set -u
UBU_BIN_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=common.sh
. "$UBU_BIN_DIR/common.sh"

ubu_require_root
ubu_init
ubu_load_config
ubu_rootfs_installed || ubu_die "no Ubuntu rootfs at $ROOTFS (run install.sh first)"

R=$ROOTFS

# 0) Self-bind the rootfs and make it private. /data is a shared mount on
#    Android, so without this every mount below would propagate to peers.
#    This is also the probe that our mount binary supports propagation flags;
#    nothing below (rbind!) is safe without them.
if ! ubu_is_mounted "$R"; then
    bb mount -o bind "$R" "$R" || ubu_die "self-bind of $R failed"
fi
if ! ubu_set_propagation private "$R"; then
    bb umount "$R" 2>/dev/null
    ubu_die "cannot set mount propagation (busybox/toybox without --make-private?); refusing to mount"
fi

# 1) Kernel filesystems and devices
ubu_mount_fs proc proc "$R/proc" || ubu_die "mount proc failed"
ubu_mount_fs sysfs sysfs "$R/sys" || ubu_die "mount sysfs failed"
ubu_bind bind /dev "$R/dev" || ubu_die "bind /dev failed"
ubu_bind bind /dev/pts "$R/dev/pts" || ubu_die "bind /dev/pts failed"
# $R/dev is the real Android /dev: dev/shm and dev/fd get created there.
ubu_mount_fs tmpfs tmpfs "$R/dev/shm" "mode=1777,nosuid,nodev" || ubu_warn "mount /dev/shm failed"
[ -e /dev/fd ] || ln -s /proc/self/fd /dev/fd 2>/dev/null
for _i in 0:stdin 1:stdout 2:stderr; do
    [ -e "/dev/${_i#*:}" ] || ln -s "/proc/self/fd/${_i%%:*}" "/dev/${_i#*:}" 2>/dev/null
done
if ubu_mount_fs tmpfs tmpfs "$R/run" "mode=0755,nosuid,nodev"; then
    mkdir -p "$R/run/lock" && chmod 1777 "$R/run/lock"
else
    ubu_warn "mount /run failed"
fi

# The kernel hostname is shared with Android and must not be changed; make it
# resolvable inside the chroot (sudo warns on every call otherwise).
_kh=$(cat /proc/sys/kernel/hostname 2>/dev/null) || _kh=""
if [ -n "$_kh" ] && [ -f "$R/etc/hosts" ] &&
    ! bb awk -v h="$_kh" '$1 !~ /^#/ { for (i = 2; i <= NF; i++) if ($i == h) f = 1 } END { exit !f }' "$R/etc/hosts"; then
    printf '127.0.1.1   %s\n' "$_kh" >>"$R/etc/hosts"
fi

# 2) Shared storage [MOUNT_SDCARD]
ubu_sdcard_source() {
    if [ -n "$SDCARD_SOURCE" ]; then
        printf '%s' "$SDCARD_SOURCE"
        return 0
    fi
    for _s in /storage/emulated/0 /mnt/user/0/emulated/0 /data/media/0; do
        if [ -d "$_s/Android" ] || [ -d "$_s/Download" ]; then
            printf '%s' "$_s"
            return 0
        fi
    done
    return 1
}
if [ "$MOUNT_SDCARD" = 1 ]; then
    if _src=$(ubu_sdcard_source); then
        ubu_bind bind "$_src" "$R/sdcard" || ubu_warn "bind $_src -> /sdcard failed"
    else
        ubu_warn "no usable shared storage source found; /sdcard not mounted"
    fi
elif ubu_is_mounted "$R/sdcard"; then
    ubu_log "MOUNT_SDCARD=0 but /sdcard is still mounted (use 'Reparar mounts')"
fi

# 3) Android integration [ANDROID_INTEGRATION]: same paths inside the chroot
#    so bionic binaries (linker64, /system/bin/*) work.
if [ "$ANDROID_INTEGRATION" = 1 ]; then
    for _p in $UBU_ANDROID_PARTS; do
        if [ -L "$_p" ]; then
            # e.g. /product -> /system/product: mirror the symlink itself.
            if [ ! -e "$R$_p" ] && [ ! -L "$R$_p" ]; then
                ln -s "$(readlink "$_p")" "$R$_p" || ubu_warn "symlink $_p failed"
            fi
        elif [ -d "$_p" ]; then
            ubu_bind rbind "$_p" "$R$_p" || ubu_warn "rbind $_p failed"
        fi
    done
    # Non-recursive: only /data itself, never the rootfs mounts below it.
    ubu_bind bind /data "$R/data" || ubu_warn "bind /data failed"

    if [ -x /system/bin/sh ]; then
        "$UBU_SH" "$UBU_BIN_DIR/android-env" --if-needed || ubu_warn "android-env failed"
    fi
else
    for _p in $UBU_ANDROID_PARTS /data; do
        if ubu_is_mounted "$R$_p"; then
            ubu_log "ANDROID_INTEGRATION=0 but $_p is still mounted (use 'Reparar mounts')"
            break
        fi
    done
fi

exit 0
