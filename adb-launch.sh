#!/bin/bash
# adb-launch.sh — open the display page on the Xiaomi Pad 6 in Chrome, fullscreen,
# with the sharp low-latency H.264 decoder enabled.
#
# Chrome only exposes WebCodecs (the H.264 decoder) on SECURE pages. Two ways:
#   default      https://<mac-ip>:8443 — direct over Wi-Fi, lowest latency. Uses the
#                local CA from certs.sh; install it on the Pad once (--install-ca),
#                otherwise Chrome shows a warning (Advanced → Proceed works too).
#   --reverse    adb tunnel to http://localhost:8080 (localhost is always secure).
#                No certificate needed; best with a USB-C cable.
#   --lan        plain http://<mac-ip>:8080 (MJPEG fallback unless flags are set)
#
# One-time setup on the Pad:
#   Settings → Additional settings → Developer options → Wireless debugging → ON
#   → "Pair device with pairing code" → then run:  adb pair <ip:port>  (type the code)
#
# Usage: ./adb-launch.sh [--reverse|--lan|--install-ca] [http-port]   (default 8080)
set -e
cd "$(dirname "$0")"

MODE=https
case "$1" in --reverse) MODE=reverse; shift;; --lan) MODE=lan; shift;; --install-ca) MODE=ca; shift;; esac
PORT=${1:-8080}
TLS_PORT=${PAD6_TLS_PORT:-$((PORT + 363))}
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

# --install-ca: copy the CA to the Pad and open the certificate settings
if [ $MODE = ca ]; then
  [ -f certs/ca.crt ] || ./certs.sh
  $A push certs/ca.crt /sdcard/Download/pad6display-ca.crt >/dev/null
  echo "copied the CA to the Pad: Download/pad6display-ca.crt"
  OUT=$($A shell am start -n 'com.android.settings/.Settings$EncryptionAndCredentialActivity' 2>&1 || true)
  echo "$OUT" | grep -q -i error && $A shell am start -a android.settings.SECURITY_SETTINGS >/dev/null 2>&1 || true
  cat <<'EOF'
On the Pad (Android won't let apps do this step for you):
  Encryption & credentials → Install a certificate → CA certificate → "Install anyway"
  → pick Download/pad6display-ca.crt  (confirm with your screen lock)
  (if Settings opened elsewhere: search Settings for "CA certificate")
The CA only works for private LAN IPs / localhost / *.local, never for real websites.
Then run:  ./adb-launch.sh
EOF
  exit 0
fi

if ! curl -s -m 2 "http://localhost:$PORT/status" >/dev/null; then
  echo "WARNING: server not answering on :$PORT — start it first with ./run.sh"
fi

IF=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
MAC_IP=$(ipconfig getifaddr "$IF" 2>/dev/null || ipconfig getifaddr en0 2>/dev/null || true)
case $MODE in
  https)
    [ -z "$MAC_IP" ] && { echo "ERROR: could not detect this Mac's LAN IP"; exit 1; }
    if ! curl -s -m 2 --cacert certs/ca.crt "https://$MAC_IP:$TLS_PORT/status" >/dev/null; then
      echo "HTTPS not reachable on :$TLS_PORT — falling back to the adb tunnel"
      MODE=reverse
    else
      URL="https://$MAC_IP:$TLS_PORT/"
    fi;;
  lan)
    [ -z "$MAC_IP" ] && { echo "ERROR: could not detect this Mac's LAN IP"; exit 1; }
    URL="http://$MAC_IP:$PORT/";;
esac
if [ $MODE = reverse ]; then
  $A reverse tcp:"$PORT" tcp:"$PORT" >/dev/null
  URL="http://localhost:$PORT/"
fi
echo "target page: $URL"

# 2) open the page in Chrome — application_id makes Chrome reuse ONE tab across launches
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
[ $MODE = https ] && echo "certificate warning on the Pad? run once: ./adb-launch.sh --install-ca"
echo "server log should show:  [client] mode=h264&secure=1"
