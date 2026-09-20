/* One V4.1 streaming MoE layer, cut vertically, two control structures.
 *
 *   host-driven : router -> commit -> WAIT -> read ids -> look up -> experts
 *   resident    : router -> GPU validate -> hit experts -> miss record
 *
 * Both run the same expert kernel over the same bytes with the same ids. The
 * only difference is whether the selected ids leave the GPU, which is the
 * thing being tested. Outputs are compared byte for byte, and the hit rate is
 * a dial so the break-even can be found rather than assumed.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define N_TOTAL   384u
#define N_SEL     6u
#define IN_DIM    5120u
#define OUT_ROWS  2304u
#define QK_K      256u
#define BLOCK_B   66u
#define NSG       2u
#define NR0       4u

typedef struct { uint32_t n_total_expert, n_selected, row_blocks, nb32; } proto_args;

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
    const uint32_t cached   = argc > 1 ? (uint32_t)atoi(argv[1]) : 64;    /* experts in the cache */
    const uint32_t layers   = argc > 2 ? (uint32_t)atoi(argv[2]) : 40;    /* layers a "token" */
    const int      hit_pct  = argc > 3 ? atoi(argv[3]) : 100;             /* all-6-hit layers */
    const uint32_t rounds   = argc > 4 ? (uint32_t)atoi(argv[4]) : 7;
    if (cached < N_SEL || cached > N_TOTAL) { fprintf(stderr, "cached must be %u..%u\n", N_SEL, N_TOTAL); return 1; }

    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    NSError *e = nil;
    NSString *src = [NSString stringWithContentsOfFile:@"moeproto.metal"
                                              encoding:NSUTF8StringEncoding error:&e];
    if (!src) { fprintf(stderr, "source: %s\n", e.localizedDescription.UTF8String); return 1; }
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&e];
    if (!lib) { fprintf(stderr, "compile: %s\n", e.localizedDescription.UTF8String); return 1; }
    id<MTLComputePipelineState> pso_router, pso_val, pso_seal, pso_exp;
#define PSO(v, n) v = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@n] error:&e]; \
                  if (!v) { fprintf(stderr, "pso %s: %s\n", n, e.localizedDescription.UTF8String); return 1; }
    PSO(pso_router, "proto_router_topk") PSO(pso_val, "proto_validate")
    PSO(pso_seal, "proto_seal") PSO(pso_exp, "proto_expert")
