#include "CHardware.h"
#include <IOKit/IOKitLib.h>
#include <mach/mach_time.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <poll.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stddef.h>
#include <signal.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <Security/Security.h>
#include <launch.h>
#include <stdlib.h>

// AppleSMC user-client selector 2, 80-byte wire layout.
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } Version;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } Limits;
typedef struct { uint32_t size, type; uint8_t attributes; } KeyInfo;
typedef struct {
    uint32_t key; Version version; Limits limits; KeyInfo info;
    uint8_t result, status, command; uint32_t value; uint8_t bytes[32];
} Packet;
_Static_assert(sizeof(Packet) == 80, "AppleSMC packet size");
_Static_assert(offsetof(Packet, bytes) == 48, "AppleSMC bytes offset");
_Static_assert(offsetof(Packet, result) == 40, "AppleSMC result offset");

static volatile sig_atomic_t stop_requested = 0;
static void request_stop(int signal_number) { stop_requested = 1; }
void breeze_install_signals(void) {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, request_stop);
    signal(SIGINT, request_stop);
    signal(SIGHUP, request_stop);
}
int breeze_stop_requested(void) { return stop_requested; }

int breeze_system_stats(uint64_t *ticks, uint64_t *used, uint64_t *total) {
    host_cpu_load_info_data_t cpu;
    mach_msg_type_number_t cpu_count = HOST_CPU_LOAD_INFO_COUNT;
    mach_port_t host = mach_host_self();
    if (host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&cpu, &cpu_count) != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), host); return -1;
    }
    for (int i=0; i<CPU_STATE_MAX; i++) ticks[i] = cpu.cpu_ticks[i];
    vm_statistics64_data_t vm;
    mach_msg_type_number_t vm_count = HOST_VM_INFO64_COUNT;
    vm_size_t page_size = 0;
    if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &vm_count) != KERN_SUCCESS ||
        host_page_size(host, &page_size) != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), host); return -1;
    }
    size_t size = sizeof(*total);
    if (sysctlbyname("hw.memsize", total, &size, NULL, 0)) {
        mach_port_deallocate(mach_task_self(), host); return -1;
    }
    // Matches the memory-used components: app/private active pages, wired, and compressor storage.
    uint64_t app_pages = (uint64_t)vm.active_count + vm.inactive_count;
    app_pages = app_pages > vm.purgeable_count ? app_pages-vm.purgeable_count : 0;
    app_pages = app_pages > vm.external_page_count ? app_pages-vm.external_page_count : 0;
    *used = (app_pages + vm.wire_count + vm.compressor_page_count) * page_size;
    if (*used > *total) *used = *total;
    mach_port_deallocate(mach_task_self(), host);
    return 0;
}

