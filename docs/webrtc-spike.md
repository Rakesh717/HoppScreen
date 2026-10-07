# WebRTC transport spike — HOLD

Branch: `spike/webrtc`, based on a verified clean `feat/hevc`. This is a video-only
prototype, **not a replacement for the shipped transport**.

## Decision

**HOLD migration.** Revisit after a bounded sender adaptation/pacing experiment and
Safari/iPad latency tests on congested Wi-Fi. libdatachannel is viable for encrypted
H.264 delivery, but the premise that it gives this application GCC/TWCC bitrate
adaptation “for free” is false for pinned release v0.24.6.

Three strongest reasons to proceed:

1. Real browser handshake and video decoding work; shared capture/VideoToolbox code
   transfers with small compile-time seams, without duplicating the encoder.
2. ICE, DTLS-SRTP, browser jitter buffering, RTCP sender reports, NACK repair and PLI
   hooks are available; this removes substantial custom media transport machinery.
3. Browser interoperability is promising: Chromium decodes the existing high-profile,
   Retina-resolution hardware output, and receiver REMB feedback actually arrives.

Three strongest reasons not to adopt yet:

1. No built-in sender GCC/TWCC controller or encoder target-rate API in this release.
   Shipping this spike unchanged **does not solve congestion**.
2. Local idle TTFF is 220–1095 ms. There is no measured congested-link/motion latency
   comparison or Safari/iPad result; replacing an excellent low-latency path without
   those measurements would be premature.
3. Sessions, multi-client policy, audio, input and codec negotiation still need product
   engineering. The single global encoder and HEVC receiver intersection make this
   more than a socket substitution.

## What exists

```
ScreenCaptureKit → existing VideoToolbox H.264 encoder (server.m, HOPP_RTC)
  → AVCC validation + parameter sets → RFC 6184 RTP (90 kHz)
  → RTCP SR / NACK / PLI / REMB handlers → libdatachannel → ICE/DTLS-SRTP/UDP
  → browser RTCPeerConnection → <video> + getStats overlay

existing HTTP / SecureTransport TLS / Basic auth
  → POST /rtc/offer {type:"offer", sdp:...} → gathered answer JSON
```

- `make rtc` builds `hoppscreen-rtc`; only this binary links libdatachannel/OpenSSL.
  `server.m` is compiled separately with `-DHOPP_RTC`. No capture/encoder fork.
- Defaults are HTTP 8090 / HTTPS 8450. Existing positional port/environment plumbing
  can override them. Audio/input are forced off; legacy mutation/stream routes are
  unavailable in this binary. `/status`, `/time`, `/ca.crt` remain available.
- Auth gating and TLS implementations are unchanged. Loopback exemption is the same
  as today's server; LAN requests need the existing credentials. JSON offers are
  bounded to 64 KiB, and ICE gathering has a 10-second deadline.
- Fully gathered, non-trickle SDP in both directions. One recvonly video m-line;
  H.264 High, packetization-mode 1, level asymmetry required. No STUN/TURN servers:
  this is a LAN experiment, not an Internet connectivity product.
- One active peer. A successful new offer replaces/closes the old peer. Invalid
  offers do not replace it. Authentication is not per-receiver session ownership.
- Capture output never waits behind signaling: a try-lock drops frames instead of
  accumulating an application queue. RTP sends are synchronous on the encoder output
  callback, **not** an isolated paced worker. libdatachannel's internal/kernel queues
  have not been bounded by a measured latency budget.

### What transferred cleanly / what fought back

**Capture/encoder:** existing AVCC and monotonic submitted PTS are enough. RTP uses a
random timestamp origin plus `(PTS - firstPTS) * 90 / 1000`, wrapping at 32 bits;
wall-clock corrections cannot alter that timeline. B-frames remain disabled. The
capture's “nobody watching” encoder gate needed an RTC-only demand seam: without it,
ICE connected but video stopped after the initial configuration frame.

