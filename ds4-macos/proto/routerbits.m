/*
 * Which step of the router's weight tail changes the bits?
 *
 * Replacing the generic five-kernel tail with kernel_dsv4_router_weights_one
 * changed the output, and three things change at once:
 *
 *   1. the sum over six entries goes from a tree reduction to index order
 *   2. `(x / sum)` and `* 1.5` stop being separate kernels with an f32
 *      round-trip between them, and become one expression the compiler may
 *      contract or reassociate
 *   3. clamp(sum, eps, +inf) becomes max(sum, eps)
 *
 * Attributing it to the first without measuring was a guess. This runs all the
 * variants over the same inputs on the GPU and prints the bits, so the guess
 * can be replaced.
 *
 *   clang -O2 -fobjc-arc -framework Foundation -framework Metal -o routerbits routerbits.m
 *   ./routerbits [rounds]
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static const char *kSrc = R"MSL(
#include <metal_stdlib>
using namespace metal;

/* What ds4 ships as the fused tail. */
kernel void fused(device const float *p, device const int *s, device float *w,
                  uint tid [[thread_position_in_grid]]) {
    if (tid >= 6) return;
    float sum = 0.0f;
    for (uint i = 0; i < 6; i++) sum += p[s[i]];
    sum = max(sum, 6.103515625e-5f);
    w[tid] = p[s[tid]] / sum * 1.5f;
}

/* Same sequential sum, but the divide and the scale kept apart with an f32
 * store between them, the way two kernels would leave it. */
kernel void seq_split(device const float *p, device const int *s, device float *w,
                      device float *tmp, uint tid [[thread_position_in_grid]]) {
    if (tid >= 6) return;
    float sum = 0.0f;
    for (uint i = 0; i < 6; i++) sum += p[s[i]];
    sum = clamp(sum, 6.103515625e-5f, INFINITY);
    tmp[tid] = p[s[tid]] / sum;
    w[tid] = tmp[tid] * 1.5f;
}

/* A tree sum of the same six, with the tail kept apart as above. This is the
 * shape the generic path has: a strided per-thread partial then a reduction. */
kernel void tree_split(device const float *p, device const int *s, device float *w,
                       device float *tmp, threadgroup float *sh [[threadgroup(0)]],
                       uint tid [[thread_position_in_threadgroup]]) {
    sh[tid] = tid < 6 ? p[s[tid]] : 0.0f;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint step = 16; step > 0; step >>= 1) {
        if (tid < step) sh[tid] += sh[tid + step];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid >= 6) return;
    float sum = clamp(sh[0], 6.103515625e-5f, INFINITY);
    tmp[tid] = p[s[tid]] / sum;
    w[tid] = tmp[tid] * 1.5f;
}
)MSL";

int main(int argc, const char **argv) {
    @autoreleasepool {
        const int rounds = argc > 1 ? atoi(argv[1]) : 20000;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:kSrc]
                                               options:nil error:&err];
        if (!lib) { NSLog(@"compile: %@", err); return 1; }
        id<MTLCommandQueue> q = [dev newCommandQueue];

        id<MTLBuffer> pb = [dev newBufferWithLength:384 * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> sb = [dev newBufferWithLength:6 * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> wb[3], tb[3];
        for (int i = 0; i < 3; i++) {
            wb[i] = [dev newBufferWithLength:6 * 4 options:MTLResourceStorageModeShared];
            tb[i] = [dev newBufferWithLength:6 * 4 options:MTLResourceStorageModeShared];
        }
        const char *names[3] = { "fused", "seq_split", "tree_split" };
        id<MTLComputePipelineState> pso[3];
        for (int i = 0; i < 3; i++) {
            id<MTLFunction> f = [lib newFunctionWithName:[NSString stringWithUTF8String:names[i]]];
            pso[i] = [dev newComputePipelineStateWithFunction:f error:&err];
            if (!pso[i]) { NSLog(@"pso %s: %@", names[i], err); return 1; }
        }

        /* Router probabilities are sqrt(softplus(logit)), so O(0.1) to O(2).
         * Random rounds, because one lucky triple proves nothing. */
        unsigned seed = 12345;
        int diff_fused_seq = 0, diff_seq_tree = 0, diff_fused_tree = 0;
        for (int r = 0; r < rounds; r++) {
            float *p = (float *)pb.contents;
            int *s = (int *)sb.contents;
            for (int i = 0; i < 384; i++) {
                seed = seed * 1103515245u + 12345u;
                p[i] = 0.05f + 2.0f * (float)((seed >> 8) & 0xffff) / 65535.0f;
            }
            for (int i = 0; i < 6; i++) {
                seed = seed * 1103515245u + 12345u;
                s[i] = (int)((seed >> 8) % 384u);
            }
            id<MTLCommandBuffer> cb = [q commandBuffer];
            for (int i = 0; i < 3; i++) {
                id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
                [e setComputePipelineState:pso[i]];
                [e setBuffer:pb offset:0 atIndex:0];
                [e setBuffer:sb offset:0 atIndex:1];
                [e setBuffer:wb[i] offset:0 atIndex:2];
                if (i > 0) [e setBuffer:tb[i] offset:0 atIndex:3];
                if (i == 2) [e setThreadgroupMemoryLength:32 * 4 atIndex:0];
                [e dispatchThreadgroups:MTLSizeMake(1, 1, 1)
                  threadsPerThreadgroup:MTLSizeMake(i == 2 ? 32 : 6, 1, 1)];
                [e endEncoding];
            }
            [cb commit];
            [cb waitUntilCompleted];
            const uint32_t *a = (const uint32_t *)wb[0].contents;
            const uint32_t *b = (const uint32_t *)wb[1].contents;
            const uint32_t *c = (const uint32_t *)wb[2].contents;
            for (int i = 0; i < 6; i++) {
                if (a[i] != b[i]) { diff_fused_seq++; break; }
            }
            for (int i = 0; i < 6; i++) {
                if (b[i] != c[i]) { diff_seq_tree++; break; }
            }
            for (int i = 0; i < 6; i++) {
                if (a[i] != c[i]) { diff_fused_tree++; break; }
            }
        }
        printf("%d rounds of six weights each\n\n", rounds);
        printf("  fused vs seq_split  (divide and scale in one expression"
               " vs two): %d differ (%.2f%%)\n", diff_fused_seq,
               100.0 * diff_fused_seq / rounds);
        printf("  seq_split vs tree_split (index-order sum vs tree sum)   : "
               "%d differ (%.2f%%)\n", diff_seq_tree,
               100.0 * diff_seq_tree / rounds);
        printf("  fused vs tree_split (both changes at once)              : "
               "%d differ (%.2f%%)\n", diff_fused_tree,
               100.0 * diff_fused_tree / rounds);
    }
    return 0;
}
