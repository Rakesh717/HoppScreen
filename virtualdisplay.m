// HoppScreen virtual display owner — private CoreGraphics API adapter.
// Logical dimensions are points; HiDPI requests a matching 2x framebuffer mode.
// Creation and mode selection wait for WindowServer's asynchronous teardown/setup;
// releasing the owned CGVirtualDisplay removes the display.
#import "virtualdisplay.h"
#import <CoreGraphics/CoreGraphics.h>

// --- Private CoreGraphics CGVirtualDisplay API ----------------------------
// These classes live in CoreGraphics but aren't in the public headers; we
// redeclare just what we use. Same API BetterDisplay & friends rely on.

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int serialNum;
@property(copy, nonatomic) NSString *name;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic) CGPoint whitePoint;
@property(copy, nonatomic) void (^terminationHandler)(id, CGVirtualDisplay *);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@property(nonatomic) unsigned int rotation;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(readonly, nonatomic) unsigned int displayID;
@end

// --------------------------------------------------------------------------

@implementation VirtualDisplay {
    CGVirtualDisplay *_display; // strong: owns the live display
    dispatch_queue_t _queue;
}

@synthesize displayID = _displayID;

- (BOOL)startWithWidth:(uint32_t)width
                height:(uint32_t)height
                 hiDPI:(BOOL)hiDPI
           refreshRate:(double)refreshRate
                 error:(NSString *_Nullable *_Nullable)error {
    Class DescCls = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class SettingsCls = NSClassFromString(@"CGVirtualDisplaySettings");
    Class ModeCls = NSClassFromString(@"CGVirtualDisplayMode");
    Class DisplayCls = NSClassFromString(@"CGVirtualDisplay");
    if (!DescCls || !SettingsCls || !ModeCls || !DisplayCls) {
        if (error)
            *error = @"CGVirtualDisplay private API unavailable on this macOS build.";
        return NO;
    }

    uint32_t scale = hiDPI ? 2 : 1;
    uint32_t pw = width * scale, ph = height * scale;

    _queue = dispatch_queue_create("hoppscreen.virtualdisplay", DISPATCH_QUEUE_SERIAL);

    CGVirtualDisplayDescriptor *desc = [[DescCls alloc] init];
    desc.queue = _queue;
    // name shown in macOS display settings; override with HOPPSCREEN_NAME=<str>
    NSString *dispName = @"HoppScreen Display";
    const char *envName = getenv("HOPPSCREEN_NAME");
    if (envName && envName[0])
        dispName = [NSString stringWithUTF8String:envName];
    desc.name = dispName;
    desc.vendorID = 0x1234;
    desc.productID = 0x1620;
    // stable serial: macOS remembers arrangement/settings instead of piling up a
    // new "display" in its prefs on every run (0x48505053 = "HPPS")
    desc.serialNum = 0x48505053u ^ (pw << 12) ^ ph;
    // nominal 11-inch 16:10 panel size -> sane reported DPI for the mode hint
    desc.sizeInMillimeters = CGSizeMake(237, 148);
    desc.maxPixelsWide = pw;
    desc.maxPixelsHigh = ph;
    desc.redPrimary = CGPointMake(0.640, 0.330);
    desc.greenPrimary = CGPointMake(0.300, 0.600);
    desc.bluePrimary = CGPointMake(0.150, 0.060);
    desc.whitePoint = CGPointMake(0.3127, 0.3290);

    // creation fails while a previous instance with the same serial is still being
    // torn down (e.g. right after a restart) — retry, then fall back to a random serial
    CGVirtualDisplay *display = nil;
    for (int attempt = 0; attempt < 6 && !display; attempt++) {
        if (attempt == 5)
            desc.serialNum = arc4random();
        display = [[DisplayCls alloc] initWithDescriptor:desc];
        if (!display && attempt < 5)
            usleep(500000);
    }
    if (!display) {
        if (error)
            *error = @"Failed to create CGVirtualDisplay.";
        return NO;
    }

    // Mode is given in POINTS; with hiDPI=1 macOS additionally synthesizes a 2x-backed
    // variant (points x2 pixels). It isn't the default, so we select it below.
    CGVirtualDisplayMode *mode = [[ModeCls alloc] initWithWidth:width
                                                         height:height
                                                    refreshRate:refreshRate];
    CGVirtualDisplaySettings *settings = [[SettingsCls alloc] init];
    settings.modes = @[ mode ];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.rotation = 0;

    if (![display applySettings:settings]) {
        if (error)
            *error = @"applySettings failed.";
        return NO;
    }

    _display = display;
    _displayID = 0;

    // displayID and the mode catalog land asynchronously after applySettings:
    // poll until assigned, then force the exact (points, pixels) mode.
    NSDictionary *modeOpts =
        @{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes : @YES};
    BOOL ok = NO;
    for (int attempt = 0; attempt < 60 && !ok; attempt++) {
        usleep(150000);

        if (_displayID == 0)
            _displayID = display.displayID;
        if (_displayID == 0)
            continue; // not assigned yet

        CFArrayRef modes =
            CGDisplayCopyAllDisplayModes(_displayID, (__bridge CFDictionaryRef)modeOpts);
        if (modes) {
            CGDisplayModeRef target = NULL;
            for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
                CGDisplayModeRef mm = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
                if (CGDisplayModeGetWidth(mm) == width && CGDisplayModeGetHeight(mm) == height &&
                    CGDisplayModeGetPixelWidth(mm) == pw && CGDisplayModeGetPixelHeight(mm) == ph) {
                    target = mm;
                    break;
                }
            }
            if (target) {
                CGDisplayConfigRef cfg;
                if (CGBeginDisplayConfiguration(&cfg) == kCGErrorSuccess) {
                    CGConfigureDisplayWithDisplayMode(cfg, _displayID, target, NULL);
                    CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
                }
            }
            CFRelease(modes);
        }

        ok = (self.servedWidth == width && self.servedHeight == height && self.pixelWidth == pw &&
              self.pixelHeight == ph);
    }

    if (!ok) {
        if (error)
            *error = [NSString
                stringWithFormat:@"display settled at %ux%u pt (%ux%u px), not %ux%u pt (%ux%u px)",
                                 self.servedWidth, self.servedHeight, self.pixelWidth,
                                 self.pixelHeight, width, height, pw, ph];
        return NO;
    }
    return YES;
}

- (uint32_t)servedWidth {
    return _displayID ? (uint32_t)CGDisplayPixelsWide(_displayID) : 0;
}
- (uint32_t)servedHeight {
    return _displayID ? (uint32_t)CGDisplayPixelsHigh(_displayID) : 0;
}

- (uint32_t)pixelWidth {
    if (!_displayID)
        return 0;
    CGDisplayModeRef m = CGDisplayCopyDisplayMode(_displayID);
    uint32_t v = m ? (uint32_t)CGDisplayModeGetPixelWidth(m) : 0;
    if (m)
        CGDisplayModeRelease(m);
    return v;
}
- (uint32_t)pixelHeight {
    if (!_displayID)
        return 0;
    CGDisplayModeRef m = CGDisplayCopyDisplayMode(_displayID);
    uint32_t v = m ? (uint32_t)CGDisplayModeGetPixelHeight(m) : 0;
    if (m)
        CGDisplayModeRelease(m);
    return v;
}

- (void)stop {
    _display = nil; // releasing the owner tears down the virtual display
    _displayID = 0;
    _queue = nil;
}

- (void)dealloc {
    [self stop];
}

@end
