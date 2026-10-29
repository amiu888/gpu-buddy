// gpupower: prints Apple Silicon power use once per interval as JSON lines, without sudo.
//
// Reads the "Energy Model" group of IOReport (the same counters powermetrics uses) and turns the
// energy used in each interval into watts:
//   {"dt": 1.0, "gpu_w": 42.5, "cpu_w": 10.1, "ane_w": 0.0, "dram_w": 8.3, "other_w": 14.7}
// "other" is the rest of the chip: fabric, memory controller, display, media engines.
// "system_w" is the whole Mac as the SMC's power sensor sees it (PSTR), or null where there isn't one.
// "gpu_temp" is the average of the SMC's GPU temperature sensors in Celsius, or null where none are known.
// SMC reads can take 50+ ms each, so they run on their own thread and never delay the power readings.
//
// Build: clang -O2 -o gpupower gpupower.c -framework CoreFoundation -framework IOKit -lIOReport
// Run:   ./gpupower [interval seconds]

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <pthread.h>
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

#define KEY(s) (((unsigned)(s)[0] << 24) | ((unsigned)(s)[1] << 16) | ((unsigned)(s)[2] << 8) | (unsigned)(s)[3])

/// A float ("flt ") SMC key, or -1 if this Mac doesn't have it.
static double smc_float(unsigned int key) {
    if (!smc) return -1;
    SMCParam in = {0}, out = {0};
    size_t size = sizeof out;
    in.key = key;
    in.data8 = 9;  // key info
    if (IOConnectCallStructMethod(smc, 2, &in, sizeof in, &out, &size) || out.result) return -1;
    if (out.keyInfo.dataType != KEY("flt ")) return -1;
    in.keyInfo.dataSize = out.keyInfo.dataSize;
    in.data8 = 5;  // read
    size = sizeof out;
    if (IOConnectCallStructMethod(smc, 2, &in, sizeof in, &out, &size) || out.result) return -1;
    float v;
    memcpy(&v, out.bytes, sizeof v);
    return v;
}

// GPU temperature sensors, M1 to M4 (the same keys fan and sensor apps use). Each Mac has some of them.
static const char *GPU_TEMP_KEYS[] = {
    "Tg05", "Tg0D", "Tg0L", "Tg0T",                                          // M1
    "Tg0f", "Tg0j",                                                          // M2
    "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A",          // M3
    "Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0d", "Tg0e", "Tg0k",          // M4
    NULL};

// Shared between the SMC thread and the main loop.
static pthread_mutex_t smc_lock = PTHREAD_MUTEX_INITIALIZER;
static double sys_sum = 0;   // PSTR readings since the main loop last took them
static int sys_n = 0;
static double gpu_temp = -1; // latest GPU temperature, -1 if unknown

/// Reads whole-Mac power (PSTR) about 4 times per interval, and GPU temperature every 5 seconds.
static void *smc_thread(void *arg) {
    double interval = *(double *)arg;
    unsigned int keys[32];
    int nkeys = 0;
    for (const char **k = GPU_TEMP_KEYS; *k && nkeys < 32; k++)
        if (smc_float(KEY(*k)) > 0) keys[nkeys++] = KEY(*k);  // keep only the sensors this Mac has
    double last_temp = 0;
    for (;;) {
        double w = smc_float(KEY("PSTR"));
        if (w >= 0) {
            pthread_mutex_lock(&smc_lock);
            sys_sum += w;
            sys_n++;
            pthread_mutex_unlock(&smc_lock);
        }
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        double t = ts.tv_sec + ts.tv_nsec / 1e9;
        if (nkeys && t - last_temp >= 5) {
            last_temp = t;
            double sum = 0;
            int n = 0;
            for (int i = 0; i < nkeys; i++) {
                double c = smc_float(keys[i]);
                if (c > 0 && c < 150) {
                    sum += c;
                    n++;
                }
            }
            pthread_mutex_lock(&smc_lock);
            gpu_temp = n ? sum / n : -1;
            pthread_mutex_unlock(&smc_lock);
        }
        usleep((useconds_t)(interval * 1e6 / 4));
    }
    return NULL;
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
    pthread_t smc_t;
    if (smc) pthread_create(&smc_t, NULL, smc_thread, &interval);

    CFDictionaryRef prev = IOReportCreateSamples(sub, subbed, NULL);
    double t0 = now();
    double last_sys = -1, last_sys_t = 0;  // the slow SMC can miss an interval: reuse a reading up to 5 s old
    for (;;) {
        usleep((useconds_t)(interval * 1e6));
        // PSTR is instantaneous, so the SMC thread averages several readings across the interval.
        pthread_mutex_lock(&smc_lock);
        double sys = sys_sum, temp_c = gpu_temp;
        int n = sys_n;
        sys_sum = 0;
        sys_n = 0;
        pthread_mutex_unlock(&smc_lock);
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
        if (gpu == 0) gpu = gpu_mj;
        CFRelease(delta);
        if (n) {
            last_sys = sys / n;
            last_sys_t = t1;
        }
        char system[32] = "null";
        if (last_sys >= 0 && t1 - last_sys_t <= 5) snprintf(system, sizeof system, "%.3f", last_sys);
        char temp[32] = "null";
        if (temp_c > 0) snprintf(temp, sizeof temp, "%.1f", temp_c);
        printf("{\"dt\": %.4f, \"gpu_w\": %.3f, \"cpu_w\": %.3f, \"ane_w\": %.3f, \"dram_w\": %.3f, \"other_w\": %.3f, "
               "\"system_w\": %s, \"gpu_temp\": %s}\n", dt, gpu / dt, cpu / dt, ane / dt, dram / dt, other / dt,
               system, temp);
        fflush(stdout);
    }
}
