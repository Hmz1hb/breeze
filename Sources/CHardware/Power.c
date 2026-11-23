#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdlib.h>
#include <string.h>
#include "CHardware.h"

// IOReport is private but stable across Apple silicon releases; the same channels
// back powermetrics. Prototypes follow the public libIOReport.tbd symbols.
typedef CFTypeRef IOReportSubscriptionRef;
extern CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern void IOReportMergeChannels(CFMutableDictionaryRef, CFMutableDictionaryRef, CFTypeRef);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
extern int32_t IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);

#define FREQ_CAPACITY 64
typedef struct {
    IOReportSubscriptionRef subscription;
    CFMutableDictionaryRef channels;
    CFDictionaryRef previous;
    double previous_time;
    double ecpu[FREQ_CAPACITY], pcpu[FREQ_CAPACITY], gpu[FREQ_CAPACITY];
    int ecpu_count, pcpu_count, gpu_count;
} PowerReader;

typedef struct { double weighted, frequency_residency, active, total; } Residency;

static int equals(CFStringRef value, CFStringRef expected) {
    return value && CFStringCompare(value, expected, 0) == kCFCompareEqualTo;
}

// Pairs of little-endian (frequency, voltage). M1–M3 publish Hz; later chips publish kHz.
static int dvfs(CFDictionaryRef properties, CFStringRef key, double *out) {
    CFDataRef data = CFDictionaryGetValue(properties, key);
    if (!data || CFGetTypeID(data) != CFDataGetTypeID()) return 0;
    const uint8_t *bytes = CFDataGetBytePtr(data);
    CFIndex length = CFDataGetLength(data);
    uint32_t raw[FREQ_CAPACITY], maximum = 0;
    int n = 0;
    for (CFIndex i = 0; i + 8 <= length && n < FREQ_CAPACITY; i += 8) {
        memcpy(&raw[n], bytes + i, 4);
        if (raw[n] > maximum) maximum = raw[n];
        n++;
    }
    double scale = maximum > 100000000 ? 1e6 : 1e3;
    int count = 0;
    for (int i = 0; i < n; i++) if (raw[i] > 0) out[count++] = raw[i] / scale;
    return count;
}

static void read_frequencies(PowerReader *reader) {
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) != KERN_SUCCESS) return;
    io_object_t entry;
    while ((entry = IOIteratorNext(iterator))) {
        io_name_t name = {0};
        if (IORegistryEntryGetName(entry, name) == KERN_SUCCESS && strcmp(name, "pmgr") == 0) {
            CFMutableDictionaryRef properties = NULL;
            if (IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS && properties) {
                reader->ecpu_count = dvfs(properties, CFSTR("voltage-states1-sram"), reader->ecpu);
                reader->pcpu_count = dvfs(properties, CFSTR("voltage-states5-sram"), reader->pcpu);
                reader->gpu_count = dvfs(properties, CFSTR("voltage-states9"), reader->gpu);
                CFRelease(properties);
            }
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iterator);
}

void *breeze_power_open(void) {
    CFMutableDictionaryRef energy = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (!energy) return NULL;
    CFMutableDictionaryRef cpu = IOReportCopyChannelsInGroup(CFSTR("CPU Stats"), CFSTR("CPU Complex Performance States"), 0, 0, 0);
    CFMutableDictionaryRef gpu = IOReportCopyChannelsInGroup(CFSTR("GPU Stats"), CFSTR("GPU Performance States"), 0, 0, 0);
    if (cpu) { IOReportMergeChannels(energy, cpu, NULL); CFRelease(cpu); }
    if (gpu) { IOReportMergeChannels(energy, gpu, NULL); CFRelease(gpu); }
    PowerReader *reader = calloc(1, sizeof(PowerReader));
    if (!reader) { CFRelease(energy); return NULL; }
    reader->channels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(energy), energy);
    CFRelease(energy);
    CFMutableDictionaryRef subscribed = NULL;
    reader->subscription = IOReportCreateSubscription(NULL, reader->channels, &subscribed, 0, NULL);
    if (subscribed) CFRelease(subscribed);
    if (!reader->subscription) { breeze_power_close(reader); return NULL; }
    read_frequencies(reader);
    return reader;
}

