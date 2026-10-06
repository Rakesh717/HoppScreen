// pad6display — wireless display extender server (macOS -> Xiaomi Pad 6 browser)
// Pure ObjC, no deps.
//   - Virtual display via private CGVirtualDisplay ObjC API (proven on macOS 26)
//   - Capture via CGDisplayCreateImage (dlsym; header-obsoleted but functional)
//   - Encodes H.264 (VideoToolbox, hardware) and/or MJPEG
//   - HTTP endpoints:
//       /            -> player page (WebCodecs H.264, MJPEG fallback)
//       /h264        -> [4B len][JSON cfg] then frames: [4B len][1B flags][AVCC AU]
//       /stream.mjpg -> MJPEG multipart (fallback)
//       /frame.jpg   -> single JPEG (debug)
//       /status      -> JSON stats
//
//   clang -fobjc-arc -O2 -I. -framework Foundation -framework CoreGraphics \
//       -framework AppKit -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
//       server.m VirtualDisplay.m -o pad6display
//
// Usage: pad6display [width_pt height_pt [port [fps]]]   defaults: 1440 900 8080 60 (HiDPI -> 2880x1800 px)

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AppKit/AppKit.h>
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
#import "virtualdisplay.h"

// ============================================================ shared state
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_auCond = PTHREAD_COND_INITIALIZER;   // signalled on every new AU
static volatile BOOL g_running = YES;
static uint32_t g_displayID = 0, g_dispW = 0, g_dispH = 0;   // logical size (points)
static uint32_t g_pixW = 0, g_pixH = 0;                       // framebuffer size (pixels) = what we encode
static double g_fps = 60.0;
static volatile int g_forceKey = 0;            // next encoded frame must be an IDR (new client / resync)
static volatile uint64_t g_lastSubmitNs = 0;   // host time of the last frame handed to the encoder
static NSString *g_codec = nil;                // "avc1.PPCCLL" derived from the real avcC
static dispatch_queue_t g_encQ = NULL;         // serializes ALL encoder submits (SC frames + refresh)

static volatile int g_mjpegClients = 0, g_h264Clients = 0;

// JPEG (latest frame only)
static NSData *g_jpeg = nil;
static uint64_t g_jpegSeq = 0;

// H.264 ring of AVCC access units
typedef struct {
    uint64_t seq;
    BOOL isKey;
    int64_t ptsUs;
    NSData *data;          // AVCC (4-byte NALU length prefixes), no SPS/PPS in-band
} AURec;
#define AU_RING 512
static AURec g_au[AU_RING];
static uint64_t g_auHead = 0;          // last written seq (0 = none yet)
static NSString *g_avcCB64 = nil;      // base64 avcC description
static volatile uint64_t g_h264Bytes = 0;
static volatile uint64_t g_encOutFrames = 0;   // AUs emitted by encoder callback
static volatile double g_encFps = 0;
static uint64_t g_encFrames = 0;
static volatile double g_captureFps = 0;
static VTCompressionSessionRef g_vts = NULL;
static CVPixelBufferPoolRef g_pbPool = NULL;   // recycled BGRA buffers for encode input
static uint64_t g_capFrames = 0;               // total capture frames
static SCStream *g_scStream = nil;             // ScreenCaptureKit stream (preferred capture)
static id g_scOut = nil;                       // SCStream only weakly references its output — must be kept alive here
static CVPixelBufferRef g_latestPB = nil;      // latest BGRA frame (retained)
static volatile uint64_t g_scCallbacks = 0;    // raw delivery counter (diagnostics)
static pthread_mutex_t g_jpegLock = PTHREAD_MUTEX_INITIALIZER;
static CGImageRef g_jpegImg = NULL;              // latest frame for the jpeg thread
static double g_capMs = 0.0;                     // avg CGDisplayCreateImage ms
static NSData *g_silentMp4 = nil;                // silent loop video (screen wakelock)
static CGDisplayStreamRef g_cgStream = NULL;   // CGDisplayStream push capture (2nd try)
// CGDisplayStream API: obsoleted from macOS 15 headers but the push machinery
// still exists in CoreGraphics — resolve dynamically and redeclare the ABI.
static void processFrame(CVPixelBufferRef pb);
typedef struct MyCGDisplayStream *MyCGDisplayStreamRef;
enum { kMyFrameComplete = 0, kMyFrameIdle = 1, kMyFrameRefresh = 2,
       kMyFrameDepressed = 3, kMyFrameRemoved = 4 };
typedef void (^MyFrameHandler)(int32_t status, uint64_t time, IOSurfaceRef surface,
                               void *updateRef);
static MyCGDisplayStreamRef (*MyCGDisplayStreamCreateWithDispatchQueue)(
    uint32_t displayID, size_t w, size_t h, uint32_t pf, CFDictionaryRef props,
    dispatch_queue_t q, MyFrameHandler handler);
static int32_t (*MyCGDisplayStreamStart)(MyCGDisplayStreamRef);
static int32_t (*MyCGDisplayStreamStop)(MyCGDisplayStreamRef);

static void cgFrameHandler(int32_t status, uint64_t time,
                           IOSurfaceRef surface, void *updateRef) {
    (void)time; (void)updateRef;
    if (status != kMyFrameComplete || !surface) return;
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreateWithIOSurface(NULL, surface, NULL, &pb);
    if (!pb) return;
    processFrame(pb);
    CFRelease(pb);
}

static BOOL startCGStreamCapture(void) {
    if (!MyCGDisplayStreamCreateWithDispatchQueue) {
        void *h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
        MyCGDisplayStreamCreateWithDispatchQueue =
            (MyCGDisplayStreamRef (*)(uint32_t, size_t, size_t, uint32_t, CFDictionaryRef,
                                      dispatch_queue_t, MyFrameHandler))
            dlsym(h, "CGDisplayStreamCreateWithDispatchQueue");
        MyCGDisplayStreamStart = (int32_t (*)(MyCGDisplayStreamRef))dlsym(h, "CGDisplayStreamStart");
        MyCGDisplayStreamStop = (int32_t (*)(MyCGDisplayStreamRef))dlsym(h, "CGDisplayStreamStop");
        if (!MyCGDisplayStreamCreateWithDispatchQueue || !MyCGDisplayStreamStart) {
            fprintf(stderr, "[cg] CGDisplayStream symbols not available\n");
            return NO;
        }
    }
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(g_displayID);
    if (!mode) return NO;
    size_t pw = CGDisplayModeGetPixelWidth(mode), ph = CGDisplayModeGetPixelHeight(mode);
    CFRelease(mode);
    dispatch_queue_t q = g_encQ;
    NSDictionary *props = @{@"kCGDisplayStreamShowCursor": @YES};
    MyCGDisplayStreamRef st = MyCGDisplayStreamCreateWithDispatchQueue(
        g_displayID, pw, ph, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)props, q,
        ^(int32_t s, uint64_t t, IOSurfaceRef surf, void *u) { cgFrameHandler(s, t, surf, u); });
    if (!st) return NO;
    if (MyCGDisplayStreamStart(st) != 0) { CFRelease(st); return NO; }
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
    g_jpeg = f; g_jpegSeq++;
    pthread_mutex_unlock(&g_lock);
}
static NSData *copyJpeg(uint64_t *seqOut) {
    pthread_mutex_lock(&g_lock);
    NSData *f = [g_jpeg copy];
    if (seqOut) *seqOut = g_jpegSeq;
    pthread_mutex_unlock(&g_lock);
    return f;
}

