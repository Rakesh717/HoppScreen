# HoppScreen — any tablet or laptop as a wireless extended display for macOS

Custom wireless-display stack. The receiver is **any device with a modern
browser** (Chrome/Edge; tested on an Android tablet) — nothing to install on
it. The Mac gets a **real virtual display**, streamed as **hardware H.264** to
the receiver's browser (WebCodecs) over the LAN, with password protection.

(Grew out of a Xiaomi Pad 6 project: the Pad's native Miracast sink is
unreachable from macOS — it lives on a Wi-Fi Direct link Apple never exposed;
verified by scan: no mDNS, no LAN ports, no P2P group visible.)

```
[CGVirtualDisplay  looks like 1440x900 pt, HiDPI -> 2880x1800 px framebuffer]
   -> capture: ScreenCaptureKit push (cursor composited by WindowServer), 60fps
      fallback chain: CGDisplayStream -> CGDisplayCreateImage polling (+ manual cursor)
   -> VideoToolbox H.264 (hardware, High@5.2, ~28Mbps cap, no B-frames, IDR on demand)
   -> HTTP :8080
        /            player page (WebCodecs H.264, MJPEG fallback, fullscreen+wakelock)
        /h264        [4B len][JSON cfg] then [4B len][1B flags][8B capture µs][AVCC AU]...
        /time        server clock (latency measurement)
        /stream.mjpg MJPEG multipart (fallback)
        /frame.jpg   single JPEG (debug)
        /status      JSON stats
        /fit         auto-fit: client panel report -> server re-execs at that size
        /ca.crt      local CA (install on the receiver once)
   -> HTTPS :8443 (same endpoints, TLS) -> receiver browser (secure context)
      -> WebCodecs VideoDecoder (hardware) -> <canvas>, optimizeForLatency
```

## Run

```bash
make start                   # build if needed + run detached (log: server.log)
make stop                    # graceful stop (also removes the virtual display)
make restart                 # after editing ./passwd or the code
make status                  # pid, uptime, /status json, recent log
make log                     # follow the server log
make run                     # foreground instead (ctrl-c stops)
```

Then open the printed `https://<mac-ip>:8443` URL in the receiver's browser
(type it once — Chrome remembers it).

Default mode looks like 1440x900 pt (Retina, 2880x1800 px) @120fps. The encoder
sleeps while no client is connected.

### Auto-fit

With no size args, the first client that opens the page **resizes the virtual
display to match that device's panel** — pixel-perfect for whatever opens it
(a tablet, a phone, a laptop). The page measures its screen and refresh rate,
calls `/fit`, and the server restarts itself with matching dimensions (same
pid, ~2s blip, page reconnects automatically). Rate-limited to one refit per
30s. `PAD6_AUTOFIT=0` disables; launching with an explicit size pins it:

```bash
make start                          # auto-fit on
make start ARGS="1680 1050"         # pinned size, auto-fit off
PAD6_AUTOFIT=1 make start ARGS="1680 1050"   # pinned + still auto-fit
```

Pinned sizes: `ARGS="1680 1050"` gives more space but smaller, slightly softer
text. `PAD6_SCALE=1 ARGS="2880 1800"` uses a non-Retina 1x mode with tiny text.
`ARGS="1440 900 8080 60"` for 60fps (less load, ~15ms more lag).

### Why HTTPS (port 8443)

Chrome only allows its H.264 decoder (WebCodecs) on **secure** pages. Plain
`http://192.168.x.x:8080` isn't secure, so the page falls back to MJPEG, which is blurry,
about 24fps and laggy. The server also serves **HTTPS on port+363 (8443)**:

- `certs.sh` (run automatically by `make run`/`make start`) creates a private CA once (`certs/ca.crt`).
  It then issues a server certificate for the Mac's current LAN IPs, and re-issues it
  automatically when you change networks.
- The CA is **name-constrained** to private IPs, `localhost` and `*.local`. Even if
  `certs/ca.key` leaked, it couldn't be used to impersonate real websites. Keep `certs/`
  private anyway.