void breeze_power_close(void *handle) {
    PowerReader *reader = handle;
    if (!reader) return;
    if (reader->previous) CFRelease(reader->previous);
    if (reader->subscription) CFRelease(reader->subscription);
    if (reader->channels) CFRelease(reader->channels);
    free(reader);
}

static void residency(CFDictionaryRef item, const double *frequencies, int count, Residency *out) {
    int32_t states = IOReportStateGetCount(item);
    int index = 0;
    for (int32_t i = 0; i < states; i++) {
        double value = (double)IOReportStateGetResidency(item, i);
        CFStringRef name = IOReportStateGetNameForIndex(item, i);
        out->total += value;
        if (equals(name, CFSTR("IDLE")) || equals(name, CFSTR("OFF")) || equals(name, CFSTR("DOWN"))) continue;
        out->active += value;
        if (index < count) {
            out->weighted += value * frequencies[index];
            out->frequency_residency += value;
        }
        index++;
    }
}

static void finish(Residency r, double *mhz, double *active) {
    *mhz = r.frequency_residency > 0 ? r.weighted / r.frequency_residency : 0;
    *active = r.total > 0 ? r.active / r.total : -1;
}

int breeze_power_sample(void *handle, BreezePower *out) {
    PowerReader *reader = handle;
    if (!reader || !out) return -1;
    memset(out, 0, sizeof(*out));
    CFDictionaryRef current = IOReportCreateSamples(reader->subscription, reader->channels, NULL);
    if (!current) return -1;
    double now = breeze_continuous_time();
    if (!reader->previous) {
        reader->previous = current; reader->previous_time = now;
        return 1; // The first sample is a baseline.
    }
    CFDictionaryRef delta = IOReportCreateSamplesDelta(reader->previous, current, NULL);
    double elapsed = now - reader->previous_time;
    CFRelease(reader->previous);
    reader->previous = current; reader->previous_time = now;
    if (!delta) return -1;
    if (elapsed <= 0) { CFRelease(delta); return 1; }

    Residency ecpu = {0}, pcpu = {0}, gpu = {0};
    CFArrayRef items = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    CFIndex count = items && CFGetTypeID(items) == CFArrayGetTypeID() ? CFArrayGetCount(items) : 0;
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef item = CFArrayGetValueAtIndex(items, i);
        CFStringRef group = IOReportChannelGetGroup(item), name = IOReportChannelGetChannelName(item);
        if (!group || !name) continue;
        if (equals(group, CFSTR("Energy Model"))) {
            CFStringRef unit = IOReportChannelGetUnitLabel(item);
            double scale = equals(unit, CFSTR("mJ")) ? 1e3 : equals(unit, CFSTR("uJ")) ? 1e6 : equals(unit, CFSTR("nJ")) ? 1e9 : 0;
            if (scale == 0) continue;
            double watts = (double)IOReportSimpleGetIntegerValue(item, 0) / scale / elapsed;
            if (CFStringHasSuffix(name, CFSTR("CPU Energy"))) out->cpu_watts += watts;
            else if (equals(name, CFSTR("GPU Energy"))) out->gpu_watts += watts;
            else if (CFStringHasPrefix(name, CFSTR("ANE"))) out->ane_watts += watts;
            else if (CFStringHasPrefix(name, CFSTR("DRAM"))) out->dram_watts += watts;
            out->has_energy = 1;
        } else if (equals(group, CFSTR("CPU Stats")) && equals(IOReportChannelGetSubGroup(item), CFSTR("CPU Complex Performance States"))) {
            if (CFStringHasPrefix(name, CFSTR("ECPU"))) residency(item, reader->ecpu, reader->ecpu_count, &ecpu);
            else if (CFStringHasPrefix(name, CFSTR("PCPU"))) residency(item, reader->pcpu, reader->pcpu_count, &pcpu);
        } else if (equals(group, CFSTR("GPU Stats")) && equals(name, CFSTR("GPUPH"))) {
            residency(item, reader->gpu, reader->gpu_count, &gpu);
        }
    }
    CFRelease(delta);
    finish(ecpu, &out->ecpu_mhz, &out->ecpu_active);
    finish(pcpu, &out->pcpu_mhz, &out->pcpu_active);
    finish(gpu, &out->gpu_mhz, &out->gpu_active);
    return 0;
}