// ============================================================ H.264 encoder
static void vtOutput(void *refCon, void *srcRefCon, OSStatus status,
                     VTEncodeInfoFlags flags, CMSampleBufferRef sb) {
    if (status != noErr || !sb || !CMSampleBufferIsValid(sb)) return;
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    if (!bb) return;
    size_t len = CMBlockBufferGetDataLength(bb);
    if (len <= 0) return;

    NSData *data = [NSMutableData dataWithLength:len];
    if (CMBlockBufferCopyDataBytes(bb, 0, len, ((NSMutableData *)data).mutableBytes) != kCMBlockBufferNoErr) return;

    // keyframe? (sync samples lack kCMSampleAttachmentKey_NotSync == true)
    BOOL isKey = YES;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (atts && CFArrayGetCount(atts) > 0) {
        CFDictionaryRef dict = CFArrayGetValueAtIndex(atts, 0);
        CFBooleanRef notSync = CFDictionaryGetValue(dict, kCMSampleAttachmentKey_NotSync);
        isKey = (notSync != kCFBooleanTrue);
    }
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
    int64_t ptsUs = (int64_t)(CMTimeGetSeconds(pts) * 1000000.0);

    pthread_mutex_lock(&g_lock);
    uint64_t seq = g_auHead + 1;
    AURec *slot = &g_au[seq % AU_RING];
    slot->seq = seq; slot->isKey = isKey; slot->ptsUs = ptsUs; slot->data = data;
    g_auHead = seq;
    g_h264Bytes += len;
    g_encOutFrames++;

    if (isKey) {
        CMFormatDescriptionRef md = CMSampleBufferGetFormatDescription(sb);
        if (md) {
            CFDictionaryRef exts = CMFormatDescriptionGetExtensions(md);
            CFDictionaryRef atoms = exts ? CFDictionaryGetValue(exts, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) : NULL;
            CFDataRef avcC = atoms ? CFDictionaryGetValue(atoms, CFSTR("avcC")) : NULL;
            if (avcC && CFDataGetLength(avcC) >= 4) {
                NSData *d = (__bridge NSData *)avcC;
                NSString *b64 = [d base64EncodedStringWithOptions:0];
                if (![b64 isEqualToString:g_avcCB64]) {
                    const uint8_t *a = d.bytes;   // [1]=profile [2]=constraints [3]=level
                    g_codec = [NSString stringWithFormat:@"avc1.%02x%02x%02x", a[1], a[2], a[3]];
                    g_avcCB64 = b64;
                    fprintf(stderr, "[h264] avcC captured (%zu bytes) codec=%s\n",
                            (size_t)d.length, g_codec.UTF8String);
                }
            }
        }
    }
    pthread_cond_broadcast(&g_auCond);
    pthread_mutex_unlock(&g_lock);
}

static uint64_t nowNs(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

// single entry point into the encoder (call only on g_encQ or the polling thread)
static void vtSubmit(CVPixelBufferRef pb) {
    if (!g_vts || !pb) return;
    uint64_t t = nowNs();
    static uint64_t lastPts = 0;
    if (t <= lastPts) t = lastPts + 1;            // strictly increasing PTS
    lastPts = t;
    CMTime pts = CMTimeMake((int64_t)(t / 1000), 1000000);
    NSDictionary *props = nil;
    if (__sync_lock_test_and_set(&g_forceKey, 0))
        props = @{(__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES};
    OSStatus est = VTCompressionSessionEncodeFrame(g_vts, pb, pts, kCMTimeInvalid,
                                                   (__bridge CFDictionaryRef)props, NULL, NULL);
    if (est != noErr) {
        static int ewarn = 0;
        if (!ewarn++) fprintf(stderr, "[h264] EncodeFrame failed: %d\n", (int)est);
    }
    g_lastSubmitNs = t;
    g_encFrames++;
}

static void setNum(CFStringRef key, double v) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberDoubleType, &v);
    OSStatus st = VTSessionSetProperty(g_vts, key, n);
    if (st != noErr) fprintf(stderr, "[h264] warning: property %s rejected (%d)\n",
                             CFStringGetCStringPtr(key, kCFStringEncodingUTF8) ?: "?", (int)st);
    CFRelease(n);
}

static BOOL startH264Encoder(void) {
    NSDictionary *encSpec = @{
        (__bridge NSString *)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: @YES,
        (__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES,
    };
    OSStatus st = VTCompressionSessionCreate(NULL, g_pixW, g_pixH, kCMVideoCodecType_H264,
                                             (__bridge CFDictionaryRef)encSpec, NULL, NULL,
                                             vtOutput, NULL, &g_vts);
    if (st != noErr) { fprintf(stderr, "[h264] VTCompressionSessionCreate failed: %d\n", (int)st); return NO; }
    VTSessionSetProperty(g_vts, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    // High profile: ~15-20% better quality/bit than Main -> sharper text at the same rate.
    // Level auto-picks 5.1/5.2 for 2880x1800@60 (codec string is derived from the real avcC).
    VTSessionSetProperty(g_vts, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel);
    VTSessionSetProperty(g_vts, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse); // no B-frames => low latency
    VTSessionSetProperty(g_vts, kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse);
    setNum(kVTCompressionPropertyKey_ExpectedFrameRate, g_fps);
    // bitrate scales with pixel count: ~28 Mbps for 2880x1800@60. Desktop content is
    // mostly static so the real average is far lower; the headroom keeps text crisp
    // while scrolling.
    double bps = (double)g_pixW * g_pixH * g_fps * 0.09;
    if (bps < 8e6) bps = 8e6;
    if (bps > 40e6) bps = 40e6;
    setNum(kVTCompressionPropertyKey_AverageBitRate, bps);
    // hard cap on bursts (bytes per 1s window) so one huge frame can't flood Wi-Fi
    {
        double bytesPerSec = bps * 1.5 / 8.0, one = 1.0;
        CFNumberRef b = CFNumberCreate(NULL, kCFNumberDoubleType, &bytesPerSec);
        CFNumberRef s1 = CFNumberCreate(NULL, kCFNumberDoubleType, &one);
        CFArrayRef lim = CFArrayCreate(NULL, (const void *[]){b, s1}, 2, &kCFTypeArrayCallBacks);
        VTSessionSetProperty(g_vts, kVTCompressionPropertyKey_DataRateLimits, lim);
        CFRelease(lim); CFRelease(b); CFRelease(s1);
    }
    // keyframes are big: avoid periodic ones (they cause a visible hitch every
    // interval). New clients / resyncs request an IDR explicitly via g_forceKey.
    setNum(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 60.0);
    VTSessionSetProperty(g_vts, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2);
    VTSessionSetProperty(g_vts, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2);
    VTSessionSetProperty(g_vts, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    st = VTCompressionSessionPrepareToEncodeFrames(g_vts);
    if (st != noErr) { fprintf(stderr, "[h264] PrepareToEncode failed: %d\n", (int)st); return NO; }

    // own BGRA buffer pool (polling path) — fresh large CVPixelBuffers per frame fail under churn
    NSDictionary *poolAttrs = @{(__bridge NSString *)kCVPixelBufferPoolMinimumBufferCountKey: @6};
    NSDictionary *pbAttrs = @{
        (__bridge NSString *)kCVPixelBufferWidthKey: @(g_pixW),
        (__bridge NSString *)kCVPixelBufferHeightKey: @(g_pixH),
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (__bridge NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVReturn pr = CVPixelBufferPoolCreate(NULL, (__bridge CFDictionaryRef)poolAttrs,
                                          (__bridge CFDictionaryRef)pbAttrs, &g_pbPool);
    if (pr != kCVReturnSuccess) fprintf(stderr, "[h264] buffer pool create failed: %d (will alloc per-frame)\n", (int)pr);
    fprintf(stderr, "[h264] encoder ready (%ux%u px, hw, High, %.0f Mbps, IDR on demand)\n",
            g_pixW, g_pixH, bps / 1e6);
    return YES;
}

static void drawCursorOverlay(CGContextRef ctx);

static void encodeH264(CGImageRef img) {
    if (!g_vts) return;
    CVPixelBufferRef pb = NULL;
    if (g_pbPool) CVPixelBufferPoolCreatePixelBuffer(NULL, g_pbPool, &pb);
    if (!pb) {
        static int warned = 0;
        if (!warned++) fprintf(stderr, "[h264] CVPixelBuffer unavailable — dropping frames\n");
        return;
    }
    CVPixelBufferLockBaseAddress(pb, 0);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb),
                                             CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb),
                                             8, CVPixelBufferGetBytesPerRow(pb), cs,
                                             kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb)), img);
        drawCursorOverlay(ctx);   // CGDisplayCreateImage omits the cursor
        CFRelease(ctx);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    vtSubmit(pb);
    CVPixelBufferRelease(pb);
}

