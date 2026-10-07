// bench2.m — diagnose CGDisplayCreateImage cost & whether concurrent requests pipeline.
// usage: ./bench2 <displayID> [threads] [calls/thread]
// Defaults: main display, one worker, 60 calls. Each worker records its own
// per-call latency slice; total wall time reveals whether capture work overlaps.
// Resolve the header-obsoleted capture API dynamically, as the server does.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <pthread.h>
#import <mach/mach_time.h>

typedef struct {
    CGDirectDisplayID id;
    int calls;
    double *ms;
    uint64_t done;
} Args;

static void *worker(void *p) {
    Args *a = (Args *)p;
    CGImageRef (*myCGDisplayCreateImage)(CGDirectDisplayID) =
        (CGImageRef(*)(CGDirectDisplayID))dlsym(RTLD_DEFAULT, "CGDisplayCreateImage");
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    for (int i = 0; i < a->calls; i++) {
        uint64_t t0 = mach_absolute_time();
        CGImageRef img = myCGDisplayCreateImage(a->id);
        uint64_t t1 = mach_absolute_time();
        a->ms[i] = (double)(t1 - t0) * tb.numer / tb.denom / 1e6;
        if (img)
            CFRelease(img);
    }
    __sync_fetch_and_add(&a->done, 1);
    return NULL;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        CGDirectDisplayID id =
            argc > 1 ? (CGDirectDisplayID)strtoul(argv[1], NULL, 0) : CGMainDisplayID();
        int nthreads = argc > 2 ? atoi(argv[2]) : 1;
        int calls = argc > 3 ? atoi(argv[3]) : 60;
        printf("bench: display %u, %d thread(s), %d calls each\n", id, nthreads, calls);

        double *all = calloc((size_t)nthreads * calls, sizeof(double));
        Args *args = calloc((size_t)nthreads, sizeof(Args));
        pthread_t *tids = calloc((size_t)nthreads, sizeof(pthread_t));

        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        uint64_t T0 = mach_absolute_time();
        for (int i = 0; i < nthreads; i++) {
            args[i] = (Args){id, calls, all + (size_t)i * calls, 0};
            pthread_create(&tids[i], NULL, worker, &args[i]);
        }
        for (int i = 0; i < nthreads; i++)
            pthread_join(tids[i], NULL);
        uint64_t T1 = mach_absolute_time();
        double wall = (double)(T1 - T0) * tb.numer / tb.denom / 1e6;

        double sum = 0, mn = 1e9, mx = 0;
        int n = nthreads * calls;
        for (int i = 0; i < n; i++) {
            sum += all[i];
            if (all[i] < mn)
                mn = all[i];
            if (all[i] > mx)
                mx = all[i];
        }
        printf("  per-call: avg %.1fms  min %.1fms  max %.1fms\n", sum / n, mn, mx);
        printf("  wall: %.0fms for %d frames -> aggregate %.1f fps\n", wall, n, n * 1000.0 / wall);
    }
    return 0;
}
