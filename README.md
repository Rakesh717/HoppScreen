# pad6display — Xiaomi Pad 6 as a wireless extended display for macOS

Custom wireless-display stack. The Pad's native Miracast sink is unreachable from
macOS (it lives on a Wi-Fi Direct link Apple never exposed — verified by scan:
no mDNS, no LAN ports, no P2P group visible). So we build our own link:
a **real virtual display** on the Mac, streamed as **hardware H.264** to the
Pad's **browser** (WebCodecs) over LAN. No apps installed on the Pad.

```
[CGVirtualDisplay  looks like 1440x900, HiDPI -> 2880x1800 px = Pad 6 native panel]
   -> capture: ScreenCaptureKit push (cursor composited by WindowServer), 60fps
      fallback chain: CGDisplayStream -> CGDisplayCreateImage polling (+ manual cursor)
   -> VideoToolbox H.264 (hardware, High@5.2, ~28Mbps cap, no B-frames, IDR on demand)
   -> HTTP :8080
        /            player page (WebCodecs, MJPEG fallback, fullscreen+wakelock)
        /h264        [4B len][JSON cfg] then [4B len][1B flags][AVCC AU]...
        /stream.mjpg MJPEG multipart (fallback)
        /frame.jpg   single JPEG (debug)
        /status      JSON stats
   -> adb reverse -> Pad 6 Chrome at http://localhost:8080 (secure context)
      -> WebCodecs VideoDecoder (hardware) -> <canvas>, optimizeForLatency
```

## Run

```bash
./run.sh            # looks like 1440x900 (Retina, 2880x1800 px) @60fps, port 8080
./adb-launch.sh     # opens it fullscreen on the Pad (sharp H.264 mode)
```

Stop with **Ctrl-C**. That ends screen recording and removes the virtual display.
The encoder sleeps while no client is connected.

Other sizes: `./run.sh 1680 1050` gives more space but smaller, slightly softer text.
`PAD6_SCALE=1 ./run.sh 2880 1800` uses a non-Retina 1x mode with tiny text.

**Why `adb-launch.sh` matters:** Chrome only allows its H.264 decoder (WebCodecs) on
secure pages. Plain `http://192.168.x.x:8080` isn't secure, so the page falls back to
MJPEG, which is blurry, about 24fps and high-latency. The script runs `adb reverse` so the Pad
opens `http://localhost:8080`, which Chrome always treats as secure. It works over
Wireless debugging. A USB-C cable gives the lowest latency.
Without adb, open `chrome://flags/#unsafely-treat-insecure-origin-as-secure` on the Pad, add
`http://<mac-ip>:8080`, relaunch Chrome, then `./adb-launch.sh --lan` (or type the URL).
The page shows a warning when it's stuck on the fallback. The server log shows
`[client] mode=h264&secure=1` when the sharp path is active.

On the Pad, tap once to go fullscreen. Tap again to show or hide the fps overlay.

## Notes (macOS 26 / M-series)

- ScreenCaptureKit **does** work for private-API virtual displays. The old "no frames"
  result was a bug: `SCStream` holds its output object *weakly*, and the output was a
  local variable, so it was deallocated right away. It is now kept in a global.
- SCK is damage-driven. A static screen sends no frames, so the server re-encodes the
  last frame for an instant IDR when a client joins, and a few times per second while
  idle so a static desktop sharpens up. `keeper` is no longer needed.
- No periodic keyframes, because they cause a visible hitch. A client that falls more than about 250ms
  behind (Wi-Fi hiccup) is resynced on a fresh IDR instead of playing stale video.
- CGVirtualDisplay HiDPI: the mode must be given in **points** with `hiDPI=1`. macOS
  then adds a 2x-backed variant, which isn't selected by default, so we pick it explicitly.

## Troubleshooting

- **Blurry / laggy / warning on the Pad page** → you're on the MJPEG fallback; use `./adb-launch.sh`.
- **Windows dragged to the display don't appear** → grant Screen Recording to your
  terminal app (System Settings → Privacy & Security → Screen Recording), restart server.
- **Pad can't open the page** → run `./run.sh` first; with `--lan`, check same Wi-Fi and
  allow the macOS "Local Network" prompt.
- **Black screen** → tap once; the page auto-reconnects.

## Files

| File | Purpose |
|---|---|
| `virtualdisplay.h/.m` | Private `CGVirtualDisplay` wrapper (HiDPI) |
| `server.m` | Capture chain + VideoToolbox encoder + HTTP + player page |
| `run.sh` / `adb-launch.sh` | build+run / auto-launch on the Pad |
| `keeper.m`, `bench2.m` | Old experiments (not needed anymore) |
| `vendor/` | Reference projects (macos-virtual-display-vnc etc.) |

## Gotchas baked into the code (learned the hard way)

- `CGDisplayCreateImage` is header-obsoleted (macOS 15) but functional → dlsym.
- `mach_absolute_time` ticks are **41.67ns** on this machine (125/3), not 1ns —
  all pacing math converts via `mach_timebase_info`.
- VideoToolbox emits SPS with NAL ref_idc=1 (`0x27`, not the usual `0x67`).
- WebCodecs wants AVCC NALUs + `avcC` as `description`; codec string is derived from the
  real avcC bytes (currently `avc1.640034`, High@5.2) — a hardcoded one breaks when level changes.
- CVPixelBuffers must come from a pool (fresh 10MB allocs fail under churn).
