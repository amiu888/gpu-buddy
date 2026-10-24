// gpupower: prints Apple Silicon power use once per interval as JSON lines, without sudo.
//
// Reads the "Energy Model" group of IOReport (the same counters powermetrics uses) and turns the
// energy used in each interval into watts:
//   {"dt": 1.0, "gpu_w": 42.5, "cpu_w": 10.1, "ane_w": 0.0, "dram_w": 8.3, "other_w": 14.7}
// "other" is the rest of the chip: fabric, memory controller, display, media engines.
//
// Build: clang -O2 -o gpupower gpupower.c -framework CoreFoundation -lIOReport
// Run:   ./gpupower [interval seconds]

#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef struct IOReportSubscription *IOReportSubscriptionRef;
extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);

// Top-level blocks of the chip besides CPU, GPU, ANE and DRAM. Sub-channels (per core, per
// cluster) are left out so nothing is counted twice.
static const char *OTHER[] = {"AFR", "ISP", "AVE", "MSR", "AMCC", "DCS", "DISP", "DISPEXT", "PMP", "SIO", "NPU", NULL};

static double joules(CFDictionaryRef ch) {
    char unit[16] = "";
    CFStringRef u = IOReportChannelGetUnitLabel(ch);
    if (u) CFStringGetCString(u, unit, sizeof unit, kCFStringEncodingUTF8);
    double v = (double)IOReportSimpleGetIntegerValue(ch, 0);
    if (!strcmp(unit, "nJ")) return v / 1e9;
    if (!strcmp(unit, "uJ")) return v / 1e6;
    return v / 1e3;  // mJ
}

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    double interval = argc > 1 ? atof(argv[1]) : 1.0;
    if (interval < 0.1) interval = 0.1;

    CFDictionaryRef channels = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (!channels) {
        fprintf(stderr, "gpupower: no Energy Model channels on this Mac\n");
        return 1;
    }
    CFMutableDictionaryRef wanted = CFDictionaryCreateMutableCopy(NULL, 0, channels);
    CFMutableDictionaryRef subbed = NULL;
    IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL, wanted, &subbed, 0, NULL);
    if (!sub) {
        fprintf(stderr, "gpupower: IOReport subscription failed\n");
        return 1;
    }

    CFDictionaryRef prev = IOReportCreateSamples(sub, subbed, NULL);
    double t0 = now();
    for (;;) {
        usleep((useconds_t)(interval * 1e6));
        CFDictionaryRef cur = IOReportCreateSamples(sub, subbed, NULL);
        double t1 = now(), dt = t1 - t0;
        CFDictionaryRef delta = IOReportCreateSamplesDelta(prev, cur, NULL);
        CFRelease(prev);
        prev = cur;
        t0 = t1;
        if (!delta) continue;

        double gpu = 0, gpu_mj = 0, cpu = 0, ane = 0, dram = 0, other = 0;
        CFArrayRef arr = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
        for (CFIndex i = 0; arr && i < CFArrayGetCount(arr); i++) {
            CFDictionaryRef ch = CFArrayGetValueAtIndex(arr, i);
            char name[128] = "";
            CFStringGetCString(IOReportChannelGetChannelName(ch), name, sizeof name, kCFStringEncodingUTF8);
            if (!strcmp(name, "GPU Energy")) gpu = joules(ch);        // finest-grained (nJ)
            else if (!strcmp(name, "GPU")) gpu_mj = joules(ch);       // older chips only have this
            else if (!strcmp(name, "CPU Energy")) cpu = joules(ch);
            else if (!strncmp(name, "ANE", 3)) ane += joules(ch);
            else if (!strcmp(name, "DRAM")) dram = joules(ch);
            else
                for (const char **o = OTHER; *o; o++)
                    if (!strcmp(name, *o)) other += joules(ch);
        }
        CFRelease(delta);
        if (gpu == 0) gpu = gpu_mj;
        printf("{\"dt\": %.4f, \"gpu_w\": %.3f, \"cpu_w\": %.3f, \"ane_w\": %.3f, \"dram_w\": %.3f, \"other_w\": %.3f}\n",
               dt, gpu / dt, cpu / dt, ane / dt, dram / dt, other / dt);
        fflush(stdout);
    }
}
