// VirtualDisplay — ownership and geometry contract for HoppScreen's desktop.
// Keep the owner alive while capturing; logical points and backing pixels differ
// on HiDPI displays. The implementation uses the private CGVirtualDisplay API.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Creates and owns an off-screen macOS virtual display via the private
/// CoreGraphics CGVirtualDisplay API. The display lives as long as this object;
/// -stop (or dealloc) tears it down.
@interface VirtualDisplay : NSObject

/// CGDirectDisplayID of the live virtual display, or 0 if not started.
@property(nonatomic, readonly) uint32_t displayID;

/// Logical size in points ("looks like" size in System Settings).
@property(nonatomic, readonly) uint32_t servedWidth;
@property(nonatomic, readonly) uint32_t servedHeight;

/// Backing framebuffer size in pixels (= points * scale). This is what gets captured.
@property(nonatomic, readonly) uint32_t pixelWidth;
@property(nonatomic, readonly) uint32_t pixelHeight;

/// Create the virtual display. width/height are in POINTS; with hiDPI the
/// framebuffer is 2x in each dimension (Retina-sharp text).
/// Returns NO and sets *error on failure. Blocks (polls) — call off the main thread.
- (BOOL)startWithWidth:(uint32_t)width
                height:(uint32_t)height
                 hiDPI:(BOOL)hiDPI
           refreshRate:(double)refreshRate
                 error:(NSString *_Nullable *_Nullable)error;

/// Release the live display and reset its ID; safe when already stopped.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
