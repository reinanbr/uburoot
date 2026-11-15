#!/system/bin/sh
# UbuRoot module, late_start service (Magisk / KernelSU / APatch).
# Installs the app copy left by the module installer (needed after a
# recovery flash). It does not mount anything; boot autostart is Phase 6.
MODDIR=${0%/*}
APK="$MODDIR/uburoot.apk"
[ -f "$APK" ] || exit 0

if [ "${1:-}" != --install-now ]; then
    until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
fi
# pm reads the file as system_server, so stage it where that is allowed.
TMP=/data/local/tmp/uburoot-module-install.apk
cp -f "$APK" "$TMP" && chmod 644 "$TMP" || exit 1
if pm install -r "$TMP" >/dev/null 2>&1; then
    rm -f "$TMP" "$APK"
    exit 0
fi
rm -f "$TMP"
exit 1