// ============================================================ ScreenCaptureKit
static void processFrame(CVPixelBufferRef pb);
@interface SCOut : NSObject <SCStreamOutput, SCStreamDelegate>
@end
static volatile int g_scFailed = 0;            // set by the delegate when SCK stops the stream
@implementation SCOut
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    (void)stream;
    fprintf(stderr, "[sc] stream stopped: %s (code %ld)\n",
            error.localizedDescription.UTF8String ?: "?", (long)error.code);
    g_scFailed = 1;
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type {
    (void)stream;
    if (type != SCStreamOutputTypeScreen) return;
    g_scCallbacks++;
    if (!CMSampleBufferIsValid(sb)) return;
    // SCK sends "idle" status samples (no pixels) while nothing changes — skip those
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (atts && CFArrayGetCount(atts) > 0) {
        NSDictionary *a = (__bridge NSDictionary *)CFArrayGetValueAtIndex(atts, 0);
        NSNumber *status = a[SCStreamFrameInfoStatus];
        if (status && status.integerValue != SCFrameStatusComplete) return;
    }
    CVPixelBufferRef pb = (CVPixelBufferRef)CMSampleBufferGetImageBuffer(sb);
    if (pb) processFrame(pb);
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
        if (g_latestPB) CFRelease(g_latestPB);
        CFRetain(pb);
        g_latestPB = pb;
        g_capFrames++;
        pthread_mutex_unlock(&g_lock);

        static uint64_t lastCount = 0, lastTick = 0;
        uint64_t now = nowNs();
        if (!lastTick) lastTick = now;
        double el = (now - lastTick) / 1e9;
        if (el >= 2.0) {
            g_captureFps = (g_capFrames - lastCount) / el;
            g_encFps = g_captureFps;
            lastCount = g_capFrames; lastTick = now;
        }
        if (encoderWanted()) vtSubmit(pb);
    }
}

// Push capture is damage-driven: a static screen yields no frames. Re-submit the
// last frame (a) immediately when an IDR is requested (new client / resync) and
// (b) a few times per second while idle — near-free P-frames that let the encoder
// refine a static desktop to full sharpness.
static void *refreshThread(void *arg) {
    (void)arg;
    while (g_running) {
        usleep(15000);
        if (!g_encQ || !encoderWanted()) continue;
        uint64_t since = nowNs() - g_lastSubmitNs;
        if (!(g_forceKey && since > 8000000ULL) && since < 250000000ULL) continue;
        pthread_mutex_lock(&g_lock);
        CVPixelBufferRef pb = g_latestPB;
        if (pb) CFRetain(pb);
        pthread_mutex_unlock(&g_lock);
        if (!pb) continue;
        dispatch_async(g_encQ, ^{
            if (nowNs() - g_lastSubmitNs > 8000000ULL) vtSubmit(pb);   // a real frame may have just landed
            CFRelease(pb);
        });
    }
    return NULL;
}

static BOOL startSCCapture(void) {
    @autoreleasepool {
        __block SCShareableContent *content = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:NO
                                                     completionHandler:^(SCShareableContent *c, NSError *err) {
            if (err) fprintf(stderr, "[sc] shareable content error: %s\n", err.localizedDescription.UTF8String ?: "?");
            content = c;
            dispatch_semaphore_signal(sem);
        }];
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
            fprintf(stderr, "[sc] ShareableContent timed out\n");
            return NO;
        }
        if (!content) { fprintf(stderr, "[sc] no shareable content (Screen Recording permission?)\n"); return NO; }

        SCDisplay *disp = nil;
        for (SCDisplay *d in content.displays) if (d.displayID == g_displayID) { disp = d; break; }
        if (!disp) { fprintf(stderr, "[sc] virtual display %u not found\n", g_displayID); return NO; }

        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:disp excludingWindows:@[]];
        SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
        cfg.width = g_pixW; cfg.height = g_pixH;          // full Retina framebuffer, no scaling
        cfg.pixelFormat = kCVPixelFormatType_32BGRA;
        cfg.minimumFrameInterval = CMTimeMake(1, (int32_t)(g_fps + 0.5));
        cfg.queueDepth = 5;                               // we retain 1 (latest) + encoder in-flight
        cfg.showsCursor = YES;                            // WindowServer composites the real cursor
        cfg.scalesToFit = NO;
        cfg.colorSpaceName = kCGColorSpaceSRGB;

        g_scOut = [SCOut new];                            // strong ref: SCStream holds outputs weakly
        SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:g_scOut];
        NSError *err = nil;
        if (![stream addStreamOutput:g_scOut type:SCStreamOutputTypeScreen
                   sampleHandlerQueue:g_encQ
                                error:&err]) {
            fprintf(stderr, "[sc] addStreamOutput failed: %s\n", err.localizedDescription.UTF8String ?: "?");
            return NO;
        }
        __block BOOL ok = YES;
        dispatch_semaphore_t sem2 = dispatch_semaphore_create(0);
        [stream startCaptureWithCompletionHandler:^(NSError *e) {
            if (e) { ok = NO; fprintf(stderr, "[sc] startCapture failed: %s\n", e.localizedDescription.UTF8String ?: "?"); }
            dispatch_semaphore_signal(sem2);
        }];
        if (dispatch_semaphore_wait(sem2, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
            fprintf(stderr, "[sc] startCapture timed out\n");
            return NO;
        }
        if (!ok) return NO;
        g_scStream = stream;
        g_scFailed = 0;
        fprintf(stderr, "[sc] ScreenCaptureKit streaming %ux%u px @%.0f (cursor composited by WindowServer)\n",
                g_pixW, g_pixH, g_fps);
        return YES;
    }
}

