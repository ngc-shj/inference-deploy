/* What does one dispatch cost, and what does sending it indirect add?
 *
 * The abort gate sends every dispatch on the decode path through an indirect
 * buffer, so that the layer which aborts can zero the rest of the table and
 * the dispatches behind it launch nothing. That is a per-dispatch change to
 * roughly 2,700 dispatches a token, and nothing here has ever priced it: the
 * fusion candidate is sized against the same number, so both need the cost of
 * one dispatch before either can be argued for.
 *
 * Five shapes, because "remove a dispatch" and "stop sending it indirect"
 * remove different things depending on what the call site does between them:
 *
 *   plain     one pipeline, no rebinding - the floor
 *   pipe      a setComputePipelineState between every dispatch
 *   bind      a setBytes of 16 bytes between every dispatch
 *   indirect  dispatchThreadgroupsWithIndirectBuffer, one slot reused
 *   slotted   the same, a distinct slot per dispatch - what the gate encodes
 *   private   slotted, with the table in private storage
 *   gatedoff  slotted, with the grid zeroed - what is left behind an abort
 *
 * Every dispatch increments an atomic and the total is checked against N, so
 * a shape that quietly launched nothing cannot be read as a fast one. The
 * gatedoff shape is the exception and is checked the other way: it must launch
 * exactly nothing, which is the guarantee gateprobe.m established.
 *
 *   clang -O2 -fobjc-arc -framework Foundation -framework Metal -o dispatchcost dispatchcost.m
 *   ./dispatchcost [laps]
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <simd/simd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *kSrc =
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"kernel void probe_a(device atomic_uint *ctr [[buffer(0)]],\n"
"                    constant uint4 &arg [[buffer(1)]],\n"
"                    uint tid [[thread_position_in_grid]]) {\n"
"    if (tid == 0) atomic_fetch_add_explicit(ctr, 1u + (arg.x & 0u), memory_order_relaxed);\n"
"}\n"
"kernel void probe_b(device atomic_uint *ctr [[buffer(0)]],\n"
"                    constant uint4 &arg [[buffer(1)]],\n"
"                    uint tid [[thread_position_in_grid]]) {\n"
"    if (tid == 0) atomic_fetch_add_explicit(ctr, 1u + (arg.x & 0u), memory_order_relaxed);\n"
"}\n";

/* The gate takes a fresh slot for every dispatch, so the command processor
 * reads 12 bytes from a different place each time rather than the same line
 * 2,900 times. Reusing one slot would price a cache hit the real path never
 * gets, so both are measured and the slotted one is the gate's. */
typedef enum { SHAPE_PLAIN, SHAPE_PIPE, SHAPE_BIND, SHAPE_INDIRECT,
               SHAPE_SLOTTED, SHAPE_PRIVATE, SHAPE_GATEDOFF } shape_t;
static const char *shape_name[] = { "plain", "pipe", "bind", "indirect",
                                    "slotted", "private", "gatedoff" };
#define N_SHAPES 7

