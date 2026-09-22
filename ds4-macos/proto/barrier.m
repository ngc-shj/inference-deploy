/*
 * What a one-threadgroup dispatch costs, and what separating two of them
 * costs: an encoder boundary against a memory barrier.
 *
 * The gate census, keyed on the grid rather than the call site alone, finds
 * that 488.7 of a V4.1 decode token's 1,511.7 gated dispatches - a third of
 * them - run a SINGLE threadgroup: the row norms, the Sinkhorn, the quantize
 * and rope passes. One threadgroup is one core of forty. Whether that is
 * worth collecting depends on two numbers this file measures:
 *
 *   - do independent one-threadgroup dispatches overlap at all, and by how
 *     much, when the encoder is created concurrent;
 *   - what it costs to keep a DEPENDENT pair apart. An encoder boundary is
 *     what the engine has today and proto/narrowmv.m prices at 22.2 us; a
 *     memory barrier inside a concurrent encoder is the alternative, and if
 *     it is much cheaper then the whole segment can be one concurrent encoder
 *     with barriers where the graph actually has edges, instead of a serial
 *     encoder that orders everything whether it needs it or not.
 *
 *   clang -O2 -fobjc-arc -framework Foundation -framework Metal -o barrier barrier.m
 *   ./barrier [dispatches]
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static const char *kSrc = R"MSL(
#include <metal_stdlib>
using namespace metal;

/* A row reduction with the shape ds41_norm's has: one threadgroup, 1024
 * threads, 7168 floats in, one row out. */
kernel void rownorm(device const float *x, device float *out,
                    constant uint &n, constant uint &slot,
                    uint tid [[thread_position_in_threadgroup]],
                    uint nth [[threads_per_threadgroup]]) {
    threadgroup float part[32];
    float acc = 0.0f;
    for (uint i = tid; i < n; i += nth) acc += x[i] * x[i];
    acc = simd_sum(acc);
    if ((tid & 31u) == 0u) part[tid >> 5] = acc;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid < 32u) {
        float v = simd_sum(part[tid]);
        if (tid == 0u) out[slot] = sqrt(v / (float)n);
    }
}

/* Same, but reading the previous dispatch's output, so a chain of these has a
 * real dependency to order. */
kernel void rownorm_chain(device const float *x, device float *out,
                          constant uint &n, constant uint &slot,
                          uint tid [[thread_position_in_threadgroup]],
                          uint nth [[threads_per_threadgroup]]) {
    threadgroup float part[32];
    const float carry = slot ? out[slot - 1u] : 1.0f;
    float acc = 0.0f;
    for (uint i = tid; i < n; i += nth) acc += x[i] * x[i] * carry;
    acc = simd_sum(acc);
    if ((tid & 31u) == 0u) part[tid >> 5] = acc;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid < 32u) {
        float v = simd_sum(part[tid]);
        if (tid == 0u) out[slot] = sqrt(v / (float)n);
    }
}
)MSL";

int main(int argc, const char **argv) {
    @autoreleasepool {
        const uint32_t n_disp = argc > 1 ? (uint32_t)atoi(argv[1]) : 512;
        const uint32_t n = 7168, laps = 64;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:kSrc]
                                               options:nil error:&err];
        if (!lib) { NSLog(@"compile: %@", err); return 1; }
        id<MTLComputePipelineState> pso =
            [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"rownorm"] error:&err];
        id<MTLComputePipelineState> psoc =
            [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"rownorm_chain"] error:&err];
        if (!pso || !psoc) { NSLog(@"pso: %@", err); return 1; }
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLBuffer> x = [dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> o = [dev newBufferWithLength:(n_disp + 1) * 4
                                           options:MTLResourceStorageModePrivate];
        for (uint32_t i = 0; i < n; i++) ((float *)x.contents)[i] = 1.0f / (float)(i + 1u);

        printf("%u one-threadgroup dispatches of 1024 threads, %u laps\n\n", n_disp, laps);
        printf("%-42s %9s %11s\n", "arm", "ms", "us a disp");

        /* independent: serial encoder, concurrent encoder, encoder each */
        const char *names[3] = {
            "independent, one serial encoder",
            "independent, one concurrent encoder",
            "independent, an encoder each",
        };
        double ms[5];
        for (int mode = 0; mode < 3; mode++) {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> shared = mode == 0 ? [cb computeCommandEncoder]
                : mode == 1 ? [cb computeCommandEncoderWithDispatchType:MTLDispatchTypeConcurrent]
                : nil;
            for (uint32_t lap = 0; lap < laps; lap++)
                for (uint32_t i = 0; i < n_disp; i++) {
                    id<MTLComputeCommandEncoder> e = shared ? shared : [cb computeCommandEncoder];
                    [e setComputePipelineState:pso];
                    [e setBuffer:x offset:0 atIndex:0];
                    [e setBuffer:o offset:0 atIndex:1];
                    [e setBytes:&n length:4 atIndex:2];
                    [e setBytes:&i length:4 atIndex:3];
                    [e dispatchThreadgroups:MTLSizeMake(1, 1, 1)
                      threadsPerThreadgroup:MTLSizeMake(1024, 1, 1)];
                    if (!shared) [e endEncoding];
                }
            if (shared) [shared endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            ms[mode] = ([cb GPUEndTime] - [cb GPUStartTime]) * 1000.0;
            printf("%-42s %9.2f %11.2f\n", names[mode], ms[mode],
                   ms[mode] * 1000.0 / (laps * n_disp));
        }

        /* dependent: every dispatch reads the one before it, so the two ways
         * of ordering them can be priced against each other. */
        const char *dnames[2] = {
            "dependent, an encoder between each",
            "dependent, a barrier in one concurrent encoder",
        };
        for (int mode = 0; mode < 2; mode++) {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> shared = mode == 1
                ? [cb computeCommandEncoderWithDispatchType:MTLDispatchTypeConcurrent] : nil;
            for (uint32_t lap = 0; lap < laps; lap++)
                for (uint32_t i = 0; i < n_disp; i++) {
                    id<MTLComputeCommandEncoder> e = shared ? shared : [cb computeCommandEncoder];
                    if (shared && i) [e memoryBarrierWithScope:MTLBarrierScopeBuffers];
                    [e setComputePipelineState:psoc];
                    [e setBuffer:x offset:0 atIndex:0];
                    [e setBuffer:o offset:0 atIndex:1];
                    [e setBytes:&n length:4 atIndex:2];
                    [e setBytes:&i length:4 atIndex:3];
                    [e dispatchThreadgroups:MTLSizeMake(1, 1, 1)
                      threadsPerThreadgroup:MTLSizeMake(1024, 1, 1)];
                    if (!shared) [e endEncoding];
                }
            if (shared) [shared endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            ms[3 + mode] = ([cb GPUEndTime] - [cb GPUStartTime]) * 1000.0;
            printf("%-42s %9.2f %11.2f\n", dnames[mode], ms[3 + mode],
                   ms[3 + mode] * 1000.0 / (laps * n_disp));
        }

        printf("\n  independent, overlapped:  %.2fx (%.2f us a dispatch saved)\n",
               ms[0] / ms[1], (ms[0] - ms[1]) * 1000.0 / (laps * n_disp));
        printf("  ordering a dependent pair: %.2f us by encoder, %.2f us by barrier\n",
               (ms[3] - ms[0]) * 1000.0 / (laps * n_disp),
               (ms[4] - ms[0]) * 1000.0 / (laps * n_disp));
    }
    return 0;
}
