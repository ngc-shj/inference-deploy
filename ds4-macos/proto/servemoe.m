/*
 * Serving the misses instead of being told where they are.
 *
 * moeproto.m compares a host-driven layer against a resident one, but its
 * resident arm reads a host-side array to decide where to break the command
 * buffer. A real decoder does not have that array: the router runs on the GPU,
 * so whether a layer's six experts are reachable is known first on the GPU and
 * only afterwards, if at all, on the host.
 *
 * This is the third arm. One command buffer holds the whole token. Per layer:
 *
 *     router -> validate (writes the masks, publishes an epoch)
 *            -> expert pass over the hit lanes
 *            -> wait on the service event
 *            -> expert pass over the repaired lanes, empty mask and no work
 *               when nothing missed
 *
 * A service thread - never the encoding thread - watches `progress`, installs
 * addresses for whatever missed, and signals the event. On an all-hit layer it
 * reads one word and signals; it never touches the ids, the route, or the
 * command buffer. The decode side never waits for the host and never commits
 * mid-token.
 *
 * What it has to prove, in this order:
 *   1. the output matches the host-driven arm byte for byte;
 *   2. on an all-hit layer the service thread does no work beyond the signal;
 *   3. it is faster, and by how much against the hit rate the model has.
 *
 * What it does NOT show, and what a reader of its numbers has to carry:
 *
 *   - The host is on the critical path on EVERY layer. The GPU signals, this
 *     thread wakes, it writes a value back, the GPU waits for it: four
 *     operations a layer whatever the masks say. Only the encoding thread is
 *     free of them. The round trip is not removed, its work is.
 *   - The repair is two pointer stores handing a missing expert another
 *     expert's bytes. No read, no view, no residency, no eviction, no down
 *     projection. Both arms read the same wrong expert, which is why they
 *     agree, and a miss costing two stores is why the hit rate does not
 *     change the answer.
 *   - The arms do not have the same shape: host-driven builds two command
 *     buffers a layer and waits on both. The difference is not the control
 *     plane's.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>

#define N_TOTAL 384u
#define N_SEL   6u
#define IN_DIM  5120u
#define OUT_ROWS 2304u
#define QK_K 256u
#define BLOCK_B (sizeof(uint16_t) + (QK_K / 8) * sizeof(uint16_t))
#define NSG 2
#define NR0 4

typedef struct { uint32_t n_total_expert, n_selected, row_blocks, nb32; } proto_args;

static double now_ms(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}
static int cmp_d(const void *a, const void *b) {
    const double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y ? 1 : 0;
}

/* ---- the service thread ------------------------------------------------ */
typedef struct {
    _Atomic uint32_t *progress;      /* written by the GPU, one word a layer */
    const uint32_t   *status;        /* hit mask, miss mask, miss count */
    const int32_t    *ids;
    uint64_t         *ga, *ua;       /* the address table it repairs */
    uint64_t          gate_base, up_base;
    size_t            expert_b;
    uint32_t          cached, layers;
    id<MTLSharedEvent> ev;         /* host -> GPU: this layer is repaired */
    id<MTLSharedEvent> gpu_ev;     /* GPU -> host: this layer's masks are written */
    uint64_t          epoch_base;
    /* BUG, not yet fixed: this is used as a flag, and the service thread
     * stores zero to it after the last layer. With two served tokens in a row
     * that store can land after the main thread has published the next epoch.
     * The arms alternate today, so the host-driven stretch hides it. A
     * sequence ring or an explicit completion acknowledgement is needed before
     * this harness measures anything else. */
    _Atomic uint32_t  epoch;         /* the token this pass belongs to */
    _Atomic uint64_t  installs;      /* experts actually brought in */
    _Atomic uint64_t  layers_with_work;
    _Atomic uint64_t  layers_signalled;
    _Atomic uint64_t  spins;
    _Atomic int       stop;
} service_ctx;