**Packetization:** `rtc_packetizer.h` validates the entire four-byte-length AU before
sending. Single NAL ≤1200 bytes; adjacent small NALs aggregate in STAP-A with 16-bit
lengths and maximum NRI; large NALs fragment in FU-A with correct start/end/header
reconstruction. Sequence wraps naturally. Only the last packet of the AU has the
RTP marker, including its final FU-A fragment. Tests cover single-NAL, STAP-A,
FU-A reassembly, exact MTU boundary, truncated AVCC and RTP header fields.
This custom packetizer is small but still needs fuzzing, capture-corpus tests and
loss/reordering tests; it is not production-hardened merely because video plays.

**Parameter sets:** VT's samples normally omit SPS/PPS. The existing captured/fixed
`avcC` is parsed and its SPS/PPS prepended to every IDR, usually becoming STAP-A.
Never assume SPS/PPS exist in each sample or use the AVCC length prefix as an RTP
start code. Additional high-profile avcC extension records are not sent. Malformed
configuration drops the AU rather than reading past a buffer.

**Joining / keyframes:** track-open and RTCP PLI/FIR call the existing atomic IDR
request. A new peer waits for an IDR before forwarding. NACK stores 512 packets
(bounded packet history, not RTX codec negotiation). A sender failure/try-lock drop
does not automatically force a new IDR; subsequent recovery depends on PLI or a new
connection. This is a production recovery gap.

**Profile/level:** the existing low-latency encoder emits ConstrainedHigh SPS
(`avc1.640c32` here). The answer advertises compatible High, the superset, at the
actual SPS level (`640032`), not the browser's lower offered level (`64001f`).
Chromium accepts the asymmetric level and decodes 2400×1500. Baseline-only offers
are rejected, not mislabeled. An explicit profile/level intersection, macroblock
limits and fallback encoder mode are required for broader receiver support.

**Certificates:** `certs/server.p12` remains the HTTPS signaling identity, with the
existing CA installation/trust UX. libdatachannel creates a separate DTLS identity;
its fingerprint is carried in authenticated SDP and the browser verifies the DTLS
peer against it. Do not reuse the HTTPS private key merely to silence browser trust
prompts: DTLS media identity and HTTPS server trust are separate concerns.

## Congestion control: the actual API, not the promise

