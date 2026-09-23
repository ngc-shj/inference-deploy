/*
 * What Metal 4 costs a dispatch, and whether it can express the decode chain.
 *
 * The gate sends every dispatch on the decode path out indirect, so an
 * aborting layer can zero the grid of everything behind it. That costs 2.25 us
 * a dispatch against 0.70 us plain - measured in the engine, and the
 * difference does not move for slot reuse or storage mode - which over a
 * token's 2,080 gated dispatches is about 3.2 ms, a tenth of the GPU term.
 * Metal 3 has no cheaper form: a compute MTLIndirectCommandBuffer is
 * concurrent-dispatch only and cannot express a forty-layer chain.
 *
 * Metal 4 might, and before porting a single layer to it - which means
 * re-expressing every kernel's bindings through an MTL4ArgumentTable - this
 * file asks the three questions that decide whether the port is worth
 * starting:
 *
 *   1. Is an indirect dispatch cheaper under MTL4 than under MTL3? The MTL4
 *      form takes a GPU address rather than a buffer and an offset, so there
 *      is a mechanism for it to be, but that is a hypothesis.
 *   2. Do MTL4 dispatches run concurrently unless a barrier says otherwise,
 *      and does barrierAfterStages: actually order a chain? That is what
 *      would let a segment be issued as its DAG instead of as its call order.
 *   3. Does a pipeline state built the Metal 3 way work on an MTL4 encoder?
 *      If it does, the port is a binding change. If it does not, every kernel
 *      needs recompiling through MTL4Compiler first.
 *
 *     clang -O2 -fobjc-arc -framework Foundation -framework Metal -o mtl4 mtl4.m
 *     ./mtl4 [dispatches] [laps]
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <mach/mach_time.h>

/* The same shape barrier.m used, so the numbers sit beside its table: one
 * threadgroup, 1024 threads, enough work that the dispatch is not free. */
static NSString *const kSrc = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"kernel void tiny(device float *out, device const float *in,\n"
"                 uint t [[thread_position_in_threadgroup]]) {\n"
"    float v = in[t];\n"
"    for (int i = 0; i < 64; i++) v = fma(v, 1.000001f, 1.0e-7f);\n"
"    out[t] = v;\n"
"}\n";

static double now_us(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1000.0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const int N = argc > 1 ? atoi(argv[1]) : 512;
        const int LAPS = argc > 2 ? atoi(argv[2]) : 64;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        printf("%s\n", dev.name.UTF8String);

        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kSrc options:nil error:&err];
        if (!lib) { fprintf(stderr, "compile: %s\n", err.description.UTF8String); return 1; }
        id<MTLFunction> fn = [lib newFunctionWithName:@"tiny"];
        id<MTLComputePipelineState> pso3 =
            [dev newComputePipelineStateWithFunction:fn error:&err];
        if (!pso3) { fprintf(stderr, "pipeline: %s\n", err.description.UTF8String); return 1; }

        id<MTLBuffer> in  = [dev newBufferWithLength:1024 * sizeof(float)
                                             options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:1024 * sizeof(float)
                                             options:MTLResourceStorageModeShared];
        /* One grid entry a dispatch, as the gate's table has. */
        /* Two widths' worth, so every dispatch reads a distinct slot at both
         * N and 2N. Reusing slots in the wider arm made the marginal cost of
         * an indirect dispatch come out below a plain one, which is not a
         * result, it is the second half of the arm reading a warm entry. */
        id<MTLBuffer> grid = [dev newBufferWithLength:(NSUInteger)2 * N * 3 * sizeof(uint32_t)
                                              options:MTLResourceStorageModeShared];
        uint32_t *g = (uint32_t *)grid.contents;
        for (int i = 0; i < 2 * N; i++) { g[3*i] = 1; g[3*i+1] = 1; g[3*i+2] = 1; }

        const MTLSize one = MTLSizeMake(1, 1, 1), tpt = MTLSizeMake(1024, 1, 1);
        /* The engine's 0.70 and 2.25 us are marginal costs - what one more
         * dispatch adds - so these are measured the same way, as the slope
         * between N and 2N. A single total divided by N carries the command
         * buffer's own fixed cost and is not comparable to them. Encode and
         * total are reported apart, because a dispatch that overlaps the one
         * before it shows its issue cost on the host and not in the wall. */
#define ARM(LABEL, BODY) do { \
    double be[2] = { 1e30, 1e30 }, bt[2] = { 1e30, 1e30 }; \
    for (int w = 0; w < 2; w++) { \
        const int n = w ? 2 * N : N; \
        for (int lap = 0; lap < LAPS; lap++) { \
            const double t0 = now_us(); \
            BODY \
            const double t1 = now_us(); \
            WAIT \
            const double t2 = now_us(); \
            if (t1 - t0 < be[w]) be[w] = t1 - t0; \
            if (t2 - t0 < bt[w]) bt[w] = t2 - t0; \
        } \
    } \
    printf("  %-27s encode %6.3f  total %6.3f us/dispatch\n", LABEL, \
           (be[1] - be[0]) / N, (bt[1] - bt[0]) / N); \
} while (0)

        /* ---- Metal 3, the two forms the engine has today ---------------- */
        id<MTLCommandQueue> q3 = [dev newCommandQueue];
        __block id<MTLCommandBuffer> cb3 = nil;