static void *service_main(void *p) {
    service_ctx *c = (service_ctx *)p;
    for (;;) {
        const uint32_t epoch = atomic_load_explicit(&c->epoch, memory_order_acquire);
        if (atomic_load_explicit(&c->stop, memory_order_relaxed)) return NULL;
        if (epoch == 0) { sched_yield(); continue; }
        for (uint32_t l = 0; l < c->layers; l++) {
            /* Wait on the event the GPU signals after the validate kernel.
             * Spinning on the status words instead looks cheaper and is wrong:
             * Metal orders a GPU write against a signalled event, and gives no
             * ordering at all for memory a running command buffer wrote. Read
             * the masks too early and a layer that missed looks clean. */
            if (![c->gpu_ev waitUntilSignaledValue:c->epoch_base + (uint64_t)l + 1u
                                          timeoutMS:10000]) {
                fprintf(stderr, "service: timed out waiting for layer %u\n", l);
                return NULL;
            }
            if (atomic_load_explicit(&c->stop, memory_order_relaxed)) return NULL;
            const uint32_t miss_mask = c->status[4u * l + 1u];
            if (miss_mask) {
                atomic_fetch_add_explicit(&c->layers_with_work, 1u, memory_order_relaxed);
                for (uint32_t k = 0; k < N_SEL; k++) {
                    if (((miss_mask >> k) & 1u) == 0u) continue;
                    const int id = c->ids[l * N_SEL + k];
                    if (id < 0) continue;
                    /* Standing in for the fetch: give the expert a slot it can
                     * be reached through. Both arms do exactly this, so the
                     * arithmetic they compare is the same arithmetic. */
                    const uint64_t slot = (uint64_t)((uint32_t)id % c->cached);
                    c->ga[id] = c->gate_base + slot * c->expert_b;
                    c->ua[id] = c->up_base + slot * c->expert_b;
                    atomic_fetch_add_explicit(&c->installs, 1u, memory_order_relaxed);
                }
            }
            c->ev.signaledValue = c->epoch_base + (uint64_t)l + 1u;
            atomic_fetch_add_explicit(&c->layers_signalled, 1u, memory_order_relaxed);
        }
        atomic_store_explicit(&c->epoch, 0u, memory_order_release);
    }
}

