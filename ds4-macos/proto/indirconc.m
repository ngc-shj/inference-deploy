/*
 * Can the abort gate's indirect dispatch share a concurrent encoder?
 *
 * The whole "run the layer's DAG instead of its call order" plan rests on
 * MTLDispatchTypeConcurrent, because a Metal 3 compute encoder serialises
 * everything otherwise. But every dispatch on the V4.1 decode path goes out
 * indirect - the gate writes the grid into a table so an aborting layer can
 * zero what follows it - and putting those inside a concurrent section
 * segfaults inside AGX, in insertIndirectTGOptKernel, on the FIRST indirect
 * dispatch after the section.
 *
 * This is the minimum reproduction, with no model and no engine: a trivial
 * kernel, an indirect buffer, and the four combinations.
 *
 *   clang -O2 -fobjc-arc -framework Foundation -framework Metal -o indirconc indirconc.m
 *   ./indirconc [case]     (no argument runs them all, each in its own process)
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static const char *kSrc = R"MSL(
#include <metal_stdlib>
using namespace metal;
kernel void bump(device float *out, constant uint &slot,
                 uint tid [[thread_position_in_threadgroup]]) {
    if (tid == 0) out[slot] += 1.0f;
}

/* The same, but with a threadgroup allocation whose size the encoder supplies
 * - which is what every matvec on the decode path has and what the SwiGLU and
 * the adds between them do not. */
kernel void bump_tg(device float *out, constant uint &slot,
                    threadgroup float *shmem [[threadgroup(0)]],
                    uint tid [[thread_position_in_threadgroup]]) {
    shmem[tid] = (float)tid;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid == 0) out[slot] += shmem[0] + 1.0f;
}
)MSL";

/* case 0  serial encoder,     direct dispatch        - the control
 * case 1  serial encoder,     indirect dispatch      - what ds4 does today
 * case 2  concurrent encoder, direct dispatch        - what barrier.m does
 * case 3  concurrent encoder, indirect dispatch      - the suspect
 * case 4  concurrent encoder, indirect, then a barrier, then indirect
 * case 5  concurrent encoder with indirect, closed, then indirect in a new
 *         serial encoder - where the engine actually died
 */
int main(int argc, const char **argv) {
    @autoreleasepool {
        const int only = argc > 1 ? atoi(argv[1]) : -1;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:kSrc]
                                               options:nil error:&err];
        if (!lib) { NSLog(@"compile: %@", err); return 1; }
        id<MTLComputePipelineState> pso =
            [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"bump"] error:&err];
        id<MTLComputePipelineState> psotg =
            [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"bump_tg"] error:&err];
        if (!pso || !psotg) { NSLog(@"pso: %@", err); return 1; }
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLBuffer> out = [dev newBufferWithLength:256 * 4 options:MTLResourceStorageModeShared];
        /* The grid table the gate keeps: three words a slot. */
        id<MTLBuffer> grid = [dev newBufferWithLength:64 * 3 * 4
                                              options:MTLResourceStorageModeShared];
        uint32_t *g = (uint32_t *)grid.contents;
        for (int i = 0; i < 64; i++) { g[3*i] = 1; g[3*i+1] = 1; g[3*i+2] = 1; }

        const char *names[7] = {
            "serial, direct", "serial, indirect", "concurrent, direct",
            "concurrent, indirect", "concurrent, indirect + barrier + indirect",
            "concurrent indirect, closed, then indirect in a serial encoder",
            "concurrent, indirect, threadgroup memory then none",
        };
        for (int c = 0; c < 7; c++) {
            if (only >= 0 && c != only) continue;
            fprintf(stderr, "case %d: %-58s ", c, names[c]);
            fflush(stderr);
            @autoreleasepool {
                id<MTLCommandBuffer> cb = [q commandBuffer];
                const bool conc = c >= 2;
                const bool indirect = (c == 1 || c >= 3);
                id<MTLComputeCommandEncoder> e = conc
                    ? [cb computeCommandEncoderWithDispatchType:MTLDispatchTypeConcurrent]
                    : [cb computeCommandEncoder];
                for (uint32_t i = 0; i < 4; i++) {
                    if (c == 4 && i == 2) [e memoryBarrierWithScope:MTLBarrierScopeBuffers];
                    /* Two dispatches that ask for threadgroup memory, then two
                     * that do not - the order the MoE section has. */
                    const bool tg = c == 6 && i < 2;
                    [e setComputePipelineState:tg ? psotg : pso];
                    if (tg) [e setThreadgroupMemoryLength:32u * sizeof(float) atIndex:0];
                    [e setBuffer:out offset:0 atIndex:0];
                    [e setBytes:&i length:4 atIndex:1];
                    if (indirect)
                        [e dispatchThreadgroupsWithIndirectBuffer:grid
                                             indirectBufferOffset:i * 3u * 4u
                                            threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
                    else
                        [e dispatchThreadgroups:MTLSizeMake(1, 1, 1)
                          threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
                }
                [e endEncoding];
                if (c == 5) {
                    id<MTLComputeCommandEncoder> e2 = [cb computeCommandEncoder];
                    [e2 setComputePipelineState:pso];
                    [e2 setBuffer:out offset:0 atIndex:0];
                    uint32_t slot = 9;
                    [e2 setBytes:&slot length:4 atIndex:1];
                    [e2 dispatchThreadgroupsWithIndirectBuffer:grid
                                          indirectBufferOffset:0
                                         threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
                    [e2 endEncoding];
                }
                [cb commit];
                [cb waitUntilCompleted];
                fprintf(stderr, "ok%s\n", cb.error ? " (with a command buffer error)" : "");
            }
        }
    }
    return 0;
}
