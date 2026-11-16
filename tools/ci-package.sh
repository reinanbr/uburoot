#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Collects the built APKs into OUTDIR, each also as a "-module.zip" copy (same
# bytes: root managers' file pickers may not list *.apk), checks that every
# file is a signed APK that also carries the root-module files, and writes
# SHA256SUMS. Run after ./gradlew assembleDebug [assembleRelease].
# Tag builds also get version-less copies of the release (uburoot.apk,
# uburoot-module.zip), so releases/latest/download/<name> links never change.
# Usage: tools/ci-package.sh OUTDIR
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: ci-package.sh OUTDIR}
APKS="$ROOT/app/build/outputs/apk"

VERSION=$(sed -n 's/^val appVersionName = "\(.*\)"$/\1/p' "$ROOT/app/build.gradle.kts")
[ -n "$VERSION" ] || { echo "cannot read appVersionName" >&2; exit 1; }
# Tag builds are named after the version only; anything else gets the commit.
if [ "${GITHUB_REF_TYPE:-}" = tag ]; then
    NAME="uburoot-$VERSION"
else
    NAME="uburoot-$VERSION-g$(git -C "$ROOT" rev-parse --short HEAD)"
fi

# apksigner from the newest build-tools.
SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
if [ -z "$SDK" ] && [ -f "$ROOT/local.properties" ]; then
    SDK=$(sed -n 's/^sdk\.dir=//p' "$ROOT/local.properties")
fi
APKSIGNER=$(for f in "$SDK"/build-tools/*/apksigner; do [ -x "$f" ] && echo "$f"; done | sort -V | tail -1)
[ -x "$APKSIGNER" ] || { echo "apksigner not found under $SDK/build-tools" >&2; exit 1; }

# What the module installers need at the APK root (see app/src/module).
MODULE_FILES="module.prop customize.sh service.sh META-INF/com/google/android/update-binary META-INF/com/google/android/updater-script"

check_apk() {
    "$APKSIGNER" verify "$1" || { echo "$1: signature does not verify" >&2; exit 1; }
    _list=$(unzip -Z1 "$1")
    for _f in $MODULE_FILES; do
        printf '%s\n' "$_list" | grep -qxF "$_f" || { echo "$1: missing $_f" >&2; exit 1; }
    done
    _prop=$(unzip -p "$1" module.prop)
    printf '%s\n' "$_prop" | grep -qx "version=$VERSION" || { echo "$1: module.prop version is not $VERSION" >&2; exit 1; }
    case "$_prop" in *@VERSION_*) echo "$1: unfilled placeholder in module.prop" >&2; exit 1 ;; esac
}

mkdir -p "$OUT"
rm -f "$OUT"/uburoot*.apk "$OUT"/uburoot*-module.zip "$OUT/SHA256SUMS"

publish() { # publish SRC.apk FLAVOR
    check_apk "$1"
    cp "$1" "$OUT/$NAME-$2.apk"
    cp "$1" "$OUT/$NAME-$2-module.zip"
    echo "packaged $NAME-$2.apk (+ -module.zip)"
}

[ -f "$APKS/debug/app-debug.apk" ] || { echo "no debug APK; run assembleDebug first" >&2; exit 1; }
publish "$APKS/debug/app-debug.apk" debug
if [ -f "$APKS/release/app-release.apk" ]; then
    publish "$APKS/release/app-release.apk" release
    if [ "${GITHUB_REF_TYPE:-}" = tag ]; then
        cp "$APKS/release/app-release.apk" "$OUT/uburoot.apk"
        cp "$APKS/release/app-release.apk" "$OUT/uburoot-module.zip"
        echo "packaged uburoot.apk + uburoot-module.zip (stable names)"
    fi
elif [ -f "$APKS/release/app-release-unsigned.apk" ]; then
    echo "release APK is unsigned (no UBUROOT_KEYSTORE): not packaged"
fi

(cd "$OUT" && sha256sum uburoot*.apk uburoot*.zip >SHA256SUMS && cat SHA256SUMS)