int main(int argc, char **argv) {
@autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { fprintf(stderr, "no Metal device\n"); return 1; }
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:kSrc]
                                           options:nil error:&err];
    if (!lib) { fprintf(stderr, "library: %s\n", err.description.UTF8String); return 1; }
    id<MTLComputePipelineState> pa =
        [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"probe_a"] error:&err];
    id<MTLComputePipelineState> pb =
        [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"probe_b"] error:&err];
    if (!pa || !pb) { fprintf(stderr, "pipeline: %s\n", err.description.UTF8String); return 1; }
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLBuffer> ctr = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    /* Two triples: a live grid and a zeroed one. The gate's table is device
     * memory the command processor reads, not arguments the encoder carries,
     * so one slot reused by every dispatch measures the same read. */
    const uint32_t MAXN = 4096;
    /* One table shaped like the gate's: three uints a slot, a slot a dispatch. */
    const NSUInteger tbl_bytes = (NSUInteger)(MAXN + 2) * 3u * sizeof(uint32_t);
    id<MTLBuffer> ind = [dev newBufferWithLength:tbl_bytes
                                         options:MTLResourceStorageModeShared];
    uint32_t *iw = (uint32_t *)ind.contents;
    for (uint32_t i = 0; i < MAXN + 2; i++) { iw[3*i] = 1; iw[3*i+1] = 1; iw[3*i+2] = 1; }
    /* The zeroed slot the switched-off shape reads sits past the live ones. */
    const NSUInteger off_slot = MAXN;
    iw[3*off_slot] = 0; iw[3*off_slot+1] = 0; iw[3*off_slot+2] = 0;
    id<MTLBuffer> indp = [dev newBufferWithLength:tbl_bytes
                                          options:MTLResourceStorageModePrivate];
    {   /* Fill the private table once; the gate would do the same at startup
         * if the grids it writes are the same every token. */
        id<MTLCommandBuffer> bcb = [q commandBuffer];
        id<MTLBlitCommandEncoder> bl = [bcb blitCommandEncoder];
        [bl copyFromBuffer:ind sourceOffset:0 toBuffer:indp
         destinationOffset:0 size:tbl_bytes];
        [bl endEncoding]; [bcb commit]; [bcb waitUntilCompleted];
    }

    const uint32_t Ns[] = { 256, 512, 1024, 2048, 2736, 4096 };
    const int nN = sizeof(Ns) / sizeof(Ns[0]);
    const int laps = argc > 1 ? atoi(argv[1]) : 9;

    /* One throwaway command buffer per shape before it is timed: the first
     * encode of a pipeline pays for warming it, and that is not per dispatch. */
    printf("shape       N     gpu_span_ms  host_ms  per_dispatch_us  launched\n");
    for (int s = 0; s < N_SHAPES; s++) {
        for (int k = -1; k < nN; k++) {
            const uint32_t N = Ns[k < 0 ? 0 : k];
            const int timed = k >= 0;
            double best_gpu = 1e9, best_host = 1e9; uint32_t seen = 0;
            for (int lap = 0; lap < (timed ? laps : 1); lap++) {
                memset(ctr.contents, 0, 16);
                @autoreleasepool {
                    id<MTLCommandBuffer> cb = [q commandBuffer];
                    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                    [enc setComputePipelineState:pa];
                    [enc setBuffer:ctr offset:0 atIndex:0];
                    vector_uint4 arg = { 0, 0, 0, 0 };
                    [enc setBytes:&arg length:sizeof(arg) atIndex:1];
                    const MTLSize tg = MTLSizeMake(1, 1, 1);
                    const MTLSize tpt = MTLSizeMake(32, 1, 1);
                    id<MTLBuffer> itbl = ((shape_t)s == SHAPE_PRIVATE) ? indp : ind;
                    const double h0 = [[NSDate date] timeIntervalSince1970];
                    for (uint32_t i = 0; i < N; i++) {
                        switch ((shape_t)s) {
                        case SHAPE_PIPE:
                            [enc setComputePipelineState:(i & 1) ? pb : pa];
                            break;
                        case SHAPE_BIND:
                            arg.x = i; [enc setBytes:&arg length:sizeof(arg) atIndex:1];
                            break;
                        default: break;
                        }
                        NSUInteger ioff = 0;
                        int is_indirect = 1;
                        switch ((shape_t)s) {
                        case SHAPE_INDIRECT: ioff = 0; break;
                        case SHAPE_SLOTTED:
                        case SHAPE_PRIVATE:  ioff = (NSUInteger)i * 3u * sizeof(uint32_t); break;
                        case SHAPE_GATEDOFF: ioff = off_slot * 3u * sizeof(uint32_t); break;
                        default: is_indirect = 0; break;
                        }
                        if (is_indirect)
                            [enc dispatchThreadgroupsWithIndirectBuffer:itbl
                                                   indirectBufferOffset:ioff
                                                  threadsPerThreadgroup:tpt];
                        else
                            [enc dispatchThreadgroups:tg threadsPerThreadgroup:tpt];
                    }
                    [enc endEncoding];
                    [cb commit];
                    [cb waitUntilCompleted];
                    const double h1 = [[NSDate date] timeIntervalSince1970];
                    const double gpu = (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
                    if (gpu < best_gpu) best_gpu = gpu;
                    if ((h1 - h0) * 1000.0 < best_host) best_host = (h1 - h0) * 1000.0;
                    seen = *(uint32_t *)ctr.contents;
                    const uint32_t want = ((shape_t)s == SHAPE_GATEDOFF) ? 0u : N;
                    if (seen != want) {
                        fprintf(stderr, "shape %s N=%u launched %u, wanted %u\n",
                                shape_name[s], N, seen, want);
                        return 2;
                    }
                }
            }
            if (!timed) continue;
            printf("%-10s %5u  %10.4f  %7.4f  %14.4f  %8u\n",
                   shape_name[s], N, best_gpu, best_host, best_gpu * 1000.0 / N, seen);
            fflush(stdout);
        }
    }
    return 0;
}
}
