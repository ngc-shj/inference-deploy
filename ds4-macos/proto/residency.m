/* Can a command buffer that is already committed be made to reach a resource
 * the CPU only decides on afterwards?
 *
 * The question behind it: today every layer commits, waits on the main thread,
 * reads the selected ids, binds the experts it now knows about, and encodes a
 * fresh command buffer. If a residency set can be updated while a committed
 * buffer is stalled on a shared event, the commit/readback/re-encode structure
 * can go and a whole token can be encoded once.
 *
 *   GPU: kernel ... signal gpu_event ... wait cpu_event ... deref addr_table
 *   CPU:            wake on gpu_event -> make a no-copy view -> add to the
 *                   residency set -> commit -> write addr_table -> signal
 *
 * Pass conditions: the dereferenced checksum matches a directly bound one, no
 * validation error, no whole-window first touch, and the add/commit plus event
 * gate beats the commit/readback/re-encode it would replace.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define PAGE 16384ull

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
    const char *path = argc > 1 ? argv[1] : NULL;
    const uint32_t iters  = argc > 2 ? (uint32_t)atoi(argv[2]) : 40;   /* "layers" */
    const uint32_t rounds = argc > 3 ? (uint32_t)atoi(argv[3]) : 7;
    const size_t region   = argc > 4 ? (size_t)atoll(argv[4]) : 3u << 20;  /* ~an expert */
    /* A bounded cache has to evict. An allocation is only removed once the GPU
     * has signalled past the step that used it, which is what makes the
     * removal safe without another synchronisation. */
    const uint32_t cap    = argc > 5 ? (uint32_t)atoi(argv[5]) : 8;
    if (!path) { fprintf(stderr, "usage: residency <gguf> [iters] [rounds] [bytes]\n"); return 1; }

    if (@available(macOS 15.0, *)) {} else {
        fprintf(stderr, "needs macOS 15 for MTLResidencySet\n"); return 1;
    }
    const size_t rbytes = ((region + PAGE - 1) / PAGE) * PAGE;
    const uint32_t words = (uint32_t)(rbytes / sizeof(uint32_t));

    int fd = open(path, O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st)) { perror("open"); return 1; }
    const size_t fsz = (size_t)st.st_size;
    void *map = mmap(NULL, fsz, PROT_READ, MAP_PRIVATE, fd, 0);
    if (map == MAP_FAILED) { perror("mmap"); return 1; }

    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    NSError *e = nil;
    NSString *src = [NSString stringWithContentsOfFile:@"residency.metal"
                                              encoding:NSUTF8StringEncoding error:&e];
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&e];
    if (!lib) { fprintf(stderr, "compile: %s\n", e.localizedDescription.UTF8String); return 1; }
    id<MTLComputePipelineState> pso_deref =
        [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"deref_sum"] error:&e];
    id<MTLComputePipelineState> pso_bound =
        [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"bound_sum"] error:&e];
    if (!pso_deref || !pso_bound) { fprintf(stderr, "pso: %s\n", e.localizedDescription.UTF8String); return 1; }

    /* 1. An empty residency set on the queue, resident before anything is in it. */
    MTLResidencySetDescriptor *rd = [MTLResidencySetDescriptor new];
    rd.label = @"dynamic expert cache";
    rd.initialCapacity = 64;
    id<MTLResidencySet> rset = [d newResidencySetWithDescriptor:rd error:&e];
    if (!rset) { fprintf(stderr, "residency set: %s\n", e.localizedDescription.UTF8String); return 1; }
    [rset commit];
    [rset requestResidency];
    id<MTLCommandQueue> q = [d newCommandQueue];
    [q addResidencySet:rset];

    id<MTLBuffer> table = [d newBufferWithLength:64 * sizeof(uint64_t) options:MTLResourceStorageModeShared];
    id<MTLBuffer> out   = [d newBufferWithLength:64 * sizeof(uint64_t) options:MTLResourceStorageModeShared];
    id<MTLBuffer> refout= [d newBufferWithLength:64 * sizeof(uint64_t) options:MTLResourceStorageModeShared];
    uint64_t *tab = table.contents;
    id<MTLSharedEvent> gpu_ev = [d newSharedEvent];   /* GPU tells the CPU */
    id<MTLSharedEvent> cpu_ev = [d newSharedEvent];   /* CPU releases the GPU */

    /* Distinct regions spread over the file, as routed experts are. */
    const size_t stride = ((fsz - rbytes * 2) / (iters + 2) / PAGE) * PAGE;
    NSMutableArray *views = [NSMutableArray array];
    double first_touch_ms = 0;
    for (uint32_t i = 0; i < iters; i++) {
        uint8_t *p = (uint8_t *)map + (size_t)(i + 1) * stride;
        id<MTLBuffer> b = [d newBufferWithBytesNoCopy:p length:rbytes
                                              options:MTLResourceStorageModeShared deallocator:nil];
        if (!b) { fprintf(stderr, "no-copy view %u failed\n", i); return 1; }
        b.label = [NSString stringWithFormat:@"expert %u", i];
        [views addObject:b];
    }

    /* Reference: bind each region directly and sum it. This also warms the
     * pages, so the timed arms are not measuring the SSD. */
    {
        const double t0 = now_ms();
        id<MTLCommandBuffer> cb = [q commandBuffer];
        for (uint32_t i = 0; i < iters; i++) {
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            [enc setComputePipelineState:pso_bound];
            [enc setBuffer:views[i] offset:0 atIndex:0];
            [enc setBuffer:refout offset:0 atIndex:1];
            [enc setBytes:&words length:4 atIndex:2];
            const uint32_t slot = i % 64;
            [enc setBytes:&slot length:4 atIndex:3];
            [enc dispatchThreads:MTLSizeMake(256,1,1) threadsPerThreadgroup:MTLSizeMake(256,1,1)];
            [enc endEncoding];
        }
        [cb commit];
        [cb waitUntilCompleted];
        first_touch_ms = now_ms() - t0;
        if (cb.status == MTLCommandBufferStatusError)
            fprintf(stderr, "reference pass error: %s\n", cb.error.localizedDescription.UTF8String);
    }

    /* The resident pass: work the GPU can do between telling the CPU what it
     * needs and being allowed to touch it. Without this the event gate is just
     * a stall in a different shape, which is what the first version measured. */
    void (^resident_pass)(id<MTLCommandBuffer>, uint32_t) = ^(id<MTLCommandBuffer> cb, uint32_t i) {
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pso_bound];
        [enc setBuffer:views[(i + 1) % iters] offset:0 atIndex:0];
        [enc setBuffer:refout offset:0 atIndex:1];
        [enc setBytes:&words length:4 atIndex:2];
        const uint32_t slot = 63;
        [enc setBytes:&slot length:4 atIndex:3];
        [enc dispatchThreads:MTLSizeMake(256,1,1) threadsPerThreadgroup:MTLSizeMake(256,1,1)];
        [enc endEncoding];
    };

    double *ms[2];
    for (int a = 0; a < 2; a++) ms[a] = malloc(rounds * sizeof(double));
    uint64_t seq = 0, evictions = 0;
    __block int validation_errors = 0;

    for (uint32_t r = 0; r < rounds + 1; r++) {
      for (int arm = 0; arm < 2; arm++) {
        memset(out.contents, 0, 64 * sizeof(uint64_t));
        memset(tab, 0, 64 * sizeof(uint64_t));
        const double t0 = now_ms();

        if (arm == 0) {
            /* What ds4 does now: commit, wait on the main thread, do the host
             * work, encode a fresh command buffer, commit again. */
            for (uint32_t i = 0; i < iters; i++) {
                id<MTLCommandBuffer> cb = [q commandBuffer];
                resident_pass(cb, i);
                [cb encodeSignalEvent:gpu_ev value:++seq];
                [cb commit];
                [cb waitUntilCompleted];
                const uint32_t slot = i % 64;
                [rset addAllocation:views[i]];
                [rset commit];
                tab[slot] = ((id<MTLBuffer>)views[i]).gpuAddress;
                id<MTLCommandBuffer> cb2 = [q commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cb2 computeCommandEncoder];
                [enc setComputePipelineState:pso_deref];
                [enc setBuffer:table offset:0 atIndex:0];
                [enc setBuffer:out offset:0 atIndex:1];
                [enc setBytes:&words length:4 atIndex:2];
                [enc setBytes:&slot length:4 atIndex:3];
                [enc dispatchThreads:MTLSizeMake(256,1,1) threadsPerThreadgroup:MTLSizeMake(256,1,1)];
                [enc endEncoding];
                [cb2 commit];
                [cb2 waitUntilCompleted];
                if (cb2.status == MTLCommandBufferStatusError) validation_errors++;
            }
        } else {
            /* One command buffer for the whole run, stalled on a shared event
             * at each step while the CPU updates residency and the table. */
            id<MTLCommandBuffer> cb = [q commandBuffer];
            const uint64_t base = seq;
            for (uint32_t i = 0; i < iters; i++) {
                [cb encodeSignalEvent:gpu_ev value:base + i * 2 + 1];
                resident_pass(cb, i);
                [cb encodeWaitForEvent:cpu_ev value:base + i * 2 + 2];
                id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                [enc setComputePipelineState:pso_deref];
                [enc setBuffer:table offset:0 atIndex:0];
                [enc setBuffer:out offset:0 atIndex:1];
                [enc setBytes:&words length:4 atIndex:2];
                const uint32_t slot = i % 64;
                [enc setBytes:&slot length:4 atIndex:3];
                [enc dispatchThreads:MTLSizeMake(256,1,1) threadsPerThreadgroup:MTLSizeMake(256,1,1)];
                [enc endEncoding];
            }
            [cb commit];
            for (uint32_t i = 0; i < iters; i++) {
                while (gpu_ev.signaledValue < base + i * 2 + 1) { /* spin: this is the wake */ }
                [rset addAllocation:views[i]];
                if (cap && i >= cap) {
                    /* views[i - cap] was used at step i - cap, and the GPU has
                     * signalled step i, so it is past it. */
                    [rset removeAllocation:views[i - cap]];
                    evictions++;
                }
                [rset commit];
                tab[i % 64] = ((id<MTLBuffer>)views[i]).gpuAddress;
                cpu_ev.signaledValue = base + i * 2 + 2;
            }
            [cb waitUntilCompleted];
            seq = base + iters * 2 + 2;
            if (cb.status == MTLCommandBufferStatusError) {
                validation_errors++;
                fprintf(stderr, "event-gated error: %s\n", cb.error.localizedDescription.UTF8String);
            }
        }
        if (r > 0) ms[arm][r - 1] = now_ms() - t0;
        if (arm == 1 && r == rounds) {
            const uint64_t *o = out.contents, *ro = refout.contents;
            int bad = 0;
            for (uint32_t i = 0; i < iters && i < 64; i++) if (o[i] != ro[i]) bad++;
            printf("  checksums against direct binding: %s (%u slots)\n",
                   bad ? "MISMATCH" : "identical", iters < 64 ? iters : 64);
        }
      }
    }
    for (int a = 0; a < 2; a++) qsort(ms[a], rounds, sizeof(double), cmp_d);
    const double a0 = ms[0][rounds / 2], a1 = ms[1][rounds / 2];
    printf("%u steps of %.1f MiB, no-copy views over %.1f GiB\n",
           iters, rbytes / 1048576.0, fsz / 1073741824.0);
    printf("  reference pass (direct bind, warms pages): %.2f ms\n", first_touch_ms);
    printf("  commit / wait / re-encode  : %7.2f ms, %5.3f ms/step\n", a0, a0 / iters);
    printf("  one buffer, event-gated    : %7.2f ms, %5.3f ms/step\n", a1, a1 / iters);
    printf("  event-gated is %+.1f%%\n", 100.0 * (a1 / a0 - 1.0));
    printf("  evictions from the set: %llu (cap %u)\n",
           (unsigned long long)evictions / (rounds + 1), cap);
    printf("  command buffer errors: %d\n", validation_errors);
    return validation_errors ? 2 : 0;
}
}