static void *captureThread(void *arg);
static void *cursorThread(void *arg);
static BOOL startCGStreamCapture(void);

static void startPolling(void) {
    pthread_t capT, curT;
    pthread_create(&curT, NULL, cursorThread, NULL);   // only polling needs a manual cursor overlay
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
    if (g_scStream && g_scCallbacks > 0) {   // SCK always delivers a few samples at start
        // healthy: keep watching for a stream error (sleep/wake, display reconfig).
        // Silence alone is normal — SCK stops sending samples for a static screen.
        while (g_running) {
            sleep(1);
            if (!g_scFailed) continue;
            fprintf(stderr, "[sc] capture failed — restarting ScreenCaptureKit\n");
            SCStream *old = g_scStream; g_scStream = nil;
            if (old) [old stopCaptureWithCompletionHandler:nil];
            while (g_running && !startSCCapture()) sleep(2);
            g_forceKey = 1;
        }
        return NULL;
    }
    if (!g_scStream) return NULL;
    fprintf(stderr, "[sc] no frames from ScreenCaptureKit — trying CGDisplayStream\n");
    [g_scStream stopCaptureWithCompletionHandler:nil];
    g_scStream = nil;
    if (!startCGStreamCapture()) { startPolling(); return NULL; }
    if (getenv("PAD6_KEEP_PUSH")) {  // debug: hold push capture, never fall back
        fprintf(stderr, "[cg] PAD6_KEEP_PUSH set — holding push capture\n");
        return NULL;
    }
    uint64_t last = g_capFrames;
    int stalls = 0;
    for (int i = 0; i < 15; i++) {          // observe up to 30s
        sleep(2);
        uint64_t cur = g_capFrames;
        uint64_t d = cur - last; last = cur;
        stalls = (d < 3) ? stalls + 1 : 0;  // <1.5fps counts as stalled
        if (stalls >= 2) break;
    }
    if (stalls >= 2) {
        fprintf(stderr, "[cg] CGDisplayStream stalled — switching to polling\n");
        if (MyCGDisplayStreamStop) MyCGDisplayStreamStop((MyCGDisplayStreamRef)g_cgStream);
        g_cgStream = NULL;
        pthread_mutex_lock(&g_lock);        // polling path doesn't use the push buffer
        if (g_latestPB) { CFRelease(g_latestPB); g_latestPB = NULL; }
        pthread_mutex_unlock(&g_lock);
        startPolling();
    } else {
        fprintf(stderr, "[cg] push capture healthy, keeping it\n");
    }
    return NULL;
}

// ============================================================ MJPEG (fallback only)
static volatile int g_wantJpeg = 0;   // one-shot request from /frame.jpg

static CGImageRef imageFromPB(CVPixelBufferRef pb) {
    // deep copy: the buffer may be recycled by the capture pool after we unlock
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb);
    CFDataRef data = CFDataCreate(NULL, CVPixelBufferGetBaseAddress(pb), (CFIndex)(bpr * h));
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    if (!data) return NULL;
    CGDataProviderRef dp = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGImageRef img = CGImageCreate(w, h, 8, 32, bpr, cs,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little, dp, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs); CGDataProviderRelease(dp); CFRelease(data);
    return img;
}

static void *jpegThread(void *arg) {
    (void)arg;
    while (g_running) {
        if (g_mjpegClients == 0 && !g_wantJpeg) { usleep(50000); continue; }
        uint64_t t0 = nowNs();
        g_wantJpeg = 0;
        CGImageRef img = NULL;
        BOOL needCursor = NO;
        pthread_mutex_lock(&g_lock);
        CVPixelBufferRef pb = g_latestPB;
        if (pb) CFRetain(pb);
        pthread_mutex_unlock(&g_lock);
        if (pb) { img = imageFromPB(pb); CFRelease(pb); }   // push capture: cursor already in frame
        else {
            pthread_mutex_lock(&g_jpegLock);
            if (g_jpegImg) { CFRetain(g_jpegImg); img = g_jpegImg; }
            pthread_mutex_unlock(&g_jpegLock);
            needCursor = YES;                               // polling: CGDisplayCreateImage omits it
        }
        if (!img) { usleep(30000); continue; }
        @autoreleasepool {
            CGImageRef src = img;
            CGImageRef composed = NULL;
            if (needCursor) {
                size_t jw = CGImageGetWidth(img), jh = CGImageGetHeight(img);
                CGColorSpaceRef jcs = CGColorSpaceCreateDeviceRGB();
                CGContextRef jctx = CGBitmapContextCreate(NULL, jw, jh, 8, 0, jcs,
                    kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
                CGColorSpaceRelease(jcs);
                if (jctx) {
                    CGContextDrawImage(jctx, CGRectMake(0, 0, jw, jh), img);
                    drawCursorOverlay(jctx);
                    composed = CGBitmapContextCreateImage(jctx);
                    CFRelease(jctx);
                    if (composed) src = composed;
                }
            }
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:src];
            NSData *jpeg = [rep representationUsingType:NSBitmapImageFileTypeJPEG
                                             properties:@{NSImageCompressionFactor: @0.75}];
            if (jpeg.length > 0) storeJpeg(jpeg);
            if (composed) CFRelease(composed);
        }
        CFRelease(img);
        uint64_t spent = (nowNs() - t0) / 1000;             // cap ~30fps
        if (spent < 33000) usleep((useconds_t)(33000 - spent));
    }
    return NULL;
}

static void *captureThread(void *arg) {
    (void)arg;
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    uint64_t intervalTicks = (uint64_t)((double)tb.denom * 1e9 / ((double)tb.numer * g_fps));
    uint64_t next = mach_absolute_time();
    uint64_t lastCount = 0, lastTick = 0;
    double capMsAvg = 0;
    CGDisplayCreateImageFn grab = CGDisplayCreateImage_dyn();
    fprintf(stderr, "[capture] CGDisplayCreateImage polling @%.0f (fallback — higher CPU than push capture)\n", g_fps);
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
                pthread_mutex_lock(&g_jpegLock);        // hand off to jpeg thread
                if (g_jpegImg) CFRelease(g_jpegImg);
                CFRetain(img);
                g_jpegImg = img;
                pthread_mutex_unlock(&g_jpegLock);
                if (encoderWanted()) encodeH264(img);
                CFRelease(img);
            } else {
                static int warned = 0;
                if (!warned++) fprintf(stderr,
                    "[capture] CGDisplayCreateImage returned NULL — grant Screen Recording "
                    "permission to your terminal app in System Settings, then restart.\n");
            }

            uint64_t now = mach_absolute_time();        // loop-rate window
            if (!lastTick) lastTick = now;
            double el = ((now - lastTick) * (double)tb.numer / tb.denom) / 1e9;
            if (el >= 2.0) {
                g_captureFps = (g_capFrames - lastCount) / el;
                g_encFps = g_captureFps;
                g_capMs = capMsAvg;
                lastCount = g_capFrames; lastTick = now;
            }

            next += intervalTicks;                       // pace: sleep only the remainder
            uint64_t now2 = mach_absolute_time();
            if (next > now2) {
                uint64_t ns = (uint64_t)((double)(next - now2) * (double)tb.numer / tb.denom);
                if (ns > 200000) usleep((useconds_t)(ns / 1000));
            } else {
                next = now2;                             // behind: resync, no sleep
            }
        }
    }
    return NULL;
}

