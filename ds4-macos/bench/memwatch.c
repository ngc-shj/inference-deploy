/* What one process group holds, for gpurun.sh.
 *
 *   memwatch <pgid>
 *
 * Prints "<processes> <summed phys_footprint bytes> <largest pid> <its bytes>"
 * for every live process in the group. phys_footprint is what the kernel
 * charges a process, GPU allocations included, which a resident-size reading
 * misses. Prints "0 0 0 0" once the group is empty. */
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: memwatch <pgid>\n"); return 2; }
    const int pgid = atoi(argv[1]);
    pid_t pids[4096];
    const int n = proc_listpids(PROC_PGRP_ONLY, (uint32_t)pgid, pids, sizeof(pids));
    int count = 0, top = 0;
    unsigned long long sum = 0, top_bytes = 0;
    for (int i = 0; n > 0 && i < n / (int)sizeof(pid_t); i++) {
        if (pids[i] <= 0) continue;
        struct rusage_info_v4 ri;
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) continue;
        count++;
        sum += ri.ri_phys_footprint;
        if (ri.ri_phys_footprint >= top_bytes) { top_bytes = ri.ri_phys_footprint; top = pids[i]; }
    }
    printf("%d %llu %d %llu\n", count, sum, top, top_bytes);
    return 0;
}
