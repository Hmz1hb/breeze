#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include "CHardware.h"

// NetworkStatistics.framework is the private client nettop and Activity Monitor use. It streams
// cumulative per-flow counts, including final counts when a flow closes, at about 1% CPU;
// a long-running nettop costs over 100%. Unprivileged readers see every process while
// net.statistics_privcheck is 0, the macOS default.
typedef void *NStatRef;
typedef struct { long long rx, tx; int pid; int seen; int baseline; } Source;
typedef struct {
    void *library;
    NStatRef manager;
    dispatch_queue_t queue;
    int primed;
    BreezeAppTraffic *apps;
    int count, capacity;
    void (*query_all)(NStatRef, void (^)(void));
    void (*destroy)(NStatRef);
} Reader;

static long long number(CFDictionaryRef dictionary, CFStringRef key) {
    long long value = 0;
    CFTypeRef item = key ? CFDictionaryGetValue(dictionary, key) : NULL;
    if (item && CFGetTypeID(item) == CFNumberGetTypeID()) CFNumberGetValue(item, kCFNumberLongLongType, &value);
    return value;
}

// ponytail: linear pid lookup; a few hundred networked processes per session is cheap.
static BreezeAppTraffic *app(Reader *reader, int pid) {
    for (int i = 0; i < reader->count; i++) if (reader->apps[i].pid == pid) return &reader->apps[i];
    if (reader->count == reader->capacity) {
        int capacity = reader->capacity ? reader->capacity * 2 : 128;
        BreezeAppTraffic *grown = realloc(reader->apps, sizeof *grown * capacity);
        if (!grown) return NULL;
        reader->apps = grown; reader->capacity = capacity;
    }
    BreezeAppTraffic *entry = &reader->apps[reader->count++];
    memset(entry, 0, sizeof *entry);
    entry->pid = pid;
    return entry;
}

void *breeze_traffic_open(void) {
    void *library = dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_LAZY);
    if (!library) return NULL;
    NStatRef (*create)(CFAllocatorRef, dispatch_queue_t, void (^)(NStatRef, void *)) = dlsym(library, "NStatManagerCreate");
    void (*add_tcp)(NStatRef) = dlsym(library, "NStatManagerAddAllTCP");
    void (*add_udp)(NStatRef) = dlsym(library, "NStatManagerAddAllUDP");
    void (*set_counts)(NStatRef, void (^)(CFDictionaryRef)) = dlsym(library, "NStatSourceSetCountsBlock");
    void (*set_description)(NStatRef, void (^)(CFDictionaryRef)) = dlsym(library, "NStatSourceSetDescriptionBlock");
    void (*set_removed)(NStatRef, void (^)(void)) = dlsym(library, "NStatSourceSetRemovedBlock");
    void (*query_description)(NStatRef) = dlsym(library, "NStatSourceQueryDescription");
    CFStringRef *rx_key = dlsym(library, "kNStatSrcKeyRxBytes"), *tx_key = dlsym(library, "kNStatSrcKeyTxBytes");
    CFStringRef *pid_key = dlsym(library, "kNStatSrcKeyPID"), *name_key = dlsym(library, "kNStatSrcKeyProcessName");
    Reader *reader = calloc(1, sizeof *reader);
    if (reader) {
        reader->query_all = dlsym(library, "NStatManagerQueryAllSources");
        reader->destroy = dlsym(library, "NStatManagerDestroy");
    }
    if (!reader || !create || !add_tcp || !add_udp || !set_counts || !set_description || !set_removed ||
        !query_description || !reader->query_all || !reader->destroy || !rx_key || !tx_key || !pid_key || !name_key) {
        free(reader); dlclose(library); return NULL;
    }
    reader->library = library;
    reader->queue = dispatch_queue_create("local.breeze.traffic", DISPATCH_QUEUE_SERIAL);
    CFStringRef rx = *rx_key, tx = *tx_key, pid = *pid_key, name = *name_key;
    reader->manager = create(kCFAllocatorDefault, reader->queue, ^(NStatRef source, void *unused) {
        (void)unused;
        Source *flow = calloc(1, sizeof *flow);
        if (!flow) return;
        flow->pid = -1;
        // Flows open before the first query carry earlier traffic; that becomes the baseline.
        flow->baseline = !reader->primed;
        set_description(source, ^(CFDictionaryRef description) {
            flow->pid = (int)number(description, pid);
            BreezeAppTraffic *entry = app(reader, flow->pid);
            CFTypeRef value = CFDictionaryGetValue(description, name);
            if (entry && !entry->name[0] && value && CFGetTypeID(value) == CFStringGetTypeID())
                CFStringGetCString(value, entry->name, sizeof entry->name, kCFStringEncodingUTF8);
        });
        set_counts(source, ^(CFDictionaryRef counts) {
            long long received = number(counts, rx), sent = number(counts, tx);
            BreezeAppTraffic *entry = flow->pid >= 0 ? app(reader, flow->pid) : NULL;
            // Until the description names the pid, rx/tx stay unread and the next count attributes them.
            if (!entry) return;
            if (flow->seen || !flow->baseline) {
                if (received > flow->rx) entry->received += (uint64_t)(received - flow->rx);
                if (sent > flow->tx) entry->sent += (uint64_t)(sent - flow->tx);
            }
            flow->rx = received; flow->tx = sent; flow->seen = 1;
        });
        // A removed flow has already delivered its final counts; free it once stray callbacks have drained.
        set_removed(source, ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), reader->queue, ^{ free(flow); });
        });
        query_description(source);
    });
    if (!reader->manager) { free(reader); dlclose(library); return NULL; }
    add_tcp(reader->manager);
    add_udp(reader->manager);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    reader->query_all(reader->manager, ^{ dispatch_semaphore_signal(done); });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    dispatch_sync(reader->queue, ^{ reader->primed = 1; });
    return reader;
}

int breeze_traffic_read(void *opaque, BreezeAppTraffic *rows, int capacity) {
    Reader *reader = opaque;
    if (!reader) return -1;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    reader->query_all(reader->manager, ^{ dispatch_semaphore_signal(done); });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
    __block int written = 0;
    dispatch_sync(reader->queue, ^{
        for (int i = 0; i < reader->count && written < capacity; i++)
            if (reader->apps[i].received || reader->apps[i].sent) rows[written++] = reader->apps[i];
    });
    return written;
}

void breeze_traffic_close(void *opaque) {
    Reader *reader = opaque;
    if (!reader) return;
    reader->destroy(reader->manager);
    dispatch_sync(reader->queue, ^{});
    free(reader->apps);
    free(reader);
    // The framework stays loaded: late blocks may still reference its code.
}
