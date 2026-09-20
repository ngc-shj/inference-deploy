/* Can a kernel zero another dispatch's indirect arguments, in the same command
 * buffer, and have that dispatch execute nothing?
 *
 * The whole abort-and-resume design rests on this one guarantee: the validator
 * for layer L writes the grid table, and every dispatch after it reads its
 * threadgroup count from that table. If Metal does not order the kernel's write
 * against the command processor's read of the indirect arguments, the mechanism
 * is not available and the design needs a different one.
 *
 * Three passes, one command buffer:
 *   1. mark[] = 0, args[] = {N,1,1} written by the host
 *   2. a kernel that conditionally zeroes args[i] for i >= gate
 *   3. dispatches 0..K-1, each indirect off args[i], each incrementing mark[i]
 * If the guarantee holds, mark[i] is zero for every i >= gate.
 */
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

static const char *SRC =
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct grid { uint x, y, z; };\n"
"kernel void zero_from(device grid *args [[buffer(0)]],\n"
"                      constant uint &gate [[buffer(1)]],\n"
"                      constant uint &n [[buffer(2)]],\n"
"                      uint i [[thread_position_in_grid]]) {\n"
"  if (i < n && i >= gate) { args[i].x = 0; args[i].y = 0; args[i].z = 0; }\n"
"}\n"
"kernel void mark_one(device atomic_uint *mark [[buffer(0)]],\n"
"                     constant uint &slot [[buffer(1)]],\n"
"                     uint tid [[thread_position_in_grid]]) {\n"
"  if (tid == 0) atomic_fetch_add_explicit(&mark[slot], 1u, memory_order_relaxed);\n"
"}\n";

int main(int argc, char **argv) { @autoreleasepool {
    const uint32_t K = argc > 1 ? (uint32_t)atoi(argv[1]) : 64;    /* dispatches */
    const uint32_t gate = argc > 2 ? (uint32_t)atoi(argv[2]) : 8;  /* abort after this many */
    const int rounds = argc > 3 ? atoi(argv[3]) : 200;
    /* ds4 keeps one compute encoder across a layer's dispatches, so the
     * zeroing kernel and the dispatches it gates land in the same encoder.
     * That is the case that matters; a separate encoder is an implicit
     * barrier and proves less. */
    const int same_encoder = argc > 4 ? atoi(argv[4]) : 0;
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    NSError *e = nil;
    id<MTLLibrary> lib = [d newLibraryWithSource:@(SRC) options:nil error:&e];
    if (!lib) { NSLog(@"compile: %@", e); return 1; }
    id<MTLComputePipelineState> pz = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"zero_from"] error:&e];
    id<MTLComputePipelineState> pm = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"mark_one"] error:&e];
    if (!pz || !pm) { NSLog(@"pso: %@", e); return 1; }
    id<MTLCommandQueue> q = [d newCommandQueue];
    id<MTLBuffer> args = [d newBufferWithLength:K * 3 * sizeof(uint32_t) options:MTLResourceStorageModeShared];
    id<MTLBuffer> mark = [d newBufferWithLength:K * sizeof(uint32_t) options:MTLResourceStorageModeShared];

    uint32_t worst_leak = 0, worst_lost = 0;
    for (int r = 0; r < rounds; r++) {
        uint32_t *a = args.contents;
        for (uint32_t i = 0; i < K; i++) { a[3*i] = 1; a[3*i+1] = 1; a[3*i+2] = 1; }
        memset(mark.contents, 0, K * sizeof(uint32_t));
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> shared_enc = same_encoder ? [cb computeCommandEncoder] : nil;
        { id<MTLComputeCommandEncoder> enc = same_encoder ? shared_enc : [cb computeCommandEncoder];
          [enc setComputePipelineState:pz];
          [enc setBuffer:args offset:0 atIndex:0];
          [enc setBytes:&gate length:sizeof(gate) atIndex:1];
          [enc setBytes:&K length:sizeof(K) atIndex:2];
          [enc dispatchThreads:MTLSizeMake(K,1,1) threadsPerThreadgroup:MTLSizeMake(32,1,1)];
          if (!same_encoder) [enc endEncoding]; }
        /* One encoder holding every gated dispatch, which is the shape the real
         * path has: a layer's dispatches are not separated by encoders. */
        { id<MTLComputeCommandEncoder> enc = same_encoder ? shared_enc : [cb computeCommandEncoder];
          [enc setComputePipelineState:pm];
          [enc setBuffer:mark offset:0 atIndex:0];
          for (uint32_t i = 0; i < K; i++) {
              [enc setBytes:&i length:sizeof(i) atIndex:1];
              [enc dispatchThreadgroupsWithIndirectBuffer:args
                                     indirectBufferOffset:(NSUInteger)i * 3 * sizeof(uint32_t)
                                    threadsPerThreadgroup:MTLSizeMake(32,1,1)];
          }
          [enc endEncoding]; }
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.status == MTLCommandBufferStatusError) { NSLog(@"cb: %@", cb.error); return 1; }
        const uint32_t *mk = mark.contents;
        uint32_t leak = 0, lost = 0;
        for (uint32_t i = 0; i < K; i++) {
            if (i >= gate && mk[i] != 0) leak++;       /* ran when it should not have */
            if (i <  gate && mk[i] != 1) lost++;       /* did not run when it should have */
        }
        if (leak > worst_leak) worst_leak = leak;
        if (lost > worst_lost) worst_lost = lost;
    }
    printf("%u dispatches, gate at %u, %d rounds, %s encoder\n", K, gate, rounds,
           same_encoder ? "ONE shared" : "separate");
    printf("  dispatches that ran past the gate (want 0): %u\n", worst_leak);
    printf("  dispatches before the gate that did not run (want 0): %u\n", worst_lost);
    printf("  -> a kernel CAN%s zero a later dispatch's indirect arguments\n",
           (worst_leak == 0 && worst_lost == 0) ? "" : "NOT");
    return (worst_leak == 0 && worst_lost == 0) ? 0 : 1;
} }
