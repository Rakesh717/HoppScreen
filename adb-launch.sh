#!/bin/bash
# adb-launch.sh — open the display page on the Xiaomi Pad 6 in Chrome with the sharp,
# low-latency H.264 decoder enabled.
#
# Why adb: Chrome only exposes WebCodecs (the H.264 decoder) on secure origins, and
# plain http://<mac-ip>:8080 isn't one -> the page falls back to blurry, laggy MJPEG.
# `adb reverse` makes the server reachable on the Pad as http://localhost:8080, which
# Chrome always treats as secure. Works over Wireless debugging; a USB-C cable gives
# the lowest latency.
#
# One-time setup on the Pad:
#   Settings → Additional settings → Developer options → Wireless debugging → ON
#   → "Pair device with pairing code" → then run:  adb pair <ip:port>  (type the code)
#
# Usage: ./adb-launch.sh [port]          (default 8080)
#        ./adb-launch.sh --lan [port]    open http://<mac-ip>:port directly instead (no
#                                        tunnel; only sharp if you added that origin in
#                                        chrome://flags/#unsafely-treat-insecure-origin-as-secure)
set -e

LAN=0
[ "$1" = "--lan" ] && { LAN=1; shift; }
PORT=${1:-8080}
CHROME=com.android.chrome

# 1) find the Pad (already connected, or discover via wireless-debugging mDNS)
DEV=$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')
if [ -z "$DEV" ]; then
  echo "searching for wireless-debugging devices via mDNS..."
  SVC=$(adb mdns services 2>/dev/null | grep -m1 '_adb-tls-connect' || true)
  if [ -n "$SVC" ]; then
    ADDR=$(echo "$SVC" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+' | head -1)
    [ -n "$ADDR" ] && adb connect "$ADDR" >/dev/null && DEV="$ADDR"
  fi
fi
if [ -z "$DEV" ]; then
  echo "ERROR: no Pad found. Enable Wireless debugging on the Pad (see header), or:"
  echo "  adb connect <pad-ip>:<port>   (shown under Wireless debugging on the Pad)"
  exit 1
fi
A="adb -s $DEV"
echo "device: $DEV"

if ! curl -s -m 2 "http://localhost:$PORT/status" >/dev/null; then
  echo "WARNING: server not answering on :$PORT — start it first with ./run.sh"
fi

if [ $LAN = 1 ]; then
  IF=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  MAC_IP=$(ipconfig getifaddr "$IF" 2>/dev/null || ipconfig getifaddr en0 2>/dev/null || true)
  [ -z "$MAC_IP" ] && { echo "ERROR: could not detect this Mac's LAN IP"; exit 1; }
  URL="http://$MAC_IP:$PORT/"
else
  $A reverse tcp:"$PORT" tcp:"$PORT" >/dev/null
  URL="http://localhost:$PORT/"
fi
echo "target page: $URL"

# 2) open the page in Chrome — application_id makes Chrome reuse ONE tab across
#    launches instead of piling up new tabs
$A shell am start -n $CHROME/com.google.android.apps.chrome.Main \
    -a android.intent.action.VIEW -d "$URL" \
    -e com.android.browser.application_id pad6display >/dev/null 2>&1
sleep 5

# 3) tap the centre once -> fullscreen (Pad 6 panel 1800x2880, any rotation)
SIZE=$($A shell wm size | awk -F': ' '/Physical/{print $2}' | tr -d '\r')
W=${SIZE%x*}; H=${SIZE#*x}
ROT=$($A shell dumpsys input | grep -m1 -oE 'orientation=[0-9]' | grep -oE '[0-9]$' || echo 0)
if [ "$ROT" = 1 ] || [ "$ROT" = 3 ]; then X=$((H / 2)); Y=$((W / 2)); else X=$((W / 2)); Y=$((H / 2)); fi
$A shell input tap "$X" "$Y"
echo "done. If the Pad isn't fullscreen yet, tap its screen once."
echo "server log should show:  [client] mode=h264&secure=1"
