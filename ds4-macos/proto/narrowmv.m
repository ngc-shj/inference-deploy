/*
 * What a narrow projection reaches on its own, and what merging several into
 * one dispatch recovers.
 *
 * DeepSeek V4.1's layer is low-rank and compressed throughout, so its
 * projections are narrow: q_a is 7168x1280, kv 7168x512, the KV compressor
 * 7168x512, the indexer projection 7168x32. A narrow output means few rows,
 * few rows mean few threadgroups, and the call-site census finds 59.1
 * dispatches a token at 24 threadgroups on a forty-core GPU.
 *
 * proto/concur.m showed that 288 threadgroups does not saturate and that the
 * way to collect it is a bigger grid, not a concurrent encoder. This measures
 * where a real projection's grid sits on that curve, and what the five that
 * hang off `norm` would reach if they went out as one dispatch.
 *
 * A fresh slab every lap, sized past the last level cache, so this is a cold
 * read rather than a replay - the same discipline as the routed sweep.
 *
 *   clang -O2 -fobjc-arc -framework Foundation -framework Metal -o narrowmv narrowmv.m
 *   ./narrowmv [laps]
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static const char *kSrc = R"MSL(
#include <metal_stdlib>
using namespace metal;

/* One threadgroup takes `rows_per_group` output rows of one lane. `lane_rows`
 * and `lane_stride` let several independent projections share a dispatch: lane
 * L reads its own weights and writes its own output, which is what merging the
 * projections that all read `norm` would look like. */
kernel void mv(device const half *w, device const float *x, device float *out,
               constant uint &n_in, constant uint &rows_per_group,
               constant uint &lane_rows, constant ulong &lane_stride,
               uint3 tg [[threadgroup_position_in_grid]],
               uint3 tid3 [[thread_position_in_threadgroup]],
               uint sgid [[simdgroup_index_in_threadgroup]],
               uint nsg [[simdgroups_per_threadgroup]],
               uint lane_id [[thread_index_in_simdgroup]]) {
    const uint groups_per_lane = (lane_rows + rows_per_group - 1u) / rows_per_group;
    const uint lane = tg.x / groups_per_lane;
    const uint g_in_lane = tg.x - lane * groups_per_lane;
    device const half *wl = w + lane * lane_stride;
    for (uint r = sgid; r < rows_per_group; r += nsg) {
        const uint row = g_in_lane * rows_per_group + r;
        if (row >= lane_rows) continue;
        device const half *src = wl + (ulong)row * n_in;
        float acc = 0.0f;
        for (uint i = lane_id; i < n_in; i += 32u) acc += float(src[i]) * x[i];
        acc = simd_sum(acc);
        if (lane_id == 0) out[lane * lane_rows + row] = acc;
    }
}
)MSL";

typedef struct { const char *name; uint32_t rows; } shape;

