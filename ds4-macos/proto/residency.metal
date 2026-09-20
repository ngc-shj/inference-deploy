#include <metal_stdlib>
using namespace metal;

/* Dereference an address the CPU wrote into a table after this command buffer
 * was already committed. If the residency update did not land, this either
 * faults or reads something else - which is the failure mode that matters,
 * because it is silent. */
kernel void deref_sum(device const ulong *addr_table [[buffer(0)]],
                      device ulong *out [[buffer(1)]],
                      constant uint &words [[buffer(2)]],
                      constant uint &slot [[buffer(3)]],
                      uint tid [[thread_position_in_grid]],
                      uint nthreads [[threads_per_grid]]) {
    const ulong a = addr_table[slot];
    if (a == 0) { if (tid == 0) out[slot] = 0; return; }
    device const uint *p = reinterpret_cast<device const uint *>(a);
    ulong acc = 0;
    for (uint i = tid; i < words; i += nthreads) acc += (ulong)p[i];
    /* One threadgroup, one slot each, thread zero adds them up: no 64-bit
     * threadgroup atomics needed and the order is fixed, so both kernels
     * produce the same value for the same bytes. */
    threadgroup ulong shared[256];
    shared[tid] = acc;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid == 0) {
        ulong t = 0;
        for (uint i = 0; i < nthreads && i < 256; i++) t += shared[i];
        out[slot] = t;
    }
}

/* Same sum over a directly bound buffer, as the reference. */
kernel void bound_sum(device const uint *p [[buffer(0)]],
                      device ulong *out [[buffer(1)]],
                      constant uint &words [[buffer(2)]],
                      constant uint &slot [[buffer(3)]],
                      uint tid [[thread_position_in_grid]],
                      uint nthreads [[threads_per_grid]]) {
    ulong acc = 0;
    for (uint i = tid; i < words; i += nthreads) acc += (ulong)p[i];
    /* One threadgroup, one slot each, thread zero adds them up: no 64-bit
     * threadgroup atomics needed and the order is fixed, so both kernels
     * produce the same value for the same bytes. */
    threadgroup ulong shared[256];
    shared[tid] = acc;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid == 0) {
        ulong t = 0;
        for (uint i = 0; i < nthreads && i < 256; i++) t += shared[i];
        out[slot] = t;
    }
}
