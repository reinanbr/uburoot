#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run shellcheck (POSIX sh dialect) on every UbuRoot script.
# Uses shellcheck from PATH; otherwise the official koalaman/shellcheck image.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# CI runners have their own shellcheck (0.9.0 on ubuntu-24.04); match it with
# SC_IMAGE=koalaman/shellcheck:v0.9.0 tests/shellcheck.sh
SC_IMAGE=${SC_IMAGE:-koalaman/shellcheck:v0.11.0}
cd "$ROOT"
set -- app/src/main/assets/uburoot/bin/*.sh app/src/main/assets/uburoot/bin/android-env \
    tests/*.sh tests/docker/*.sh tests/device/*.sh tools/*.sh \
    app/src/module/customize.sh app/src/module/service.sh app/src/module/META-INF/com/google/android/update-binary
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck --version | sed -n 2p
    shellcheck -s sh -x -P app/src/main/assets/uburoot/bin "$@"
elif command -v docker >/dev/null 2>&1; then
    echo "shellcheck not in PATH; using docker image $SC_IMAGE" >&2
    docker run --rm -v "$ROOT:/mnt:ro" -w /mnt "$SC_IMAGE" \
        -s sh -x -P app/src/main/assets/uburoot/bin "$@"
else
    echo "shellcheck not found (apt install shellcheck)" >&2
    exit 2
fi
echo "shellcheck: OK ($# files)"