int main(int argc, char **argv) {
@autoreleasepool {
    const uint32_t cached  = argc > 1 ? (uint32_t)atoi(argv[1]) : 64;
    const uint32_t layers  = argc > 2 ? (uint32_t)atoi(argv[2]) : 40;
    const int      hit_pct = argc > 3 ? atoi(argv[3]) : 71;
    const uint32_t rounds  = argc > 4 ? (uint32_t)atoi(argv[4]) : 7;
    if (cached < N_SEL || cached > N_TOTAL) { fprintf(stderr, "cached must be %u..%u\n", N_SEL, N_TOTAL); return 1; }

    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    NSError *e = nil;
    NSString *src = [NSString stringWithContentsOfFile:@"moeproto.metal"
                                              encoding:NSUTF8StringEncoding error:&e];
    if (!src) { fprintf(stderr, "source: %s\n", e.localizedDescription.UTF8String); return 1; }
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&e];
    if (!lib) { fprintf(stderr, "compile: %s\n", e.localizedDescription.UTF8String); return 1; }
    id<MTLComputePipelineState> pso_router, pso_val, pso_exp;
#define PSO(v, n) v = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@n] error:&e]; \
                  if (!v) { fprintf(stderr, "pso %s: %s\n", n, e.localizedDescription.UTF8String); return 1; }
    PSO(pso_router, "serve_router") PSO(pso_val, "serve_validate") PSO(pso_exp, "serve_expert")
#undef PSO

    const uint32_t row_blocks = IN_DIM / QK_K, nb32 = row_blocks * (QK_K / 32);
    const size_t   expert_b = (size_t)OUT_ROWS * row_blocks * BLOCK_B;
    proto_args args = { N_TOTAL, N_SEL, row_blocks, nb32 };

    id<MTLBuffer> gate = [d newBufferWithLength:expert_b * cached options:MTLResourceStorageModeShared];
    id<MTLBuffer> up   = [d newBufferWithLength:expert_b * cached options:MTLResourceStorageModeShared];
    id<MTLBuffer> y    = [d newBufferWithLength:IN_DIM * sizeof(float) options:MTLResourceStorageModeShared];
    id<MTLBuffer> scores = [d newBufferWithLength:(size_t)N_TOTAL * sizeof(float) * layers options:MTLResourceStorageModeShared];
    id<MTLBuffer> gaddr = [d newBufferWithLength:N_TOTAL * sizeof(uint64_t) options:MTLResourceStorageModeShared];
    id<MTLBuffer> uaddr = [d newBufferWithLength:N_TOTAL * sizeof(uint64_t) options:MTLResourceStorageModeShared];
    id<MTLBuffer> ids_l[2], og[2], ou[2], st_l[2], prog[2];
    for (int a = 0; a < 2; a++) {
        ids_l[a] = [d newBufferWithLength:(size_t)layers * N_SEL * sizeof(int32_t) options:MTLResourceStorageModeShared];
        og[a]    = [d newBufferWithLength:(size_t)layers * N_SEL * OUT_ROWS * sizeof(float) options:MTLResourceStorageModeShared];
        ou[a]    = [d newBufferWithLength:(size_t)layers * N_SEL * OUT_ROWS * sizeof(float) options:MTLResourceStorageModeShared];
        st_l[a]  = [d newBufferWithLength:(size_t)layers * 4u * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        prog[a]  = [d newBufferWithLength:(size_t)layers * sizeof(uint32_t) options:MTLResourceStorageModeShared];
    }
    srandom(7);
    uint8_t *wg = gate.contents, *wu = up.contents;
    for (size_t i = 0; i < expert_b * cached; i++) { wg[i] = random() & 0xff; wu[i] = random() & 0xff; }
    /* The block's first two bytes are a half scale; random bits there give
     * NaN and Inf, which say nothing about the control structure under test. */
    for (size_t b = 0; b + BLOCK_B <= expert_b * cached; b += BLOCK_B) {
        const uint16_t h = 0x2E66;                 /* about 0.1 in half */
        memcpy(wg + b, &h, sizeof(h));
        memcpy(wu + b, &h, sizeof(h));
    }
    float *yf = y.contents;
    for (uint32_t i = 0; i < IN_DIM; i++) yf[i] = (float)((random() % 2001) - 1000) / 1000.0f;

    /* The pristine table: experts outside the cache have no address at all. */
    uint64_t *ga0 = calloc(N_TOTAL, sizeof(uint64_t)), *ua0 = calloc(N_TOTAL, sizeof(uint64_t));
    for (uint32_t i = 0; i < cached; i++) {
        ga0[i] = gate.gpuAddress + (uint64_t)i * expert_b;
        ua0[i] = up.gpuAddress + (uint64_t)i * expert_b;
    }
    float *sc = scores.contents;
    uint32_t all_hit_layers = 0;
    for (uint32_t l = 0; l < layers; l++) {
        float *s = sc + (size_t)l * N_TOTAL;
        for (uint32_t i = 0; i < N_TOTAL; i++) s[i] = (float)(random() % 1000) / 1000.0f;
        const int all_hit = (int)(random() % 100) < hit_pct;
        if (all_hit) all_hit_layers++;
        const uint32_t wanted = all_hit ? N_SEL : N_SEL - 1u;
        for (uint32_t k = 0; k < wanted; k++) s[(l * 13u + k * 7u) % cached] = 10.0f + (float)k;
        if (!all_hit) s[cached + ((l * 5u) % (N_TOTAL - cached))] = 100.0f;
    }

    id<MTLCommandQueue> q = [d newCommandQueue];
    id<MTLSharedEvent> ev = [d newSharedEvent];
    ev.label = @"serve-repaired";
    id<MTLSharedEvent> gpu_ev = [d newSharedEvent];
    gpu_ev.label = @"serve-validated";
    const MTLSize egrid = MTLSizeMake(OUT_ROWS / (NSG * NR0), 1, N_SEL);
    const MTLSize etg = MTLSizeMake(32 * NSG, 1, 1);
    const NSUInteger shmem = 256 * sizeof(uint64_t) + 128;
    const uint32_t out_stride = OUT_ROWS;

    service_ctx ctx = {0};
    ctx.progress = (_Atomic uint32_t *)prog[1].contents;
    ctx.status = st_l[1].contents;
    ctx.ids = ids_l[1].contents;
    ctx.ga = gaddr.contents; ctx.ua = uaddr.contents;
    ctx.gate_base = gate.gpuAddress; ctx.up_base = up.gpuAddress;
    ctx.expert_b = expert_b; ctx.cached = cached; ctx.layers = layers;
    ctx.ev = ev;
    ctx.gpu_ev = gpu_ev;
    pthread_t th;
    pthread_create(&th, NULL, service_main, &ctx);

    double *ms[2];
    for (int a = 0; a < 2; a++) ms[a] = malloc(rounds * sizeof(double));
    /* Before either arm is compared with the other, each has to agree with
     * itself: a kernel that is not deterministic makes the comparison
     * meaningless whichever way it comes out. */
    const size_t out_bytes = (size_t)layers * N_SEL * OUT_ROWS * sizeof(float);
    void *snap[2] = { malloc(out_bytes), malloc(out_bytes) };
    const size_t id_bytes = (size_t)layers * N_SEL * sizeof(int32_t);
    void *idsnap[2] = { malloc(id_bytes), malloc(id_bytes) };
    int self_stable[2] = { 1, 1 }, ids_stable[2] = { 1, 1 };
    int snapped[2] = { 0, 0 };
    uint64_t host_blocking_waits = 0;
    uint64_t epoch_base = 0;

    for (uint32_t r = 0; r < rounds + 1; r++) {
      for (int arm = 0; arm < 2; arm++) {
        /* Both arms start from the same table and perform the same installs. */
        memcpy(gaddr.contents, ga0, N_TOTAL * sizeof(uint64_t));
        memcpy(uaddr.contents, ua0, N_TOTAL * sizeof(uint64_t));
        memset(prog[arm].contents, 0, (size_t)layers * sizeof(uint32_t));
        /* Rows a dispatch never covers keep whatever was there, which makes a
         * run disagree with itself for reasons that are not the control
         * structure. Start both arms from the same blank sheet. */
        memset(og[arm].contents, 0, (size_t)layers * N_SEL * OUT_ROWS * sizeof(float));
        memset(ou[arm].contents, 0, (size_t)layers * N_SEL * OUT_ROWS * sizeof(float));
        uint64_t *ga = gaddr.contents, *ua = uaddr.contents;
        const double t0 = now_ms();

        if (arm == 0) {
            /* Host-driven: commit, wait, read the route, repair, run. */
            for (uint32_t l = 0; l < layers; l++) {
                id<MTLCommandBuffer> cb = [q commandBuffer];
                id<MTLComputeCommandEncoder> rt = [cb computeCommandEncoder];
                [rt setComputePipelineState:pso_router];
                [rt setBuffer:scores offset:(NSUInteger)l * N_TOTAL * sizeof(float) atIndex:0];
                [rt setBuffer:ids_l[arm] offset:0 atIndex:1];
                [rt setBytes:&args length:sizeof(args) atIndex:2];
                [rt setBytes:&l length:sizeof(l) atIndex:3];
                [rt dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(32,1,1)];
                [rt endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                if (r > 0) host_blocking_waits++;
                const int32_t *sel = (const int32_t *)ids_l[arm].contents + l * N_SEL;
                uint32_t hit = 0, miss = 0;
                for (uint32_t k = 0; k < N_SEL; k++) {
                    const int id = sel[k];
                    const int ok = id >= 0 && (uint32_t)id < N_TOTAL && ga[id] != 0 && ua[id] != 0;
                    if (ok) hit |= 1u << k;
                    else {
                        miss |= 1u << k;
                        if (id >= 0) {
                            const uint64_t slot = (uint64_t)((uint32_t)id % cached);
                            ga[id] = gate.gpuAddress + slot * expert_b;
                            ua[id] = up.gpuAddress + slot * expert_b;
                        }
                    }
                }
                uint32_t *st = (uint32_t *)st_l[arm].contents + 4u * l;
                st[0] = hit; st[1] = miss; st[2] = __builtin_popcount(miss);
                id<MTLCommandBuffer> cb2 = [q commandBuffer];
                for (uint32_t which = 0; which < 2; which++) {
                    id<MTLComputeCommandEncoder> ex = [cb2 computeCommandEncoder];
                    [ex setComputePipelineState:pso_exp];
                    [ex setBuffer:ids_l[arm] offset:0 atIndex:0];
                    [ex setBuffer:gaddr offset:0 atIndex:1];
                    [ex setBuffer:uaddr offset:0 atIndex:2];
                    [ex setBuffer:y offset:0 atIndex:3];
                    [ex setBuffer:og[arm] offset:(NSUInteger)l * N_SEL * OUT_ROWS * sizeof(float) atIndex:4];
                    [ex setBuffer:ou[arm] offset:(NSUInteger)l * N_SEL * OUT_ROWS * sizeof(float) atIndex:5];
                    [ex setBytes:&args length:sizeof(args) atIndex:6];
                    [ex setBytes:&out_stride length:sizeof(out_stride) atIndex:7];
                    [ex setBuffer:st_l[arm] offset:0 atIndex:8];
                    [ex setBytes:&l length:sizeof(l) atIndex:9];
                    [ex setBytes:&which length:sizeof(which) atIndex:10];
                    [ex useResource:gate usage:MTLResourceUsageRead];
                    [ex useResource:up usage:MTLResourceUsageRead];
                    [ex setThreadgroupMemoryLength:shmem atIndex:0];
                    [ex dispatchThreadgroups:egrid threadsPerThreadgroup:etg];
                    [ex endEncoding];
                }
                [cb2 commit];
                [cb2 waitUntilCompleted];
            }
        } else {
            /* Served: one command buffer, the host never on the critical path. */
            const uint32_t epoch = r + 1u;
            atomic_store_explicit(&ctx.epoch, 0u, memory_order_release);
            ctx.epoch_base = epoch_base;
            ev.signaledValue = epoch_base;
            gpu_ev.signaledValue = epoch_base;
            atomic_store_explicit(&ctx.epoch, epoch, memory_order_release);
            id<MTLCommandBuffer> cb = [q commandBuffer];
            for (uint32_t l = 0; l < layers; l++) {
                id<MTLComputeCommandEncoder> rt = [cb computeCommandEncoder];
                [rt setComputePipelineState:pso_router];
                [rt setBuffer:scores offset:(NSUInteger)l * N_TOTAL * sizeof(float) atIndex:0];
                [rt setBuffer:ids_l[arm] offset:0 atIndex:1];
                [rt setBytes:&args length:sizeof(args) atIndex:2];
                [rt setBytes:&l length:sizeof(l) atIndex:3];
                [rt dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(32,1,1)];
                [rt endEncoding];
                id<MTLComputeCommandEncoder> v = [cb computeCommandEncoder];
                [v setComputePipelineState:pso_val];
                [v setBuffer:ids_l[arm] offset:0 atIndex:0];
                [v setBuffer:gaddr offset:0 atIndex:1];
                [v setBuffer:uaddr offset:0 atIndex:2];
                [v setBuffer:st_l[arm] offset:0 atIndex:3];
                [v setBuffer:prog[arm] offset:0 atIndex:4];
                [v setBytes:&args length:sizeof(args) atIndex:5];
                [v setBytes:&l length:sizeof(l) atIndex:6];
                [v setBytes:&epoch length:sizeof(epoch) atIndex:7];
                [v dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(32,1,1)];
                [v endEncoding];
                [cb encodeSignalEvent:gpu_ev value:epoch_base + (uint64_t)l + 1u];
                for (uint32_t which = 0; which < 2; which++) {
                    if (which == 1) [cb encodeWaitForEvent:ev value:epoch_base + (uint64_t)l + 1u];
                    id<MTLComputeCommandEncoder> ex = [cb computeCommandEncoder];
                    [ex setComputePipelineState:pso_exp];
                    [ex setBuffer:ids_l[arm] offset:0 atIndex:0];
                    [ex setBuffer:gaddr offset:0 atIndex:1];
                    [ex setBuffer:uaddr offset:0 atIndex:2];
                    [ex setBuffer:y offset:0 atIndex:3];
                    [ex setBuffer:og[arm] offset:(NSUInteger)l * N_SEL * OUT_ROWS * sizeof(float) atIndex:4];
                    [ex setBuffer:ou[arm] offset:(NSUInteger)l * N_SEL * OUT_ROWS * sizeof(float) atIndex:5];
                    [ex setBytes:&args length:sizeof(args) atIndex:6];
                    [ex setBytes:&out_stride length:sizeof(out_stride) atIndex:7];
                    [ex setBuffer:st_l[arm] offset:0 atIndex:8];
                    [ex setBytes:&l length:sizeof(l) atIndex:9];
                    [ex setBytes:&which length:sizeof(which) atIndex:10];
                    [ex useResource:gate usage:MTLResourceUsageRead];
                    [ex useResource:up usage:MTLResourceUsageRead];
                    [ex setThreadgroupMemoryLength:shmem atIndex:0];
                    [ex dispatchThreadgroups:egrid threadsPerThreadgroup:etg];
                    [ex endEncoding];
                }
            }
            [cb commit];
            [cb waitUntilCompleted];
            if (cb.status == MTLCommandBufferStatusError)
                fprintf(stderr, "served arm failed: %s\n", cb.error.localizedDescription.UTF8String);
            epoch_base += layers;
        }
        if (r > 0) ms[arm][r - 1] = now_ms() - t0;
        if (!snapped[arm]) {
            memcpy(snap[arm], og[arm].contents, out_bytes);
            memcpy(idsnap[arm], ids_l[arm].contents, id_bytes);
            snapped[arm] = 1;
        } else {
            if (memcmp(snap[arm], og[arm].contents, out_bytes)) self_stable[arm] = 0;
            if (memcmp(idsnap[arm], ids_l[arm].contents, id_bytes)) ids_stable[arm] = 0;
        }
      }
      if (r == 0) {
          if (memcmp(og[0].contents, og[1].contents, (size_t)layers * N_SEL * OUT_ROWS * sizeof(float)) ||
              memcmp(ou[0].contents, ou[1].contents, (size_t)layers * N_SEL * OUT_ROWS * sizeof(float)))
              fprintf(stderr, "MISMATCH after the warm-up round\n");
      }
    }
    atomic_store_explicit(&ctx.stop, 1, memory_order_release);
    atomic_store_explicit(&ctx.epoch, 1u, memory_order_release);
    ctx.epoch_base = epoch_base;
    gpu_ev.signaledValue = epoch_base + layers + 1u;
    pthread_join(th, NULL);

    const int same = memcmp(og[0].contents, og[1].contents, (size_t)layers * N_SEL * OUT_ROWS * sizeof(float)) == 0 &&
                     memcmp(ou[0].contents, ou[1].contents, (size_t)layers * N_SEL * OUT_ROWS * sizeof(float)) == 0;
    if (!same) {
        const float *a0 = og[0].contents, *a1 = og[1].contents;
        size_t ndiff = 0, first = (size_t)-1;
        for (size_t i = 0; i < (size_t)layers * N_SEL * OUT_ROWS; i++)
            if (memcmp(&a0[i], &a1[i], sizeof(float))) { if (first == (size_t)-1) first = i; ndiff++; }
        {   /* Where do they differ: which rows within a lane, which layers? */
            size_t by_row0 = 0, other = 0; unsigned char *lay = calloc(layers, 1);
            for (size_t i = 0; i < (size_t)layers * N_SEL * OUT_ROWS; i++)
                if (memcmp(&a0[i], &a1[i], sizeof(float))) {
                    if (i % OUT_ROWS == 0) by_row0++; else other++;
                    lay[i / ((size_t)N_SEL * OUT_ROWS)] = 1;
                }
            size_t nlay = 0; for (uint32_t l = 0; l < layers; l++) nlay += lay[l];
            fprintf(stderr, "  differing floats at row 0 of a lane: %zu; elsewhere: %zu; layers touched: %zu of %u\n",
                    by_row0, other, nlay, layers);
            free(lay);
        }
        fprintf(stderr, "  og differs in %zu of %zu floats; first at %zu (lane %zu row %zu): %g vs %g\n",
                ndiff, (size_t)layers * N_SEL * OUT_ROWS, first, first / OUT_ROWS, first % OUT_ROWS,
                first == (size_t)-1 ? 0.0 : (double)a0[first], first == (size_t)-1 ? 0.0 : (double)a1[first]);
        const int32_t *i0 = (const int32_t *)ids_l[0].contents + (size_t)(layers - 1) * N_SEL;
        const int32_t *i1 = (const int32_t *)ids_l[1].contents + (size_t)(layers - 1) * N_SEL;
        fprintf(stderr, "  last layer ids host  :");
        for (uint32_t k = 0; k < N_SEL; k++) fprintf(stderr, " %d", i0[k]);
        fprintf(stderr, "\n  last layer ids served:");
        for (uint32_t k = 0; k < N_SEL; k++) fprintf(stderr, " %d", i1[k]);
        const uint32_t *s0 = (const uint32_t *)st_l[0].contents + 4u * (layers - 1);
        const uint32_t *s1 = (const uint32_t *)st_l[1].contents + 4u * (layers - 1);
        fprintf(stderr, "\n  last layer masks host hit=%#x miss=%#x  served hit=%#x miss=%#x\n",
                s0[0], s0[1], s1[0], s1[1]);
    }
    for (int a = 0; a < 2; a++) qsort(ms[a], rounds, sizeof(double), cmp_d);
    const double h = ms[0][rounds / 2], s = ms[1][rounds / 2];
    printf("cached=%u layers=%u all-hit=%u/%u (%.0f%%) rounds=%u\n",
           cached, layers, all_hit_layers, layers, 100.0 * all_hit_layers / layers, rounds);
    printf("  host-driven   %.3f ms/token  %.3f ms/layer   blocking waits %llu/token\n",
           h, h / layers, (unsigned long long)(host_blocking_waits / rounds / layers ? 0 : 0) + host_blocking_waits / rounds);
    printf("  served        %.3f ms/token  %.3f ms/layer   blocking waits 0/token\n", s, s / layers);
    printf("  %+.1f%%\n", 100.0 * (s - h) / h);
    printf("  self-consistency over rounds: host output %s / ids %s, served output %s / ids %s\n",
           self_stable[0] ? "stable" : "NOT STABLE", ids_stable[0] ? "stable" : "NOT STABLE",
           self_stable[1] ? "stable" : "NOT STABLE", ids_stable[1] ? "stable" : "NOT STABLE");
    printf("  output: %s\n", same ? "identical" : "DIFFERENT");
    printf("  service thread: %llu layers signalled, %llu had work, %llu experts installed\n",
           (unsigned long long)atomic_load(&ctx.layers_signalled),
           (unsigned long long)atomic_load(&ctx.layers_with_work),
           (unsigned long long)atomic_load(&ctx.installs));
    printf("  layers needing no host work: %llu of %llu (%.1f%%)\n",
           (unsigned long long)(atomic_load(&ctx.layers_signalled) - atomic_load(&ctx.layers_with_work)),
           (unsigned long long)atomic_load(&ctx.layers_signalled),
           100.0 * (double)(atomic_load(&ctx.layers_signalled) - atomic_load(&ctx.layers_with_work)) /
                   (double)atomic_load(&ctx.layers_signalled));
    return same ? 0 : 1;
} }