int main(int argc, const char **argv) {
    @autoreleasepool {
        const uint32_t laps = argc > 1 ? (uint32_t)atoi(argv[1]) : 96;
        const uint32_t n_in = 7168;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:kSrc]
                                               options:nil error:&err];
        if (!lib) { NSLog(@"compile: %@", err); return 1; }
        id<MTLComputePipelineState> pso =
            [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"mv"] error:&err];
        if (!pso) { NSLog(@"pso: %@", err); return 1; }
        id<MTLCommandQueue> q = [dev newCommandQueue];

        /* The five that all read `norm` in one V4.1 layer. */
        const shape shapes[] = {
            { "indexer_proj      7168x32",   32 },
            { "attn_kv           7168x512",  512 },
            { "attn_compressor   7168x512",  512 },
            { "attn_output_a     7168x1024", 1024 },
            { "attn_q_a          7168x1280", 1280 },
        };
        const uint32_t n_shapes = sizeof(shapes) / sizeof(shapes[0]);
        uint32_t merged_rows = 0;
        for (uint32_t i = 0; i < n_shapes; i++) merged_rows += shapes[i].rows;

        /* Room for `laps` distinct copies of the widest lane set, so a lap
         * never reads what the previous lap warmed. */
        const uint64_t lane_rows_max = 1280;
        const uint64_t slab = lane_rows_max * n_in * sizeof(uint16_t);
        const uint64_t total = slab * n_shapes * laps;
        id<MTLBuffer> w = [dev newBufferWithLength:total options:MTLResourceStorageModePrivate];
        id<MTLBuffer> x = [dev newBufferWithLength:n_in * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> o = [dev newBufferWithLength:merged_rows * 4
                                           options:MTLResourceStorageModePrivate];
        if (!w) { printf("could not allocate %.1f GiB\n", total / 1073741824.0); return 1; }
        for (uint32_t i = 0; i < n_in; i++) ((float *)x.contents)[i] = 1.0f / (float)(i + 1u);
        printf("%.2f GiB of weights, %u laps, one cold slab a lap\n\n",
               total / 1073741824.0, laps);

        /* rows a threadgroup, chosen so attn_q_a lands on the 24 the census
         * reports for the real kernel. */
        const uint32_t rpg = 54;

        printf("%-28s %6s %10s %8s %9s\n", "projection", "tgs", "MiB", "ms", "GB/s");
        double serial_ms = 0.0, serial_bytes = 0.0;
        for (uint32_t s = 0; s < n_shapes; s++) {
            const uint32_t rows = shapes[s].rows;
            const uint32_t tgs = (rows + rpg - 1u) / rpg;
            const uint64_t bytes_lap = (uint64_t)rows * n_in * 2ull;
            const uint32_t one = 1u;
            const uint64_t zero = 0;
            id<MTLCommandBuffer> cb = [q commandBuffer];
            for (uint32_t lap = 0; lap < laps; lap++) {
                id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
                [e setComputePipelineState:pso];
                [e setBuffer:w offset:(NSUInteger)(slab * ((uint64_t)s * laps + lap)) atIndex:0];
                [e setBuffer:x offset:0 atIndex:1];
                [e setBuffer:o offset:0 atIndex:2];
                [e setBytes:&n_in length:4 atIndex:3];
                [e setBytes:&rpg length:4 atIndex:4];
                [e setBytes:&rows length:4 atIndex:5];
                [e setBytes:&zero length:8 atIndex:6];
                (void)one;
                [e dispatchThreadgroups:MTLSizeMake(tgs, 1, 1)
                  threadsPerThreadgroup:MTLSizeMake(32, 8, 1)];
                [e endEncoding];
            }
            [cb commit];
            [cb waitUntilCompleted];
            const double ms = ([cb GPUEndTime] - [cb GPUStartTime]) * 1000.0;
            const double bytes = (double)bytes_lap * laps;
            printf("%-28s %6u %10.1f %8.2f %9.1f\n", shapes[s].name, tgs,
                   bytes / 1048576.0, ms, bytes / (ms / 1000.0) / 1e9);
            serial_ms += ms; serial_bytes += bytes;
        }
        printf("%-28s %6s %10.1f %8.2f %9.1f\n", "  the five, one at a time", "",
               serial_bytes / 1048576.0, serial_ms,
               serial_bytes / (serial_ms / 1000.0) / 1e9);

        /* Merged: every lane the same width, so one grid covers them all. The
         * widest is what a real merge would have to pad to. */
        {
            const uint32_t rows = 1280;
            const uint32_t tgs = ((rows + rpg - 1u) / rpg) * n_shapes;
            const uint64_t bytes_lap = (uint64_t)rows * n_in * 2ull * n_shapes;
            id<MTLCommandBuffer> cb = [q commandBuffer];
            for (uint32_t lap = 0; lap < laps; lap++) {
                id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
                [e setComputePipelineState:pso];
                [e setBuffer:w offset:(NSUInteger)(slab * (uint64_t)lap * n_shapes) atIndex:0];
                [e setBuffer:x offset:0 atIndex:1];
                [e setBuffer:o offset:0 atIndex:2];
                [e setBytes:&n_in length:4 atIndex:3];
                [e setBytes:&rpg length:4 atIndex:4];
                [e setBytes:&rows length:4 atIndex:5];
                [e setBytes:&slab length:8 atIndex:6];
                [e dispatchThreadgroups:MTLSizeMake(tgs, 1, 1)
                  threadsPerThreadgroup:MTLSizeMake(32, 8, 1)];
                [e endEncoding];
            }
            [cb commit];
            [cb waitUntilCompleted];
            const double ms = ([cb GPUEndTime] - [cb GPUStartTime]) * 1000.0;
            const double bytes = (double)bytes_lap * laps;
            printf("%-28s %6u %10.1f %8.2f %9.1f\n", "  five lanes, one dispatch",
                   tgs, bytes / 1048576.0, ms, bytes / (ms / 1000.0) / 1e9);
        }
    }
    return 0;
}