#define WAIT [cb3 waitUntilCompleted];
        for (int indirect = 0; indirect < 2; indirect++) {
            ARM(indirect ? "MTL3 serial, indirect" : "MTL3 serial, plain", {
                cb3 = [q3 commandBuffer];
                id<MTLComputeCommandEncoder> e = [cb3 computeCommandEncoder];
                [e setComputePipelineState:pso3];
                [e setBuffer:out offset:0 atIndex:0];
                [e setBuffer:in offset:0 atIndex:1];
                for (int i = 0; i < n; i++) {
                    if (indirect)
                        [e dispatchThreadgroupsWithIndirectBuffer:grid
                                             indirectBufferOffset:(NSUInteger)i * 3 * sizeof(uint32_t)
                                            threadsPerThreadgroup:tpt];
                    else
                        [e dispatchThreadgroups:one threadsPerThreadgroup:tpt];
                }
                [e endEncoding];
                [cb3 commit];
            });
        }
#undef WAIT

        /* ---- Metal 4 ---------------------------------------------------- */
        if (@available(macOS 26.0, *)) {
            if (![dev supportsFamily:MTLGPUFamilyMetal4]) {
                printf("  MTL4 not supported on this device\n");
                return 0;
            }
            id<MTL4CommandQueue> q4 = [dev newMTL4CommandQueue];
            /* MTL4 has no waitUntilCompleted: the queue signals an event and
             * the host waits on it. */
            id<MTLSharedEvent> done = [dev newSharedEvent];
            uint64_t stamp = 0;
            id<MTL4CommandAllocator> alloc = [dev newCommandAllocator];
            id<MTL4CommandBuffer> cb4 = [dev newCommandBuffer];
            if (!q4 || !alloc || !cb4) { printf("  MTL4 objects unavailable\n"); return 0; }

            /* Question 3, answered before anything is timed: does a pipeline
             * built the Metal 3 way bind on an MTL4 encoder at all? */
            MTL4ArgumentTableDescriptor *atd = [MTL4ArgumentTableDescriptor new];
            atd.maxBufferBindCount = 4;
            id<MTL4ArgumentTable> table =
                [dev newArgumentTableWithDescriptor:atd error:&err];
            if (!table) {
                printf("  MTL4 argument table: %s\n", err.description.UTF8String);
                return 0;
            }
            [table setAddress:out.gpuAddress atIndex:0];
            [table setAddress:in.gpuAddress atIndex:1];

            /* MTL4 tracks no residency implicitly. */
            MTLResidencySetDescriptor *rsd = [MTLResidencySetDescriptor new];
            id<MTLResidencySet> rs = [dev newResidencySetWithDescriptor:rsd error:&err];
            if (rs) {
                [rs addAllocation:in]; [rs addAllocation:out]; [rs addAllocation:grid];
                [rs commit];
                [q4 addResidencySet:rs];
            }

#define WAIT [q4 signalEvent:done value:++stamp]; \
             [done waitUntilSignaledValue:stamp timeoutMS:10000];
            for (int mode = 0; mode < 5; mode++) {
                /* 0 plain, 1 indirect, 2 indirect with an intra-encoder
                 * barrier between every dispatch - the chain a decode segment
                 * actually is - and 3 the queue-stage barrier, which is a
                 * different call and does not order work inside the encoder.
                 * 3 is here because using it by mistake reads as "Metal 4
                 * makes the chain free", which it is not. */
                const char *name[5] = { "MTL4 plain", "MTL4 indirect",
                                        "MTL4 indirect + encoder barrier",
                                        "MTL4 indirect + queue barrier",
                                        "MTL4 plain + encoder barrier" };
                ARM(name[mode], {
                    [alloc reset];
                    [cb4 beginCommandBufferWithAllocator:alloc];
                    id<MTL4ComputeCommandEncoder> e = [cb4 computeCommandEncoder];
                    [e setArgumentTable:table];
                    [e setComputePipelineState:pso3];
                    for (int i = 0; i < n; i++) {
                        if (mode == 0 || mode == 4)
                            [e dispatchThreadgroups:one threadsPerThreadgroup:tpt];
                        else
                            [e dispatchThreadgroupsWithIndirectBuffer:
                                    grid.gpuAddress + (uint64_t)i * 3 * sizeof(uint32_t)
                                                threadsPerThreadgroup:tpt];
                        if (mode == 2 || mode == 4)
                            [e barrierAfterEncoderStages:MTLStageDispatch
                                     beforeEncoderStages:MTLStageDispatch
                                       visibilityOptions:MTL4VisibilityOptionDevice];
                        else if (mode == 3)
                            [e barrierAfterStages:MTLStageDispatch
                                beforeQueueStages:MTLStageDispatch
                                visibilityOptions:MTL4VisibilityOptionDevice];
                    }
                    [e endEncoding];
                    [cb4 endCommandBuffer];
                    [q4 commit:&cb4 count:1];
                });
            }
#undef WAIT
            printf("\n  a Metal 3 pipeline state bound and ran on an MTL4 encoder.\n");
        } else {
            printf("  built against a pre-26.0 SDK\n");
        }
    }
    return 0;
}
