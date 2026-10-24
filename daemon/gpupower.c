// gpupower: prints Apple Silicon power use once per interval as JSON lines, without sudo.
//
// Reads the "Energy Model" group of IOReport (the same counters powermetrics uses) and turns the
// energy used in each interval into watts:
//   {"dt": 1.0, "gpu_w": 42.5, "cpu_w": 10.1, "ane_w": 0.0, "dram_w": 8.3, "other_w": 14.7}
// "other" is the rest of the chip: fabric, memory controller, display, media engines.
// "system_w" is the whole Mac as the SMC's power sensor sees it (PSTR), or null where there isn't one.
//
// Build: clang -O2 -o gpupower gpupower.c -framework CoreFoundation -framework IOKit -lIOReport
// Run:   ./gpupower [interval seconds]

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
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

// The SMC's struct interface (as used by every fan/power monitor); reading keys needs no privileges.
typedef struct { char major, minor, build, reserved[1]; unsigned short release; } SMCVers;
typedef struct { unsigned short version, length; unsigned int cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { unsigned int dataSize, dataType; char dataAttributes; } SMCKeyInfo;
typedef struct {
    unsigned int key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    char result, status, data8;
    unsigned int data32;
    unsigned char bytes[32];
} SMCParam;

static io_connect_t smc;

/// Total system power in watts from the SMC key PSTR, or -1 if this Mac doesn't have it.
static double system_watts(void) {
    if (!smc) return -1;
    SMCParam in = {0}, out = {0};
    size_t size = sizeof out;
    in.key = ('P' << 24) | ('S' << 16) | ('T' << 8) | 'R';
    in.data8 = 9;  // key info
    if (IOConnectCallStructMethod(smc, 2, &in, sizeof in, &out, &size) || out.result) return -1;
    if (out.keyInfo.dataType != (('f' << 24) | ('l' << 16) | ('t' << 8) | ' ')) return -1;
    in.keyInfo.dataSize = out.keyInfo.dataSize;
    in.data8 = 5;  // read
    size = sizeof out;
    if (IOConnectCallStructMethod(smc, 2, &in, sizeof in, &out, &size) || out.result) return -1;
    float w;
    memcpy(&w, out.bytes, sizeof w);
    return w;
}

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

    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (svc && IOServiceOpen(svc, mach_task_self(), 0, &smc) != KERN_SUCCESS) smc = 0;

    CFDictionaryRef prev = IOReportCreateSamples(sub, subbed, NULL);
    double t0 = now();
    for (;;) {
        // PSTR is instantaneous, so average a few readings across the interval.
        double sys = 0;
        int n = 0;
        for (int i = 0; i < 4; i++) {
            usleep((useconds_t)(interval * 1e6 / 4));
            double w = system_watts();
            if (w >= 0) {
                sys += w;
                n++;
            }
        }
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
        char system[32] = "null";
        if (n) snprintf(system, sizeof system, "%.3f", sys / n);
        printf("{\"dt\": %.4f, \"gpu_w\": %.3f, \"cpu_w\": %.3f, \"ane_w\": %.3f, \"dram_w\": %.3f, \"other_w\": %.3f, "
               "\"system_w\": %s}\n", dt, gpu / dt, cpu / dt, ane / dt, dram / dt, other / dt, system);
        fflush(stdout);
    }
}
