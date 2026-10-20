#!/usr/bin/env bash
# End-to-end on-device verification of the iOS app: build, install, launch,
# then probe the loopback bridge through a usbmux TCP forward.
#
# Requires: USB-connected unlocked iPhone, xtool, python3.
# Usage: scripts/verify-ios-device.sh [wait-minutes]   (default waits 30)
set -u
cd "$(dirname "$0")/.."

UDID="${PI_IOS_UDID:-00008120-00014D843C000032}"
BUNDLE_ID="${PI_IOS_BUNDLE_ID:-XTL-MVX92LB7D7.org.pimobile.app}"
BRIDGE_PORT=41943          # fixed port the iOS RuntimeController passes
LOCAL_PORT=41944           # host-side of the usbmux forward
WAIT_MIN="${1:-30}"

fail() { echo "FAIL: $*"; exit 1; }

echo "== waiting for an Apple USB device (up to ${WAIT_MIN} min; plug in + unlock the iPhone)"
deadline=$(( $(date +%s) + WAIT_MIN * 60 ))
until lsusb 2>/dev/null | grep -q '05ac:'; do
  [ "$(date +%s)" -ge "$deadline" ] && fail "no Apple USB device appeared"
  sleep 5
done
echo "   device visible on USB"
# udev respawns usbmuxd on attach; give it a moment before the forwarder probes it
sleep 3

echo "== rebuilding payload and app, installing to device"
python3 scripts/prepare-runtime-ios.py || fail "payload build failed"
( cd ios && timeout 420 xtool dev run -u "$UDID" ) > /tmp/verify-devrun.log 2>&1 \
  || fail "xtool dev run failed (see /tmp/verify-devrun.log)"
tail -2 /tmp/verify-devrun.log

echo "== launching app"
( cd ios && timeout 60 xtool launch -u "$UDID" "$BUNDLE_ID" ) >/dev/null 2>&1 \
  || echo "   (launch call returned nonzero — device may need unlocking; continuing)"

echo "== starting usbmux forward 127.0.0.1:${LOCAL_PORT} -> device:${BRIDGE_PORT}"
python3 scripts/mux-forward.py "$LOCAL_PORT" "$BRIDGE_PORT" "$UDID" >/tmp/verify-mux.log 2>&1 &
MUX_PID=$!
sleep 2
kill -0 "$MUX_PID" 2>/dev/null || { cat /tmp/verify-mux.log; fail "forwarder did not start (usbmuxd dead? replug the phone)"; }

echo "== polling the bridge (first launch extracts ~170 MB runtime, allow up to 4 min)"
deadline=$(( $(date +%s) + 240 ))
until curl -s -m 5 -o /tmp/verify-index.html -w '%{http_code}' "http://127.0.0.1:${LOCAL_PORT}/" 2>/dev/null | grep -q 200; do
  [ "$(date +%s)" -ge "$deadline" ] && { cat /tmp/verify-mux.log; fail "bridge never answered"; }
  sleep 5
done

results=0
check() { # check <label> <exit-code>
  if [ "$2" -eq 0 ]; then echo "PASS: $1"; else echo "FAIL: $1"; results=1; fi
}

grep -q PI_MOBILE_IOS /tmp/verify-index.html; check "GET / -> 200 with iOS flag injected" $?
curl -s -m 5 "http://127.0.0.1:${LOCAL_PORT}/api/sessions" -o /dev/null -w '%{http_code}' | grep -q 401
check "GET /api/sessions without token -> 401" $?
curl -s -m 5 "http://127.0.0.1:${LOCAL_PORT}/menu.js" | grep -q PI_MOBILE_IOS && rc=1 || rc=0
check "menu.js served without flag (JS never rewritten)" $rc
curl -s -m 5 "http://127.0.0.1:${LOCAL_PORT}/terminal.html" | grep -q PI_MOBILE_IOS
check "terminal.html has iOS flag" $?

kill "$MUX_PID" 2>/dev/null
echo
[ "$results" -eq 0 ] && echo "ALL CHECKS PASSED — bridge verified on device" || exit 1
