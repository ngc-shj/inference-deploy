/* Two independent expert matvecs: serialised, as Metal does by default inside
 * one encoder, against concurrent, which is what MTLDispatchTypeConcurrent
 * allows when the app knows they do not alias.
 *
 * The reason to ask: a V4.1 layer's shared expert (Q8_0, 37.6 MiB) and its six
 * routed experts (IQ2/Q2_K, 59.7 MiB) depend on the same norm and on nothing of
 * each other's. Serially they cost the sum; overlapped they cost the larger,
 * if there is memory bandwidth left to carry both. One kernel reaches about
 * 300 GB/s here, and the machine has more than that.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>

#define NE00 5120u
#define NE01 2304u
#define QK_K 256u
#define BLOCK_B 66u
#define NSG 2u
#define NR0 4u

static double now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1.0e6;
}
static int cmp_d(const void *a, const void *b) {
    const double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y ? 1 : 0;
}

int main(int argc, char **argv) {
@autoreleasepool {
    const uint32_t pairs = argc > 1 ? (uint32_t)atoi(argv[1]) : 6;   /* dispatches a "layer" */
    const uint32_t iters = argc > 2 ? (uint32_t)atoi(argv[2]) : 64;
    const uint32_t rounds = argc > 3 ? (uint32_t)atoi(argv[3]) : 7;
    const uint32_t nexp = argc > 4 ? (uint32_t)atoi(argv[4]) : 64;

    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    NSError *e = nil;
    NSString *src = [NSString stringWithContentsOfFile:@"rows2.metal"
                                              encoding:NSUTF8StringEncoding error:&e];
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&e];
    if (!lib) { fprintf(stderr, "compile: %s\n", e.localizedDescription.UTF8String); return 1; }
    id<MTLComputePipelineState> pso =
        [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"iq2_pair_rows1"] error:&e];
    if (!pso) { fprintf(stderr, "pso: %s\n", e.localizedDescription.UTF8String); return 1; }

    const uint32_t row_blocks = NE00 / QK_K, nb32 = row_blocks * (QK_K / 32);
    const size_t w_bytes = (size_t)NE01 * row_blocks * BLOCK_B;
    id<MTLBuffer> xg = [d newBufferWithLength:w_bytes * nexp options:MTLResourceStorageModeShared];
    id<MTLBuffer> y = [d newBufferWithLength:NE00 * sizeof(float) options:MTLResourceStorageModeShared];
    /* Separate outputs, so the dispatches genuinely do not alias and the
     * concurrent encoder is allowed to overlap them. */
    NSMutableArray<id<MTLBuffer>> *og = [NSMutableArray array], *ou = [NSMutableArray array];
    for (uint32_t i = 0; i < pairs; i++) {
        [og addObject:[d newBufferWithLength:NE01 * sizeof(float) options:MTLResourceStorageModeShared]];
        [ou addObject:[d newBufferWithLength:NE01 * sizeof(float) options:MTLResourceStorageModeShared]];
    }
    srandom(3);
    uint8_t *w = xg.contents;
    for (size_t i = 0; i < w_bytes * nexp; i++) w[i] = random() & 0xff;
    float *yf = y.contents;
    for (uint32_t i = 0; i < NE00; i++) yf[i] = (float)((random() % 2001) - 1000) / 1000.0f;

    id<MTLCommandQueue> q = [d newCommandQueue];
    const MTLSize grid = MTLSizeMake(NE01 / (NSG * NR0), 1, 1);
    const MTLSize tg = MTLSizeMake(32 * NSG, 1, 1);
    const NSUInteger shmem = 256 * sizeof(uint64_t) + 128;
    const uint32_t zero = 0;
    /* Arm 2 is what the real kernel does: one dispatch whose z extent carries
     * all the lanes, so every threadgroup is in flight from the start without
     * asking the encoder for anything. If that already reaches the concurrent
     * rate, overlapping separate dispatches has nothing left to give. */
    double *ms[3];
    for (int a = 0; a < 3; a++) ms[a] = malloc(rounds * sizeof(double));

    for (uint32_t r = 0; r < rounds + 1; r++) {
      for (int arm = 0; arm < 3; arm++) {
        id<MTLCommandBuffer> cb = [q commandBuffer];
        for (uint32_t it = 0; it < iters; it++) {
            id<MTLComputeCommandEncoder> enc = arm == 1
                ? [cb computeCommandEncoderWithDispatchType:MTLDispatchTypeConcurrent]
                : [cb computeCommandEncoder];
            for (uint32_t p = 0; p < (arm == 2 ? 1u : pairs); p++) {
                const NSUInteger woff = (NSUInteger)((it * pairs + p) % nexp) * w_bytes;
                [enc setComputePipelineState:pso];
                [enc setBuffer:xg offset:woff atIndex:0];
                [enc setBuffer:xg offset:woff atIndex:1];
                [enc setBuffer:y offset:0 atIndex:2];
                [enc setBuffer:og[p] offset:0 atIndex:3];
                [enc setBuffer:ou[p] offset:0 atIndex:4];
                [enc setBytes:&nb32 length:4 atIndex:5];
                [enc setBytes:&row_blocks length:4 atIndex:6];
                [enc setBytes:&zero length:4 atIndex:7];
                [enc setBytes:&zero length:4 atIndex:8];
                [enc setThreadgroupMemoryLength:shmem atIndex:0];
                [enc dispatchThreadgroups:(arm == 2 ? MTLSizeMake(grid.width, 1, pairs) : grid)
                     threadsPerThreadgroup:tg];
            }
            [enc endEncoding];
        }
        [cb commit];
        [cb waitUntilCompleted];
        const double t = (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
        if (r > 0) ms[arm][r - 1] = t;
      }
    }
    for (int a = 0; a < 3; a++) qsort(ms[a], rounds, sizeof(double), cmp_d);
    const double a0 = ms[0][rounds / 2], a1 = ms[1][rounds / 2], a2 = ms[2][rounds / 2];
    const double gib = 2.0 * w_bytes * pairs / (1024.0*1024.0*1024.0);
    printf("%u independent dispatches a group, %u groups\n", pairs, iters);
    printf("  serial encoder     : %7.2f ms, %6.1f GB/s\n", a0, gib * iters * 1.073741824 / (a0/1000.0));
    printf("  concurrent encoder : %7.2f ms, %6.1f GB/s\n", a1, gib * iters * 1.073741824 / (a1/1000.0));
    printf("  one dispatch, z=%u  : %7.2f ms, %6.1f GB/s\n", pairs, a2,
           gib * iters * 1.073741824 / (a2/1000.0));
    printf("  concurrent is %+.1f%% against serial, the single dispatch %+.1f%%\n",
           100.0 * (a1/a0 - 1.0), 100.0 * (a2/a0 - 1.0));
    return 0;
}
}
