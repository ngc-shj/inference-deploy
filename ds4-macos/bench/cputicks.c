/*
 * Cumulative CPU ticks across every logical core, from the kernel.
 *
 * The obvious shell answer - sum `ps -Ao time=` over live processes and
 * difference it - is not a measurement of CPU. A process that starts and ends
 * inside the window contributes nothing; a long-lived one exiting removes its
 * whole lifetime from the sum and the difference goes negative; and any change
 * in which processes exist reads as a change in load. The interference this is
 * meant to catch is a scanner spawning short-lived helpers, which is precisely
 * the case it cannot see.
 *
 * host_processor_info(PROCESSOR_CPU_LOAD_INFO) returns per-core tick counters
 * that only ever increase and belong to no process, so a difference of two
 * readings is exactly the work done in between, whoever did it and whether or
 * not they are still here.
 *
 *     cc -O2 -o cputicks cputicks.c
 *     ./cputicks          ->  user system idle nice ncpu
 *
 * Two calls a window, so the logger is not part of what it measures.
 */
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/processor_info.h>
#include <stdio.h>

int main(void) {
    natural_t ncpu = 0;
    processor_info_array_t info = NULL;
    mach_msg_type_number_t count = 0;
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                            &ncpu, &info, &count) != KERN_SUCCESS) {
        fprintf(stderr, "host_processor_info failed\n");
        return 1;
    }
    processor_cpu_load_info_t load = (processor_cpu_load_info_t)info;
    unsigned long long user = 0, sys = 0, idle = 0, nice = 0;
    for (natural_t i = 0; i < ncpu; i++) {
        user += load[i].cpu_ticks[CPU_STATE_USER];
        sys  += load[i].cpu_ticks[CPU_STATE_SYSTEM];
        idle += load[i].cpu_ticks[CPU_STATE_IDLE];
        nice += load[i].cpu_ticks[CPU_STATE_NICE];
    }
    printf("%llu %llu %llu %llu %u\n", user, sys, idle, nice, ncpu);
    vm_deallocate(mach_task_self(), (vm_address_t)info,
                  count * sizeof(integer_t));
    return 0;
}
