#!/bin/sh
# Push the UbuRoot scripts to a rooted device without the app:
#   tools/adb-push-scripts.sh [-s SERIAL]
# Then, for example:
#   adb shell su -M -c /data/local/uburoot/bin/rootinfo.sh
#   adb push ubuntu-base-*-arm64.tar.gz /data/local/tmp/
#   adb shell su -M -c "/data/local/uburoot/bin/install.sh /data/local/tmp/ubuntu-base-...tar.gz <sha256>"
#   adb shell su -M -c "/data/local/uburoot/bin/setup.sh --user ubuntu --nopasswd"
#   adb shell -t su -M -c /data/local/uburoot/bin/enter.sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/app/src/main/assets/uburoot/bin"
TMP=/data/local/tmp/uburoot-bin
DEST=/data/local/uburoot/bin
ADB="adb"
if [ "${1:-}" = -s ] && [ -n "${2:-}" ]; then ADB="adb -s $2"; fi

$ADB shell "rm -rf $TMP && mkdir -p $TMP"
for f in "$SRC"/*; do
    $ADB push "$f" "$TMP/" >/dev/null
done
# --mount-master is accepted by Magisk, KernelSU and APatch (see CLAUDE.md).
$ADB shell "su --mount-master -c 'mkdir -p $DEST && cp $TMP/* $DEST/ && chmod 755 $DEST/* && chmod 644 $DEST/common.sh && chown -R 0:0 $DEST && rm -rf $TMP'"
$ADB shell "su --mount-master -c $DEST/rootinfo.sh"
