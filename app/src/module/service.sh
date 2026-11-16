#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# UbuRoot module, late_start service (Magisk / KernelSU / APatch; runs in the
# global mount namespace, after post-fs-data, without blocking the boot).
#  1. Installs the app copy left by the module installer (after a recovery
#     flash there was no package manager to do it).
#  2. Runs /data/local/uburoot/bin/boot.sh, which does nothing unless "Start
#     at boot" is on in the app (BOOT_START=1): mounts Ubuntu and runs
#     /etc/uburoot-boot.d/* inside it. Log: /data/local/uburoot/boot.log
# There is deliberately no uninstall.sh: removing the module never touches
# the rootfs (deleting it while mounted would delete the phone's data).
MODDIR=${0%/*}
APK="$MODDIR/uburoot.apk"
BASE=/data/local/uburoot
BOOT="$BASE/bin/boot.sh"

install_app() {
    # pm reads the file as system_server, so stage it where that is allowed.
    _tmp=/data/local/tmp/uburoot-module-install.apk
    cp -f "$APK" "$_tmp" && chmod 644 "$_tmp" || return 1
    if pm install -r "$_tmp" >/dev/null 2>&1; then
        rm -f "$_tmp" "$APK"
        return 0
    fi
    rm -f "$_tmp"
    return 1
}

# Only a root-owned script that nobody else can change is run as root:
# owner 0, no write bit (2) for group or others.
root_only() {
    case "$(stat -c '%u %a' "$1" 2>/dev/null)" in
        "0 "[0-7][0145][0145] | "0 "[0-7][0-7][0145][0145]) return 0 ;;
    esac
    return 1
}

if [ "${1:-}" = --install-now ]; then
    [ -f "$APK" ] || exit 0
    install_app
    exit
fi

until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
[ -f "$APK" ] && install_app

if [ -f "$BOOT" ] && root_only "$BASE" && root_only "$BASE/bin" && root_only "$BOOT"; then
    [ -f "$BASE/boot.log" ] && mv -f "$BASE/boot.log" "$BASE/boot.log.old"
    /system/bin/sh "$BOOT" >"$BASE/boot.log" 2>&1
fi
exit 0
