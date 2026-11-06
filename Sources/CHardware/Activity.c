#include "CHardware.h"
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <sys/proc_info.h>
#include <libproc.h>
#include <stdlib.h>
#include <string.h>

int breeze_core_ticks(uint64_t *ticks, int capacity) {
    natural_t cores = 0;
    processor_info_array_t info = NULL;
    mach_msg_type_number_t count = 0;
    mach_port_t host = mach_host_self();
    kern_return_t result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cores, &info, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (result != KERN_SUCCESS) return -1;
    int copied = (int)cores < capacity ? (int)cores : capacity;
    for (int i = 0; i < copied * CPU_STATE_MAX; i++) ticks[i] = (uint32_t)info[i];
    vm_deallocate(mach_task_self(), (vm_address_t)info, count * sizeof(integer_t));
    return copied;
}

int breeze_memory(BreezeMemory *out) {
    memset(out, 0, sizeof(*out));
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    vm_size_t page = 0;
    mach_port_t host = mach_host_self();
    int ok = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count) == KERN_SUCCESS &&
        host_page_size(host, &page) == KERN_SUCCESS;
    mach_port_deallocate(mach_task_self(), host);
    size_t size = sizeof(out->total);
    if (!ok || sysctlbyname("hw.memsize", &out->total, &size, NULL, 0)) return -1;
    uint64_t app = (uint64_t)vm.active_count + vm.inactive_count;
    uint64_t reclaimable = (uint64_t)vm.purgeable_count + vm.external_page_count;
    out->app = (app > reclaimable ? app - reclaimable : 0) * page;
    out->wired = (uint64_t)vm.wire_count * page;
    out->compressed = (uint64_t)vm.compressor_page_count * page;
    out->cached = reclaimable * page;
    struct xsw_usage swap = {0};
    size = sizeof(swap);
    if (!sysctlbyname("vm.swapusage", &swap, &size, NULL, 0)) {
        out->swap_valid = 1;
        out->swap_used = swap.xsu_used; out->swap_total = swap.xsu_total;
    }
    size = sizeof(out->pressure);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &out->pressure, &size, NULL, 0)) out->pressure = 0;
    return 0;
}

int breeze_processes(BreezeProcess *rows, int capacity) {
    int bytes = proc_listallpids(NULL, 0);
    if (bytes <= 0) return -1;
    int slots = bytes + 256; // proc_listallpids returns a PID count, not bytes.
    pid_t *pids = calloc((size_t)slots, sizeof(pid_t));
    if (!pids) return -1;
    int count = proc_listallpids(pids, slots * (int)sizeof(pid_t));
    if (count < 0) { free(pids); return -1; }
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    int n = 0;
    for (int i = 0; i < count && n < capacity; i++) {
        if (pids[i] <= 0) continue;
        struct proc_bsdinfo bsd = {0};
        if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) != sizeof(bsd)) continue;
        BreezeProcess row = {0};
        row.pid = pids[i]; row.uid = bsd.pbi_uid;
        row.start_seconds = bsd.pbi_start_tvsec; row.start_microseconds = bsd.pbi_start_tvusec;
        proc_name(pids[i], row.name, sizeof(row.name));
        if (!row.name[0]) strlcpy(row.name, bsd.pbi_comm, sizeof(row.name));
        struct proc_taskinfo task = {0};
        if (proc_pidinfo(pids[i], PROC_PIDTASKINFO, 0, &task, sizeof(task)) == sizeof(task)) {
            row.has_task = 1;
            // PROC_PIDTASKINFO returns Mach absolute time, not nanoseconds on ARM.
            row.cpu_ns = (uint64_t)(((__uint128_t)task.pti_total_user + task.pti_total_system) * timebase.numer / timebase.denom);
            row.resident = task.pti_resident_size; row.threads = task.pti_threadnum;
        }
        // Physical footprint is Activity Monitor's preferred memory measure.
        struct rusage_info_v2 usage = {0};
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V2, (rusage_info_t *)&usage) == 0) row.footprint = usage.ri_phys_footprint;
        rows[n++] = row;
    }
    free(pids);
    return n;
}
