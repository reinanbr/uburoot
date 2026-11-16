#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Real-mount test suite in a privileged Docker container (root + real mounts,
# without touching the host). Uses the x86_64 Ubuntu Base of the same LTS the
# app installs on arm64, so apt/chroot run natively.
# Usage: tests/docker/run.sh
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CACHE="$ROOT/tests/.cache"
IMAGE=ubuntu:26.04
REL_URL=https://cdimage.ubuntu.com/ubuntu-base/releases/26.04/release
FILE=ubuntu-base-26.04.1-base-amd64.tar.gz

mkdir -p "$CACHE"
curl -fsSL "$REL_URL/SHA256SUMS" -o "$CACHE/SHA256SUMS"
SHA=$(awk -v f="*$FILE" '$2 == f { print $1 }' "$CACHE/SHA256SUMS")
[ -n "$SHA" ] || { echo "$FILE not in SHA256SUMS" >&2; exit 1; }
if [ ! -f "$CACHE/$FILE" ] || [ "$(sha256sum "$CACHE/$FILE" | cut -d' ' -f1)" != "$SHA" ]; then
    echo "downloading $FILE" >&2
    curl -fL --retry 3 -C - "$REL_URL/$FILE" -o "$CACHE/$FILE"
fi
[ "$(sha256sum "$CACHE/$FILE" | cut -d' ' -f1)" = "$SHA" ] || { echo "SHA256 mismatch" >&2; exit 1; }

docker run --rm --privileged \
    -v "$ROOT:/src:ro" -v "$CACHE:/cache:ro" \
    "$IMAGE" sh /src/tests/docker/inside.sh "/cache/$FILE" "$SHA"
