#pragma once
#include <stdint.h>
#include <sys/types.h>

int32_t breeze_smc_open(uint32_t *connection);
void breeze_smc_close(uint32_t connection);
int32_t breeze_smc_read(uint32_t connection, const char *key, uint32_t *type, uint32_t *size, uint8_t *bytes);
int32_t breeze_smc_write(uint32_t connection, const char *key, uint32_t size, const uint8_t *bytes);
int32_t breeze_smc_key(uint32_t connection, uint32_t index, char *key);
int breeze_listen(const char *path);
int breeze_accept(int server, int timeout_ms);
int breeze_connect(const char *path);
int breeze_peer(int fd, uid_t *uid, pid_t *pid);
// Checks the socket's audit token against an Apple signature from our own team.
int breeze_authenticate_peer(int fd, const char *identifier);
int breeze_activate_socket(void);
int breeze_send(int fd, const char *bytes, size_t size);
// A newline-delimited frame, limited to capacity. 0 = timeout, -1 = closed/error.
int breeze_receive(int fd, char *bytes, size_t capacity, int timeout_ms);
double breeze_continuous_time(void);
void breeze_install_signals(void);
int breeze_stop_requested(void);
int breeze_system_stats(uint64_t *cpu_ticks, uint64_t *memory_used, uint64_t *memory_total);

// Read-only activity monitoring. CPU states: user, system, idle, nice.
int breeze_core_ticks(uint64_t *ticks, int capacity);
typedef struct {
    uint64_t total, app, wired, compressed, cached, swap_used, swap_total;
    int swap_valid;
    int pressure; // 1 normal, 2 warning, 4 critical, 0 unavailable
} BreezeMemory;
int breeze_memory(BreezeMemory *memory);
typedef struct {
    int32_t pid;
    uint32_t uid, threads;
    uint64_t start_seconds, start_microseconds, cpu_ns, resident, footprint;
    int has_task;
    char name[256];
} BreezeProcess;
int breeze_processes(BreezeProcess *rows, int capacity);
