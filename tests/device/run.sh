#!/bin/sh
# Run the on-device suite (tests/device/checks.sh) on a rooted phone via adb.
# Pushes the current scripts first. The suite runs under nohup with a log on
# the device, so an adb disconnect cannot SIGPIPE-kill it halfway.
# Usage: tests/device/run.sh [--reset] [-s SERIAL]
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
RESET=""
SERIAL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --reset) RESET=--reset ;;
        -s) SERIAL=$2; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
if [ -n "$SERIAL" ]; then ADB="adb -s $SERIAL"; else ADB="adb"; fi
LOG=/data/local/tmp/uburoot-device-tests.log

if [ -n "$SERIAL" ]; then sh "$ROOT/tools/adb-push-scripts.sh" -s "$SERIAL" >/dev/null; else sh "$ROOT/tools/adb-push-scripts.sh" >/dev/null; fi
$ADB push "$ROOT/tests/device/checks.sh" /data/local/tmp/uburoot-checks.sh >/dev/null
$ADB shell "su --mount-master -c 'rm -f $LOG; nohup sh -c \"sh /data/local/tmp/uburoot-checks.sh $RESET; echo SUITE_RC=\\\$?\" >$LOG 2>&1 </dev/null &'"
$ADB shell "su --mount-master -c 'i=0; while ! grep -q SUITE_RC $LOG 2>/dev/null && [ \$i -lt 600 ]; do sleep 2; i=\$((i+2)); done; cat $LOG'" | tee /dev/stderr | grep -q '^SUITE_RC=0'