Pinned source: [v0.24.6](https://github.com/paullouisageneau/libdatachannel/tree/v0.24.6),
commit `6b1e2e62` (full pin in the submodule gitlink).

- [`rtc::RembHandler(std::function<void(unsigned int)>)`](https://github.com/paullouisageneau/libdatachannel/blob/v0.24.6/include/rtc/rembhandler.hpp)
  receives the browser's REMB rate estimate. C equivalent:
  [`rtcChainRembHandler`](https://github.com/paullouisageneau/libdatachannel/blob/v0.24.6/include/rtc/rtc.h).
  This spike logs it; **it does not change VT bitrate**. REMB is not GCC/TWCC.
- [`rtc::PliHandler`](https://github.com/paullouisageneau/libdatachannel/blob/v0.24.6/include/rtc/plihandler.hpp),
  `RtcpNackResponder`, `RtcpSrReporter` handle useful RTCP mechanisms, not a sender
  bandwidth estimator that controls the encoder.
- [`rtc::PacingHandler(double bitsPerSecond, milliseconds sendInterval)`](https://github.com/paullouisageneau/libdatachannel/blob/v0.24.6/include/rtc/pacinghandler.hpp)
  is a fixed-budget queue/pacer. It has no public target-rate setter and is not an
  adaptive congestion controller. This spike does not enable it.
- `rtcSctpSettings.congestionControlModule` / `SctpSettings` refer to **SCTP data**,
  not video RTP. They cannot solve this problem.
- Searching this pin's public headers and media implementation found no GCC/TWCC
  feedback/controller API. The browser offered `transport-cc` and a transport-wide
  sequence extension, but the answer deliberately does not negotiate them. RTP
  contains no TWCC sequence extension; no TWCC feedback was observed/claimed.

A cheap follow-up is bounded REMB-driven VT `AverageBitRate` updates on `g_encQ`,
clamped to the user ceiling, with smoothing, update cadence, a bounded media queue,
and loss-triggered IDR recovery. That must be tested, not presented as “GCC”. Proper
sender TWCC/GCC needs per-packet transport sequence extensions, send-time history,
RTCP feedback parsing, estimation/probing, adaptive pacing and encoder control.
Evaluate libwebrtc before reimplementing this stack ourselves.

## Verification and numbers (local Chromium, not Safari)

Prerequisites already installed: CMake **4.4.3**, OpenSSL **3.6.5** selected by Brew.
Ran `brew list cmake openssl@3`; no Brew installation was needed. Recursive submodule
dependencies built from source. OpenSSL remains a dynamic dependency of the spike;
copying just its binary to another Mac is not a deployment solution.

Passed: `make rtc`, `make rtc-test`, `make build` (also forced with `make -B build`),
`make format-check`. Default `server.m` preprocessor output (`clang -E -P`) compared
byte-for-byte equal before/after the RTC seams. `otool -L hoppscreen` has no RTC or
OpenSSL dependencies. Existing capture, wire format, audio, input, auth and TLS
implementations are unchanged when `HOPP_RTC` is absent.

| Observation | Result / limitation |
| --- | --- |
| Synthetic HTTPS offer, authenticated LAN curl | HTTP 200; answer has PT 102, sendonly, fingerprint and ICE candidates; one request 5.9 ms |
| LAN HTTPS request without credentials | HTTP 401 |
| Malformed JSON offer | HTTP 400 |
| Real browser handshake | ICE/DTLS connected; RTP decoded, 2400×1500; offer/answer PT 118 matched |
| TTFF | 220, 230, 999, 1095 ms observed, from Connect click to first `requestVideoFrameCallback`; final version resets the old video stream before timing |
| Idle decoded fps | approximately 4 fps (existing 250 ms refresh), not a 30 fps motion benchmark |
| Idle received video rate | approximately 0.11–0.14 Mbps in steady overlay samples, despite 6 Mbps ceiling |
| Feedback | REMB observed (e.g. 110,216–160,657 bps, rising); no encoder adaptation; no negotiated TWCC |
| Local loss/repair | 0 loss, 0 NACK and 0 PLI in sampled stats; recovery under real loss untested |
| Jitter / jitter buffer | displayed RTP jitter 0.00 ms; one sample cumulative buffer delay 2.691 s / 475 emitted frames ≈5.7 ms, NOT full capture-to-photon latency |
| Motion-load fps | unmeasured: throwaway native animation ran but did not appear in SCK capture; no fabricated result |
| Approximate binary size | default 180 KiB, spike 2.0 MiB, excluding OpenSSL runtime libraries |

TTFF includes SDP gathering/signaling/ICE/DTLS, keyframe request, encode and first
presentation. It does not measure steady-state latency. For the latter, film a
millisecond counter on the source and receiver together at ≥240 fps; subtract shown
times, compare identical content/resolution/30 fps/6 Mbps cap against the main path,
and report median/p95 during Wi-Fi contention, loss and bandwidth step-down/up.
The RTC PTS is not exposed as today's custom receiver's wall-clock metadata.

The main server was never stopped/reconfigured. Its observed initial configuration
was not the requested office configuration; it was left as found. Only spike
processes were restarted/stopped during verification.

## Exact manual test

Do not use `make start` for the spike: that remains the main service.

```sh
git submodule update --init --recursive vendor/libdatachannel
# Only if missing: brew install cmake openssl@3
make rtc rtc-test format-check
HOPPSCREEN_MBPS=6 ./hoppscreen-rtc 1200 750 8090 30
```

1. On this Mac open `http://127.0.0.1:8090/rtc-test.html` in Chromium. On an iPad or
   LAN receiver use `https://<Mac-IP>:8450/rtc-test.html`, trust the existing CA per
   README, and sign in using the main server's credentials. LAN plain HTTP is not
   a secure WebRTC context. Safari behavior remains to be tested.
2. Click **Connect**. Expect `connected`, visible desktop video, increasing frames,
   and fps >0 (about 4 idle). Move a window/animation onto the **spike** virtual
   display, not the main server's display, to test motion up to configured 30 fps.
   Click **Fullscreen**. The overlay shows live received bitrate, bytes/s, jitter,
   fps, TTFF and loss, including document fullscreen. On Safari versions limited
   to native video fullscreen the fallback hides the HTML overlay.
3. Synthetic signaling (this replaces the browser's single active peer):

```sh
curl -sS -H 'Content-Type: application/json' \
  --data-binary @tests/rtc-offer.json http://127.0.0.1:8090/rtc/offer
# TLS + auth variant (substitute your actual user/password; -k is test-only):
curl -ksS -u 'USER:PASSWORD' -H 'Content-Type: application/json' \
  --data-binary @tests/rtc-offer.json https://<Mac-IP>:8450/rtc/offer
```

The fixture intentionally has no real candidate/private key; it tests answer
generation only, not media connectivity. Click Connect again for real video.
Ctrl-C only `hoppscreen-rtc` when done; do not stop/restart the main service.

## Integration plan and estimated cost

Estimates are engineering judgments for one experienced engineer, not measured
delivery dates. Do not add them as independent tasks without allowing integration
and device testing time.

1. **Video hardening, 1–2 weeks:** extract a transport-neutral AU/config/PTS sink
   from the compile-time seams, keep today's transport selectable/default, negotiate
   profile/level/resolution explicitly, fuzz packetizer/avcC, pace on a bounded worker,
   test IDR/NACK under loss, add per-session ownership, deadlines and cleanup.
2. **Congestion decision, 1–2 weeks for an REMB proof:** connect feedback to VT on
   the encoder queue; measure cap/drop/recovery behavior and p95 latency under link
   steps. A robust TWCC/GCC controller is likely **4–8+ weeks**, with substantial
   maintenance risk. Compare a libwebrtc-backed sender instead before committing.
3. **Audio, 1–2 weeks:** SCK PCM → libopus → RTP Opus 48 kHz, synchronized RTCP
   clocks/SSRCs, negotiated audio track, discontinuities and browser audio unlock.
   libdatachannel packetizes Opus but does **not encode PCM**. Existing raw PCM
   wire format cannot simply be forwarded to an Opus track.
4. **Input, 3–5 days plus device QA:** authenticated peer datachannel, reliable
   ordered clicks/keys and bounded/unordered movement as appropriate; retain view-only
   boot gate, Accessibility permissions and explicit enable consent. No changes to
   the existing input security policy are implied by WebRTC encryption.
5. **Product/device/network rollout, 1–2+ weeks:** Safari/iPad backgrounding,
   orientation, fullscreen, reconnect/ICE restart, TURN policy, packaged/signable
   dependencies and fallback UX. Rough total with REMB (not GCC): **4–7 weeks**.

### What breaks first in production

- **Congestion / large IDRs:** no adaptation or adaptive pacing here; a burst can
  inflate socket/browser queues. UDP and SRTP alone do not prevent latency collapse.
- **Multiple receivers:** this spike evicts the previous peer. In the real product
  one shared encoder must choose a minimum common bitrate/profile or generate
  per-peer encodes/simulcast; a slow client should not silently degrade every client.
- **Lifecycle:** full gathered SDP is convenient locally, but reconnects, interface
  changes, ICE restarts, renegotiation, failed peers and suspended iPads need a real
  session state machine. The current singleton does not implement those semantics.
- **HEVC:** a library H.265 packetizer is not proof of browser support. Safari's
  HEVC WebCodecs support does not imply interoperable HEVC WebRTC offer/answer on
  every Safari/iPad version or Chromium peer. Keep H.264 mandatory fallback and
  inspect actual SDP/receiver capability; this spike deliberately disables HEVC.

**Bottom line:** keep this branch as evidence of a working H.264 transport core.
Do not migrate until adaptation and the latency/device matrix are demonstrated.
