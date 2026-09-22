/*
 * How hot the machine is, read off a fixed workload rather than a clock.
 *
 * There is no thermal counter on this device without sudo, and `pmset -g
 * therm` records nothing. But V4.1-TUNING.md's own measurement is that an hour
 * of running costs 6-7 ms a token and ten minutes idle gives it back, with
 * every memory counter flat - so the machine's state is visible in the rate of
 * any fixed piece of work. This runs one, in about a second, and prints it.
 *
 * Waiting ten minutes by the clock assumes the recovery; this measures it.
 *
 *   clang -O2 -fobjc-arc -framework Foundation -framework Metal -o thermal thermal.m
 *   ./thermal                 one reading
 *   ./thermal --record        write this reading to thermal.cool as the
 *                             reference for a machine that has settled
 *   ./thermal --until 0.97    wait until the reading reaches 97% of that
 *                             reference, or twenty minutes have passed
 *
 * The reference has to be absolute. An earlier version compared against the
 * best reading seen in the same invocation, which a machine that is hot but
 * steady passes on its second reading - it measures nothing. Measured on this
 * machine: 996 GFLOP/s straight after an hour of generation, 1216 five minutes
 * later, and flat after that. Eighteen percent, and the recovery is about five
 * minutes rather than the ten the page assumes.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <libgen.h>

static const char *kSrc = R"MSL(
#include <metal_stdlib>
using namespace metal;
/* Compute-bound and tiny: what moves is the clock, not the memory system. */
kernel void spin(device float *out, constant uint &iters,
                 uint gid [[thread_position_in_grid]]) {
    float a = (float)(gid & 255u) * 1e-3f + 1.0f, b = 1.000001f;
    for (uint i = 0; i < iters; i++) { a = fma(a, b, 1e-7f); b = fma(b, 0.9999999f, 1e-7f); }
    if (gid == 0) out[0] = a + b;
}
)MSL";

int main(int argc, const char **argv) {
    @autoreleasepool {
        double until = 0.0;
        int record = 0;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--record")) record = 1;
            if (!strcmp(argv[i], "--until") && i + 1 < argc) until = atof(argv[i + 1]);
        }
        char refpath[4096];
        snprintf(refpath, sizeof refpath, "%s/thermal.cool",
                 dirname((char *)argv[0]));
        double reference = 0.0;
        if (until > 0.0) {
            FILE *f = fopen(refpath, "r");
            if (!f || fscanf(f, "%lf", &reference) != 1 || reference <= 0.0) {
                fprintf(stderr, "no settled reference in %s - run --record once "
                                "on a machine that has been idle\n", refpath);
                if (f) fclose(f);
                return 2;
            }
            fclose(f);
            printf("settled reference %.1f GFLOP/s, waiting for %.0f%% of it\n",
                   reference, until * 100.0);
        }
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:kSrc]
                                               options:nil error:&err];
        if (!lib) { NSLog(@"compile: %@", err); return 1; }
        id<MTLComputePipelineState> pso =
            [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"spin"] error:&err];
        if (!pso) { NSLog(@"pso: %@", err); return 1; }
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLBuffer> out = [dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
        const uint32_t threads = 40u * 1024u, iters = 4096u;

        double best = 0.0;
        for (int round = 0; ; round++) {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
            [e setComputePipelineState:pso];
            [e setBuffer:out offset:0 atIndex:0];
            [e setBytes:&iters length:4 atIndex:1];
            [e dispatchThreads:MTLSizeMake(threads, 1, 1)
         threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [e endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            const double ms = ([cb GPUEndTime] - [cb GPUStartTime]) * 1000.0;
            /* Two fused multiply-adds an iteration, two flops each. */
            const double gflops = (double)threads * iters * 4.0 / (ms / 1000.0) / 1e9;
            if (gflops > best) best = gflops;
            printf("%.1f GFLOP/s (%.3f ms)%s\n", gflops, ms,
                   until > 0.0 ? (gflops >= until * reference ? "  - settled"
                                                             : "  - still warm") : "");
            fflush(stdout);
            if (record) {
                FILE *f = fopen(refpath, "w");
                if (!f) { perror("thermal.cool"); return 2; }
                fprintf(f, "%.1f\n", gflops);
                fclose(f);
                printf("recorded as the settled reference in %s\n", refpath);
            }
            if (until <= 0.0) break;
            if (gflops >= until * reference) break;
            if (round > 240) { printf("gave up waiting\n"); break; }
            usleep(5 * 1000 * 1000);
        }
    }
    return 0;
}