// ============================================================ http helpers
static int listenSocket(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { perror("bind"); return -1; }
    listen(fd, 16);
    return fd;
}

static BOOL writeAll(int fd, const void *buf, size_t len) {
    const char *p = buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n <= 0) { if (errno == EINTR) continue; return NO; }
        p += n; len -= n;
    }
    return YES;
}
static BOOL writeStr(int fd, const char *s) { return writeAll(fd, s, strlen(s)); }

// print reachable URLs for every live IPv4 interface (IP changes with Wi-Fi networks)
static void printLocalURLs(uint16_t port) {
    struct ifaddrs *ifs = NULL, *it;
    if (getifaddrs(&ifs) != 0) return;
    for (it = ifs; it; it = it->ifa_next) {
        if (!it->ifa_addr || it->ifa_addr->sa_family != AF_INET) continue;
        if (!(it->ifa_flags & IFF_UP) || !(it->ifa_flags & IFF_RUNNING)) continue;
        if (it->ifa_flags & IFF_LOOPBACK) continue;
        char ip[64];
        struct sockaddr_in *sa = (struct sockaddr_in *)it->ifa_addr;
        if (!inet_ntop(AF_INET, &sa->sin_addr, ip, sizeof(ip))) continue;
        printf("  -> http://%s:%u/   (%s)\n", ip, port, it->ifa_name);
    }
    freeifaddrs(ifs);
}
static BOOL writeRec(int fd, uint8_t flags, NSData *payload) { // [4B len][1B flags][payload]
    size_t L = payload.length;
    uint8_t *buf = malloc(5 + L);                    // one write = one TCP segment train
    if (!buf) return NO;
    buf[0] = (uint8_t)(L >> 24); buf[1] = (uint8_t)(L >> 16);
    buf[2] = (uint8_t)(L >> 8);  buf[3] = (uint8_t)L; buf[4] = flags;
    if (L) memcpy(buf + 5, payload.bytes, L);
    BOOL ok = writeAll(fd, buf, 5 + L);
    free(buf);
    return ok;
}

// composite the system cursor into a frame context (CGDisplayCreateImage omits it).
// cursor state is sampled at capture START (frame content + cursor stay in sync).
static pthread_mutex_t g_curLock = PTHREAD_MUTEX_INITIALIZER;
static NSPoint g_curPos;            // global, bottom-left origin
static NSImage *g_curImg = nil;
static NSPoint g_curHot;            // hotspot in cursor-image POINTS, top-left origin

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
            if (c != lastC || !g_curImg) { lastC = c; g_curImg = c.image; g_curHot = c.hotSpot; }
            pthread_mutex_unlock(&g_curLock);
        } @catch (NSException *e) {}
        usleep(8000);
    }
    return NULL;
}

static void drawCursorOverlay(CGContextRef ctx) {
    pthread_mutex_lock(&g_curLock);
    NSPoint pos = g_curPos; NSImage *img = g_curImg; NSPoint hot = g_curHot;
    pthread_mutex_unlock(&g_curLock);
    if (!img || img.size.width <= 0 || img.size.height <= 0) return;
    // NSEvent.mouseLocation: Cocoa global space, origin bottom-left of the primary
    // display, y UP. CGDisplayBounds: origin top-left of the primary display, y DOWN.
    CGFloat primaryH = CGDisplayBounds(CGMainDisplayID()).size.height;
    CGPoint cg = { pos.x, primaryH - pos.y };
    CGRect vb = CGDisplayBounds(g_displayID);                 // points
    if (!CGRectContainsPoint(vb, cg)) return;
    CGFloat ctxW = (CGFloat)CGBitmapContextGetWidth(ctx), ctxH = (CGFloat)CGBitmapContextGetHeight(ctx);
    CGFloat scale = vb.size.width > 0 ? ctxW / vb.size.width : 1.0;   // px per point (2 on HiDPI)
    // best (largest) bitmap rep; draw it at the cursor's POINT size * scale
    CGImageRef cgi = NULL; NSInteger bestW = 0;
    for (NSImageRep *rep in img.representations)
        if ([rep isKindOfClass:[NSBitmapImageRep class]] && ((NSBitmapImageRep *)rep).CGImage && rep.pixelsWide > bestW) {
            cgi = ((NSBitmapImageRep *)rep).CGImage; bestW = rep.pixelsWide;
        }
    if (!cgi) cgi = [img CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cgi) return;
    CGFloat cw = img.size.width * scale, ch = img.size.height * scale;
    // hotspot (top-left origin, points) must land exactly on the pointer position
    CGFloat left   = (cg.x - vb.origin.x - hot.x) * scale;
    CGFloat topPx  = (cg.y - vb.origin.y - hot.y) * scale;    // from the top edge
    CGRect crect = CGRectMake(left, ctxH - topPx - ch, cw, ch); // bitmap context is y-up
    if (getenv("PAD6_DEBUG")) {
        static uint64_t lastDbg = 0; uint64_t t = nowNs();
        if (t - lastDbg > 500000000ULL) { lastDbg = t;
            fprintf(stderr, "[cursor] cg(%.1f,%.1f) vb(%.0f,%.0f %.0fx%.0f) hot(%.1f,%.1f) size %.0fx%.0f scale %.2f -> rect(%.1f,%.1f %.0fx%.0f)\n",
                    cg.x, cg.y, vb.origin.x, vb.origin.y, vb.size.width, vb.size.height,
                    hot.x, hot.y, img.size.width, img.size.height, scale,
                    crect.origin.x, crect.origin.y, crect.size.width, crect.size.height);
        }
    }
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, crect, cgi);
}

