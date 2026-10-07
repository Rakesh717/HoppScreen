/*
 * HoppScreen — macOS virtual display streamed directly to a browser.
 * Private CGVirtualDisplay creates the desktop; capture tries ScreenCaptureKit,
 * then CGDisplayStream, then CGDisplayCreateImage polling. VideoToolbox encodes
 * hardware H.264; JPEG is the browser fallback. System audio requires SCK.
 *
 * Request routes (shared by HTTP and HTTPS):
 *   /, /index.html  Embedded receiver: WebCodecs H.264 or MJPEG fallback.
 *   /h264           [4B length][JSON config], then records described at writeRec.
 *   /stream.mjpg    Multipart JPEG stream. /frame.jpg requests one fresh JPEG.
 *   /status         JSON display, capture, stream and input state.
 *   /time           Wall-clock microseconds for receiver clock synchronization.
 *   /hello          Receiver diagnostics in the log; returns 204.
 *   /ca.crt         Local CA download. /silent.mp4 serves the wake-lock loop.
 *   /input          POST JSON gestures, replayed with Accessibility permission.
 *   /input/toggle   POST JSON to toggle input; boot opt-in is still required.
 *   /fit            POST JSON panel dimensions; may re-exec with a matching mode.
 * All routes use Basic auth, except IPv4 loopback peers (127/8). Credentials
 * come from passwd next to the binary (generated if absent), or the env below.
 *
 * Environment (HOPPSCREEN_ prefix on every name):
 *   NAME           Nonempty display name; default "HoppScreen Display".
 *   PORT           HTTP port fallback (1..65535); positional port wins.
 *   FPS            FPS fallback (1..120); positional fps wins.
 *   SCALE          atoi(value)==1 selects 1x; otherwise HiDPI 2x.
 *   AUTOFIT        No size args: on unless 0; size args: on only if 1.
 *   LASTFIT        Internal epoch-seconds timestamp carried across refit execs.
 *   AUDIO          On unless atoi(value)==0; make defaults AUDIO=0.
 *   INPUT          Off unless atoi(value)!=0; boot-disabled input stays view-only.
 *   SCROLL_INVERT  Nonzero atoi(value) reverses wheel/zoom direction.
 *   PASSWORD       Nonempty password overrides passwd; accepts any username.
 *   TLS_PORT       HTTPS port; default HTTP+363; 0 disables HTTPS.
 *   LOWLAT         Encoder low-latency mode on unless atoi(value)==0.
 *   NOVUI          Presence disables low-delay SPS/VUI rewriting.
 *   POLL           Presence skips push capture and starts polling directly.
 *   KEEP_PUSH      Presence keeps the watchdog's CGDisplayStream fallback.
 *   DEBUG          Presence enables additional capture/audio/TLS/cursor logs.
 *
 * Build: make build (Objective-C/C99, clang -fobjc-arc -O2; macOS frameworks).
 * The Makefile embeds web/index.html via xxd; the receiver is self-contained.
 * Run: make run (foreground), make start/stop/restart (background, server.log).
 * Usage: hoppscreen [width_pt height_pt [port [fps]]]; defaults 1440 900 8080 120.
 * No size args enables auto-fit; explicit sizes pin the mode unless overridden.
 * make run/start prepares TLS via certs.sh. Screen Recording is needed for capture;
 * Accessibility is needed only for input. Runtime assets resolve beside the binary.
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AppKit/AppKit.h>
#import <IOKit/pwr_mgt/IOPMLib.h> // user-activity assertion: re-activate the virtual display
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <unistd.h>
#include <mach/mach_time.h>
#include <dlfcn.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/tcp.h>
#import <Security/Security.h>
#import <Security/SecureTransport.h>
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <string.h>
#include <strings.h>
#include <limits.h>
#import <mach-o/dyld.h>
#import "virtualdisplay.h"
#include "web_index.h"

// ============================================================ shared state
// Display geometry, capture snapshots and stream publications shared by workers.
// g_lock guards published JPEG/AU/latest-buffer state; g_encQ serializes push submits.
// State blocks below keep declaration/initialization order unchanged.

// Lifecycle and display geometry (points versus encoded framebuffer pixels).
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_auCond = PTHREAD_COND_INITIALIZER; // signalled on every new AU
static volatile BOOL g_running = YES;
static uint32_t g_displayID = 0, g_dispW = 0, g_dispH = 0; // logical size (points)
static uint32_t g_pixW = 0, g_pixH = 0; // framebuffer size (pixels) = what we encode
static double g_fps = 60.0;

// Encoder submission, refresh requests and client demand.
static volatile int g_forceKey = 0; // next encoded frame must be an IDR (new client / resync)
static volatile uint64_t g_lastSubmitNs = 0; // host time of the last frame handed to the encoder
static volatile uint64_t g_lastRealNs = 0;   // last frame that came from capture (not a repeat)
static volatile int g_repeatsSinceReal = 0;
static NSString *g_codec = nil;        // "avc1.PPCCLL" derived from the real avcC
static dispatch_queue_t g_encQ = NULL; // serializes ALL encoder submits (SC frames + refresh)

static volatile int g_mjpegClients = 0, g_h264Clients = 0;

// JPEG (latest frame only)
static NSData *g_jpeg = nil;
static uint64_t g_jpegSeq = 0;

// H.264 ring of AVCC access units (+ audio records)
// Writers publish under g_lock, then wake g_auCond; seq detects overwritten slots.
// Audio advances seq but not vseq, so video lag and physical overflow are distinct.
typedef struct {
    uint64_t seq;
    uint64_t vseq; // video-only sequence (audio records carry the current one)
    BOOL isKey;
    BOOL isRepeat; // re-submitted unchanged frame (decoder flush / refinement)
    BOOL isAudio;  // payload = interleaved SInt16 stereo PCM (see "audio")
    int64_t ptsUs;
    NSData *data; // AVCC (4-byte NALU length prefixes), no SPS/PPS in-band
} AURec;
#define AU_RING 512
static AURec g_au[AU_RING];
static uint64_t g_auHead = 0;      // last written seq (0 = none yet)
static uint64_t g_auVideoHead = 0; // vseq of the last VIDEO record
static NSString *g_avcCB64 = nil;  // base64 avcC description
static volatile uint64_t g_h264Bytes = 0;
static volatile uint64_t g_encOutFrames = 0; // AUs emitted by encoder callback
static volatile double g_encFps = 0;
static uint64_t g_encFrames = 0;
static volatile double g_captureFps = 0;

// Capture/encoder resources and diagnostics; retained snapshots outlive callbacks.
static VTCompressionSessionRef g_vts = NULL;
static CVPixelBufferPoolRef g_pbPool = NULL; // recycled BGRA buffers for encode input
static uint64_t g_capFrames = 0;             // total capture frames
static SCStream *g_scStream = nil;           // ScreenCaptureKit stream (preferred capture)
static id g_scOut = nil; // SCStream only weakly references its output — must be kept alive here
static CVPixelBufferRef g_latestPB = nil;   // latest BGRA frame (retained)
static volatile uint64_t g_scCallbacks = 0; // raw delivery counter (diagnostics)
static pthread_mutex_t g_jpegLock = PTHREAD_MUTEX_INITIALIZER;
static CGImageRef g_jpegImg = NULL;          // latest frame for the jpeg thread
static double g_capMs = 0.0;                 // avg CGDisplayCreateImage ms
static NSData *g_silentMp4 = nil;            // silent loop video (screen wakelock)
static CGDisplayStreamRef g_cgStream = NULL; // CGDisplayStream push capture (2nd try)

// Compatibility ABI for the CoreGraphics push fallback.
// CGDisplayStream API: obsoleted from macOS 15 headers but the push machinery
// still exists in CoreGraphics — resolve dynamically and redeclare the ABI.
static void processFrame(CVPixelBufferRef pb);
typedef struct MyCGDisplayStream *MyCGDisplayStreamRef;
enum {
    kMyFrameComplete = 0,
    kMyFrameIdle = 1,
    kMyFrameRefresh = 2,
    kMyFrameDepressed = 3,
    kMyFrameRemoved = 4
};
typedef void (^MyFrameHandler)(int32_t status, uint64_t time, IOSurfaceRef surface,
                               void *updateRef);
static MyCGDisplayStreamRef (*MyCGDisplayStreamCreateWithDispatchQueue)(
    uint32_t displayID, size_t w, size_t h, uint32_t pf, CFDictionaryRef props, dispatch_queue_t q,
    MyFrameHandler handler);
static int32_t (*MyCGDisplayStreamStart)(MyCGDisplayStreamRef);
static int32_t (*MyCGDisplayStreamStop)(MyCGDisplayStreamRef);

static void cgFrameHandler(int32_t status, uint64_t time, IOSurfaceRef surface, void *updateRef) {
    (void)time;
    (void)updateRef;
    if (status != kMyFrameComplete || !surface)
        return;
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreateWithIOSurface(NULL, surface, NULL, &pb);
    if (!pb)
        return;
    processFrame(pb);
    CFRelease(pb);
}

static volatile BOOL g_audioFailed; // defined in the audio section; needed by the capture fallbacks

static BOOL startCGStreamCapture(void) {
    g_audioFailed = YES; // honesty: audio exists only on the ScreenCaptureKit path
    if (!MyCGDisplayStreamCreateWithDispatchQueue) {
        void *h =
            dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
        MyCGDisplayStreamCreateWithDispatchQueue = (MyCGDisplayStreamRef(*)(
            uint32_t, size_t, size_t, uint32_t, CFDictionaryRef, dispatch_queue_t,
            MyFrameHandler))dlsym(h, "CGDisplayStreamCreateWithDispatchQueue");
        MyCGDisplayStreamStart =
            (int32_t (*)(MyCGDisplayStreamRef))dlsym(h, "CGDisplayStreamStart");
        MyCGDisplayStreamStop = (int32_t (*)(MyCGDisplayStreamRef))dlsym(h, "CGDisplayStreamStop");
        if (!MyCGDisplayStreamCreateWithDispatchQueue || !MyCGDisplayStreamStart) {
            fprintf(stderr, "[cg] CGDisplayStream symbols not available\n");
            return NO;
        }
    }
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(g_displayID);
    if (!mode)
        return NO;
    size_t pw = CGDisplayModeGetPixelWidth(mode), ph = CGDisplayModeGetPixelHeight(mode);
    CFRelease(mode);
    dispatch_queue_t q = g_encQ;
    NSDictionary *props = @{@"kCGDisplayStreamShowCursor" : @YES};
    MyCGDisplayStreamRef st = MyCGDisplayStreamCreateWithDispatchQueue(
        g_displayID, pw, ph, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)props, q,
        ^(int32_t s, uint64_t t, IOSurfaceRef surf, void *u) {
          cgFrameHandler(s, t, surf, u);
        });
    if (!st)
        return NO;
    if (MyCGDisplayStreamStart(st) != 0) {
        CFRelease(st);
        return NO;
    }
    g_cgStream = (CGDisplayStreamRef)st;
    fprintf(stderr, "[cg] CGDisplayStream push capture %zux%zu\n", pw, ph);
    return YES;
}

// CGDisplayCreateImage is obsoleted in macOS 15 headers but still functional at
// runtime (verified on macOS 26) — resolve it dynamically.
typedef CGImageRef (*CGDisplayCreateImageFn)(CGDirectDisplayID);
static CGDisplayCreateImageFn CGDisplayCreateImage_dyn(void) {
    static CGDisplayCreateImageFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      void *h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
      fn = (CGDisplayCreateImageFn)dlsym(h, "CGDisplayCreateImage");
    });
    return fn;
}

static void storeJpeg(NSData *f) {
    pthread_mutex_lock(&g_lock);
    g_jpeg = f;
    g_jpegSeq++;
    pthread_mutex_unlock(&g_lock);
}
static NSData *copyJpeg(uint64_t *seqOut) {
    pthread_mutex_lock(&g_lock);
    NSData *f = [g_jpeg copy];
    if (seqOut)
        *seqOut = g_jpegSeq;
    pthread_mutex_unlock(&g_lock);
    return f;
}

// ============================================================ SPS VUI rewrite (decoder latency)
// Rewrite only decoder buffering restrictions, preserving the remaining SPS bits.
// Both avcC and in-band SPS use this path; HOPPSCREEN_NOVUI bypasses it.
// VideoToolbox writes SPS with pic_order_cnt_type=0 and NO VUI bitstream_restriction.
// A spec-compliant decoder must then assume frames may be reordered and hold up to
// MaxDpbFrames (≈9 at 2880x1800, level 5.2) before outputting — ~150ms of lag while
// moving, and the final frames stay stuck when motion stops. Hardware decoders
// (Android MediaCodec / Qualcomm) do exactly that. Like WebRTC's SpsVuiRewriter, we
// add bitstream_restriction with max_num_reorder_frames=0 and
// max_dec_frame_buffering=max_num_ref_frames so every frame is output immediately.
typedef struct {
    const uint8_t *p;
    size_t n, bit;
    BOOL err;
} BitR;
typedef struct {
    uint8_t *p;
    size_t cap, bit;
} BitW;
static uint32_t br1(BitR *r) {
    if (r->bit >= r->n * 8) {
        r->err = YES;
        return 0;
    }
    uint32_t v = (r->p[r->bit >> 3] >> (7 - (r->bit & 7))) & 1;
    r->bit++;
    return v;
}
static uint32_t brN(BitR *r, int k) {
    uint32_t v = 0;
    while (k--)
        v = (v << 1) | br1(r);
    return v;
}
static uint32_t brUE(BitR *r) {
    int z = 0;
    while (!br1(r) && !r->err && z < 32)
        z++;
    if (z > 31) {
        r->err = YES;
        return 0;
    } // 1u<<32 is UB; oversized code = garbage
    return z ? ((1u << z) - 1 + brN(r, z)) : 0;
}
static void bw1(BitW *w, uint32_t b) {
    if (w->bit >= w->cap * 8)
        return;
    if (b)
        w->p[w->bit >> 3] |= (uint8_t)(0x80 >> (w->bit & 7));
    w->bit++;
}
static void bwN(BitW *w, uint32_t v, int k) {
    while (k--)
        bw1(w, (v >> k) & 1);
}
static void bwUE(BitW *w, uint32_t v) {
    uint32_t x = v + 1;
    int len = 0;
    while ((x >> len) > 1)
        len++;
    bwN(w, 0, len);
    bwN(w, x, len + 1);
}
// copy helpers: read from r, write identical bits to w, return value
static uint32_t cN(BitR *r, BitW *w, int k) {
    uint32_t v = brN(r, k);
    bwN(w, v, k);
    return v;
}
static uint32_t cUE(BitR *r, BitW *w) {
    uint32_t v = brUE(r);
    bwUE(w, v);
    return v;
}
static void cHRD(BitR *r, BitW *w) {
    uint32_t cnt = cUE(r, w);
    cN(r, w, 4);
    cN(r, w, 4);
    for (uint32_t i = 0; i <= cnt && i < 32; i++) {
        cUE(r, w);
        cUE(r, w);
        cN(r, w, 1);
    }
    cN(r, w, 20); // 4 x u(5)
}

// rbsp (no emulation bytes) -> rewritten rbsp. Returns nil if unparseable.
static NSData *spsAddLowDelayVUI(NSData *rbsp) {
    BitR r = {rbsp.bytes, rbsp.length, 0, NO};
    size_t cap = rbsp.length + 32;
    NSMutableData *out = [NSMutableData dataWithLength:cap];
    BitW w = {out.mutableBytes, cap, 0};
    cN(&r, &w, 8); // NAL header
    uint32_t profile = cN(&r, &w, 8);
    cN(&r, &w, 8);
    cN(&r, &w, 8);
    cUE(&r, &w); // sps id
    if (profile == 100 || profile == 110 || profile == 122 || profile == 244 || profile == 44 ||
        profile == 83 || profile == 86 || profile == 118 || profile == 128 || profile == 138 ||
        profile == 139 || profile == 134 || profile == 135) {
        uint32_t chroma = cUE(&r, &w);
        if (chroma == 3)
            cN(&r, &w, 1);
        cUE(&r, &w);
        cUE(&r, &w);
        cN(&r, &w, 1);
        if (cN(&r, &w, 1)) { // scaling matrices
            for (int i = 0; i < (chroma != 3 ? 8 : 12); i++)
                if (cN(&r, &w, 1)) {
                    int size = i < 6 ? 16 : 64, last = 8, next = 8;
                    for (int j = 0; j < size && next; j++) {
                        uint32_t u = cUE(&r, &w);
                        int32_t d = (u & 1) ? (int32_t)((u + 1) / 2) : -(int32_t)(u / 2);
                        next = (last + d + 256) % 256;
                        if (next)
                            last = next;
                    }
                }
        }
    }
    cUE(&r, &w); // log2_max_frame_num
    uint32_t poc = cUE(&r, &w);
    if (poc == 0)
        cUE(&r, &w);
    else if (poc == 1) {
        cN(&r, &w, 1);
        cUE(&r, &w);
        cUE(&r, &w);
        uint32_t k = cUE(&r, &w);
        for (uint32_t i = 0; i < k && i < 256; i++)
            cUE(&r, &w);
    }
    uint32_t maxRef = cUE(&r, &w);
    cN(&r, &w, 1);
    cUE(&r, &w);
    cUE(&r, &w);
    if (!cN(&r, &w, 1))
        cN(&r, &w, 1); // frame_mbs_only / mb_adaptive
    cN(&r, &w, 1);     // direct_8x8
    if (cN(&r, &w, 1)) {
        cUE(&r, &w);
        cUE(&r, &w);
        cUE(&r, &w);
        cUE(&r, &w);
    }
    uint32_t vui = brN(&r, 1);
    bw1(&w, 1); // force VUI present
    if (vui) {
        if (cN(&r, &w, 1) && cN(&r, &w, 8) == 255)
            cN(&r, &w, 32);
        if (cN(&r, &w, 1))
            cN(&r, &w, 1);
        if (cN(&r, &w, 1)) {
            cN(&r, &w, 4);
            if (cN(&r, &w, 1))
                cN(&r, &w, 24);
        }
        if (cN(&r, &w, 1)) {
            cUE(&r, &w);
            cUE(&r, &w);
        }
        if (cN(&r, &w, 1)) {
            cN(&r, &w, 32);
            cN(&r, &w, 32);
            cN(&r, &w, 1);
        }
        uint32_t nal = cN(&r, &w, 1);
        if (nal)
            cHRD(&r, &w);
        uint32_t vcl = cN(&r, &w, 1);
        if (vcl)
            cHRD(&r, &w);
        if (nal || vcl)
            cN(&r, &w, 1);
        cN(&r, &w, 1); // pic_struct_present
        if (brN(&r, 1)) {
            // restriction already present (low-latency encoder writes reorder=0 but
            // max_dec_frame_buffering=9): re-emit with the minimal values below
            brN(&r, 1);
            brUE(&r);
            brUE(&r);
            brUE(&r);
            brUE(&r);
            uint32_t reorder = brUE(&r), dpb = brUE(&r);
            if (reorder == 0 && dpb <= (maxRef ? maxRef : 1))
                return nil; // already minimal
        }
    } else {
        bwN(&w, 0,
            8); // aspect, overscan, signal, chroma_loc, timing, nal_hrd, vcl_hrd, pic_struct = 0
    }
    if (r.err)
        return nil;
    bw1(&w, 1); // bitstream_restriction_flag
    bw1(&w, 1); // motion_vectors_over_pic_boundaries
    bwUE(&w, 2);
    bwUE(&w, 1);
    bwUE(&w, 16);
    bwUE(&w, 16);                  // spec defaults
    bwUE(&w, 0);                   // max_num_reorder_frames = 0
    bwUE(&w, maxRef ? maxRef : 1); // max_dec_frame_buffering
    bw1(&w, 1);                    // rbsp_stop_one_bit
    while (w.bit & 7)
        bw1(&w, 0);
    out.length = w.bit / 8;
    return out;
}
static NSData *nalUnescape(const uint8_t *p, size_t n) {
    NSMutableData *o = [NSMutableData dataWithCapacity:n];
    int zeros = 0;
    for (size_t i = 0; i < n; i++) {
        if (zeros >= 2 && p[i] == 3) {
            zeros = 0;
            continue;
        }
        [o appendBytes:&p[i] length:1];
        zeros = p[i] == 0 ? zeros + 1 : 0;
    }
    return o;
}
static NSData *nalEscape(NSData *d) {
    const uint8_t *p = d.bytes;
    NSMutableData *o = [NSMutableData dataWithCapacity:d.length + 8];
    int zeros = 0;
    const uint8_t three = 3;
    for (size_t i = 0; i < d.length; i++) {
        if (zeros >= 2 && p[i] <= 3) {
            [o appendBytes:&three length:1];
            zeros = 0;
        }
        [o appendBytes:&p[i] length:1];
        zeros = p[i] == 0 ? zeros + 1 : 0;
    }
    return o;
}
static NSData *fixSPS(const uint8_t *sps, size_t n) {
    NSData *r = spsAddLowDelayVUI(nalUnescape(sps, n));
    return r ? nalEscape(r) : nil;
}
// avcC with every SPS rewritten (nil = unchanged / unparseable)
static NSData *fixAvcC(NSData *avcC) {
    const uint8_t *a = avcC.bytes;
    size_t n = avcC.length;
    if (n < 7)
        return nil;
    NSMutableData *o = [NSMutableData dataWithBytes:a length:6];
    size_t i = 6;
    int numSps = a[5] & 0x1f;
    BOOL changed = NO;
    for (int k = 0; k < numSps; k++) {
        if (i + 2 > n)
            return nil;
        size_t L = ((size_t)a[i] << 8) | a[i + 1];
        if (i + 2 + L > n)
            return nil;
        NSData *f = fixSPS(a + i + 2, L);
        NSData *use = f ?: [NSData dataWithBytes:a + i + 2 length:L];
        changed |= (f != nil);
        uint8_t hdr[2] = {(uint8_t)(use.length >> 8), (uint8_t)use.length};
        [o appendBytes:hdr length:2];
        [o appendData:use];
        i += 2 + L;
    }
    [o appendBytes:a + i length:n - i]; // PPS (+ High-profile tail) untouched
    return changed ? o : nil;
}
// in-band SPS (if VT ever emits them in AUs) get the same rewrite
static NSData *fixInbandSPS(NSData *au) {
    const uint8_t *p = au.bytes;
    size_t n = au.length, i = 0;
    BOOL has = NO;
    while (i + 4 <= n) {
        size_t L =
            ((size_t)p[i] << 24) | ((size_t)p[i + 1] << 16) | ((size_t)p[i + 2] << 8) | p[i + 3];
        if (i + 4 + L > n || L == 0)
            return au;
        if ((p[i + 4] & 0x1f) == 7) {
            has = YES;
            break;
        }
        i += 4 + L;
    }
    if (!has)
        return au;
    NSMutableData *o = [NSMutableData dataWithCapacity:n + 16];
    for (i = 0; i + 4 <= n;) {
        size_t L =
            ((size_t)p[i] << 24) | ((size_t)p[i + 1] << 16) | ((size_t)p[i + 2] << 8) | p[i + 3];
        if (i + 4 + L > n)
            break; // validate EVERY nal, not just up to the first SPS
        if (L == 0) {
            i += 4;
            continue;
        }
        NSData *nal = [NSData dataWithBytes:p + i + 4 length:L];
        if ((p[i + 4] & 0x1f) == 7) {
            NSData *f = fixSPS(p + i + 4, L);
            if (f)
                nal = f;
        }
        uint8_t h[4] = {(uint8_t)(nal.length >> 24), (uint8_t)(nal.length >> 16),
                        (uint8_t)(nal.length >> 8), (uint8_t)nal.length};
        [o appendBytes:h length:4];
        [o appendData:nal];
        i += 4 + L;
    }
    return o;
}

// ============================================================ H.264 encoder
// Publish AVCC output and codec configuration into the shared ring under g_lock.
// Submission/setup helpers follow audio conversion; LOWLAT and NOVUI are the switches.
// Bitrate bounds, burst limits and on-demand IDRs keep desktop text crisp without queues.
static volatile double g_encLatMs = 0; // avg submit -> encoded output
static int64_t realtimeUsFromUptimeUs(int64_t upUs) {
    int64_t nowUp = (int64_t)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000);
    int64_t nowRt = (int64_t)(clock_gettime_nsec_np(CLOCK_REALTIME) / 1000);
    return nowRt - (nowUp - upUs);
}
static void vtOutput(void *refCon, void *srcRefCon, OSStatus status, VTEncodeInfoFlags flags,
                     CMSampleBufferRef sb) {
    if (status != noErr || !sb || !CMSampleBufferIsValid(sb))
        return;
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    if (!bb)
        return;
    size_t len = CMBlockBufferGetDataLength(bb);
    if (len <= 0)
        return;

    NSData *data = [NSMutableData dataWithLength:len];
    if (CMBlockBufferCopyDataBytes(bb, 0, len, ((NSMutableData *)data).mutableBytes) !=
        kCMBlockBufferNoErr)
        return;

    // keyframe? (sync samples lack kCMSampleAttachmentKey_NotSync == true)
    BOOL isKey = YES;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (atts && CFArrayGetCount(atts) > 0) {
        CFDictionaryRef dict = CFArrayGetValueAtIndex(atts, 0);
        CFBooleanRef notSync = CFDictionaryGetValue(dict, kCMSampleAttachmentKey_NotSync);
        isKey = (notSync != kCFBooleanTrue);
    }
    // PTS is CLOCK_UPTIME_RAW µs at submit (see vtSubmit) -> encode latency + the
    // wall-clock capture time the player uses to measure end-to-end latency
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
    int64_t upUs = pts.value;
    int64_t nowUp = (int64_t)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000);
    g_encLatMs = g_encLatMs * 0.95 + ((nowUp - upUs) / 1000.0) * 0.05;
    int64_t ptsUs = realtimeUsFromUptimeUs(upUs);
    if (!getenv("HOPPSCREEN_NOVUI"))
        data = fixInbandSPS(data);
    len = data.length;

    pthread_mutex_lock(&g_lock);
    uint64_t seq = g_auHead + 1;
    AURec *slot = &g_au[seq % AU_RING];
    slot->seq = seq;
    slot->vseq = ++g_auVideoHead;
    slot->isKey = isKey;
    slot->isRepeat = (srcRefCon != NULL);
    slot->isAudio = NO;
    slot->ptsUs = ptsUs;
    slot->data = data;
    g_auHead = seq;
    g_h264Bytes += len;
    g_encOutFrames++;

    if (isKey) {
        CMFormatDescriptionRef md = CMSampleBufferGetFormatDescription(sb);
        if (md) {
            CFDictionaryRef exts = CMFormatDescriptionGetExtensions(md);
            CFDictionaryRef atoms =
                exts ? CFDictionaryGetValue(
                           exts, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
                     : NULL;
            CFDataRef avcC = atoms ? CFDictionaryGetValue(atoms, CFSTR("avcC")) : NULL;
            if (avcC && CFDataGetLength(avcC) >= 4) {
                NSData *d = (__bridge NSData *)avcC;
                NSData *fixed = getenv("HOPPSCREEN_NOVUI") ? nil : fixAvcC(d);
                static BOOL said = NO;
                if (!said) {
                    said = YES;
                    fprintf(stderr, "[h264] SPS low-delay VUI rewrite: %s\n",
                            fixed ? "applied (decoder outputs every frame immediately)"
                                  : "NOT applied");
                }
                if (fixed)
                    d = fixed;
                NSString *b64 = [d base64EncodedStringWithOptions:0];
                if (![b64 isEqualToString:g_avcCB64]) {
                    const uint8_t *a = d.bytes; // [1]=profile [2]=constraints [3]=level
                    g_codec = [NSString stringWithFormat:@"avc1.%02x%02x%02x", a[1], a[2], a[3]];
                    g_avcCB64 = b64;
                    fprintf(stderr, "[h264] avcC captured (%zu bytes) codec=%s\n", (size_t)d.length,
                            g_codec.UTF8String);
                }
            }
        }
    }
    pthread_cond_broadcast(&g_auCond);
    pthread_mutex_unlock(&g_lock);
}

// ============================================================ audio (system sound -> ring)
// Convert SCK audio to stereo PCM records sharing the video's wall-clock timeline.
// AUDIO=0 disables capture; fallback capture paths explicitly mark audio unavailable.
// ScreenCaptureKit taps the system audio and delivers CMSampleBuffers on
// g_audioQ. We flatten them (planar or interleaved Float32, any channel count)
// to interleaved SInt16 stereo at g_audioRate and push them into the same AU
// ring the video uses — the /h264 stream muxes them out in order, so a client
// can sync A/V against the shared wall-clock timestamps. Bandwidth ~1.5 Mbps
// raw PCM; HOPPSCREEN_AUDIO=0 turns it off. Only the SCK capture path has
// audio (the CGDisplayStream/polling fallbacks stay silent).
static dispatch_queue_t g_audioQ = NULL;
static volatile uint32_t g_audioRate = 48000; // announced in the /h264 cfg
static volatile BOOL g_audioWanted = NO;      // env: not HOPPSCREEN_AUDIO=0
static volatile BOOL g_audioFailed = NO;

static void pushAudio(int64_t ptsUs, NSData *pcm) {
    pthread_mutex_lock(&g_lock);
    uint64_t seq = g_auHead + 1;
    AURec *slot = &g_au[seq % AU_RING];
    slot->seq = seq;
    slot->vseq = g_auVideoHead; // lag accounting stays video-only
    slot->isKey = NO;
    slot->isRepeat = NO;
    slot->isAudio = YES;
    slot->ptsUs = ptsUs;
    slot->data = pcm;
    g_auHead = seq;
    pthread_cond_broadcast(&g_auCond);
    pthread_mutex_unlock(&g_lock);
}

static float clampf(float v) {
    return v < -1 ? -1 : (v > 1 ? 1 : v);
}

// one LPCM sample -> float, honoring the ASBD's bit depth
static float readPCM(const uint8_t *p, BOOL isFloat, UInt32 bits) {
    if (isFloat && bits == 32) {
        float f;
        memcpy(&f, p, 4);
        return f;
    }
    if (isFloat && bits == 64) {
        double d;
        memcpy(&d, p, 8);
        return (float)d;
    }
    if (bits == 16) {
        int16_t v;
        memcpy(&v, p, 2);
        return v / 32768.0f;
    }
    if (bits == 32) {
        int32_t v;
        memcpy(&v, p, 4);
        return v / 2147483648.0f;
    }
    return 0;
}

static void processAudioSample(CMSampleBufferRef sb) {
    if (g_audioFailed || !CMSampleBufferIsValid(sb))
        return;
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
        (CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(sb));
    UInt32 frames = CMSampleBufferGetNumSamples(sb);
    if (!asbd || !frames)
        return;
    // SCK delivers interleaved LPCM in the sample buffer's CMBlockBuffer
    // (the AudioBufferList accessor rejects it with -12737, so read raw bytes
    // and interpret per the ASBD: Int16/Float32, planar or interleaved)
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    size_t len = bb ? CMBlockBufferGetDataLength(bb) : 0;
    if (!bb || !len) {
        if (!g_audioFailed)
            fprintf(stderr, "[audio] no PCM data in sample buffer — audio off\n");
        g_audioFailed = YES;
        return;
    }
    uint8_t *raw = malloc(len);
    if (!raw || CMBlockBufferCopyDataBytes(bb, 0, len, raw) != kCMBlockBufferNoErr) {
        free(raw);
        return;
    }
    UInt32 ch = asbd->mChannelsPerFrame > 0 ? asbd->mChannelsPerFrame : 2;
    UInt32 bits = asbd->mBitsPerChannel ? asbd->mBitsPerChannel : 16;
    BOOL isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL planar = (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 bpf = asbd->mBytesPerFrame ? asbd->mBytesPerFrame : ch * ((bits + 7) / 8);
    UInt32 bps = (bits + 7) / 8;
    if (len < frames * (planar ? ch * bps : bpf)) {
        free(raw);
        return;
    } // both planes must fit
    float *in = malloc((size_t)frames * 2 * sizeof(float));
    if (!in) {
        free(raw);
        return;
    }
    for (UInt32 i = 0; i < frames; i++) {
        float l, r;
        if (planar) { // plane 0 (all frames), then plane 1
            l = readPCM(raw + (size_t)i * bps, isFloat, bits);
            r = ch >= 2 ? readPCM(raw + (size_t)(frames + i) * bps, isFloat, bits) : l;
        } else { // interleaved frames
            l = readPCM(raw + (size_t)i * bpf, isFloat, bits);
            r = ch >= 2 ? readPCM(raw + (size_t)i * bpf + bps, isFloat, bits) : l;
        }
        in[i * 2] = clampf(l);
        in[i * 2 + 1] = clampf(r);
    }
    free(raw);
    // resample to the announced rate if SCK delivered something else (linear)
    double rate = asbd->mSampleRate > 0 ? asbd->mSampleRate : (double)g_audioRate;
    if ((uint32_t)rate != g_audioRate && getenv("HOPPSCREEN_DEBUG"))
        fprintf(stderr, "[audio] src rate %.0f -> %u\n", rate, g_audioRate);
    UInt32 outFrames = (UInt32)((double)frames * (double)g_audioRate / rate);
    if (outFrames < 1)
        outFrames = 1;
    NSMutableData *pcm = [NSMutableData dataWithLength:outFrames * 2 * sizeof(int16_t)];
    int16_t *dst = (int16_t *)pcm.mutableBytes;
    double step = (double)frames / outFrames;
    for (UInt32 i = 0; i < outFrames; i++) {
        double pos = i * step;
        UInt32 i0 = (UInt32)pos;
        float f = (float)(pos - i0);
        UInt32 i1 = i0 + 1 < frames ? i0 + 1 : i0;
        dst[i * 2] = (int16_t)((in[i0 * 2] + (in[i1 * 2] - in[i0 * 2]) * f) * 32767);
        dst[i * 2 + 1] =
            (int16_t)((in[i0 * 2 + 1] + (in[i1 * 2 + 1] - in[i0 * 2 + 1]) * f) * 32767);
    }
    free(in);
    // PTS is host time — same clock the video encoder uses -> shared wall µs
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
    int64_t ptsUs = CMTIME_IS_VALID(pts)
                        ? realtimeUsFromUptimeUs((int64_t)(CMTimeGetSeconds(pts) * 1e6))
                        : (int64_t)(clock_gettime_nsec_np(CLOCK_REALTIME) / 1000);
    static int said = 0;
    if (!said++)
        fprintf(stderr, "[audio] flowing: %.0f Hz, %u ch, %u-frame chunks\n", rate, ch,
                (unsigned)frames);
    pushAudio(ptsUs, pcm);
}

// ============================================================ encoder submission and setup
// All submissions use monotonic host-time PTS and consume the shared IDR request.
// Push/refresh work runs on g_encQ; polling submits from its single capture thread.
// Setup retains the existing low-latency, bitrate and pixel-buffer-pool policy.
static uint64_t nowNs(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

// single entry point into the encoder (call only on g_encQ or the polling thread)
static void vtSubmitEx(CVPixelBufferRef pb, BOOL repeat) {
    if (!g_vts || !pb)
        return;
    uint64_t t = nowNs();
    static uint64_t lastPts = 0;
    if (t <= lastPts)
        t = lastPts + 1; // strictly increasing PTS
    lastPts = t;
    CMTime pts = CMTimeMake((int64_t)(t / 1000), 1000000);
    NSDictionary *props = nil;
    if (__sync_lock_test_and_set(&g_forceKey, 0))
        props = @{(__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame : @YES};
    OSStatus est = VTCompressionSessionEncodeFrame(g_vts, pb, pts, kCMTimeInvalid,
                                                   (__bridge CFDictionaryRef)props,
                                                   repeat ? (void *)1 : NULL, NULL);
    if (est != noErr) {
        static int ewarn = 0;
        if (!ewarn++)
            fprintf(stderr, "[h264] EncodeFrame failed: %d\n", (int)est);
    }
    g_lastSubmitNs = t;
    g_encFrames++;
}
static void vtSubmit(CVPixelBufferRef pb) {
    vtSubmitEx(pb, NO);
}

static void setNum(CFStringRef key, double v) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberDoubleType, &v);
    OSStatus st = VTSessionSetProperty(g_vts, key, n);
    if (st != noErr)
        fprintf(stderr, "[h264] warning: property %s rejected (%d)\n",
                CFStringGetCStringPtr(key, kCFStringEncodingUTF8) ?: "?", (int)st);
    CFRelease(n);
}

static BOOL startH264Encoder(void) {
    // Low-latency mode (the FaceTime path): the hardware encoder emits each frame as
    // soon as it is coded instead of pipelining several. HOPPSCREEN_LOWLAT=0 disables it.
    BOOL lowLat = !(getenv("HOPPSCREEN_LOWLAT") && atoi(getenv("HOPPSCREEN_LOWLAT")) == 0);
    NSMutableDictionary *encSpec = [@{
        (__bridge NSString *)
        kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder : @YES,
        (__bridge NSString *)
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder : @YES,
    } mutableCopy];
    if (lowLat)
        encSpec[(__bridge NSString *)kVTVideoEncoderSpecification_EnableLowLatencyRateControl] =
            @YES;
    OSStatus st = VTCompressionSessionCreate(NULL, g_pixW, g_pixH, kCMVideoCodecType_H264,
                                             (__bridge CFDictionaryRef)encSpec, NULL, NULL,
                                             vtOutput, NULL, &g_vts);
    if (st != noErr && lowLat) {
        fprintf(stderr, "[h264] low-latency encoder unavailable (%d) — using standard mode\n",
                (int)st);
        lowLat = NO;
        [encSpec removeObjectForKey:(__bridge NSString *)
                                        kVTVideoEncoderSpecification_EnableLowLatencyRateControl];
        st = VTCompressionSessionCreate(NULL, g_pixW, g_pixH, kCMVideoCodecType_H264,
                                        (__bridge CFDictionaryRef)encSpec, NULL, NULL, vtOutput,
                                        NULL, &g_vts);
    }
    if (st != noErr) {
        fprintf(stderr, "[h264] VTCompressionSessionCreate failed: %d\n", (int)st);
        return NO;
    }
    VTSessionSetProperty(g_vts, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    // High profile: ~15-20% better quality/bit than Main -> sharper text at the same rate.
    // Low-latency mode requires the Constrained variant (no B-frames anyway).
    // Level auto-picks 5.1/5.2 for 2880x1800@60 (codec string is derived from the real avcC).
    OSStatus pst = VTSessionSetProperty(g_vts, kVTCompressionPropertyKey_ProfileLevel,
                                        lowLat ? kVTProfileLevel_H264_ConstrainedHigh_AutoLevel
                                               : kVTProfileLevel_H264_High_AutoLevel);
    if (pst != noErr)
        VTSessionSetProperty(g_vts, kVTCompressionPropertyKey_ProfileLevel,
                             kVTProfileLevel_H264_High_AutoLevel);
    VTSessionSetProperty(g_vts, kVTCompressionPropertyKey_AllowFrameReordering,
                         kCFBooleanFalse); // no B-frames => low latency
    VTSessionSetProperty(g_vts, kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse);
    setNum(kVTCompressionPropertyKey_ExpectedFrameRate, g_fps);
    // bitrate scales with pixel count: ~28 Mbps for 2880x1800@60. Desktop content is
    // mostly static so the real average is far lower; the headroom keeps text crisp
    // while scrolling. HOPPSCREEN_MBPS=<n> overrides the ceiling for slow or shared
    // Wi-Fi; the floor follows so a tiny budget is honored instead of floored at 8.
    double cap = 40e6, floorBps = 8e6;
    const char *mb = getenv("HOPPSCREEN_MBPS");
    if (mb) {
        double v = atof(mb);
        if (v > 0) {
            cap = v * 1e6;
            if (floorBps > cap)
                floorBps = cap;
        }
    }
    double bps = (double)g_pixW * g_pixH * g_fps * 0.09;
    if (bps < floorBps)
        bps = floorBps;
    if (bps > cap)
        bps = cap;
    setNum(kVTCompressionPropertyKey_AverageBitRate, bps);
    // hard cap on bursts (bytes per 1s window) so one huge frame can't flood Wi-Fi
    {
        double bytesPerSec = bps * 1.5 / 8.0, one = 1.0;
        CFNumberRef b = CFNumberCreate(NULL, kCFNumberDoubleType, &bytesPerSec);
        CFNumberRef s1 = CFNumberCreate(NULL, kCFNumberDoubleType, &one);
        CFArrayRef lim = CFArrayCreate(NULL, (const void *[]){b, s1}, 2, &kCFTypeArrayCallBacks);
        VTSessionSetProperty(g_vts, kVTCompressionPropertyKey_DataRateLimits, lim);
        CFRelease(lim);
        CFRelease(b);
        CFRelease(s1);
    }
    // keyframes are big: avoid periodic ones (they cause a visible hitch every
    // interval). New clients / resyncs request an IDR explicitly via g_forceKey.
    setNum(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 60.0);
    VTSessionSetProperty(g_vts, kVTCompressionPropertyKey_ColorPrimaries,
                         kCVImageBufferColorPrimaries_ITU_R_709_2);
    VTSessionSetProperty(g_vts, kVTCompressionPropertyKey_TransferFunction,
                         kCVImageBufferTransferFunction_ITU_R_709_2);
    VTSessionSetProperty(g_vts, kVTCompressionPropertyKey_YCbCrMatrix,
                         kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    st = VTCompressionSessionPrepareToEncodeFrames(g_vts);
    if (st != noErr) {
        fprintf(stderr, "[h264] PrepareToEncode failed: %d\n", (int)st);
        return NO;
    }

    // own BGRA buffer pool (polling path) — fresh large CVPixelBuffers per frame fail under churn
    NSDictionary *poolAttrs = @{(__bridge NSString *)kCVPixelBufferPoolMinimumBufferCountKey : @6};
    NSDictionary *pbAttrs = @{
        (__bridge NSString *)kCVPixelBufferWidthKey : @(g_pixW),
        (__bridge NSString *)kCVPixelBufferHeightKey : @(g_pixH),
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
        (__bridge NSString *)kCVPixelBufferCGImageCompatibilityKey : @YES,
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };
    CVReturn pr = CVPixelBufferPoolCreate(NULL, (__bridge CFDictionaryRef)poolAttrs,
                                          (__bridge CFDictionaryRef)pbAttrs, &g_pbPool);
    if (pr != kCVReturnSuccess)
        fprintf(stderr, "[h264] buffer pool create failed: %d (will alloc per-frame)\n", (int)pr);
    fprintf(stderr, "[h264] encoder ready (%ux%u px, hw, High, %.0f Mbps, IDR on demand%s)\n",
            g_pixW, g_pixH, bps / 1e6, lowLat ? ", low-latency mode" : "");
    return YES;
}

static void drawCursorOverlay(CGContextRef ctx);

static void encodeH264(CGImageRef img) {
    if (!g_vts)
        return;
    CVPixelBufferRef pb = NULL;
    if (g_pbPool)
        CVPixelBufferPoolCreatePixelBuffer(NULL, g_pbPool, &pb);
    if (!pb) {
        static int warned = 0;
        if (!warned++)
            fprintf(stderr, "[h264] CVPixelBuffer unavailable — dropping frames\n");
        return;
    }
    CVPixelBufferLockBaseAddress(pb, 0);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx =
        CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), CVPixelBufferGetWidth(pb),
                              CVPixelBufferGetHeight(pb), 8, CVPixelBufferGetBytesPerRow(pb), cs,
                              kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (ctx) {
        CGContextDrawImage(
            ctx, CGRectMake(0, 0, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb)), img);
        drawCursorOverlay(ctx); // CGDisplayCreateImage omits the cursor
        CFRelease(ctx);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    vtSubmit(pb);
    CVPixelBufferRelease(pb);
}

// ============================================================ ScreenCaptureKit
// Preferred damage-driven capture, with retained latest pixels for JPEG and refresh.
// Refresh drains decoder-held final frames; watchdog falls back only on capture failure.
// FPS, queue depth and idle-repeat timing remain defined at their decision sites.
static void processFrame(CVPixelBufferRef pb);
@interface SCOut : NSObject <SCStreamOutput, SCStreamDelegate>
@end
static volatile int g_scFailed = 0; // set by the delegate when SCK stops the stream
@implementation SCOut
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    (void)stream;
    fprintf(stderr, "[sc] stream stopped: %s (code %ld)\n",
            error.localizedDescription.UTF8String ?: "?", (long)error.code);
    g_scFailed = 1;
}
- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sb
                   ofType:(SCStreamOutputType)type {
    (void)stream;
    if (type == SCStreamOutputTypeAudio) { // system sound -> AU ring
        processAudioSample(sb);
        return;
    }
    if (type != SCStreamOutputTypeScreen)
        return;
    g_scCallbacks++;
    if (!CMSampleBufferIsValid(sb))
        return;
    // SCK sends "idle" status samples (no pixels) while nothing changes — skip those
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (atts && CFArrayGetCount(atts) > 0) {
        NSDictionary *a = (__bridge NSDictionary *)CFArrayGetValueAtIndex(atts, 0);
        NSNumber *status = a[SCStreamFrameInfoStatus];
        if (status && status.integerValue != SCFrameStatusComplete)
            return;
    }
    CVPixelBufferRef pb = (CVPixelBufferRef)CMSampleBufferGetImageBuffer(sb);
    if (pb)
        processFrame(pb);
}
@end

static BOOL encoderWanted(void) {
    // nobody watching -> don't burn the hardware encoder (heat/battery). Still encode
    // until the first avcC exists so clients can start instantly.
    return g_h264Clients > 0 || g_avcCB64 == nil;
}

// push-capture frame (runs on g_encQ): keep latest buffer, count fps, encode
static void processFrame(CVPixelBufferRef pb) {
    @autoreleasepool {
        pthread_mutex_lock(&g_lock);
        if (g_latestPB)
            CFRelease(g_latestPB);
        CFRetain(pb);
        g_latestPB = pb;
        g_capFrames++;
        pthread_mutex_unlock(&g_lock);

        static uint64_t lastCount = 0, lastTick = 0;
        uint64_t now = nowNs();
        if (!lastTick)
            lastTick = now;
        double el = (now - lastTick) / 1e9;
        if (el >= 2.0) {
            g_captureFps = (g_capFrames - lastCount) / el;
            g_encFps = g_captureFps;
            lastCount = g_capFrames;
            lastTick = now;
        }
        g_lastRealNs = nowNs();
        g_repeatsSinceReal = 0;
        if (encoderWanted())
            vtSubmit(pb);
    }
}

// Push capture is damage-driven: a static screen yields no frames. The last frame
// is re-submitted:
//  (a) immediately when an IDR is requested (new client / resync);
//  (b) twice, right after motion stops: hardware decoders (Android MediaCodec)
//      release frame N only once frame N+1 arrives, so without this the final
//      cursor position would sit invisible in the decoder until the next refresh;
//  (c) every 250ms while idle — near-free P-frames that refine a static desktop.
static void *refreshThread(void *arg) {
    (void)arg;
    const uint64_t frameNs = (uint64_t)(1e9 / g_fps);
    while (g_running) {
        usleep(4000);
        if (!g_encQ || !encoderWanted())
            continue;
        uint64_t now = nowNs(), since = now - g_lastSubmitNs;
        BOOL want = NO;
        if (g_forceKey && since > 8000000ULL)
            want = YES;
        else if (g_repeatsSinceReal < 2 && now - g_lastRealNs > 2 * frameNs && since > frameNs)
            want = YES;
        else if (since > 250000000ULL)
            want = YES;
        if (!want)
            continue;
        pthread_mutex_lock(&g_lock);
        CVPixelBufferRef pb = g_latestPB;
        if (pb)
            CFRetain(pb);
        pthread_mutex_unlock(&g_lock);
        if (!pb)
            continue;
        g_repeatsSinceReal++;
        g_lastSubmitNs = now; // don't queue duplicates while this one is pending
        dispatch_async(g_encQ, ^{
          if (nowNs() - g_lastRealNs > frameNs)
              vtSubmitEx(pb, YES); // a real frame may have just landed
          CFRelease(pb);
        });
    }
    return NULL;
}

static BOOL startSCCapture(void) {
    @autoreleasepool {
        __block SCShareableContent *content = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [SCShareableContent
            getShareableContentExcludingDesktopWindows:NO
                                   onScreenWindowsOnly:NO
                                     completionHandler:^(SCShareableContent *c, NSError *err) {
                                       if (err)
                                           fprintf(stderr, "[sc] shareable content error: %s\n",
                                                   err.localizedDescription.UTF8String ?: "?");
                                       content = c;
                                       dispatch_semaphore_signal(sem);
                                     }];
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
            fprintf(stderr, "[sc] ShareableContent timed out\n");
            return NO;
        }
        if (!content) {
            fprintf(stderr, "[sc] no shareable content (Screen Recording permission?)\n");
            return NO;
        }

        SCDisplay *disp = nil;
        for (SCDisplay *d in content.displays)
            if (d.displayID == g_displayID) {
                disp = d;
                break;
            }
        if (!disp) {
            fprintf(stderr, "[sc] virtual display %u not found\n", g_displayID);
            return NO;
        }

        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:disp
                                                          excludingWindows:@[]];
        SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
        cfg.width = g_pixW;
        cfg.height = g_pixH; // full Retina framebuffer, no scaling
        cfg.pixelFormat = kCVPixelFormatType_32BGRA;
        cfg.minimumFrameInterval = CMTimeMake(1, (int32_t)(g_fps + 0.5));
        cfg.queueDepth = 5;    // we retain 1 (latest) + encoder in-flight
        cfg.showsCursor = YES; // WindowServer composites the real cursor
        cfg.scalesToFit = NO;
        cfg.colorSpaceName = kCGColorSpaceSRGB;
        if (g_audioWanted && !g_audioFailed) { // system audio -> PCM records
            cfg.capturesAudio = YES;
            cfg.sampleRate = (NSInteger)g_audioRate;
            cfg.channelCount = 2;
        }

        g_scOut = [SCOut new]; // strong ref: SCStream holds outputs weakly
        SCStream *stream = [[SCStream alloc] initWithFilter:filter
                                              configuration:cfg
                                                   delegate:g_scOut];
        NSError *err = nil;
        if (![stream addStreamOutput:g_scOut
                                type:SCStreamOutputTypeScreen
                  sampleHandlerQueue:g_encQ
                               error:&err]) {
            fprintf(stderr, "[sc] addStreamOutput failed: %s\n",
                    err.localizedDescription.UTF8String ?: "?");
            return NO;
        }
        if (g_audioWanted && !g_audioFailed &&
            ![stream addStreamOutput:g_scOut
                                type:SCStreamOutputTypeAudio
                  sampleHandlerQueue:g_audioQ
                               error:&err]) {
            fprintf(stderr, "[audio] output registration failed: %s — audio off\n",
                    err.localizedDescription.UTF8String ?: "?");
            g_audioFailed = YES; // capture continues, silent
        }
        __block BOOL ok = YES;
        dispatch_semaphore_t sem2 = dispatch_semaphore_create(0);
        [stream startCaptureWithCompletionHandler:^(NSError *e) {
          if (e) {
              ok = NO;
              fprintf(stderr, "[sc] startCapture failed: %s\n",
                      e.localizedDescription.UTF8String ?: "?");
          }
          dispatch_semaphore_signal(sem2);
        }];
        if (dispatch_semaphore_wait(sem2, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) !=
            0) {
            fprintf(stderr, "[sc] startCapture timed out\n");
            return NO;
        }
        if (!ok)
            return NO;
        g_scStream = stream;
        g_scFailed = 0;
        fprintf(
            stderr,
            "[sc] ScreenCaptureKit streaming %ux%u px @%.0f (cursor composited by WindowServer)\n",
            g_pixW, g_pixH, g_fps);
        return YES;
    }
}

static void *captureThread(void *arg);
static void *cursorThread(void *arg);
static BOOL startCGStreamCapture(void);

static void startPolling(void) {
    g_audioFailed = YES; // honesty: audio exists only on the ScreenCaptureKit path
    pthread_t capT, curT;
    pthread_create(&curT, NULL, cursorThread, NULL); // only polling needs a manual cursor overlay
    pthread_detach(curT);
    pthread_create(&capT, NULL, captureThread, NULL);
    pthread_detach(capT);
}

// capture health watchdog: SCStream -> CGDisplayStream -> polling loop.
// SCK delivers idle-status samples even for a static screen, so "zero callbacks"
// really means it is broken.
static void *captureWatchdog(void *arg) {
    (void)arg;
    sleep(4);
    if (g_scStream && g_scCallbacks > 0) { // SCK always delivers a few samples at start
        // healthy: keep watching for a stream error (sleep/wake, display reconfig).
        // Silence alone is normal — SCK stops sending samples for a static screen.
        while (g_running) {
            sleep(1);
            if (!g_scFailed)
                continue;
            fprintf(stderr, "[sc] capture failed — restarting ScreenCaptureKit\n");
            SCStream *old = g_scStream;
            g_scStream = nil;
            if (old)
                [old stopCaptureWithCompletionHandler:nil];
            while (g_running && !startSCCapture())
                sleep(2);
            g_forceKey = 1;
        }
        return NULL;
    }
    if (!g_scStream)
        return NULL;
    fprintf(stderr, "[sc] no frames from ScreenCaptureKit — trying CGDisplayStream\n");
    [g_scStream stopCaptureWithCompletionHandler:nil];
    g_scStream = nil;
    if (!startCGStreamCapture()) {
        startPolling();
        return NULL;
    }
    if (getenv("HOPPSCREEN_KEEP_PUSH")) { // debug: hold push capture, never fall back
        fprintf(stderr, "[cg] HOPPSCREEN_KEEP_PUSH set — holding push capture\n");
        return NULL;
    }
    uint64_t last = g_capFrames;
    int stalls = 0;
    for (int i = 0; i < 15; i++) { // observe up to 30s
        sleep(2);
        uint64_t cur = g_capFrames;
        uint64_t d = cur - last;
        last = cur;
        stalls = (d < 3) ? stalls + 1 : 0; // <1.5fps counts as stalled
        if (stalls >= 2)
            break;
    }
    if (stalls >= 2) {
        fprintf(stderr, "[cg] CGDisplayStream stalled — switching to polling\n");
        if (MyCGDisplayStreamStop)
            MyCGDisplayStreamStop((MyCGDisplayStreamRef)g_cgStream);
        g_cgStream = NULL;
        pthread_mutex_lock(&g_lock); // polling path doesn't use the push buffer
        if (g_latestPB) {
            CFRelease(g_latestPB);
            g_latestPB = NULL;
        }
        pthread_mutex_unlock(&g_lock);
        startPolling();
    } else {
        fprintf(stderr, "[cg] push capture healthy, keeping it\n");
    }
    return NULL;
}

// ============================================================ MJPEG (fallback only)
// Produce the latest JPEG only when a stream or /frame.jpg asks for it (about 30fps).
// Push buffers already contain the cursor; polling requires the separate cursor overlay.
// The polling loop also feeds H.264 when push capture is unavailable.
static volatile int g_wantJpeg = 0; // one-shot request from /frame.jpg

static CGImageRef imageFromPB(CVPixelBufferRef pb) {
    // deep copy: the buffer may be recycled by the capture pool after we unlock
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb),
           bpr = CVPixelBufferGetBytesPerRow(pb);
    CFDataRef data = CFDataCreate(NULL, CVPixelBufferGetBaseAddress(pb), (CFIndex)(bpr * h));
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    if (!data)
        return NULL;
    CGDataProviderRef dp = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGImageRef img =
        CGImageCreate(w, h, 8, 32, bpr, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little,
                      dp, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(dp);
    CFRelease(data);
    return img;
}

static void *jpegThread(void *arg) {
    (void)arg;
    while (g_running) {
        if (g_mjpegClients == 0 && !g_wantJpeg) {
            usleep(50000);
            continue;
        }
        uint64_t t0 = nowNs();
        g_wantJpeg = 0;
        CGImageRef img = NULL;
        BOOL needCursor = NO;
        pthread_mutex_lock(&g_lock);
        CVPixelBufferRef pb = g_latestPB;
        if (pb)
            CFRetain(pb);
        pthread_mutex_unlock(&g_lock);
        if (pb) {
            img = imageFromPB(pb);
            CFRelease(pb);
        } // push capture: cursor already in frame
        else {
            pthread_mutex_lock(&g_jpegLock);
            if (g_jpegImg) {
                CFRetain(g_jpegImg);
                img = g_jpegImg;
            }
            pthread_mutex_unlock(&g_jpegLock);
            needCursor = YES; // polling: CGDisplayCreateImage omits it
        }
        if (!img) {
            usleep(30000);
            continue;
        }
        @autoreleasepool {
            CGImageRef src = img;
            CGImageRef composed = NULL;
            if (needCursor) {
                size_t jw = CGImageGetWidth(img), jh = CGImageGetHeight(img);
                CGColorSpaceRef jcs = CGColorSpaceCreateDeviceRGB();
                CGContextRef jctx =
                    CGBitmapContextCreate(NULL, jw, jh, 8, 0, jcs,
                                          kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
                CGColorSpaceRelease(jcs);
                if (jctx) {
                    CGContextDrawImage(jctx, CGRectMake(0, 0, jw, jh), img);
                    drawCursorOverlay(jctx);
                    composed = CGBitmapContextCreateImage(jctx);
                    CFRelease(jctx);
                    if (composed)
                        src = composed;
                }
            }
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:src];
            NSData *jpeg = [rep representationUsingType:NSBitmapImageFileTypeJPEG
                                             properties:@{
                                                 NSImageCompressionFactor : @0.75
                                             }];
            if (jpeg.length > 0)
                storeJpeg(jpeg);
            if (composed)
                CFRelease(composed);
        }
        CFRelease(img);
        uint64_t spent = (nowNs() - t0) / 1000; // cap ~30fps
        if (spent < 33000)
            usleep((useconds_t)(33000 - spent));
    }
    return NULL;
}

static void *captureThread(void *arg) {
    (void)arg;
    static mach_timebase_info_data_t tb;
    if (!tb.denom)
        mach_timebase_info(&tb);
    uint64_t intervalTicks = (uint64_t)((double)tb.denom * 1e9 / ((double)tb.numer * g_fps));
    uint64_t next = mach_absolute_time();
    uint64_t lastCount = 0, lastTick = 0;
    double capMsAvg = 0;
    CGDisplayCreateImageFn grab = CGDisplayCreateImage_dyn();
    fprintf(
        stderr,
        "[capture] CGDisplayCreateImage polling @%.0f (fallback — higher CPU than push capture)\n",
        g_fps);
    while (g_running) {
        // nobody watching: don't grab the screen at all (this loop is the CPU hog)
        if (!encoderWanted() && g_mjpegClients == 0 && !g_wantJpeg) {
            usleep(100000);
            next = mach_absolute_time();
            continue;
        }
        @autoreleasepool {
            uint64_t t0 = mach_absolute_time();
            CGImageRef img = grab ? grab(g_displayID) : NULL;
            uint64_t t1 = mach_absolute_time();
            double capMs = (double)(t1 - t0) * (double)tb.numer / (double)tb.denom / 1e6;
            capMsAvg = capMsAvg ? capMsAvg * 0.9 + capMs * 0.1 : capMs;
            g_capFrames++;
            if (img) {
                pthread_mutex_lock(&g_jpegLock); // hand off to jpeg thread
                if (g_jpegImg)
                    CFRelease(g_jpegImg);
                CFRetain(img);
                g_jpegImg = img;
                pthread_mutex_unlock(&g_jpegLock);
                if (encoderWanted())
                    encodeH264(img);
                CFRelease(img);
            } else {
                static int warned = 0;
                if (!warned++)
                    fprintf(stderr,
                            "[capture] CGDisplayCreateImage returned NULL — grant Screen Recording "
                            "permission to your terminal app in System Settings, then restart.\n");
            }

            uint64_t now = mach_absolute_time(); // loop-rate window
            if (!lastTick)
                lastTick = now;
            double el = ((now - lastTick) * (double)tb.numer / tb.denom) / 1e9;
            if (el >= 2.0) {
                g_captureFps = (g_capFrames - lastCount) / el;
                g_encFps = g_captureFps;
                g_capMs = capMsAvg;
                lastCount = g_capFrames;
                lastTick = now;
            }

            next += intervalTicks; // pace: sleep only the remainder
            uint64_t now2 = mach_absolute_time();
            if (next > now2) {
                uint64_t ns = (uint64_t)((double)(next - now2) * (double)tb.numer / tb.denom);
                if (ns > 200000)
                    usleep((useconds_t)(ns / 1000));
            } else {
                next = now2; // behind: resync, no sleep
            }
        }
    }
    return NULL;
}

// ============================================================ http helpers
// Bind IPv4 listeners with restart-friendly reuse and no SIGPIPE delivery.
// Close-on-exec prevents listeners from leaking into an auto-fit replacement.
static int listenSocket(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        perror("socket");
        return -1;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    fcntl(fd, F_SETFD, FD_CLOEXEC); // never leak listeners across a /fit re-exec
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(fd, 16) < 0) {
        fprintf(stderr, "[net] bind/listen :%u failed: %s\n", port, strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

// ============================================================ TLS (HTTPS port)
// Wrap the blocking connection I/O without changing request handlers or stream framing.
// TLS state is thread-local; identities load into memory only, with TLS 1.2 minimum.
// Chrome only exposes WebCodecs (H.264 decode) to secure contexts. Serving HTTPS
// with a local CA (certs.sh) makes https://<mac-ip>:8443 one — direct over Wi-Fi.
// SecureTransport is deprecated but present and fits the blocking thread-per-
// connection model; every connection thread keeps its TLS session in t_ssl so the
// write helpers transparently encrypt.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static SecIdentityRef g_tlsIdentity = NULL;
static CFArrayRef g_tlsChain = NULL; // [identity, CA cert...]
static uint16_t g_tlsPort = 0;
static NSData *g_caCert = nil; // served at /ca.crt for installing on the receiver
static __thread SSLContextRef t_ssl = NULL;

static OSStatus sslReadCB(SSLConnectionRef c, void *data, size_t *len) {
    int fd = (int)(intptr_t)c;
    size_t want = *len, got = 0;
    while (got < want) {
        ssize_t n = recv(fd, (char *)data + got, want - got, 0);
        if (n > 0) {
            got += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR)
            continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            // would-block: deliver what arrived, or let the handshake retry —
            // treating this as an abort kills slow/fragmented TLS handshakes
            if (got > 0)
                break;
            *len = 0; // report actual bytes, even on would-block
            return errSSLWouldBlock;
        }
        *len = got;
        if (n == 0)
            return errSSLClosedGraceful;
        return errSSLClosedAbort;
    }
    *len = got;
    return noErr;
}
static OSStatus sslWriteCB(SSLConnectionRef c, const void *data, size_t *len) {
    int fd = (int)(intptr_t)c;
    size_t want = *len, put = 0;
    while (put < want) {
        ssize_t n = write(fd, (const char *)data + put, want - put);
        if (n > 0) {
            put += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR)
            continue;
        *len = put;
        return errSSLClosedAbort; // incl. SO_SNDTIMEO expiry: client stalled
    }
    *len = put;
    return noErr;
}

static BOOL loadTLSIdentity(NSString *p12Path) {
    NSData *p12 = [NSData dataWithContentsOfFile:p12Path];
    if (!p12)
        return NO;
    NSDictionary *opts = @{
        (__bridge id)kSecImportExportPassphrase : @"hoppscreen",
        (__bridge id)kSecImportToMemoryOnly : @YES
    }; // never touch the keychain
    CFArrayRef items = NULL;
    OSStatus st = SecPKCS12Import((__bridge CFDataRef)p12, (__bridge CFDictionaryRef)opts, &items);
    if (st != errSecSuccess || !items || CFArrayGetCount(items) == 0) {
        fprintf(stderr, "[tls] could not load %s (err %d)\n", p12Path.UTF8String, (int)st);
        if (items)
            CFRelease(items);
        return NO;
    }
    CFDictionaryRef item = CFArrayGetValueAtIndex(items, 0);
    SecIdentityRef ident = (SecIdentityRef)CFDictionaryGetValue(item, kSecImportItemIdentity);
    CFArrayRef chain = CFDictionaryGetValue(item, kSecImportItemCertChain);
    if (!ident) {
        CFRelease(items);
        return NO;
    }
    NSMutableArray *arr = [NSMutableArray arrayWithObject:(__bridge id)ident];
    if (chain)
        for (CFIndex i = 1; i < CFArrayGetCount(chain); i++) // [0] is the leaf itself
            [arr addObject:(__bridge id)CFArrayGetValueAtIndex(chain, i)];
    g_tlsIdentity = (SecIdentityRef)CFRetain(ident);
    g_tlsChain = (CFArrayRef)CFBridgingRetain([arr copy]);
    CFRelease(items);
    return YES;
}

static BOOL tlsAccept(int fd) {
    SSLContextRef ctx = SSLCreateContext(NULL, kSSLServerSide, kSSLStreamType);
    if (!ctx)
        return NO;
    OSStatus cfg = SSLSetIOFuncs(ctx, sslReadCB, sslWriteCB);
    if (cfg == noErr)
        cfg = SSLSetConnection(ctx, (SSLConnectionRef)(intptr_t)fd);
    if (cfg == noErr)
        cfg = SSLSetProtocolVersionMin(ctx, kTLSProtocol12);
    if (cfg == noErr)
        cfg = SSLSetCertificate(ctx, g_tlsChain);
    if (cfg != noErr) { // config failure would surface as a confusing handshake error
        fprintf(stderr, "[tls] setup failed (%d)\n", (int)cfg);
        CFRelease(ctx);
        return NO;
    }
    OSStatus st;
    do {
        st = SSLHandshake(ctx);
    } while (st == errSSLWouldBlock);
    if (st != noErr) {
        // -9806/-9805 here usually = the browser closed the socket after showing its
        // certificate warning (CA not installed on the receiver yet) — harmless
        static int logged = 0;
        if (st != errSSLClosedAbort && st != errSSLClosedGraceful &&
            (getenv("HOPPSCREEN_DEBUG") || !logged++))
            fprintf(stderr,
                    "[tls] handshake rejected (%d) — client doesn't trust the cert yet? "
                    "install certs/ca.crt on the receiver (README: 'Why HTTPS')\n",
                    (int)st);
        CFRelease(ctx);
        return NO;
    }
    t_ssl = ctx;
    return YES;
}

static ssize_t connRecv(int fd, void *buf, size_t len) {
    if (!t_ssl)
        return recv(fd, buf, len, 0);
    size_t got = 0;
    OSStatus st = SSLRead(t_ssl, buf, len, &got);
    if (got > 0)
        return (ssize_t)got;
    return st == noErr ? 0 : -1;
}

static void closeConn(int fd) {
    if (t_ssl) {
        SSLClose(t_ssl);
        CFRelease(t_ssl);
        t_ssl = NULL;
    }
    close(fd);
}

static BOOL writeAll(int fd, const void *buf, size_t len) {
    const char *p = buf;
    if (t_ssl) {
        while (len > 0) {
            size_t done = 0;
            OSStatus st = SSLWrite(t_ssl, p, len, &done);
            p += done;
            len -= done;
            if (st != noErr && !(st == errSSLWouldBlock && done > 0)) {
                if (len && getenv("HOPPSCREEN_DEBUG"))
                    fprintf(stderr, "[tls] write failed: status %d errno %d (%s), %zu bytes left\n",
                            (int)st, errno, strerror(errno), len);
                return len == 0;
            }
        }
        return YES;
    }
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n <= 0) {
            if (errno == EINTR)
                continue;
            return NO;
        }
        p += n;
        len -= n;
    }
    return YES;
}
#pragma clang diagnostic pop
// ============================================================ response and stream helpers
// Text writes use strlen; binary records carry explicit lengths and wall-clock times.
// HTTP and HTTPS share writeAll so framing is identical on both listeners.
static BOOL writeStr(int fd, const char *s) {
    return writeAll(fd, s, strlen(s));
}

// print reachable URLs for every live IPv4 interface (IP changes with Wi-Fi networks)
static void printLocalURLs(const char *scheme, uint16_t port) {
    struct ifaddrs *ifs = NULL, *it;
    if (getifaddrs(&ifs) != 0)
        return;
    for (it = ifs; it; it = it->ifa_next) {
        if (!it->ifa_addr || it->ifa_addr->sa_family != AF_INET)
            continue;
        if (!(it->ifa_flags & IFF_UP) || !(it->ifa_flags & IFF_RUNNING))
            continue;
        if (it->ifa_flags & IFF_LOOPBACK)
            continue;
        char ip[64];
        struct sockaddr_in *sa = (struct sockaddr_in *)it->ifa_addr;
        if (!inet_ntop(AF_INET, &sa->sin_addr, ip, sizeof(ip)))
            continue;
        printf("  -> %s://%s:%u/   (%s)\n", scheme, ip, port, it->ifa_name);
    }
    freeifaddrs(ifs);
}
// [4B len][1B flags][8B capture time, wall-clock µs][payload]   (len = payload bytes)
static BOOL writeRec(int fd, uint8_t flags, int64_t tsUs, NSData *payload) {
    size_t L = payload.length;
    uint8_t *buf = malloc(13 + L); // one write = one TCP segment train
    if (!buf)
        return NO;
    buf[0] = (uint8_t)(L >> 24);
    buf[1] = (uint8_t)(L >> 16);
    buf[2] = (uint8_t)(L >> 8);
    buf[3] = (uint8_t)L;
    buf[4] = flags;
    for (int i = 0; i < 8; i++)
        buf[5 + i] = (uint8_t)((uint64_t)tsUs >> (56 - 8 * i));
    if (L)
        memcpy(buf + 13, payload.bytes, L);
    BOOL ok = writeAll(fd, buf, 13 + L);
    free(buf);
    return ok;
}

// ============================================================ polling cursor overlay
// CGDisplayCreateImage omits the cursor; polling capture composites a cached snapshot.
// Sampling stays off the capture thread to avoid a WindowServer round-trip per frame.
// Coordinate conversion distinguishes desktop points from framebuffer pixels.
static pthread_mutex_t g_curLock = PTHREAD_MUTEX_INITIALIZER;
static NSPoint g_curPos; // global, bottom-left origin
static NSImage *g_curImg = nil;
static NSPoint g_curHot; // hotspot in cursor-image POINTS, top-left origin

// cursor sampling is a WindowServer round-trip (~15ms) — keep it OFF the capture
// loop: dedicated thread at ~120Hz, capture reads the latest snapshot.
static void *cursorThread(void *arg) {
    (void)arg;
    NSCursor *lastC = nil;
    while (g_running) {
        @try {
            NSPoint p = [NSEvent mouseLocation];
            NSCursor *c = [NSCursor currentSystemCursor];
            pthread_mutex_lock(&g_curLock);
            g_curPos = p;
            if (c != lastC || !g_curImg) {
                lastC = c;
                g_curImg = c.image;
                g_curHot = c.hotSpot;
            }
            pthread_mutex_unlock(&g_curLock);
        } @catch (NSException *e) {
        }
        usleep(8000);
    }
    return NULL;
}

static void drawCursorOverlay(CGContextRef ctx) {
    pthread_mutex_lock(&g_curLock);
    NSPoint pos = g_curPos;
    NSImage *img = g_curImg;
    NSPoint hot = g_curHot;
    pthread_mutex_unlock(&g_curLock);
    if (!img || img.size.width <= 0 || img.size.height <= 0)
        return;
    // NSEvent.mouseLocation: Cocoa global space, origin bottom-left of the primary
    // display, y UP. CGDisplayBounds: origin top-left of the primary display, y DOWN.
    CGFloat primaryH = CGDisplayBounds(CGMainDisplayID()).size.height;
    CGPoint cg = {pos.x, primaryH - pos.y};
    CGRect vb = CGDisplayBounds(g_displayID); // points
    vb.size = CGSizeMake(g_dispW, g_dispH);   // bounds size can be stale (see inputPoint)
    if (!CGRectContainsPoint(vb, cg))
        return;
    CGFloat ctxW = (CGFloat)CGBitmapContextGetWidth(ctx),
            ctxH = (CGFloat)CGBitmapContextGetHeight(ctx);
    CGFloat scale = vb.size.width > 0 ? ctxW / vb.size.width : 1.0; // px per point (2 on HiDPI)
    // best (largest) bitmap rep; draw it at the cursor's POINT size * scale
    CGImageRef cgi = NULL;
    NSInteger bestW = 0;
    for (NSImageRep *rep in img.representations)
        if ([rep isKindOfClass:[NSBitmapImageRep class]] && ((NSBitmapImageRep *)rep).CGImage &&
            rep.pixelsWide > bestW) {
            cgi = ((NSBitmapImageRep *)rep).CGImage;
            bestW = rep.pixelsWide;
        }
    if (!cgi)
        cgi = [img CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cgi)
        return;
    CGFloat cw = img.size.width * scale, ch = img.size.height * scale;
    // hotspot (top-left origin, points) must land exactly on the pointer position
    CGFloat left = (cg.x - vb.origin.x - hot.x) * scale;
    CGFloat topPx = (cg.y - vb.origin.y - hot.y) * scale;       // from the top edge
    CGRect crect = CGRectMake(left, ctxH - topPx - ch, cw, ch); // bitmap context is y-up
    if (getenv("HOPPSCREEN_DEBUG")) {
        static uint64_t lastDbg = 0;
        uint64_t t = nowNs();
        if (t - lastDbg > 500000000ULL) {
            lastDbg = t;
            fprintf(stderr,
                    "[cursor] cg(%.1f,%.1f) vb(%.0f,%.0f %.0fx%.0f) hot(%.1f,%.1f) size %.0fx%.0f "
                    "scale %.2f -> rect(%.1f,%.1f %.0fx%.0f)\n",
                    cg.x, cg.y, vb.origin.x, vb.origin.y, vb.size.width, vb.size.height, hot.x,
                    hot.y, img.size.width, img.size.height, scale, crect.origin.x, crect.origin.y,
                    crect.size.width, crect.size.height);
        }
    }
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, crect, cgi);
}

// ============================================================ player page
// Receiver layout/styles/script remain together in their original byte order.
// CSS is in <style>, page markup precedes <script>, and the AudioWorklet uses a blob.
// The exact receiver bytes live in web/index.html; make embeds them in
// web_index.h. The array has no trailing NUL: always use its explicit length.

// ============================================================ password protection
// Validate Basic credentials against a password digest, with constant-time comparison.
// The handler gate exempts IPv4 loopback; header helpers bound lookup to header lines.
// The server is reachable by anyone on the same Wi-Fi, so every endpoint
// requires HTTP Basic auth. The receiver's browser asks once, remembers it for the
// origin and attaches it to every following request (player page, /h264,
// /stream.mjpg), so the streams keep working unchanged after login.
//   credentials: first line of ./passwd next to the binary, "user:password"
//   (auto-generated on first run, file mode 600), or HOPPSCREEN_PASSWORD=<password>
//   env (any username). Connections from 127.0.0.1 (this Mac) are exempt.
static NSData *g_authHash = nil;   // SHA256(password); nil = protection off
static NSString *g_authUser = nil; // required username, nil = any

static BOOL timingSafeEq(const void *a, const void *b, size_t n) {
    const uint8_t *x = a, *y = b;
    uint8_t d = 0;
    for (size_t i = 0; i < n; i++)
        d |= x[i] ^ y[i];
    return d == 0; // compares digests, never the password itself
}
static NSData *sha256(NSString *s) {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t dig[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, dig);
    return [NSData dataWithBytes:dig length:sizeof dig];
}
// verify "Authorization: Basic base64(user:password)" in a raw request header
static BOOL requestAuthorized(const char *req) {
    const char *h = strcasestr(req, "Authorization:");
    if (!h)
        return NO;
    char scheme[16] = {0}, cred[512] = {0};
    if (sscanf(h + 14, "%15s %511s", scheme, cred) != 2 || strcasecmp(scheme, "Basic") != 0)
        return NO;
    NSData *credData =
        [[NSData alloc] initWithBase64EncodedString:@(cred)
                                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    NSString *pair =
        credData ? [[NSString alloc] initWithData:credData encoding:NSUTF8StringEncoding] : nil;
    if (!pair)
        return NO;
    NSRange colon = [pair rangeOfString:@":"];
    if (colon.location == NSNotFound)
        return NO;
    if (g_authUser && ![[pair substringToIndex:colon.location] isEqualToString:g_authUser])
        return NO;
    NSData *dig = sha256([pair substringFromIndex:colon.location + 1]);
    return dig.length == g_authHash.length && timingSafeEq(dig.bytes, g_authHash.bytes, dig.length);
}
static BOOL isLoopbackPeer(int fd) {
    struct sockaddr_in peer;
    socklen_t pl = sizeof(peer);
    return getpeername(fd, (struct sockaddr *)&peer, &pl) == 0 && peer.sin_family == AF_INET &&
           (ntohl(peer.sin_addr.s_addr) >> 24) == 127;
}
static void peerIp(int fd, char *out, size_t n) {
    snprintf(out, n, "?");
    struct sockaddr_in peer;
    socklen_t pl = sizeof(peer);
    if (getpeername(fd, (struct sockaddr *)&peer, &pl) == 0 && peer.sin_family == AF_INET)
        inet_ntop(AF_INET, &peer.sin_addr, out, (socklen_t)n);
}

// case-insensitive header lookup bounded by the line end. Searching the whole
// request with strcasestr would match header names echoed in the body (e.g. a
// text/plain CSRF POST mentioning "application/json" in its payload).
static void headerVal(const char *req, const char *name, char *out, size_t n) {
    out[0] = 0;
    size_t nl = strlen(name);
    for (const char *ln = req, *eol; (eol = strstr(ln, "\r\n")) != NULL; ln = eol + 2) {
        if (strncasecmp(ln, name, nl) == 0 && ln[nl] == ':') {
            const char *v = ln + nl + 1;
            while (*v == ' ' || *v == '\t')
                v++;
            size_t l = (size_t)(eol - v);
            if (l > n - 1)
                l = n - 1;
            memcpy(out, v, l);
            out[l] = 0;
            return;
        }
    }
}
static BOOL isJsonContent(const char *req) {
    char ct[96];
    headerVal(req, "Content-Type", ct, sizeof ct);
    return strncmp(ct, "application/json", 16) == 0 &&
           (ct[16] == 0 || ct[16] == ';' || ct[16] == ' ');
}

// ============================================================ auto-fit (/fit)
// Re-exec preserves pid/logging while rebuilding the display at the receiver's size.
// Explicit size args pin by default; AUTOFIT overrides, LASTFIT carries the cooldown.
// HoppScreen is generic: the receiver may be any device with a browser. The
// page compares its own panel with /status and posts {w,h,dpr,hz} to /fit;
// if the current framebuffer is far off, the server re-execs itself with
// matching display arguments. execv keeps the pid (so make's pidfile stays
// valid) and the log fd; WindowServer reaps the old virtual display, and
// VirtualDisplay's serial-retry loop handles the teardown race.
//   - no args at launch  -> auto-fit ON
//   - explicit W H args  -> auto-fit OFF (user pinned the size)
//   - HOPPSCREEN_AUTOFIT=0/1   -> force either way
static uint16_t g_port = 0;
static int g_httpFd = -1, g_tlsFd = -1;
static BOOL g_autofit = NO;
static char g_exePath[PATH_MAX] = {0};
static time_t g_lastFit = 0;         // survives re-execs via HOPPSCREEN_LASTFIT
static volatile BOOL g_fitBusy = NO; // test-and-set: one /fit decision at a time

static void refitExec(uint32_t ptW, uint32_t ptH, double fps, BOOL hiDPI) __attribute__((noreturn));
static void refitExec(uint32_t ptW, uint32_t ptH, double fps, BOOL hiDPI) {
    fprintf(stderr, "[fit] re-exec as %ux%u pt %s @%.0f\n", ptW, ptH, hiDPI ? "(HiDPI 2x)" : "(1x)",
            fps);
    fflush(stdout);
    fflush(stderr);
    // the new instance must use the scale decided here, whatever the env says
    setenv("HOPPSCREEN_SCALE", hiDPI ? "0" : "1", 1); // "0" -> stays HiDPI
    setenv("HOPPSCREEN_AUTOFIT", "1", 1);             // explicit args must NOT pin
                                                      // the size after a refit
    { // keep the refit rate-limit window across the exec
        char tS[24];
        snprintf(tS, sizeof tS, "%lld", (long long)g_lastFit);
        setenv("HOPPSCREEN_LASTFIT", tS, 1);
    }
    char wS[16], hS[16], pS[16], fS[16];
    snprintf(wS, sizeof wS, "%u", ptW);
    snprintf(hS, sizeof hS, "%u", ptH);
    snprintf(pS, sizeof pS, "%u", g_port);
    snprintf(fS, sizeof fS, "%u", (uint32_t)(fps + 0.5));
    char *av[] = {g_exePath, wS, hS, pS, fS, NULL};
    if (g_httpFd >= 0)
        close(g_httpFd); // child re-binds them
    if (g_tlsFd >= 0)
        close(g_tlsFd);
    execv(g_exePath, av);
    perror("[fit] execv"); // only on failure
    _exit(1);
}

// ============================================================ touch input (/input)
// Validate normalized gestures before applying them in order on g_inputQ.
// Boot opt-in, the live toggle and Accessibility trust are separate acceptance gates.
// The other direction of the pipe: the page posts touch events here and the
// server replays them onto the virtual display with CGEventPost — the receiver
// becomes a touchscreen for the Mac (tap=click, long-press=right-click,
// drag=left-drag, two-finger swipe=scroll wheel; a mouse in a laptop browser
// works too). Coordinates are normalized (0..1 over the stream picture), so
// they survive auto-fit and re-execs.
//   - macOS requires the Accessibility permission for event injection; until
//     it is granted input is inert (/status "input":false, banner says so).
//   - POST-only + Content-Type: application/json, so a page from another site
//     open in the receiver's browser cannot forge events (no-cors requests
//     cannot carry that header). Auth applies as everywhere else.
//   - Input is view-only unless HOPPSCREEN_INPUT is set to a nonzero integer.
static volatile BOOL g_inputWanted = NO; // env boot default (HOPPSCREEN_INPUT)
static BOOL g_inputTrusted = NO;         // Accessibility granted
static BOOL g_inputEnabled = YES;        // runtime toggle (presenter mode), POST /input/toggle
static BOOL g_inputLogged = NO, g_inputDragging = NO;
static CGPoint g_lastInputPoint = {0, 0}; // 'up' without coords releases at the last spot
static dispatch_queue_t g_inputQ = NULL;  // serial: applies events in arrival order
static BOOL g_scrollInvert = NO;          // HOPPSCREEN_SCROLL_INVERT=1 flips wheel/zoom
static CGEventSourceRef g_evtSrc = NULL;

static double clampd(double v, double lo, double hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

// macOS 26 can drop the headless virtual display out of the ACTIVE list while
// it stays online: capture/encode keep working, but WindowServer refuses to
// move the pointer onto it, so every touch clamps to the real screen's edge.
// Holding a user-activity assertion (what `caffeinate -u` does) re-activates
// it. Called before applying gestures; self-heals within ~a second.
static void ensureDisplayActive(void) {
    if (!g_displayID || CGDisplayIsActive(g_displayID))
        return;
    IOPMAssertionID aid = 0;
    // "UserIsActive" is the assertion type behind `caffeinate -u` (no public constant)
    if (IOPMAssertionCreateWithName(CFSTR("UserIsActive"), kIOPMAssertionLevelOn,
                                    CFSTR("HoppScreen virtual display wake"), &aid) ==
        kIOReturnSuccess) {
        fprintf(stderr, "[input] virtual display #%u inactive — waking it\n", g_displayID);
        usleep(1200000); // WindowServer needs a beat to re-activate the display
        IOPMAssertionRelease(aid);
    }
}

static CGPoint inputPoint(double nx, double ny) { // stream coords -> global desktop points
    CGRect b = CGDisplayBounds(g_displayID);      // origin is global; the SIZE can lag
    return CGPointMake(b.origin.x + clampd(nx, 0, 1) * (g_dispW - 1), // g_dispW/H = served mode
                       b.origin.y +
                           clampd(ny, 0, 1) * (g_dispH - 1)); // -1: nx=1 stays ON the display
}

static CGEventSourceRef evtSrc(void) {
    if (!g_evtSrc)
        g_evtSrc = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    return g_evtSrc;
}

static void postMouseC(CGEventType ty, CGPoint p, CGMouseButton btn, int clicks, uint64_t flags) {
    CGEventRef e = CGEventCreateMouseEvent(evtSrc(), ty, p, btn);
    if (e) {
        if (clicks > 1)
            CGEventSetIntegerValueField(e, kCGMouseEventClickState, clicks);
        if (flags)
            CGEventSetFlags(e, flags);
        CGEventPost(kCGHIDEventTap, e);
        CFRelease(e);
    }
}

static void postKey(CGKeyCode code, uint64_t flags) { // flags = modifiers held during the press
    CGEventRef d = CGEventCreateKeyboardEvent(evtSrc(), code, true);
    CGEventRef u = CGEventCreateKeyboardEvent(evtSrc(), code, false);
    if (d && u) {
        if (flags) {
            CGEventSetFlags(d, flags);
            CGEventSetFlags(u, flags);
        }
        CGEventPost(kCGHIDEventTap, d);
        CGEventPost(kCGHIDEventTap, u);
    }
    if (d)
        CFRelease(d);
    if (u)
        CFRelease(u);
}

// gesture -> native event. Event vocabulary (see the page's gesture engine):
//   tap(c=1..3) left click with click count (2 = open/word, 3 = paragraph)
//   rclick      right click          mclick  middle click (open in new tab)
//   down/move/up  left-drag, c carries the click count (double-tap-drag = word select)
//   scroll      wheel, dx/dy pixels; zoom:1 adds Cmd (pinch -> app zoom)
//   key         spaceL/spaceR (Ctrl-Arrow = switch Space), mission (Ctrl-Up),
//               appwin (Ctrl-Down), launchpad (F4)
// strict schema check BEFORE touching the event: a malformed {"t":"tap","x":[]}
// would throw an unrecognized-selector exception on a connection thread and
// kill the whole server. Only exact types pass; unknown event types are 400s.
static BOOL inputEventValid(NSDictionary *ev) {
    NSString *t = ev[@"t"];
    if (![t isKindOfClass:[NSString class]])
        return NO;
    if (![t isEqualToString:@"tap"] && ![t isEqualToString:@"rclick"] &&
        ![t isEqualToString:@"mclick"] && ![t isEqualToString:@"down"] &&
        ![t isEqualToString:@"move"] && ![t isEqualToString:@"up"] &&
        ![t isEqualToString:@"scroll"] && ![t isEqualToString:@"key"])
        return NO;
    for (NSString *k in @[ @"x", @"y", @"dx", @"dy", @"c" ]) {
        id v = ev[k];
        if (v && (![v isKindOfClass:[NSNumber class]] || !isfinite([v doubleValue])))
            return NO;
    }
    if (ev[@"k"] && ![ev[@"k"] isKindOfClass:[NSString class]])
        return NO;
    if (ev[@"zoom"] && ![ev[@"zoom"] isKindOfClass:[NSNumber class]])
        return NO;
    return YES;
}

static void applyInputEvent(NSDictionary *ev) {
    NSString *t = ev[@"t"];
    if (![t isKindOfClass:[NSString class]])
        return;
    // events without x/y ('up', and scroll bursts that omitted position)
    // reuse the last known point so releasing a drag ends where the finger was
    BOOL hasXY =
        [ev[@"x"] isKindOfClass:[NSNumber class]] && [ev[@"y"] isKindOfClass:[NSNumber class]];
    CGPoint p =
        hasXY ? inputPoint([ev[@"x"] doubleValue], [ev[@"y"] doubleValue]) : g_lastInputPoint;
    if (hasXY)
        g_lastInputPoint = p;
    int c = [ev[@"c"] intValue]; // click count
    if (c < 1 || c > 3)
        c = 1;
    if ([t isEqualToString:@"tap"]) { // cursor jump + click
        postMouseC(kCGEventMouseMoved, p, kCGMouseButtonLeft, 0, 0);
        postMouseC(kCGEventLeftMouseDown, p, kCGMouseButtonLeft, c, 0);
        postMouseC(kCGEventLeftMouseUp, p, kCGMouseButtonLeft, c, 0);
    } else if ([t isEqualToString:@"rclick"]) {
        postMouseC(kCGEventMouseMoved, p, kCGMouseButtonLeft, 0, 0);
        postMouseC(kCGEventRightMouseDown, p, kCGMouseButtonRight, 1, 0);
        postMouseC(kCGEventRightMouseUp, p, kCGMouseButtonRight, 1, 0);
    } else if ([t isEqualToString:@"mclick"]) {
        postMouseC(kCGEventMouseMoved, p, kCGMouseButtonLeft, 0, 0);
        postMouseC(kCGEventOtherMouseDown, p, kCGMouseButtonCenter, 1, 0);
        postMouseC(kCGEventOtherMouseUp, p, kCGMouseButtonCenter, 1, 0);
    } else if ([t isEqualToString:@"down"]) {
        g_inputDragging = YES;
        postMouseC(kCGEventMouseMoved, p, kCGMouseButtonLeft, 0, 0);
        postMouseC(kCGEventLeftMouseDown, p, kCGMouseButtonLeft, c, 0);
    } else if ([t isEqualToString:@"move"]) {
        postMouseC(g_inputDragging ? kCGEventLeftMouseDragged : kCGEventMouseMoved, p,
                   kCGMouseButtonLeft, 0, 0);
    } else if ([t isEqualToString:@"up"]) {
        g_inputDragging = NO;
        postMouseC(kCGEventLeftMouseUp, p, kCGMouseButtonLeft, 0, 0);
    } else if ([t isEqualToString:@"scroll"]) { // dy/dx pixels, "natural" direction
        // wheel events go to whatever is UNDER THE CURSOR — without a warp a
        // scroll-only gesture would hit whatever screen the real mouse sits on.
        // The page sends the finger position; land the cursor there first.
        if (hasXY)
            postMouseC(kCGEventMouseMoved, p, kCGMouseButtonLeft, 0, 0);
        double dy = [ev[@"dy"] doubleValue] * (g_scrollInvert ? -1 : 1);
        double dx = [ev[@"dx"] doubleValue] * (g_scrollInvert ? -1 : 1);
        CGEventRef e = CGEventCreateScrollWheelEvent(evtSrc(), kCGScrollEventUnitPixel, 2,
                                                     (int32_t)clampd(dy, -2000, 2000),
                                                     (int32_t)clampd(dx, -2000, 2000));
        if (e) {
            if ([ev[@"zoom"] boolValue])
                CGEventSetFlags(e, kCGEventFlagMaskCommand);
            CGEventPost(kCGHIDEventTap, e);
            CFRelease(e);
        }
    } else if ([t isEqualToString:@"key"]) {
        NSString *k = ev[@"k"];
        if ([k isEqualToString:@"spaceL"])
            postKey(123, kCGEventFlagMaskControl); // Ctrl-Left
        else if ([k isEqualToString:@"spaceR"])
            postKey(124, kCGEventFlagMaskControl); // Ctrl-Right
        else if ([k isEqualToString:@"mission"])
            postKey(126, kCGEventFlagMaskControl); // Ctrl-Up
        else if ([k isEqualToString:@"appwin"])
            postKey(125, kCGEventFlagMaskControl); // Ctrl-Down
        else if ([k isEqualToString:@"launchpad"])
            postKey(118, 0); // F4
    }
}

// ============================================================ handlers
// One bounded request per connection, authenticated before route dispatch.
// H.264 starts on a fresh IDR and drops ~250ms backlogs rather than accumulating delay.
// JSON-only mutation routes and a shared listener budget bound receiver-side work.
static void handleClient(int fd, BOOL tls) {
    @autoreleasepool {
        if (tls && !tlsAccept(fd)) {
            close(fd);
            return;
        }
        char req[4096] = {0};
        ssize_t n = connRecv(fd, req, sizeof(req) - 1);
        if (n > 0 && (req[0] < 'A' || req[0] > 'Z')) { // not an HTTP method: TLS bytes on the
            closeConn(fd);
            return; // plain port / port scans — reject instantly
        }
        // headers may span reads — wait for the terminator (or buffer exhaustion)
        while (n > 0 && n < (ssize_t)sizeof(req) - 1 && !memmem(req, (size_t)n, "\r\n\r\n", 4)) {
            ssize_t r = connRecv(fd, req + n, sizeof(req) - 1 - (size_t)n);
            if (r <= 0)
                break;
            n += r;
        }
        if (n <= 0 || !memmem(req, (size_t)n, "\r\n\r\n", 4)) {
            // Never parse a truncated header as a complete request/body.
            closeConn(fd);
            return;
        }
        char method[16] = {0}, path[256] = {0}, query[256] = {0};
        sscanf(req, "%15s %255s", method, path);
        char *q = strchr(path, '?');
        if (q) {
            snprintf(query, sizeof(query), "%s", q + 1);
            *q = 0;
        }
        char ua[256] = {0};
        char *uh = strcasestr(req, "User-Agent:");
        if (uh)
            sscanf(uh + 11, "%255[^\r\n]", ua);
        if (strcmp(path, "/hello") != 0 && strcmp(path, "/time") != 0 &&
            strcmp(path, "/input") != 0)
            fprintf(stderr, "[%s] %s %s%s%s\n", tls ? "https" : "http", method, path,
                    ua[0] ? "  UA=" : "", ua);

        // Apply the same password gate before dispatch on either listener.
        if (g_authHash && !isLoopbackPeer(fd) && !requestAuthorized(req)) {
            char ip[48];
            peerIp(fd, ip, sizeof(ip));
            fprintf(stderr, "[auth] %s %s from %s — wrong or missing password\n",
                    tls ? "https" : "http", path, ip);
            static const char body[] =
                "<!doctype html><meta charset=utf-8><meta name=viewport "
                "content='width=device-width'>"
                "<body style=\"background:#000;color:#bbb;font:17px system-ui;text-align:center;"
                "padding-top:40vh\">This screen is password protected.<br>"
                "Sign in to watch (user + password are printed by <code>make start</code> on the "
                "Mac).</body>";
            char resp[640];
            snprintf(
                resp, sizeof(resp),
                "HTTP/1.1 401 Unauthorized\r\n"
                "WWW-Authenticate: Basic realm=\"hoppscreen\", charset=\"UTF-8\"\r\n"
                "Content-Type: text/html\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s",
                strlen(body), body);
            writeStr(fd, resp);
            closeConn(fd);
            return;
        }

        if (strcmp(path, "/") == 0 || strcmp(path, "/index.html") == 0) {
            char hdr[256];
            snprintf(hdr, sizeof(hdr),
                     "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %zu\r\n"
                     "Cache-Control: no-store\r\nConnection: close\r\n\r\n",
                     (size_t)web_index_html_len);
            writeStr(fd, hdr);
            writeAll(fd, (const char *)web_index_html, web_index_html_len);
        } else if (strcmp(path, "/ca.crt") == 0) {
            if (!g_caCert)
                writeStr(fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
            else {
                char hdr[256];
                snprintf(hdr, sizeof(hdr),
                         "HTTP/1.1 200 OK\r\nContent-Type: application/x-x509-ca-cert\r\n"
                         "Content-Disposition: attachment; filename=\"hoppscreen-ca.crt\"\r\n"
                         "Content-Length: %lu\r\nConnection: close\r\n\r\n",
                         (unsigned long)g_caCert.length);
                writeStr(fd, hdr);
                writeAll(fd, g_caCert.bytes, g_caCert.length);
            }
        } else if (strcmp(path, "/time") == 0) {
            char body[64], hdr[160];
            snprintf(body, sizeof(body), "%lld",
                     (long long)(clock_gettime_nsec_np(CLOCK_REALTIME) / 1000));
            snprintf(hdr, sizeof(hdr),
                     "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\n"
                     "Content-Length: %zu\r\nConnection: close\r\n\r\n",
                     strlen(body));
            writeStr(fd, hdr);
            writeStr(fd, body);
        } else if (strcmp(path, "/hello") == 0) {
            fprintf(stderr, "[client] %s%s\n", query,
                    strstr(query, "mode=mjpeg") ? "   <-- MJPEG fallback: page is not a secure "
                                                  "context, open the https URL instead"
                                                : "");
            writeStr(fd, "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n");
        } else if (strcmp(path, "/frame.jpg") == 0) {
            uint64_t s0 = 0;
            copyJpeg(&s0);
            g_wantJpeg = 1; // fresh frame, up to ~1.5s
            for (int i = 0; i < 150; i++) {
                uint64_t s1 = 0;
                copyJpeg(&s1);
                if (s1 != s0)
                    break;
                usleep(10000);
            }
            NSData *f = copyJpeg(NULL);
            if (!f)
                writeStr(fd, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n");
            else {
                char hdr[160];
                snprintf(hdr, sizeof(hdr),
                         "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: %lu\r\n"
                         "Cache-Control: no-store\r\nConnection: close\r\n\r\n",
                         (unsigned long)f.length);
                writeStr(fd, hdr);
                writeAll(fd, f.bytes, f.length);
            }
        } else if (strcmp(path, "/silent.mp4") == 0) {
            if (!g_silentMp4)
                writeStr(fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
            else {
                char hdr[160];
                snprintf(hdr, sizeof(hdr),
                         "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: %lu\r\n"
                         "Cache-Control: max-age=3600\r\nConnection: close\r\n\r\n",
                         (unsigned long)g_silentMp4.length);
                writeStr(fd, hdr);
                writeAll(fd, g_silentMp4.bytes, g_silentMp4.length);
            }
        } else if (strcmp(path, "/stream.mjpg") == 0) {
            __sync_fetch_and_add(&g_mjpegClients, 1);
            uint64_t lastSeq = 0;
            int sent = 0;
            writeStr(fd, "HTTP/1.1 200 OK\r\n"
                         "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n"
                         "Cache-Control: no-store\r\nConnection: close\r\n\r\n");
            while (g_running) {
                @autoreleasepool {
                    uint64_t seq = 0;
                    NSData *f = copyJpeg(&seq);
                    if (!f) {
                        usleep(100000);
                        continue;
                    }
                    if (seq == lastSeq) {
                        usleep(2000);
                        continue;
                    }
                    lastSeq = seq;
                    char part[160];
                    snprintf(part, sizeof(part),
                             "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %lu\r\n\r\n",
                             (unsigned long)f.length);
                    if (!writeStr(fd, part) || !writeAll(fd, f.bytes, f.length) ||
                        !writeStr(fd, "\r\n"))
                        break;
                    sent++;
                }
            }
            fprintf(stderr, "[stream] mjpeg client done (%d frames)\n", sent);
            __sync_fetch_and_sub(&g_mjpegClients, 1);
        } else if (strcmp(path, "/h264") == 0) {
            __sync_fetch_and_add(&g_h264Clients, 1); // also wakes the encoder if idle
            // watermark FIRST, then request the IDR: if the keyframe is encoded
            // before waitAfter is sampled, the priming scan below would skip it
            // and a static screen could stay black until the next periodic IDR
            uint64_t waitAfter;
            pthread_mutex_lock(&g_lock);
            waitAfter = g_auHead;
            pthread_mutex_unlock(&g_lock);
            g_forceKey = 1;
            NSString *codec = nil, *desc = nil;
            for (int i = 0; i < 100 && g_running; i++) { // wait for encoder config (max ~5s)
                pthread_mutex_lock(&g_lock);
                codec = g_codec;
                desc = g_avcCB64;
                pthread_mutex_unlock(&g_lock);
                if (desc)
                    break;
                usleep(50000);
            }
            if (!desc) {
                writeStr(fd, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n");
                __sync_fetch_and_sub(&g_h264Clients, 1);
                closeConn(fd);
                return;
            }
            BOOL audio = g_audioWanted && !g_audioFailed;
            NSString *cfg =
                [NSString stringWithFormat:@"{\"codec\":\"%@\",\"desc\":\"%@\",\"w\":%u,\"h\":%u,"
                                           @"\"fps\":%.0f,\"arate\":%u,\"ach\":2}",
                                           codec, desc, g_pixW, g_pixH, g_fps,
                                           audio ? (unsigned)g_audioRate : 0];
            NSData *cfgData = [cfg dataUsingEncoding:NSUTF8StringEncoding];
            uint8_t cl[4] = {(uint8_t)(cfgData.length >> 24), (uint8_t)(cfgData.length >> 16),
                             (uint8_t)(cfgData.length >> 8), (uint8_t)cfgData.length};
            // small fixed send buffer: frames must not pile up invisibly in the kernel
            // (that is pure latency). Backlog is handled below by skipping to an IDR.
            int sndbuf = 512 * 1024;
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
            if (!writeStr(fd, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
                              "Cache-Control: no-store\r\nConnection: close\r\n\r\n") ||
                !writeAll(fd, cl, 4) || !writeAll(fd, cfgData.bytes, cfgData.length)) {
                __sync_fetch_and_sub(&g_h264Clients, 1);
                closeConn(fd);
                return;
            }

            // Start at the first keyframe produced after connect. If the client falls
            // behind (Wi-Fi hiccup), drop the backlog and resync on a fresh IDR rather
            // than playing seconds-old video.
            const uint64_t MAX_LAG = (uint64_t)(g_fps / 4) + 2; // ~250ms of frames
            uint64_t lastSent = 0, lastSentV = 0;               // V = video-only sequence
            BOOL primed = NO;
            int sent = 0, resyncs = 0;
            NSData *out[64];
            uint8_t fl[64];
            int64_t tss[64];
            while (g_running) {
                @autoreleasepool {
                    int cnt = 0;
                    pthread_mutex_lock(&g_lock);
                    if (!primed) {
                        for (uint64_t s = waitAfter + 1; s <= g_auHead; s++) {
                            AURec *r = &g_au[s % AU_RING];
                            if (r->seq == s && r->isKey && !r->isAudio) {
                                lastSent = s - 1;
                                lastSentV = g_auVideoHead;
                                primed = YES;
                                break;
                            }
                        }
                        if (!primed)
                            waitAfter = g_auHead;
                    }
                    if (primed) {
                        // video lag OR physical ring overflow (audio chunks share the
                        // 512 slots; a static screen + music can wrap the ring while
                        // video lag stays low — silently losing reference frames)
                        if (g_auVideoHead - lastSentV > MAX_LAG || g_auHead - lastSent >= AU_RING) {
                            primed = NO;
                            waitAfter = g_auHead;
                            lastSentV = g_auVideoHead;
                            g_forceKey = 1;
                            resyncs++;
                        } else {
                            for (uint64_t s = lastSent + 1; s <= g_auHead && cnt < 64; s++) {
                                AURec *r = &g_au[s % AU_RING];
                                if (r->seq != s)
                                    continue;
                                out[cnt] = r->data;
                                fl[cnt] = (uint8_t)((r->isKey ? 1 : 0) | (r->isRepeat ? 2 : 0) |
                                                    (r->isAudio ? 4 : 0));
                                tss[cnt] = r->ptsUs;
                                cnt++;
                                lastSent = s;
                                if (!r->isAudio)
                                    lastSentV = r->vseq;
                            }
                        }
                    }
                    if (cnt == 0) { // sleep until the encoder emits
                        struct timespec ts;
                        clock_gettime(CLOCK_REALTIME, &ts);
                        ts.tv_nsec += 100 * 1000000L;
                        if (ts.tv_nsec >= 1000000000L) {
                            ts.tv_sec++;
                            ts.tv_nsec -= 1000000000L;
                        }
                        pthread_cond_timedwait(&g_auCond, &g_lock, &ts);
                    }
                    pthread_mutex_unlock(&g_lock);
                    BOOL ok = YES;
                    for (int i = 0; i < cnt && ok; i++)
                        ok = writeRec(fd, fl[i], tss[i], out[i]);
                    for (int i = 0; i < cnt; i++)
                        out[i] = nil;
                    if (!ok)
                        break;
                    sent += cnt;
                }
            }
            fprintf(stderr, "[stream] h264 client done (%d AUs, %d lag resyncs)\n", sent, resyncs);
            __sync_fetch_and_sub(&g_h264Clients, 1);
        } else if (strcmp(path, "/input/toggle") == 0) {
            // presenter mode: flip input acceptance at runtime. HARD GATE: only
            // works when the server booted with INPUT=1 — a boot-disabled server
            // can never be talked into accepting input from the receiver side.
            char ip[48];
            if (strcmp(method, "POST") != 0 || !isJsonContent(req) || !g_inputWanted) {
                const char *msg = !g_inputWanted ? "input is off (boot again with INPUT=1)" : "";
                char why[192];
                snprintf(
                    why, sizeof(why),
                    "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: %zu\r\n"
                    "Connection: close\r\n\r\n%s",
                    strlen(msg), msg);
                writeStr(fd, why);
            } else {
                g_inputEnabled = !g_inputEnabled;
                peerIp(fd, ip, sizeof ip);
                fprintf(stderr, "[input] %s by %s\n",
                        g_inputEnabled ? "ENABLED" : "DISABLED (view-only)", ip);
                const char *b = g_inputEnabled ? "on" : "off";
                char resp[128];
                snprintf(resp, sizeof(resp),
                         "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %zu\r\n"
                         "Cache-Control: no-store\r\nConnection: close\r\n\r\n%s",
                         strlen(b), b);
                writeStr(fd, resp);
            }
        } else if (strcmp(path, "/input") == 0) {
            if (strcmp(method, "POST") != 0 || !isJsonContent(req)) {
                writeStr(
                    fd, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            } else if (!g_inputWanted || !g_inputEnabled) {
                writeStr(
                    fd,
                    "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: 12\r\n"
                    "Connection: close\r\n\r\ninput is off");
            } else {
                long cl = 0;
                char chv[32];
                headerVal(req, "Content-Length", chv, sizeof chv);
                cl = atol(chv);
                if (cl < 2 || cl > 2048) {
                    writeStr(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: "
                                 "close\r\n\r\n");
                } else {
                    char body[2049] = {0}; // small events only; bigger = abuse
                    size_t have = 0;
                    char *b0 = strstr(req, "\r\n\r\n");
                    if (b0) { // body bytes that arrived with the headers
                        size_t inReq = (size_t)(req + n - (b0 + 4));
                        if (inReq > (size_t)cl)
                            inReq = (size_t)cl;
                        memcpy(body, b0 + 4, inReq);
                        have = inReq;
                    }
                    while ((long)have < cl && have < sizeof body - 1) {
                        ssize_t r = connRecv(fd, body + have, (size_t)cl - have);
                        if (r <= 0)
                            break;
                        have += (size_t)r;
                    }
                    NSDictionary *ev =
                        have == (size_t)cl
                            ? [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:body
                                                                                     length:have]
                                                              options:0
                                                                error:nil]
                            : nil;
                    if (![ev isKindOfClass:[NSDictionary class]] || !inputEventValid(ev)) {
                        writeStr(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: "
                                     "close\r\n\r\n");
                    } else {
                        g_inputTrusted = AXIsProcessTrusted();
                        if (!g_inputLogged) {
                            char ip[48];
                            peerIp(fd, ip, sizeof ip);
                            fprintf(stderr, "[input] first event '%s' from %s — %s\n",
                                    ev[@"t"] ? [ev[@"t"] UTF8String] : "?", ip,
                                    g_inputTrusted
                                        ? "replaying on the display"
                                        : "BLOCKED, no Accessibility permission (System Settings > "
                                          "Privacy & Security > Accessibility > hoppscreen)");
                            g_inputLogged = YES;
                        }
                        if (g_inputTrusted)
                            ensureDisplayActive(); // pointer needs an active display to land on
                            dispatch_async(g_inputQ, ^{
                              applyInputEvent(ev);
                            }); // serial: keeps order
                        writeStr(fd, "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n");
                    }
                }
            }
        } else if (strcmp(path, "/status") == 0) {
            char body[1024], hdr[128];
            if (g_inputWanted)
                g_inputTrusted = AXIsProcessTrusted();
            pthread_mutex_lock(&g_lock);
            NSString *b = [NSString
                stringWithFormat:
                    @"{\"display\":%u,\"width\":%u,\"height\":%u,\"pixel_width\":%u,\"pixel_"
                    @"height\":%u,"
                    @"\"capture\":\"%s\",\"capture_fps\":%.1f,\"encode_fps\":%.1f,"
                    @"\"tls_port\":%u,\"sc_callbacks\":%llu,\"h264_total_kbits\":%llu,\"mjpeg_"
                    @"clients\":%d,\"h264_clients\":%d,\"h264\":%@,\"audio\":%@,"
                    @"\"input\":%@,\"input_wanted\":%@,\"input_enabled\":%@,\"input_trusted\":%@}",
                    g_displayID, g_dispW, g_dispH, g_pixW, g_pixH,
                    g_scStream ? "screencapturekit" : (g_cgStream ? "cgdisplaystream" : "polling"),
                    g_captureFps, g_encFps, (unsigned)g_tlsPort, (unsigned long long)g_scCallbacks,
                    (unsigned long long)(g_h264Bytes * 8 / 1000), g_mjpegClients, g_h264Clients,
                    g_vts ? @"true" : @"false",
                    (g_audioWanted && !g_audioFailed) ? @"true" : @"false",
                    (g_inputWanted && g_inputEnabled && g_inputTrusted) ? @"true" : @"false",
                    g_inputWanted ? @"true" : @"false", g_inputEnabled ? @"true" : @"false",
                    g_inputTrusted ? @"true" : @"false"];
            pthread_mutex_unlock(&g_lock);
            snprintf(body, sizeof(body), "%s", b.UTF8String);
            snprintf(hdr, sizeof(hdr),
                     "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n"
                     "Connection: close\r\n\r\n",
                     strlen(body));
            writeStr(fd, hdr);
            writeStr(fd, body);
        } else if (strcmp(path, "/fit") == 0) {
            // auto-fit: the page reports its panel. POST + JSON only (a GET here
            // could be triggered cross-site with a plain <img> tag).
            long w = 0, h = 0;
            double dpr = 2.0, hz = 0;
            if (strcmp(method, "POST") != 0 || !isJsonContent(req)) {
                writeStr(
                    fd, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            } else {
                long cl = 0;
                char chv[32];
                headerVal(req, "Content-Length", chv, sizeof chv);
                cl = atol(chv);
                char fbody[256] = {0};
                size_t have = 0;
                char *b0 = strstr(req, "\r\n\r\n");
                // Require exact bounded framing; incomplete JSON must never cause an exec.
                if (b0 && cl >= 2 && cl <= 255) {
                    size_t inReq = (size_t)(req + n - (b0 + 4));
                    if (inReq > (size_t)cl)
                        inReq = (size_t)cl;
                    memcpy(fbody, b0 + 4, inReq);
                    have = inReq;
                }
                while (cl >= 2 && cl <= 255 && (long)have < cl) {
                    ssize_t r = connRecv(fd, fbody + have, (size_t)cl - have);
                    if (r <= 0)
                        break;
                    have += (size_t)r;
                }
                NSDictionary *fj =
                    cl >= 2 && cl <= 255 && have == (size_t)cl
                        ? [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:fbody
                                                                                 length:have]
                                                          options:0
                                                            error:nil]
                        : nil;
                // Containers/null lack numeric selectors; reject them instead of crashing.
                BOOL fitValid = [fj isKindOfClass:[NSDictionary class]];
                if (fitValid)
                    for (NSString *k in @[ @"w", @"h", @"dpr", @"hz" ]) {
                        id v = fj[k];
                        if (v &&
                            (![v isKindOfClass:[NSNumber class]] || !isfinite([v doubleValue])))
                            fitValid = NO;
                    }
                if (!fitValid) {
                    writeStr(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n");
                } else {
                    w = [fj[@"w"] longValue];
                    h = [fj[@"h"] longValue];
                    dpr = [fj[@"dpr"] doubleValue];
                    hz = [fj[@"hz"] doubleValue];
                    if (dpr < 0.5 || dpr > 4)
                        dpr = 2.0;
                    if (w < 500 || w > 3840 || h < 500 || h > 2400 || w * h > 3840L * 2160L) {
                        writeStr(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n");
                    } else if (!g_autofit) {
                        writeStr(fd, "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n");
                    } else if (labs(w - (long)g_pixW) <= w / 8 && labs(h - (long)g_pixH) <= h / 8) {
                        writeStr(
                            fd,
                            "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"); // close enough
                    } else {
                        time_t now = time(NULL);
                        if (__sync_lock_test_and_set(&g_fitBusy, 1)) {
                            // Losing callers must not release the current owner's lock.
                            writeStr(fd, "HTTP/1.1 503 Busy\r\nContent-Length: 0\r\nConnection: "
                                         "close\r\n\r\n");
                        } else if (now - g_lastFit < 30) { // don't ping-pong devices
                            __sync_lock_release(&g_fitBusy);
                            writeStr(fd, "HTTP/1.1 503 Busy\r\nContent-Length: 0\r\nConnection: "
                                         "close\r\n\r\n");
                        } else {
                            g_lastFit = now;
                            // Keep ownership until exec so a second refit cannot race us.
                            BOOL hi = dpr >= 1.5; // Retina panels render at 2x points
                            uint32_t ptW = hi ? (uint32_t)((w + 1) / 2) : (uint32_t)w;
                            uint32_t ptH = hi ? (uint32_t)((h + 1) / 2) : (uint32_t)h;
                            double fps = 60.0;
                            if (hz > 0)
                                fps =
                                    hz < 30 ? 30 : (hz > 120 ? 120 : (double)((int)(hz / 10) * 10));
                            writeStr(fd, "HTTP/1.1 200 OK\r\nContent-Type: "
                                         "text/plain\r\nContent-Length: 6\r\n"
                                         "Connection: close\r\n\r\nrefit\n");
                            closeConn(fd);
                            usleep(300000);               // let the response flush
                            refitExec(ptW, ptH, fps, hi); // never returns
                        }
                    }
                }
            }
        } else {
            writeStr(fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
        }
        closeConn(fd);
    }
}

typedef struct {
    int fd;
    BOOL tls;
} ConnArg;
static volatile int g_conns = 0;
void *handleClientWrapper(void *p) {
    ConnArg a = *(ConnArg *)p;
    free(p);
    handleClient(a.fd, a.tls);
    __sync_fetch_and_sub(&g_conns, 1);
    return NULL;
}

typedef struct {
    int lfd;
    BOOL tls;
} ListenArg;
static void *serverThread(void *arg) {
    ListenArg la = *(ListenArg *)arg;
    free(arg);
    int lfd = la.lfd;
    while (g_running) {
        struct sockaddr_in cli;
        socklen_t cl = sizeof(cli);
        int fd = accept(lfd, (struct sockaddr *)&cli, &cl);
        if (fd < 0)
            continue;
        // Both listeners accept concurrently: reserve the shared budget atomically.
        if (__sync_fetch_and_add(&g_conns, 1) >= 48) {
            __sync_fetch_and_sub(&g_conns, 1);
            close(fd);
            continue;
        }
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one,
                   sizeof(one)); // no Nagle: frames leave immediately
        // DSCP AF41: congested/enterprise APs map this to the WMM video queue,
        // so stream packets jump ahead of bulk traffic. No-op on APs that ignore DSCP.
        int tos = 0x88 << 2;
        setsockopt(fd, IPPROTO_IP, IP_TOS, &tos, sizeof(tos));
        fcntl(fd, F_SETFD, FD_CLOEXEC); // active streams must not survive a /fit re-exec
        struct timeval tv = {10, 0}, stv = {3, 0};
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        // 3s receive timeout: a wedged TLS handshake or half-open request then
        // parks its thread for 3s, not 10 — mobile receivers that flap (screen
        // lock, background tab, preconnects) can't starve the connection budget
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &stv, sizeof(stv));
        ConnArg *ca = malloc(sizeof(ConnArg));
        // The worker immediately copies/frees ca: initializing after pthread_create
        // wrote into freed heap memory and also handed it garbage fd/tls values.
        if (ca) {
            ca->fd = fd;
            ca->tls = la.tls;
        }
        pthread_t t;
        if (!ca || pthread_create(&t, NULL, handleClientWrapper, ca) != 0) {
            __sync_fetch_and_sub(&g_conns, 1);
            if (ca)
                free(ca);
            close(fd);
            continue;
        }
        pthread_detach(t);
    }
    return NULL;
}

// ============================================================ main
// Resolve launch policy, create/place the display, then initialize encoder and listeners.
// Start capture and background workers only after resources and credentials are ready.
// Shutdown stops capture before releasing the virtual display owner.
static void onSig(int sig) {
    fprintf(stderr, "[sig] %d -> shutdown\n", sig);
    g_running = NO;
}

int main(int argc, char **argv) {
    // args are the LOGICAL ("looks like") size in points; the framebuffer is 2x that
    // (Retina) unless HOPPSCREEN_SCALE=1. Default 1440x900 pt = 2880x1800 px. With no
    // size args, auto-fit can recreate the display to match the first client.
    uint32_t w = argc > 1 ? (uint32_t)atoi(argv[1]) : 1440;
    uint32_t h = argc > 2 ? (uint32_t)atoi(argv[2]) : 900;
    uint16_t port = argc > 3 ? (uint16_t)atoi(argv[3]) : 8080;
    g_fps = argc > 4 ? atof(argv[4]) : 120.0; // high-hz panels: 120 halves per-frame latency
    // env fallbacks: a launcher can set port/fps WITHOUT pinning
    // the size — positional args would disable auto-fit. Positional args win.
    if (argc <= 3) {
        const char *e = getenv("HOPPSCREEN_PORT");
        if (e && atoi(e) > 0 && atoi(e) < 65536)
            port = (uint16_t)atoi(e);
    }
    if (argc <= 4) {
        const char *e = getenv("HOPPSCREEN_FPS");
        double f = e ? atof(e) : 0;
        if (isfinite(f) && f >= 1 && f <= 120)
            g_fps = f;
    }
    BOOL hiDPI = !(getenv("HOPPSCREEN_SCALE") && atoi(getenv("HOPPSCREEN_SCALE")) == 1);
    if (!w || !h || !port || w < 500 || h < 500 || w > 3840 || h > 2400 || !isfinite(g_fps) ||
        g_fps < 1 || g_fps > 120) { // atof("nan") would pass < and > checks
        fprintf(stderr,
                "usage: %s [width_pt height_pt [port [fps]]]   (default 1440 900 8080 120)\n",
                argv[0]);
        return 2;
    }

    g_port = port; // for /fit's re-exec
    {              // absolute path: cwd may differ
        uint32_t n = (uint32_t)sizeof(g_exePath) - 1;
        if (_NSGetExecutablePath(g_exePath, &n) != 0)
            g_exePath[0] = 0;
    }
    // auto-fit: on with no size args, off when the size was pinned; HOPPSCREEN_AUTOFIT forces
    {
        const char *af = getenv("HOPPSCREEN_AUTOFIT");
        g_autofit = (argc > 1) ? (af && atoi(af) == 1) : !(af && atoi(af) == 0);
        const char *lf = getenv("HOPPSCREEN_LASTFIT"); // rate-limit window survives execs
        if (lf)
            g_lastFit = (time_t)atoll(lf);
    }

    signal(SIGINT, onSig);
    signal(SIGTERM, onSig);
    signal(SIGHUP, onSig);
    signal(SIGPIPE, SIG_IGN);

    VirtualDisplay *vd = [[VirtualDisplay alloc] init];
    NSString *err = nil;
    if (![vd startWithWidth:w height:h hiDPI:hiDPI refreshRate:g_fps error:&err]) {
        fprintf(stderr, "virtual display failed: %s\n", err.UTF8String ?: "?");
        return 1;
    }
    g_displayID = vd.displayID;
    g_dispW = vd.servedWidth;
    g_dispH = vd.servedHeight;
    g_pixW = vd.pixelWidth;
    g_pixH = vd.pixelHeight;
    printf("virtual display #%u looks like %ux%u, %ux%u px%s\n", g_displayID, g_dispW, g_dispH,
           g_pixW, g_pixH, hiDPI ? " (HiDPI)" : "");

    // deterministic placement: immediately right of the rightmost display, top-aligned with it
    {
        CGDirectDisplayID ids[16];
        uint32_t cnt = 0;
        CGGetActiveDisplayList(16, ids, &cnt);
        CGFloat right = 0, top = 0;
        for (uint32_t i = 0; i < cnt; i++) {
            if (ids[i] == g_displayID)
                continue;
            CGRect b = CGDisplayBounds(ids[i]);
            if (b.origin.x + b.size.width > right) {
                right = b.origin.x + b.size.width;
                top = b.origin.y;
            }
        }
        CGDisplayConfigRef cfg;
        if (CGBeginDisplayConfiguration(&cfg) == kCGErrorSuccess) {
            CGConfigureDisplayOrigin(cfg, g_displayID, (int32_t)right, (int32_t)top);
            CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
        }
        CGRect fb = CGDisplayBounds(g_displayID);
        printf("arranged right of existing displays: origin (%g, %g)\n", fb.origin.x, fb.origin.y);
    }

    g_encQ = dispatch_queue_create("hoppscreen.encode",
                                   dispatch_queue_attr_make_with_qos_class(
                                       DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    g_audioQ = dispatch_queue_create("hoppscreen.audio", DISPATCH_QUEUE_SERIAL);
    g_audioWanted = !(getenv("HOPPSCREEN_AUDIO") && atoi(getenv("HOPPSCREEN_AUDIO")) == 0);
    g_inputWanted = getenv("HOPPSCREEN_INPUT") &&
                    atoi(getenv("HOPPSCREEN_INPUT")) != 0; // opt-in: view-only by default
    g_scrollInvert =
        (getenv("HOPPSCREEN_SCROLL_INVERT") && atoi(getenv("HOPPSCREEN_SCROLL_INVERT")) != 0);
    if (g_inputWanted) {
        g_inputQ = dispatch_queue_create("hoppscreen.input", DISPATCH_QUEUE_SERIAL);
        g_evtSrc = CGEventSourceCreate(
            kCGEventSourceStateCombinedSessionState); // once, not lazily per thread
        g_inputTrusted = AXIsProcessTrusted();
        if (!g_inputTrusted) {
            fprintf(stderr, "[input] touch input needs the Accessibility permission —\n"
                            "[input] allow hoppscreen in System Settings > Privacy & Security > "
                            "Accessibility\n");
            NSDictionary *opt = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt : @YES};
            AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opt); // system dialog, once
        } else
            fprintf(stderr, "[input] touch input ready (accessibility granted)\n");
    }
    if (!startH264Encoder())
        fprintf(stderr, "continuing without h264 (mjpeg only)\n");

    // resolve next to the binary, not the caller's cwd (g_exePath is absolute,
    // so a PATH launch doesn't make us read/write assets in whatever cwd)
    NSString *exeDir = [[NSString stringWithUTF8String:g_exePath[0] ? g_exePath : argv[0]]
        stringByDeletingLastPathComponent];
    g_silentMp4 =
        [NSData dataWithContentsOfFile:[exeDir stringByAppendingPathComponent:@"silent.mp4"]];
    if (!g_silentMp4)
        fprintf(stderr, "[init] WARNING: silent.mp4 not found — screen-wakelock video disabled\n");

    // login credentials for the LAN (see the "password protection" section)
    {
        const char *envPw = getenv("HOPPSCREEN_PASSWORD");
        NSString *user = nil, *pass = nil, *src = nil;
        if (envPw && envPw[0]) {
            pass = @(envPw);
            src = @"HOPPSCREEN_PASSWORD env, any username";
        } else {
            NSString *pwFile = [exeDir stringByAppendingPathComponent:@"passwd"];
            NSString *line = [[NSString stringWithContentsOfFile:pwFile
                                                        encoding:NSUTF8StringEncoding
                                                           error:nil]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSRange c = [line rangeOfString:@":"];
            if (line.length) {
                user = c.location == NSNotFound ? nil : [line substringToIndex:c.location];
                pass = c.location == NSNotFound ? line : [line substringFromIndex:c.location + 1];
                src = pwFile.lastPathComponent;
            }
            if (pass.length == 0) { // first run: generate and save
                static const char *abc = "abcdefghjkmnpqrstuvwxyz23456789"; // no 0/O, 1/l/I
                NSMutableString *gen = [NSMutableString stringWithCapacity:8];
                for (int i = 0; i < 8; i++)
                    [gen appendFormat:@"%c", abc[arc4random_uniform((uint32_t)strlen(abc))]];
                user = @"hopp";
                pass = gen;
                if ([[NSString stringWithFormat:@"%@:%@\n", user, pass]
                        writeToFile:pwFile
                         atomically:YES
                           encoding:NSUTF8StringEncoding
                              error:nil]) {
                    chmod(pwFile.fileSystemRepresentation, 0600);
                    src = @"passwd (generated, mode 600)";
                } else {
                    fprintf(
                        stderr,
                        "[auth] WARNING: could not write %s — password valid for this run only\n",
                        pwFile.UTF8String);
                    src = @"generated, NOT saved";
                }
            }
        }
        g_authUser = user;
        g_authHash = sha256(pass);
        printf("[auth] password protection ON — user \"%s\"  password \"%s\"  (%s)\n",
               user.UTF8String ?: "<any>", pass.UTF8String, src.UTF8String);
    }

    g_httpFd = listenSocket(port);
    if (g_httpFd < 0)
        return 1;

    // HTTPS: certs.sh (run by make) keeps certs/server.p12 valid for the current IPs
    int tfd = -1;
    {
        const char *tp = getenv("HOPPSCREEN_TLS_PORT");
        uint16_t tlsPort = tp ? (uint16_t)atoi(tp) : (uint16_t)(port + 363); // 8080 -> 8443
        NSString *certDir = [exeDir stringByAppendingPathComponent:@"certs"];
        g_caCert =
            [NSData dataWithContentsOfFile:[certDir stringByAppendingPathComponent:@"ca.crt"]];
        if (tlsPort && loadTLSIdentity([certDir stringByAppendingPathComponent:@"server.p12"])) {
            tfd = listenSocket(tlsPort);
            if (tfd >= 0) {
                g_tlsPort = tlsPort;
                g_tlsFd = tfd;
            }
        } else if (tlsPort) {
            fprintf(stderr, "[tls] no certs/server.p12 — HTTPS disabled (run ./certs.sh)\n");
        }
    }

    if (g_tlsPort) {
        printf("serving — open on the receiver (secure = sharp H.264, direct over Wi-Fi):\n");
        printLocalURLs("https", g_tlsPort);
        printf("  first time: install certs/ca.crt on the receiver (README: 'Why HTTPS'),\n"
               "  or just tap Advanced -> Proceed through Chrome's warning\n");
        printf("  plain http (MJPEG fallback) on :%u\n", port);
    } else {
        printf("serving — open on the receiver:\n");
        printLocalURLs("http", port);
        printf("  (no certs/server.p12 — MJPEG only; run ./certs.sh for sharp H.264)\n");
    }
    printf("  auto-fit: %s\n",
           g_autofit ? "on — the display will match the first client's panel"
                     : "off — size pinned by launch args (HOPPSCREEN_AUTOFIT=1 to enable)");
    printf("  audio: %s\n",
           g_audioWanted ? "system sound rides the /h264 stream (HOPPSCREEN_AUDIO=0 disables)"
                         : "off (HOPPSCREEN_AUDIO=0)");
    printf("  input: %s\n",
           !g_inputWanted
               ? "off — view-only (start with INPUT=1 to allow touch control)"
               : (g_inputTrusted ? "receiver touches click the Mac (toggle live from the page)"
                                 : "WAITING — grant Accessibility, then it goes live"));
    fflush(stdout);

    if (getenv("HOPPSCREEN_POLL")) { // debug: skip push APIs entirely
        fprintf(stderr, "HOPPSCREEN_POLL set — CGDisplayCreateImage polling loop\n");
        startPolling();
    } else if (startSCCapture()) {
        pthread_t wd;
        pthread_create(&wd, NULL, captureWatchdog, NULL);
        pthread_detach(wd);
    } else {
        fprintf(stderr, "falling back to CGDisplayCreateImage polling loop\n");
        startPolling();
    }
    pthread_t srvT, jpgT, refT;
    ListenArg *la = malloc(sizeof(ListenArg));
    la->lfd = g_httpFd;
    la->tls = NO;
    pthread_create(&srvT, NULL, serverThread, la);
    pthread_detach(srvT);
    if (tfd >= 0) {
        pthread_t tlsT;
        ListenArg *tla = malloc(sizeof(ListenArg));
        tla->lfd = tfd;
        tla->tls = YES;
        pthread_create(&tlsT, NULL, serverThread, tla);
        pthread_detach(tlsT);
    }
    pthread_create(&jpgT, NULL, jpegThread, NULL);
    pthread_detach(jpgT);
    pthread_create(&refT, NULL, refreshThread, NULL);
    pthread_detach(refT);

    uint64_t lastBytes = 0, lastOut = 0, lastCb = 0;
    while (g_running) {
        for (int i = 0; i < 10 && g_running; i++)
            sleep(1);
        if (!g_running)
            break;
        uint64_t b = g_h264Bytes, o = g_encOutFrames, cb = g_scCallbacks;
        if (g_h264Clients || g_mjpegClients || o != lastOut || getenv("HOPPSCREEN_DEBUG"))
            fprintf(stderr,
                    "[status] capture=%.1ffps encout=%.1ffps enc=%.1fms h264=%.0fkbit/s "
                    "clients(h264=%d mjpeg=%d) sccb=%llu%s\n",
                    g_captureFps, (double)(o - lastOut) / 10.0, g_encLatMs,
                    (double)(b - lastBytes) * 8 / 10000, g_h264Clients, g_mjpegClients,
                    (unsigned long long)(cb - lastCb),
                    g_capMs > 0 ? [NSString stringWithFormat:@" poll=%.0fms", g_capMs].UTF8String
                                : "");
        lastBytes = b;
        lastOut = o;
        lastCb = cb;
    }

    fprintf(stderr, "shutting down...\n");
    close(g_httpFd);
    if (tfd >= 0)
        close(tfd);
    if (g_scStream) {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [g_scStream stopCaptureWithCompletionHandler:^(NSError *e) {
          (void)e;
          dispatch_semaphore_signal(done);
        }];
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    }
    if (g_cgStream && MyCGDisplayStreamStop)
        MyCGDisplayStreamStop((MyCGDisplayStreamRef)g_cgStream);
    if (g_vts) {
        VTCompressionSessionCompleteFrames(g_vts, kCMTimeInvalid);
        VTCompressionSessionInvalidate(g_vts);
    }
    [vd stop];
    return 0;
}
