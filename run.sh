#!/bin/bash
# Build (if needed) and run the pad6display server.
# Usage: ./run.sh [width_pt height_pt port fps]   defaults: 1440 900 8080 120
#   Size is the "looks like" size in points; the display is HiDPI (2x pixels), so the
#   default 1440x900 renders at 2880x1800 = the Pad 6's native panel (pixel-perfect).
#   More space (smaller text, slightly soft):  ./run.sh 1680 1050
#   Non-Retina 1x mode:                        PAD6_SCALE=1 ./run.sh 2880 1800
#   60fps (less Mac/Pad load, ~15ms more lag):  ./run.sh 1440 900 8080 60
# Stop with Ctrl-C — that also ends screen recording and removes the virtual display.
cd "$(dirname "$0")"
if [ ! -x pad6display ] || [ server.m -nt pad6display ] || [ virtualdisplay.m -nt pad6display ] \
   || [ virtualdisplay.h -nt pad6display ]; then
  echo "building..."
  clang -fobjc-arc -O2 -I. \
      -framework Foundation -framework CoreGraphics -framework AppKit \
      -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
      -framework ScreenCaptureKit -framework IOSurface -framework Security \
      server.m virtualdisplay.m -o pad6display || exit 1
fi
./certs.sh || echo "warning: certificate setup failed — HTTPS disabled"
[ $# -eq 0 ] && set -- 1440 900 8080 120
exec ./pad6display "$@"
