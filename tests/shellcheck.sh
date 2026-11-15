#!/bin/sh
# Run shellcheck (POSIX sh dialect) on every UbuRoot script.
# Uses shellcheck from PATH; otherwise the official koalaman/shellcheck image.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SC_IMAGE=koalaman/shellcheck:v0.11.0
cd "$ROOT"
set -- app/src/main/assets/uburoot/bin/*.sh app/src/main/assets/uburoot/bin/android-env \
    tests/*.sh tests/docker/*.sh tools/*.sh
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
