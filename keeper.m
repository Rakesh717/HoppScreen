// keeper.m — forces continuous compositing of a virtual display.
//
// Push capture APIs (ScreenCaptureKit / CGDisplayStream) are damage-driven:
// a static display produces no frames. This parks a 2x2 click-through window
// with a Core Animation running forever on the target display, so WindowServer
// keeps recompositing it and push capture delivers at full rate.
//
// Usage: ./keeper <displayID>          (0 = rightmost display)
// Standalone diagnostic utility; HoppScreen does not launch it automatically.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>

@interface KeeperApp : NSObject <NSApplicationDelegate>
@property (assign) CGDirectDisplayID target;
@end

@implementation KeeperApp
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    (void)n;
    // A zero target selects the display with the furthest-right edge.
    CGDirectDisplayID target = self.target;
    if (!target) {
        CGDirectDisplayID ids[16]; uint32_t count = 0;
        CGGetActiveDisplayList(16, ids, &count);
        if (count == 0) { fprintf(stderr, "no displays\n"); exit(1); }
        target = ids[0];
        CGRect best = CGDisplayBounds(ids[0]);
        for (uint32_t i = 1; i < count; i++) {          // rightmost wins
            CGRect b = CGDisplayBounds(ids[i]);
            if (b.origin.x + b.size.width > best.origin.x + best.size.width) {
                best = b; target = ids[i];
            }
        }
    }
    CGRect bounds = CGDisplayBounds(target);
    fprintf(stderr, "[keeper] display %u at (%g,%g) %gx%g\n", target,
            bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height);

    // 2x2 window in the top-left corner of that display (global coords)
    CGFloat sz = 2;
    NSRect frame = NSMakeRect(bounds.origin.x + 4, bounds.origin.y + bounds.size.height - sz - 4,
                              sz, sz);
    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                                styleMask:NSWindowStyleMaskBorderless
                                                  backing:NSBackingStoreBuffered defer:NO];
    win.ignoresMouseEvents = YES;
    win.level = NSNormalWindowLevel;      // visible to compositor (occlusion-safe)
    win.opaque = YES;
    win.hasShadow = NO;
    win.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                             NSWindowCollectionBehaviorStationary;

    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, sz, sz)];
    v.wantsLayer = YES;
    CALayer *l = [CALayer layer];
    l.frame = CGRectMake(0, 0, sz, sz);
    l.backgroundColor = [NSColor.blackColor CGColor];
    // subtle luminance oscillation — visually ~invisible, forces recomposite
    CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"backgroundColor"];
    anim.fromValue  = (id)[NSColor.blackColor CGColor];
    anim.toValue    = (id)[NSColor.darkGrayColor CGColor];
    anim.duration   = 1.0 / 30.0;        // 30Hz flicker is plenty
    anim.autoreverses = YES;
    anim.repeatCount = HUGE_VALF;
    anim.removedOnCompletion = NO;
    [l addAnimation:anim forKey:@"keepalive"];
    v.layer = l;
    win.contentView = v;
    [win orderFrontRegardless];
    fprintf(stderr, "[keeper] animating window up — display %u now composites continuously\n", target);
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        KeeperApp *del = [KeeperApp new];
        del.target = argc > 1 ? (CGDirectDisplayID)strtoul(argv[1], NULL, 0) : 0;
        [NSApp setDelegate:del];
        [NSApp run];
    }
    return 0;
}