- Install `ca.crt` on the receiver once (in its browser, open `http://<mac-ip>:8080/ca.crt`,
  then Settings → Encryption & credentials → Install a certificate → CA certificate).
  After that the https page has no warnings. Without installing it, Chrome warns
  and **Advanced → Proceed** still works.
- Opening the plain `http://…:8080` page redirects to https automatically.
- TLS is macOS SecureTransport (TLS 1.2, ECDSA P-256 / AES-GCM). It adds no noticeable latency.

The server log shows `[client] mode=h264&secure=1` when the sharp path is active.

## Password (login)

Anyone on the same Wi-Fi could open the page and watch, so **every endpoint**
(both `:8080` and `:8443`) requires a login:

- On first start the server generates `passwd` next to the binary
  (`user:password`, one line, mode 600) and prints both. Change it by editing
  the file and restarting. Or set it inline: `PAD6_PASSWORD=x make start`
  (then any username is accepted).
- The Pad's Chrome asks once, then caches the login for the origin and attaches
  it to every request (page, `/h264`, `/stream.mjpg`) — streams are unaffected.
  If you change the password, reload the page: the 401 makes Chrome ask again.
- Connections from this Mac (127.0.0.1) are exempt — no prompt.
- Prefer the https URL: on plain http the password travels only base64-encoded
  (readable by a LAN sniffer); https encrypts it.

On the Pad, tap once to go fullscreen. Tap again to show or hide the fps overlay.

## Latency (measured on the Pad, cursor motion, capture → on screen)

| build | moving | final frame after you stop |
|---|---|---|
| before (std encoder, VT's default SPS) | ~255 ms | ~255 ms |
| low-latency encoder @60 | ~61 ms | ~80 ms |
| **low-latency encoder @120 (default)** | **~49–64 ms** | **~48–65 ms** |

Tap the Pad screen to show the overlay. It has the same numbers: `arrive` is capture → bytes
received, `shown` is capture → drawn, and `last` is the newest real frame. The page also reports
them to the server log every 5s (`[client] … arrive_ms=… shown_ms=…`).

What fixed it:
- **Decoder frame holding.** VideoToolbox's standard SPS lacks VUI `bitstream_restriction`, so
  the Pad's hardware decoder buffered up to about 9 frames. The server now rewrites the SPS
  (`max_num_reorder_frames=0`), the same approach as WebRTC's `SpsVuiRewriter`. The low-latency
  encoder already writes it.
- **The final frame stuck in the decoder.** MediaCodec releases frame N only when N+1 arrives.
  When motion stops, the server immediately sends 2 tiny repeat frames to push it out.
- **Low-latency VideoToolbox mode** (`EnableLowLatencyRateControl`, Constrained High).
- **120 fps** halves every per-frame wait. The Pad 6 panel runs at 144 Hz.

Debug switches: `PAD6_LOWLAT=0` (standard encoder), `PAD6_NOVUI=1` (no SPS rewrite),
`PAD6_DEBUG=1` (verbose).

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

- **Blurry / laggy / warning on the Pad page** → you're on the MJPEG fallback; open the
  `https://…:8443` URL instead and tap through the cert warning.
- **Windows dragged to the display don't appear** → grant Screen Recording to your
  terminal app (System Settings → Privacy & Security → Screen Recording), restart server.
- **Pad can't open the page** → run `make start` first; check same Wi-Fi and
  allow the macOS "Local Network" prompt.
- **Black screen** → tap once; the page auto-reconnects.

## Files

| File | Purpose |
|---|---|
| `virtualdisplay.h/.m` | Private `CGVirtualDisplay` wrapper (HiDPI) |
| `server.m` | Capture chain + VideoToolbox encoder + HTTP + player page |
| `certs.sh` | Local CA + per-IP server cert (HTTPS) |
| `Makefile` | build + `make run/start/stop/restart/status/log` |
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
