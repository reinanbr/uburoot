#!/system/bin/sh
# Print machine-readable facts about the root environment (key=value lines).
# Used by the app's preflight checks; also handy via adb.
set -u
UBU_BIN_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=common.sh
. "$UBU_BIN_DIR/common.sh"

ubu_detect_busybox
ubu_detect_root_impl
printf 'uid=%s\n' "$(id -u)"
printf 'impl=%s\n' "$UBU_ROOT_IMPL"
printf 'version=%s\n' "$UBU_ROOT_VERSION"
printf 'mount_master_flag=%s\n' "$UBU_MOUNT_MASTER_FLAG"
printf 'busybox=%s\n' "${BB:-none}"
printf 'busybox_kind=%s\n' "$BB_KIND"
printf 'arch=%s\n' "$(uname -m)"
printf 'mnt_ns=%s\n' "$(readlink /proc/self/ns/mnt 2>/dev/null)"
printf 'init_mnt_ns=%s\n' "$(readlink /proc/1/ns/mnt 2>/dev/null)"
if [ -d "$UBU_BASE" ]; then
    printf 'free_kb=%s\n' "$(bb df -Pk "$UBU_BASE" | bb awk 'NR == 2 { print $4 }')"
fi
if ubu_rootfs_installed; then printf 'rootfs=installed\n'; else printf 'rootfs=absent\n'; fi
