#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Build one version the way F-Droid does and check it against the published
# release APK (reproducible build). Uses fdroidserver from PyPI in a temporary
# venv, the recipe tools/fdroid/com.reinanbr.uburoot.yml (the file submitted to
# fdroiddata) and the official category list.
# Usage: tools/fdroid-check.sh [VERSIONCODE]   (default: the recipe's CurrentVersionCode)
# Needs: python3, git, JDK 21 (JAVA_HOME), the Android SDK (ANDROID_HOME or
# ~/Android/Sdk). Run it after the version's tag and GitHub release exist.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RECIPE="$ROOT/tools/fdroid/com.reinanbr.uburoot.yml"
APP=com.reinanbr.uburoot
VC=${1:-$(awk '/^CurrentVersionCode:/ { print $2 }' "$RECIPE")}
SDK=${ANDROID_HOME:-$HOME/Android/Sdk}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The Gradle version the wrapper asks for; the wrapper checks its SHA-256
# (distributionSha256Sum, the same value as F-Droid's gradle-transparency-log).
(cd "$ROOT" && ./gradlew -q --version >/dev/null)
GV=$(sed -n 's/^distributionUrl=.*gradle-\(.*\)-bin\.zip$/\1/p' "$ROOT/gradle/wrapper/gradle-wrapper.properties")
GRADLE=$(find "$HOME/.gradle/wrapper/dists/gradle-$GV-bin" -path "*/gradle-$GV/bin/gradle" -type f | head -n 1)
[ -n "$GRADLE" ] || { echo "Gradle $GV not found in the wrapper cache" >&2; exit 1; }

python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install -q fdroidserver
F="$WORK/fdroiddata"
mkdir -p "$F/metadata" "$F/config" "$F/build"
cp "$RECIPE" "$F/metadata/"
# Category icons are not needed for lint.
curl -fsSL https://gitlab.com/fdroid/fdroiddata/-/raw/master/config/categories.yml |
    sed '/^ *icon:/d' >"$F/config/categories.yml"
printf 'sdk_path: %s\ngradle: %s\n' "$SDK" "$GRADLE" >"$F/config.yml"
chmod 600 "$F/config.yml"
# fdroidserver's local mode reads the source date before it clones.
git clone -q "$(awk '/^Repo:/ { print $2 }' "$RECIPE")" "$F/build/$APP"

cd "$F"
"$WORK/venv/bin/fdroid" lint "$APP"
"$WORK/venv/bin/fdroid" rewritemeta "$APP"
if ! cmp -s "$RECIPE" "metadata/$APP.yml"; then
    echo "fdroid rewritemeta would change the recipe:" >&2
    diff "$RECIPE" "metadata/$APP.yml" >&2 || true
    exit 1
fi
"$WORK/venv/bin/fdroid" build -l --no-tarball "$APP:$VC" >"$WORK/build.log" 2>&1 || true
if grep -q 'compared built binary to supplied reference binary successfully' "$WORK/build.log"; then
    echo "fdroid build $APP:$VC: built from source and identical to the published APK"
    exit 0
fi
tail -n 40 "$WORK/build.log" >&2
echo "fdroid build $APP:$VC: FAILED (log above)" >&2
exit 1
