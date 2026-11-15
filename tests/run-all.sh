#!/bin/sh
# Phase 1 test entry point: shellcheck, critical-rule guard test, and the
# real-mount Docker suite (skipped with a notice when Docker is unavailable).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
rc=0
echo "### shellcheck"
sh "$HERE/shellcheck.sh" || rc=1
echo
echo "### critical rule (dummy dirs, fake mount table)"
sh "$HERE/test_reset_guard.sh" || rc=1
echo
echo "### real mounts (privileged Docker container)"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    sh "$HERE/docker/run.sh" || rc=1
else
    echo "SKIPPED: Docker not available"
fi
echo
[ "$rc" = 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit "$rc"