// ============================================================ player page
static const char *INDEX_HTML =
"<!doctype html><html><head><meta charset=utf-8>\n"
"<meta name=viewport content='width=device-width,initial-scale=1,viewport-fit=cover,user-scalable=no'>\n"
"<title>Mac Display</title><style>\n"
"html,body{margin:0;height:100%;background:#000;overflow:hidden;touch-action:none;user-select:none;-webkit-user-select:none}\n"
"#c,#s{position:fixed;inset:0;width:100vw;height:100vh;object-fit:contain;display:none}\n"
"#ui{position:fixed;inset:0;display:flex;flex-direction:column;gap:22px;align-items:center;justify-content:center;background:#000;z-index:9;color:#bbb;font:17px system-ui,sans-serif;text-align:center;padding:24px}\n"
"#warn{color:#fb4;max-width:820px;line-height:1.5;display:none}\n"
"#warn code{background:#222;padding:2px 6px;border-radius:4px;color:#fff}\n"
"#st{position:fixed;top:8px;right:12px;color:#7f7;font:13px monospace;z-index:8;display:none;text-shadow:0 0 4px #000;pointer-events:none;white-space:pre;text-align:right}\n"
"button{font-size:22px;padding:18px 34px;border-radius:14px;border:0;background:#1a73e8;color:#fff;font-weight:600}\n"
"</style></head><body>\n"
"<canvas id=c></canvas><img id=s alt=''><video id=w playsinline loop muted preload=none style='position:fixed;left:0;top:0;width:1px;height:1px;opacity:0.01'></video><div id=st></div>\n"
"<div id=ui><button id=go>&#9654; TAP FOR FULLSCREEN</button><div id=warn></div><div style='color:#666;font-size:14px'>tap the screen later to show/hide fps &middot; tap again after leaving fullscreen</div></div>\n"
"<script>\n"
"const $=i=>document.getElementById(i);\n"
"const cv=$('c'),img=$('s'),st=$('st'),ui=$('ui');\n"
"const WC=('VideoDecoder' in window);\n"
"let alive=false,mode='',fpsN=0,fpsT=0,fps=0,showStats=false,info='';\n"
"if(!WC){const w=$('warn');w.style.display='block';\n"
" w.innerHTML='&#9888; Sharp low-latency H.264 is blocked: Chrome only allows its video decoder on secure pages, and this is plain http.<br>'+\n"
" 'Falling back to MJPEG (blurry + laggy).<br><br><b>Fix (once):</b> run <code>./adb-launch.sh</code> on the Mac &mdash; or open '+\n"
" '<code>chrome://flags/#unsafely-treat-insecure-origin-as-secure</code>, add <code>'+location.origin+'</code>, Enable, Relaunch.';}\n"
"function report(){fetch('/hello?mode='+mode+'&secure='+(window.isSecureContext?1:0)+'&screen='+\n"
" Math.round(screen.width*devicePixelRatio)+'x'+Math.round(screen.height*devicePixelRatio)+'&dpr='+devicePixelRatio,{cache:'no-store'}).catch(()=>{});}\n"
"function draw(){st.textContent=showStats?(mode+' '+fps+' fps\\n'+info):'';}\n"
"function tick(){fpsN++;const t=performance.now();if(t-fpsT>=1000){fps=fpsN;fpsN=0;fpsT=t;draw();}}\n"
"const b64u8=b=>Uint8Array.from(atob(b),c=>c.charCodeAt(0));\n"
"class Buf{constructor(){this.b=new Uint8Array(1<<20);this.o=0;this.n=0;}\n"
" push(v){if(this.o&&this.b.length-this.n<v.length){this.b.copyWithin(0,this.o,this.n);this.n-=this.o;this.o=0;}\n"
"  if(this.b.length-this.n<v.length){const t=new Uint8Array(Math.max(this.b.length*2,this.n+v.length));t.set(this.b.subarray(0,this.n));this.b=t;}\n"
"  this.b.set(v,this.n);this.n+=v.length;}\n"
" have(){return this.n-this.o;}\n"
" u32(i){const b=this.b,o=this.o+i;return ((b[o]<<24)>>>0)+(b[o+1]<<16)+(b[o+2]<<8)+b[o+3];}\n"
" take(k){const r=this.b.slice(this.o,this.o+k);this.o+=k;if(this.o===this.n){this.o=this.n=0;}return r;}}\n"
"async function startH264(){\n"
" const res=await fetch('/h264',{cache:'no-store'});if(!res.ok||!res.body)throw new Error('no h264');\n"
" const rd=res.body.getReader();const buf=new Buf();let cfg=null,dec=null,g=null,bad=false,ts=0;\n"
" try{\n"
"  while(alive&&!bad){\n"
"   const {done,value}=await rd.read();if(done)break;buf.push(value);\n"
"   if(!cfg){if(buf.have()<4)continue;const L=buf.u32(0);if(buf.have()<4+L)continue;\n"
"    buf.take(4);cfg=JSON.parse(new TextDecoder().decode(buf.take(L)));\n"
"    if(cv.width!==cfg.w||cv.height!==cfg.h){cv.width=cfg.w;cv.height=cfg.h;}\n"
"    g=cv.getContext('2d',{alpha:false,desynchronized:true});\n"
"    dec=new VideoDecoder({output:f=>{g.drawImage(f,0,0,cv.width,cv.height);f.close();tick();},\n"
"     error:e=>{console.warn(e);bad=true;}});\n"
"    const c={codec:cfg.codec,description:b64u8(cfg.desc),optimizeForLatency:true,hardwareAcceleration:'prefer-hardware'};\n"
"    try{if(!(await VideoDecoder.isConfigSupported(c)).supported)delete c.hardwareAcceleration;}catch(e){delete c.hardwareAcceleration;}\n"
"    dec.configure(c);cv.style.display='block';img.style.display='none';\n"
"    info=cfg.w+'x'+cfg.h+' '+cfg.codec;report();\n"
"   }\n"
"   while(buf.have()>=5){const L=buf.u32(0);if(buf.have()<5+L)break;\n"
"    const fl=buf.b[buf.o+4];buf.take(5);const data=buf.take(L);\n"
"    if(L>0&&dec.state==='configured'){ts+=16667;dec.decode(new EncodedVideoChunk({type:(fl&1)?'key':'delta',timestamp:ts,data}));}\n"
"   }\n"
"  }\n"
" }finally{try{rd.cancel();}catch(e){}try{if(dec&&dec.state!=='closed')dec.close();}catch(e){}}\n"
"}\n"
"function startMjpeg(){mode='mjpeg';report();img.style.display='block';cv.style.display='none';\n"
" img.onerror=()=>{if(alive)setTimeout(()=>{img.src='/stream.mjpg?t='+Date.now();},900);};\n"
" img.onload=()=>tick();img.src='/stream.mjpg?t='+Date.now();}\n"
"async function start(){\n"
" alive=true;st.style.display='block';\n"
" if(WC){mode='h264';\n"
"  while(alive){try{await startH264();}catch(e){console.warn(e);}\n"
"   if(!alive)break;await new Promise(r=>setTimeout(r,500));}\n"
" } else startMjpeg();\n"
"}\n"
"const wv=$('w');\n"
"function keepAwake(){if(wv.paused)wv.play().catch(()=>{});try{navigator.wakeLock&&navigator.wakeLock.request('screen').catch(()=>{});}catch(e){}}\n"
"async function goFull(){try{if(!document.fullscreenElement)await document.documentElement.requestFullscreen({navigationUI:'hide'});}catch(e){}\n"
" try{await screen.orientation.lock('landscape');}catch(e){}}\n"
"// stream starts immediately (decoder warm before the tap); fullscreen needs a user gesture\n"
"start();\n"
"let armed=false;\n"
"document.addEventListener('click',async()=>{\n"
" if(!armed){armed=true;ui.remove();await goFull();\n"
"  wv.src='/silent.mp4';wv.volume=0;await wv.play().catch(()=>{});keepAwake();setInterval(keepAwake,5000);return;}\n"
" if(!document.fullscreenElement)goFull();else{showStats=!showStats;draw();}\n"
"});\n"
"document.addEventListener('visibilitychange',()=>{if(!document.hidden)keepAwake();});\n"
"</script></body></html>\n";