static uint32_t code(const char *key) {
    return (uint32_t)(uint8_t)key[0]<<24 | (uint32_t)(uint8_t)key[1]<<16 |
           (uint32_t)(uint8_t)key[2]<<8 | (uint8_t)key[3];
}
static int32_t call(uint32_t c, Packet *in, Packet *out) {
    size_t size = sizeof(*out);
    kern_return_t result = IOConnectCallStructMethod(c, 2, in, sizeof(*in), out, &size);
    if (result) return result;
    if (size != sizeof(*out)) return -1000;
    return out->result ? -(int32_t)out->result : 0;
}
int32_t breeze_smc_open(uint32_t *connection) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return -1001;
    int32_t result = IOServiceOpen(service, mach_task_self(), 0, connection);
    IOObjectRelease(service);
    return result;
}
void breeze_smc_close(uint32_t c) { if (c) IOServiceClose(c); }
int32_t breeze_smc_read(uint32_t c, const char *key, uint32_t *type, uint32_t *size, uint8_t *bytes) {
    if (strlen(key) != 4) return -1002;
    Packet in = {0}, out = {0}; in.key = code(key); in.command = 9;
    int32_t result = call(c, &in, &out);
    if (result) return result;
    if (!out.info.size || out.info.size > 32) return -1003;
    *type = out.info.type; *size = out.info.size;
    in.info = out.info; in.command = 5;
    result = call(c, &in, &out);
    if (!result) memcpy(bytes, out.bytes, *size);
    return result;
}
int32_t breeze_smc_write(uint32_t c, const char *key, uint32_t size, const uint8_t *bytes) {
    if (strlen(key) != 4 || !size || size > 32) return -1002;
    Packet in = {0}, out = {0}; in.key = code(key); in.command = 9;
    int32_t result = call(c, &in, &out);
    if (result) return result;
    if (size != out.info.size) return -1003;
    in.info = out.info; in.command = 6;
    memcpy(in.bytes, bytes, size);
    return call(c, &in, &out);
}
int32_t breeze_smc_key(uint32_t c, uint32_t index, char *key) {
    Packet in = {0}, out = {0}; in.command = 8; in.value = index;
    int32_t result = call(c, &in, &out);
    if (!result) {
        for (int i=0; i<4; i++) key[i] = (char)(out.key >> (24-8*i));
        key[4] = 0;
    }
    return result;
}
static int make_socket(const char *path, int server) {
    struct sockaddr_un address = {0};
    if (strlen(path) >= sizeof(address.sun_path)) { errno = ENAMETOOLONG; return -1; }
    address.sun_family = AF_UNIX;
    address.sun_len = sizeof(address);
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int yes = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    struct timeval timeout = {.tv_sec=2};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    int result = server ? bind(fd, (struct sockaddr *)&address, sizeof(address)) :
                          connect(fd, (struct sockaddr *)&address, sizeof(address));
    if (result || (server && listen(fd, 1))) { close(fd); return -1; }
    return fd;
}
int breeze_listen(const char *p) { return make_socket(p, 1); }
int breeze_connect(const char *p) { return make_socket(p, 0); }
int breeze_accept(int server, int timeout_ms) {
    struct pollfd p = {.fd=server, .events=POLLIN};
    if (poll(&p, 1, timeout_ms) <= 0) return -1;
    int fd = accept(server, NULL, NULL);
    if (fd >= 0) {
        int yes=1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
        struct timeval timeout = {.tv_sec=2};
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    }
    return fd;
}
int breeze_peer(int fd, uid_t *uid, pid_t *pid) {
    gid_t gid; socklen_t size = sizeof(*pid);
    if (getpeereid(fd, uid, &gid)) return -1;
    return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, pid, &size);
}
int breeze_activate_socket(void) {
    int *fds = NULL;
    size_t count = 0;
    if (launch_activate_socket("Control", &fds, &count) != 0) return -1;
    if (count != 1) {
        for (size_t i = 0; i < count; i++) close(fds[i]);
        free(fds);
        return -1;
    }
    int fd = fds[0];
    free(fds);
    return fd;
}
int breeze_authenticate_peer(int fd, const char *identifier) {
    audit_token_t token;
    socklen_t size = sizeof(token);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) || size != sizeof(token)) return -1;

    SecCodeRef self = NULL, peer = NULL;
    CFDictionaryRef info = NULL, attributes = NULL;
    CFDataRef audit = NULL;
    CFStringRef text = NULL;
    SecRequirementRef requirement = NULL;
    int result = -1;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &self) != errSecSuccess ||
        SecCodeCopySigningInformation(self, kSecCSSigningInformation, &info) != errSecSuccess) goto done;
    CFStringRef team = CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier);
    if (!team || CFGetTypeID(team) != CFStringGetTypeID()) goto done;
    // Only interpolate a real Team ID and the two compile-time Breeze identifiers.
    char team_id[11];
    if (!CFStringGetCString(team, team_id, sizeof(team_id), kCFStringEncodingASCII) || strlen(team_id) != 10) goto done;
    for (int i = 0; i < 10; i++) {
        if (!((team_id[i] >= 'A' && team_id[i] <= 'Z') || (team_id[i] >= '0' && team_id[i] <= '9'))) goto done;
    }
    if (strcmp(identifier, "local.breeze.fancontrol") && strcmp(identifier, "local.breeze.fancontrol.helper")) goto done;
    text = CFStringCreateWithFormat(NULL, NULL,
        CFSTR("anchor apple generic and identifier \"%s\" and certificate leaf[subject.OU] = \"%s\""), identifier, team_id);
    if (!text || SecRequirementCreateWithString(text, kSecCSDefaultFlags, &requirement) != errSecSuccess) goto done;
    audit = CFDataCreate(NULL, (const UInt8 *)&token, sizeof(token));
    if (!audit) goto done;
    const void *keys[] = { kSecGuestAttributeAudit };
    const void *values[] = { audit };
    attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!attributes || SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &peer) != errSecSuccess) goto done;
    if (SecCodeCheckValidity(peer, kSecCSStrictValidate, requirement) == errSecSuccess) result = 0;
done:
    if (requirement) CFRelease(requirement);
    if (text) CFRelease(text);
    if (attributes) CFRelease(attributes);
    if (audit) CFRelease(audit);
    if (info) CFRelease(info);
    if (peer) CFRelease(peer);
    if (self) CFRelease(self);
    return result;
}
int breeze_send(int fd, const char *bytes, size_t size) {
    size_t sent=0;
    while (sent < size) {
        ssize_t n = send(fd, bytes+sent, size-sent, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        sent += (size_t)n;
    }
    return 0;
}
double breeze_continuous_time(void) {
    mach_timebase_info_data_t info; mach_timebase_info(&info);
    return (double)mach_continuous_time() * info.numer / info.denom / 1e9;
}
int breeze_receive(int fd, char *bytes, size_t capacity, int timeout_ms) {
    double deadline = breeze_continuous_time() + timeout_ms/1000.0;
    size_t count=0;
    while (count+1 < capacity) {
        int remaining = (int)((deadline-breeze_continuous_time())*1000);
        if (remaining <= 0) return count ? -1 : 0;
        struct pollfd p = {.fd=fd, .events=POLLIN};
        int ready = poll(&p, 1, remaining);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) return count ? -1 : 0;
        char ch;
        ssize_t n = recv(fd, &ch, 1, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        if (ch == '\n') { bytes[count]=0; return (int)count; }
        bytes[count++] = ch;
    }
    return -1;
}
