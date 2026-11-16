#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
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
# /data is nosuid on Android and the self-bind inherits it, which breaks sudo,
# su and ping inside the chroot. Remount this bind without it; a remount
# replaces all per-mount flags, so nodev is passed again explicitly.
bb mount -o remount,bind,nodev "$R" "$R" 2>/dev/null ||
    ubu_warn "could not clear nosuid on $R (sudo will not work)"

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

# 1b) Kernel access [KERNEL_ACCESS]: the kernel's own interfaces inside Ubuntu,
#     at the paths a normal Linux has them. Root in Ubuntu then controls the
#     phone's kernel; every change made through uburoot-kernel is recorded in
#     $UBU_STATE and reverted by Stop all.
if [ "$KERNEL_ACCESS" = 1 ]; then
    for _k in $UBU_KERNEL_FS; do
        _t=${_k%%:*}
        _rest=${_k#*:}
        _p=${_rest%%:*}
        _how=${_rest#*:}
        _dst="$R$_p"
        # The kernel creates these directories in sysfs/proc only when it
        # supports the filesystem; never mkdir there.
        [ -d "$_dst" ] || continue
        ubu_is_mounted "$_dst" && continue
        _src=$(ubu_fs_mount "$_t" "$_p")
        if [ -n "$_src" ]; then
            ubu_bind bind "$_src" "$_dst" || ubu_warn "bind $_src ($_t) -> $_p failed"
        elif [ "$_how" = new ] && bb grep -qw "$_t" /proc/filesystems 2>/dev/null; then
            # Under the private rootfs a new mount is private too.
            ubu_mount_fs "$_t" "$_t" "$_dst" || ubu_warn "mount $_t at $_p failed"
        fi
    done
    # Android's cgroup v1 controllers (cpuset, cpuctl, memcg...) live under
    # /dev; $R/dev is a non-recursive bind, so bind each at the same path.
    for _c in $(bb awk -v r="$R" '$3 == "cgroup" && index($2, "/dev/") == 1 && index($2, r "/") != 1 { print $2 }' "$UBU_MOUNTS_FILE"); do
        if [ -d "$R$_c" ] && ! ubu_is_mounted "$R$_c"; then
            ubu_bind bind "$_c" "$R$_c" || ubu_warn "bind cgroup $_c failed"
        fi
    done

    # The ROM's kernel modules, read-only, under /lib/modules/$(uname -r)/uburoot/;
    # depmod writes modules.dep into the rootfs, never into vendor.
    _kv=$(uname -r)
    _mods=""
    for _s in $UBU_MODULE_SOURCES; do
        [ -d "$_s/$_kv" ] && _s="$_s/$_kv"
        [ -d "$_s" ] || continue
        [ -n "$(bb find "$_s" -name '*.ko*' 2>/dev/null | head -n 1)" ] || continue
        _name=$(printf '%s' "${_s#/}" | tr '/' '_')
        _dst="$R/usr/lib/modules/$_kv/uburoot/$_name"
        if ! ubu_is_mounted "$_dst"; then
            if ubu_bind bind "$_s" "$_dst"; then
                bb mount -o remount,bind,ro "$_dst" 2>/dev/null || ubu_warn "could not make $_dst read-only"
            else
                ubu_warn "bind $_s -> modules failed"
                continue
            fi
        fi
        _mods="$_mods $_s"
    done
    _md="$R/usr/lib/modules/$_kv"
    if [ -n "$_mods" ]; then
        if [ ! -e "$R/usr/sbin/depmod" ] && [ ! -e "$R/sbin/depmod" ]; then
            ubu_log "kernel modules found ($_mods ), but Ubuntu has no depmod: apt install kmod"
        elif [ ! -f "$_md/modules.dep" ] || [ "$(cat "$_md/.uburoot-sources" 2>/dev/null)" != "$_mods" ]; then
            if bb chroot "$R" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin depmod -a "$_kv" 2>/dev/null; then
                printf '%s' "$_mods" >"$_md/.uburoot-sources"
            else
                ubu_warn "depmod failed for $_kv"
            fi
        fi
    fi

elif ubu_is_mounted "$R/sys/kernel/config" || ubu_is_mounted "$R/sys/kernel/tracing"; then
    ubu_log "KERNEL_ACCESS=0 but the kernel interfaces are still mounted (use 'Reparar mounts')"
fi

# 1c) The change log and the Ubuntu-side tools [KERNEL_ACCESS / HARDWARE_ACCESS].
#     uburoot-kernel and uburoot-hw record every change in $UBU_STATE, shared
#     with the host side, so Stop all (kernel.sh -y revert) undoes them.
ubu_install_tool() { # SOURCE DEST MODE
    # Ubuntu's own /bin/sh: /system/bin/sh is there only with ANDROID_INTEGRATION.
    bb sed '1s|^#!/system/bin/sh$|#!/bin/sh|' "$UBU_BIN_DIR/$1" >"$2.tmp" &&
        chown 0:0 "$2.tmp" && chmod "$3" "$2.tmp" && mv -f "$2.tmp" "$2"
}
mkdir -p "$R/run/uburoot" && chmod 700 "$R/run/uburoot"
printf 'KERNEL_ACCESS=%s\nHARDWARE_ACCESS=%s\n' "$KERNEL_ACCESS" "$HARDWARE_ACCESS" >"$R/run/uburoot/access"
if [ "$KERNEL_ACCESS" = 1 ] || [ "$HARDWARE_ACCESS" = 1 ]; then
    mkdir -p "$UBU_STATE" && chmod 700 "$UBU_STATE"
    if ! ubu_is_mounted "$R/run/uburoot/state"; then
        mkdir -p "$R/run/uburoot/state"
        ubu_bind bind "$UBU_STATE" "$R/run/uburoot/state" || ubu_warn "bind $UBU_STATE failed"
    fi
    if mkdir -p "$R/usr/local/sbin" "$R/usr/local/lib/uburoot"; then
        ubu_install_tool changes.sh "$R/usr/local/lib/uburoot/changes.sh" 644 || ubu_warn "cannot install changes.sh"
        if [ "$KERNEL_ACCESS" = 1 ]; then
            ubu_install_tool kernel.sh "$R/usr/local/sbin/uburoot-kernel" 755 || ubu_warn "cannot install uburoot-kernel"
            ubu_install_tool kbuild.sh "$R/usr/local/sbin/uburoot-kbuild" 755 || ubu_warn "cannot install uburoot-kbuild"
            ln -sf uburoot-kernel "$R/usr/local/sbin/uburoot-kmod"
        fi
        if [ "$HARDWARE_ACCESS" = 1 ]; then
            ubu_install_tool hardware.sh "$R/usr/local/sbin/uburoot-hw" 755 || ubu_warn "cannot install uburoot-hw"
            # The app's bridges (audio, camera, sensors, location): a perl-base client
            # and one dispatcher behind four names.
            ubu_install_tool bridge-client "$R/usr/local/lib/uburoot/bridge-client" 755 || ubu_warn "cannot install bridge-client"
            ubu_install_tool hwbridge.sh "$R/usr/local/lib/uburoot/hwbridge" 755 || ubu_warn "cannot install hwbridge"
            for _n in uburoot-audio uburoot-camera uburoot-sensors uburoot-gps; do
                ln -sfn ../lib/uburoot/hwbridge "$R/usr/local/bin/$_n"
            done
        fi
    fi
    # Permission rules for hotplugged devices (serial, hidraw) granted earlier.
    if [ "$HARDWARE_ACCESS" = 1 ] && [ -s "$R/etc/uburoot/hw-rules" ]; then
        "$UBU_SH" "$UBU_BIN_DIR/hardware.sh" apply >/dev/null 2>&1
        # exec first: a redirection on a function call (bb) keeps a saved copy of the
        # caller's stdout open in the background subshell, so $(enter.sh ...) never ended.
        # The watcher exits by itself if one is already running.
        (
            exec </dev/null >/dev/null 2>&1
            bb chroot "$R" /usr/bin/env -i PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
                /usr/local/sbin/uburoot-hw watch
        ) &
    fi
fi

# The kernel hostname is shared with Android and must not be changed; make it
# resolvable inside the chroot (sudo warns on every call otherwise).
_kh=$(cat /proc/sys/kernel/hostname 2>/dev/null) || _kh=""
if [ -n "$_kh" ] && [ -f "$R/etc/hosts" ] &&
    ! bb awk -v h="$_kh" '$1 !~ /^#/ { for (i = 2; i <= NF; i++) if ($i == h) f = 1 } END { exit !f }' "$R/etc/hosts"; then
    printf '127.0.1.1   %s\n' "$_kh" >>"$R/etc/hosts"
fi

# 2) Shared storage [MOUNT_SDCARD]
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

# 4) inotify watches [INOTIFY_MAX_WATCHES] for IDEs, file watchers and
#    webpack (Android's default, 8192, is far too low for VS Code). This is a
#    global kernel setting shared with Android, so it is only ever raised,
#    never lowered; 0 leaves it alone. Reset by a reboot.
case "$INOTIFY_MAX_WATCHES" in
    '' | *[!0-9]*) ubu_warn "invalid INOTIFY_MAX_WATCHES: $INOTIFY_MAX_WATCHES" ;;
    0) ;;
    *)
        _cur=$(cat "$UBU_INOTIFY_FILE" 2>/dev/null) || _cur=""
        case "$_cur" in
            '' | *[!0-9]*) ubu_warn "cannot read $UBU_INOTIFY_FILE" ;;
            *)
                if [ "$_cur" -lt "$INOTIFY_MAX_WATCHES" ]; then
                    if echo "$INOTIFY_MAX_WATCHES" >"$UBU_INOTIFY_FILE" 2>/dev/null; then
                        ubu_log "inotify max_user_watches: $_cur -> $INOTIFY_MAX_WATCHES"
                    else
                        ubu_warn "cannot raise inotify max_user_watches ($_cur)"
                    fi
                fi
                ;;
        esac
        ;;
esac

exit 0