// ============================================================ handlers
static void handleClient(int fd) {
    @autoreleasepool {
        char req[2048] = {0};
        ssize_t n = recv(fd, req, sizeof(req) - 1, 0);
        if (n <= 0) { close(fd); return; }
        char method[16] = {0}, path[256] = {0}, query[256] = {0};
        sscanf(req, "%15s %255s", method, path);
        char *q = strchr(path, '?'); if (q) { snprintf(query, sizeof(query), "%s", q + 1); *q = 0; }
        char ua[256] = {0};
        char *uh = strcasestr(req, "User-Agent:");
        if (uh) sscanf(uh + 11, "%255[^\r\n]", ua);
        if (strcmp(path, "/hello") != 0)
            fprintf(stderr, "[http] GET %s%s%s\n", path, ua[0] ? "  UA=" : "", ua);

        if (strcmp(path, "/") == 0 || strcmp(path, "/index.html") == 0) {
            char hdr[256];
            snprintf(hdr, sizeof(hdr),
                "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %zu\r\n"
                "Cache-Control: no-store\r\nConnection: close\r\n\r\n", strlen(INDEX_HTML));
            writeStr(fd, hdr); writeStr(fd, INDEX_HTML);
        }
        else if (strcmp(path, "/hello") == 0) {
            fprintf(stderr, "[client] %s%s\n", query,
                    strstr(query, "mode=mjpeg") ? "   <-- MJPEG fallback: page is not a secure context, run ./adb-launch.sh" : "");
            writeStr(fd, "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n");
        }
        else if (strcmp(path, "/frame.jpg") == 0) {
            uint64_t s0 = 0; copyJpeg(&s0);
            g_wantJpeg = 1;                                  // fresh frame, up to ~1.5s
            for (int i = 0; i < 150; i++) { uint64_t s1 = 0; copyJpeg(&s1); if (s1 != s0) break; usleep(10000); }
            NSData *f = copyJpeg(NULL);
            if (!f) writeStr(fd, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n");
            else {
                char hdr[160];
                snprintf(hdr, sizeof(hdr),
                    "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: %lu\r\n"
                    "Cache-Control: no-store\r\nConnection: close\r\n\r\n", (unsigned long)f.length);
                writeStr(fd, hdr); writeAll(fd, f.bytes, f.length);
            }
        }
        else if (strcmp(path, "/silent.mp4") == 0) {
            if (!g_silentMp4) writeStr(fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
            else {
                char hdr[160];
                snprintf(hdr, sizeof(hdr),
                    "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: %lu\r\n"
                    "Cache-Control: max-age=3600\r\nConnection: close\r\n\r\n",
                    (unsigned long)g_silentMp4.length);
                writeStr(fd, hdr); writeAll(fd, g_silentMp4.bytes, g_silentMp4.length);
            }
        }
        else if (strcmp(path, "/stream.mjpg") == 0) {
            __sync_fetch_and_add(&g_mjpegClients, 1);
            uint64_t lastSeq = 0; int sent = 0;
            writeStr(fd,
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n"
                "Cache-Control: no-store\r\nConnection: close\r\n\r\n");
            while (g_running) {
                @autoreleasepool {
                    uint64_t seq = 0;
                    NSData *f = copyJpeg(&seq);
                    if (!f) { usleep(100000); continue; }
                    if (seq == lastSeq) { usleep(2000); continue; }
                    lastSeq = seq;
                    char part[160];
                    snprintf(part, sizeof(part),
                        "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %lu\r\n\r\n",
                        (unsigned long)f.length);
                    if (!writeStr(fd, part) || !writeAll(fd, f.bytes, f.length) || !writeStr(fd, "\r\n")) break;
                    sent++;
                }
            }
            fprintf(stderr, "[http] mjpeg client done (%d frames)\n", sent);
            __sync_fetch_and_sub(&g_mjpegClients, 1);
        }
        else if (strcmp(path, "/h264") == 0) {
            __sync_fetch_and_add(&g_h264Clients, 1);         // also wakes the encoder if idle
            g_forceKey = 1;
            NSString *codec = nil, *desc = nil;
            for (int i = 0; i < 100 && g_running; i++) {     // wait for encoder config (max ~5s)
                pthread_mutex_lock(&g_lock);
                codec = g_codec; desc = g_avcCB64;
                pthread_mutex_unlock(&g_lock);
                if (desc) break;
                usleep(50000);
            }
            if (!desc) {
                writeStr(fd, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n");
                __sync_fetch_and_sub(&g_h264Clients, 1); close(fd); return;
            }
            NSString *cfg = [NSString stringWithFormat:
                @"{\"codec\":\"%@\",\"desc\":\"%@\",\"w\":%u,\"h\":%u,\"fps\":%.0f}",
                codec, desc, g_pixW, g_pixH, g_fps];
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
                __sync_fetch_and_sub(&g_h264Clients, 1); close(fd); return;
            }

            // Start at the first keyframe produced after connect. If the client falls
            // behind (Wi-Fi hiccup), drop the backlog and resync on a fresh IDR rather
            // than playing seconds-old video.
            const uint64_t MAX_LAG = (uint64_t)(g_fps / 4) + 2;   // ~250ms of frames
            uint64_t waitAfter;
            pthread_mutex_lock(&g_lock); waitAfter = g_auHead; pthread_mutex_unlock(&g_lock);
            uint64_t lastSent = 0;
            BOOL primed = NO;
            int sent = 0, resyncs = 0;
            NSData *out[64]; uint8_t fl[64];
            while (g_running) {
                @autoreleasepool {
                    int cnt = 0;
                    pthread_mutex_lock(&g_lock);
                    if (!primed) {
                        for (uint64_t s = waitAfter + 1; s <= g_auHead; s++) {
                            AURec *r = &g_au[s % AU_RING];
                            if (r->seq == s && r->isKey) { lastSent = s - 1; primed = YES; break; }
                        }
                        if (!primed) waitAfter = g_auHead;
                    }
                    if (primed) {
                        if (g_auHead - lastSent > MAX_LAG) {        // too far behind: resync
                            primed = NO; waitAfter = g_auHead; g_forceKey = 1; resyncs++;
                        } else {
                            for (uint64_t s = lastSent + 1; s <= g_auHead && cnt < 64; s++) {
                                AURec *r = &g_au[s % AU_RING];
                                if (r->seq != s) continue;
                                out[cnt] = r->data; fl[cnt] = r->isKey ? 1 : 0; cnt++;
                                lastSent = s;
                            }
                        }
                    }
                    if (cnt == 0) {                                  // sleep until the encoder emits
                        struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
                        ts.tv_nsec += 100 * 1000000L;
                        if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
                        pthread_cond_timedwait(&g_auCond, &g_lock, &ts);
                    }
                    pthread_mutex_unlock(&g_lock);
                    BOOL ok = YES;
                    for (int i = 0; i < cnt && ok; i++) ok = writeRec(fd, fl[i], out[i]);
                    for (int i = 0; i < cnt; i++) out[i] = nil;
                    if (!ok) break;
                    sent += cnt;
                }
            }
            fprintf(stderr, "[http] h264 client done (%d AUs, %d lag resyncs)\n", sent, resyncs);
            __sync_fetch_and_sub(&g_h264Clients, 1);
        }
        else if (strcmp(path, "/status") == 0) {
            char body[512], hdr[128];
            pthread_mutex_lock(&g_lock);
            NSString *b = [NSString stringWithFormat:
                @"{\"display\":%u,\"width\":%u,\"height\":%u,\"pixel_width\":%u,\"pixel_height\":%u,"
                @"\"capture\":\"%s\",\"capture_fps\":%.1f,\"encode_fps\":%.1f,"
                @"\"sc_callbacks\":%llu,\"h264_total_kbits\":%llu,\"mjpeg_clients\":%d,\"h264_clients\":%d,\"h264\":%@}",
                g_displayID, g_dispW, g_dispH, g_pixW, g_pixH,
                g_scStream ? "screencapturekit" : (g_cgStream ? "cgdisplaystream" : "polling"),
                g_captureFps, g_encFps, (unsigned long long)g_scCallbacks,
                (unsigned long long)(g_h264Bytes * 8 / 1000), g_mjpegClients, g_h264Clients,
                g_vts ? @"true" : @"false"];
            pthread_mutex_unlock(&g_lock);
            snprintf(body, sizeof(body), "%s", b.UTF8String);
            snprintf(hdr, sizeof(hdr),
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n"
                "Connection: close\r\n\r\n", strlen(body));
            writeStr(fd, hdr); writeStr(fd, body);
        }
        else {
            writeStr(fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
        }
        close(fd);
    }
}

void *handleClientWrapper(void *fdp) { handleClient(*(int *)fdp); free(fdp); return NULL; }

static void *serverThread(void *arg) {
    int lfd = *(int *)arg;
    while (g_running) {
        struct sockaddr_in cli; socklen_t cl = sizeof(cli);
        int fd = accept(lfd, (struct sockaddr *)&cli, &cl);
        if (fd < 0) continue;
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));   // no Nagle: frames leave immediately
        struct timeval tv = {10, 0};
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        pthread_t t;
        int *argfd = malloc(sizeof(int)); *argfd = fd;
        pthread_create(&t, NULL, handleClientWrapper, argfd);
        pthread_detach(t);
    }
    return NULL;
}

// ============================================================ main
static void onSig(int sig) { (void)sig; g_running = NO; }

int main(int argc, char **argv) {
    // args are the LOGICAL ("looks like") size in points; the framebuffer is 2x that
    // (Retina) unless PAD6_SCALE=1. Default 1440x900 pt = 2880x1800 px = Pad 6 native.
    uint32_t w = argc > 1 ? (uint32_t)atoi(argv[1]) : 1440;
    uint32_t h = argc > 2 ? (uint32_t)atoi(argv[2]) : 900;
    uint16_t port = argc > 3 ? (uint16_t)atoi(argv[3]) : 8080;
    g_fps = argc > 4 ? atof(argv[4]) : 60.0;
    BOOL hiDPI = !(getenv("PAD6_SCALE") && atoi(getenv("PAD6_SCALE")) == 1);
    if (!w || !h || !port || g_fps < 1 || g_fps > 120) {
        fprintf(stderr, "usage: %s [width_pt height_pt [port [fps]]]   (default 1440 900 8080 60)\n", argv[0]);
        return 2;
    }

    signal(SIGINT, onSig); signal(SIGTERM, onSig); signal(SIGHUP, onSig);
    signal(SIGPIPE, SIG_IGN);

    VirtualDisplay *vd = [[VirtualDisplay alloc] init];
    NSString *err = nil;
    if (![vd startWithWidth:w height:h hiDPI:hiDPI refreshRate:g_fps error:&err]) {
        fprintf(stderr, "virtual display failed: %s\n", err.UTF8String ?: "?");
        return 1;
    }
    g_displayID = vd.displayID; g_dispW = vd.servedWidth; g_dispH = vd.servedHeight;
    g_pixW = vd.pixelWidth; g_pixH = vd.pixelHeight;
    printf("virtual display #%u looks like %ux%u, %ux%u px%s\n", g_displayID, g_dispW, g_dispH,
           g_pixW, g_pixH, hiDPI ? " (HiDPI)" : "");

    // deterministic placement: immediately right of the rightmost display, top-aligned with it
    {
        CGDirectDisplayID ids[16]; uint32_t cnt = 0;
        CGGetActiveDisplayList(16, ids, &cnt);
        CGFloat right = 0, top = 0;
        for (uint32_t i = 0; i < cnt; i++) {
            if (ids[i] == g_displayID) continue;
            CGRect b = CGDisplayBounds(ids[i]);
            if (b.origin.x + b.size.width > right) { right = b.origin.x + b.size.width; top = b.origin.y; }
        }
        CGDisplayConfigRef cfg;
        if (CGBeginDisplayConfiguration(&cfg) == kCGErrorSuccess) {
            CGConfigureDisplayOrigin(cfg, g_displayID, (int32_t)right, (int32_t)top);
            CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
        }
        CGRect fb = CGDisplayBounds(g_displayID);
        printf("arranged right of existing displays: origin (%g, %g)\n", fb.origin.x, fb.origin.y);
    }

    g_encQ = dispatch_queue_create("pad6.encode", dispatch_queue_attr_make_with_qos_class(
                                       DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    if (!startH264Encoder()) fprintf(stderr, "continuing without h264 (mjpeg only)\n");

    // resolve next to the binary, not the caller's cwd
    NSString *exeDir = [[NSString stringWithUTF8String:argv[0]] stringByDeletingLastPathComponent];
    g_silentMp4 = [NSData dataWithContentsOfFile:[exeDir stringByAppendingPathComponent:@"silent.mp4"]];
    if (!g_silentMp4) fprintf(stderr, "[init] WARNING: silent.mp4 not found — screen-wakelock video disabled\n");

    int lfd = listenSocket(port);
    if (lfd < 0) return 1;
    printf("serving — open on the Pad (best: ./adb-launch.sh, enables sharp H.264):\n");
    printLocalURLs(port);
    fflush(stdout);

    if (getenv("PAD6_POLL")) {              // debug: skip push APIs entirely
        fprintf(stderr, "PAD6_POLL set — CGDisplayCreateImage polling loop\n");
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
    pthread_create(&srvT, NULL, serverThread, &lfd);
    pthread_detach(srvT);
    pthread_create(&jpgT, NULL, jpegThread, NULL);
    pthread_detach(jpgT);
    pthread_create(&refT, NULL, refreshThread, NULL);
    pthread_detach(refT);

    uint64_t lastBytes = 0, lastOut = 0, lastCb = 0;
    while (g_running) {
        for (int i = 0; i < 10 && g_running; i++) sleep(1);
        if (!g_running) break;
        uint64_t b = g_h264Bytes, o = g_encOutFrames, cb = g_scCallbacks;
        if (g_h264Clients || g_mjpegClients || o != lastOut || getenv("PAD6_DEBUG"))
            fprintf(stderr, "[status] capture=%.1ffps encout=%.1ffps h264=%.0fkbit/s clients(h264=%d mjpeg=%d) sccb=%llu%s\n",
                    g_captureFps, (double)(o - lastOut) / 10.0, (double)(b - lastBytes) * 8 / 10000,
                    g_h264Clients, g_mjpegClients, (unsigned long long)(cb - lastCb),
                    g_capMs > 0 ? [NSString stringWithFormat:@" poll=%.0fms", g_capMs].UTF8String : "");
        lastBytes = b; lastOut = o; lastCb = cb;
    }

    fprintf(stderr, "shutting down...\n");
    close(lfd);
    if (g_scStream) {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [g_scStream stopCaptureWithCompletionHandler:^(NSError *e) { (void)e; dispatch_semaphore_signal(done); }];
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    }
    if (g_cgStream && MyCGDisplayStreamStop) MyCGDisplayStreamStop((MyCGDisplayStreamRef)g_cgStream);
    if (g_vts) { VTCompressionSessionCompleteFrames(g_vts, kCMTimeInvalid); VTCompressionSessionInvalidate(g_vts); }
    [vd stop];
    return 0;
}