#undef PSO

    const uint32_t row_blocks = IN_DIM / QK_K, nb32 = row_blocks * (QK_K / 32);
    const size_t   expert_b = (size_t)OUT_ROWS * row_blocks * BLOCK_B;
    proto_args args = { N_TOTAL, N_SEL, row_blocks, nb32 };

    /* Only cached experts have storage, which is what "in the cache" means:
     * the others have no address and the GPU cannot reach them. */
    id<MTLBuffer> gate = [d newBufferWithLength:expert_b * cached options:MTLResourceStorageModeShared];
    id<MTLBuffer> up   = [d newBufferWithLength:expert_b * cached options:MTLResourceStorageModeShared];
    id<MTLBuffer> gaddr = [d newBufferWithLength:N_TOTAL * sizeof(uint64_t) options:MTLResourceStorageModeShared];
    id<MTLBuffer> uaddr = [d newBufferWithLength:N_TOTAL * sizeof(uint64_t) options:MTLResourceStorageModeShared];
    id<MTLBuffer> y    = [d newBufferWithLength:IN_DIM * sizeof(float) options:MTLResourceStorageModeShared];
    id<MTLBuffer> scores = [d newBufferWithLength:N_TOTAL * sizeof(float) * layers options:MTLResourceStorageModeShared];
    id<MTLBuffer> ids[2], og[2], ou[2], status[2], missids[2];
    for (int a = 0; a < 2; a++) {
        ids[a]     = [d newBufferWithLength:N_SEL * sizeof(int32_t) options:MTLResourceStorageModeShared];
        og[a]      = [d newBufferWithLength:(size_t)N_SEL * OUT_ROWS * sizeof(float) options:MTLResourceStorageModeShared];
        ou[a]      = [d newBufferWithLength:(size_t)N_SEL * OUT_ROWS * sizeof(float) options:MTLResourceStorageModeShared];
        status[a]  = [d newBufferWithLength:4 * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        missids[a] = [d newBufferWithLength:N_SEL * sizeof(int32_t) options:MTLResourceStorageModeShared];
    }
    srandom(7);
    uint8_t *wg = gate.contents, *wu = up.contents;
    for (size_t i = 0; i < expert_b * cached; i++) { wg[i] = random() & 0xff; wu[i] = random() & 0xff; }
    float *yf = y.contents;
    for (uint32_t i = 0; i < IN_DIM; i++) yf[i] = (float)((random() % 2001) - 1000) / 1000.0f;
    uint64_t *ga = gaddr.contents, *ua = uaddr.contents;
    memset(ga, 0, N_TOTAL * sizeof(uint64_t));
    memset(ua, 0, N_TOTAL * sizeof(uint64_t));
    for (uint32_t i = 0; i < cached; i++) {
        ga[i] = gate.gpuAddress + (uint64_t)i * expert_b;
        ua[i] = up.gpuAddress + (uint64_t)i * expert_b;
    }

    /* Scores per layer, arranged so a chosen fraction of layers has all six
     * selections inside the cache and the rest has exactly one outside it. */
    float *sc = scores.contents;
    uint32_t all_hit_layers = 0;
    /* Which layers were arranged to miss. The resident arm needs this to model
     * repair: a layer whose expert is not in the cache has to come back to the
     * host whatever the control structure, so the segment ends there. */
    uint8_t *layer_all_hit = calloc(layers, 1);
    for (uint32_t l = 0; l < layers; l++) {
        float *s = sc + (size_t)l * N_TOTAL;
        for (uint32_t i = 0; i < N_TOTAL; i++) s[i] = (float)(random() % 1000) / 1000.0f;
        const int all_hit = (int)(random() % 100) < hit_pct;
        layer_all_hit[l] = (uint8_t)all_hit;
        if (all_hit) all_hit_layers++;
        /* Push the intended winners above everything else. */
        const uint32_t wanted = all_hit ? N_SEL : N_SEL - 1u;
        for (uint32_t k = 0; k < wanted; k++) s[(l * 13u + k * 7u) % cached] = 10.0f + (float)k;
        if (!all_hit) s[cached + ((l * 5u) % (N_TOTAL - cached))] = 100.0f;
    }

    id<MTLCommandQueue> q = [d newCommandQueue];
    const MTLSize egrid = MTLSizeMake(OUT_ROWS / (NSG * NR0), 1, N_SEL);
    const MTLSize etg = MTLSizeMake(32 * NSG, 1, 1);
    const NSUInteger shmem = 256 * sizeof(uint64_t) + 128;
    const uint32_t out_stride = OUT_ROWS;

    /* Blocks cannot capture C arrays, so the per-arm buffers come in as
     * arguments rather than being indexed inside. */
    void (^encode_router)(id<MTLCommandBuffer>, id<MTLBuffer>, uint32_t) =
      ^(id<MTLCommandBuffer> cb, id<MTLBuffer> idbuf, uint32_t l) {
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pso_router];
        [enc setBuffer:scores offset:(NSUInteger)l * N_TOTAL * sizeof(float) atIndex:0];
        [enc setBuffer:idbuf offset:0 atIndex:1];
        [enc setBytes:&args length:sizeof(args) atIndex:2];
        [enc dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(32,1,1)];
        [enc endEncoding];
      };
    void (^encode_experts)(id<MTLCommandBuffer>, id<MTLBuffer>, id<MTLBuffer>, id<MTLBuffer>) =
      ^(id<MTLCommandBuffer> cb, id<MTLBuffer> idbuf, id<MTLBuffer> ogbuf, id<MTLBuffer> oubuf) {
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pso_exp];
        [enc setBuffer:idbuf offset:0 atIndex:0];
        [enc setBuffer:gaddr offset:0 atIndex:1];
        [enc setBuffer:uaddr offset:0 atIndex:2];
        [enc setBuffer:y offset:0 atIndex:3];
        [enc setBuffer:ogbuf offset:0 atIndex:4];
        [enc setBuffer:oubuf offset:0 atIndex:5];
        [enc setBytes:&args length:sizeof(args) atIndex:6];
        [enc setBytes:&out_stride length:sizeof(out_stride) atIndex:7];
        [enc useResource:gate usage:MTLResourceUsageRead];
        [enc useResource:up usage:MTLResourceUsageRead];
        [enc setThreadgroupMemoryLength:shmem atIndex:0];
        [enc dispatchThreadgroups:egrid threadsPerThreadgroup:etg];
        [enc endEncoding];
      };

    uint64_t host_readbacks = 0, gpu_miss_layers = 0, resident_syncs = 0;
    double *ms[2];
    for (int a = 0; a < 2; a++) ms[a] = malloc(rounds * sizeof(double));

    for (uint32_t r = 0; r < rounds + 1; r++) {
      for (int arm = 0; arm < 2; arm++) {
        const double t0 = now_ms();
        if (arm == 0) {
            /* Host-driven: every layer commits, waits, and comes back. */
            for (uint32_t l = 0; l < layers; l++) {
                id<MTLCommandBuffer> cb = [q commandBuffer];
                encode_router(cb, ids[arm], l);
                [cb commit];
                [cb waitUntilCompleted];
                if (r > 0) host_readbacks++;
                const int32_t *sel = ids[arm].contents;
                for (uint32_t k = 0; k < N_SEL; k++) {
                    const int id = sel[k];
                    (void)(id >= 0 && (uint32_t)id < N_TOTAL && ga[id] != 0);
                }
                id<MTLCommandBuffer> cb2 = [q commandBuffer];
                encode_experts(cb2, ids[arm], og[arm], ou[arm]);
                [cb2 commit];
                [cb2 waitUntilCompleted];
            }
        } else {
            /* Resident: the ids never leave the GPU while the experts are
             * cached. A layer that misses has to come back to the host to have
             * the expert brought in, so the segment ends there and only there:
             * the synchronisations left are the misses, not the layers. */
            id<MTLCommandBuffer> cb = [q commandBuffer];
            for (uint32_t l = 0; l < layers; l++) {
                encode_router(cb, ids[arm], l);
                id<MTLComputeCommandEncoder> v = [cb computeCommandEncoder];
                [v setComputePipelineState:pso_val];
                [v setBuffer:ids[arm] offset:0 atIndex:0];
                [v setBuffer:gaddr offset:0 atIndex:1];
                [v setBuffer:uaddr offset:0 atIndex:2];
                [v setBuffer:status[arm] offset:0 atIndex:3];
                [v setBuffer:missids[arm] offset:0 atIndex:4];
                [v setBytes:&args length:sizeof(args) atIndex:5];
                [v dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(32,1,1)];
                [v endEncoding];
                encode_experts(cb, ids[arm], og[arm], ou[arm]);
                if (!layer_all_hit[l] && l + 1u < layers) {
                    [cb commit];
                    [cb waitUntilCompleted];
                    if (r > 0) resident_syncs++;
                    const uint32_t *st = status[arm].contents;
                    (void)st;                      /* the host reads the miss record here */
                    cb = [q commandBuffer];
                }
            }
            id<MTLComputeCommandEncoder> sl = [cb computeCommandEncoder];
            [sl setComputePipelineState:pso_seal];
            [sl setBuffer:status[arm] offset:0 atIndex:0];
            [sl dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(32,1,1)];
            [sl endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            const uint32_t *st = status[arm].contents;
            if (r > 0 && st[2]) gpu_miss_layers += st[2];
        }
        if (r > 0) ms[arm][r - 1] = now_ms() - t0;
      }
    }

    const size_t out_b = (size_t)N_SEL * OUT_ROWS * sizeof(float);
    const int same = memcmp(og[0].contents, og[1].contents, out_b) == 0 &&
                     memcmp(ou[0].contents, ou[1].contents, out_b) == 0;
    for (int a = 0; a < 2; a++) qsort(ms[a], rounds, sizeof(double), cmp_d);
    const double a0 = ms[0][rounds / 2], a1 = ms[1][rounds / 2];
    printf("cache %u/%u experts, %u layers, %u%% all-hit layers (%u of %u arranged)\n",
           cached, N_TOTAL, layers, hit_pct, all_hit_layers, layers);
    printf("  host-driven (wait a layer) : %7.2f ms, %5.3f ms/layer, %llu readbacks\n",
           a0, a0 / layers, (unsigned long long)host_readbacks / rounds);
    printf("  resident (sync on miss)    : %7.2f ms, %5.3f ms/layer, %llu syncs, %llu GPU-recorded misses\n",
           a1, a1 / layers, (unsigned long long)resident_syncs / rounds,
           (unsigned long long)gpu_miss_layers / rounds);
    printf("  resident is %+.1f%%\n", 100.0 * (a1 / a0 - 1.0));
    printf("  outputs byte-identical: %s\n", same ? "yes" : "NO");
    return same ? 0 : 2;
}
}
