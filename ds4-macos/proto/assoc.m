/*
 * Does the Metal compiler keep `a * b * c` in the order it is written?
 *
 * The speculative expert reuse needs the routed gate/up kernel to store
 * silu*u without the route weight, so the match can apply the weight as it
 * copies the row. That is only allowed if
 *
 *     store(silu*u) ; load ; * w      ==      silu * u * w
 *
 * bit for bit. In the engine it is not: 1,066 of a 2,048-wide row differ, 93%
 * of them by exactly one ulp, which is what a single rounding step moved from
 * one place to another looks like. This file asks the compiler directly, with
 * nothing else in the picture.
 *
 *     clang -O2 -fobjc-arc -framework Foundation -framework Metal -o assoc assoc.m
 *     ./assoc [n]
 *
 * Arms, over the same random f32 triples:
 *
 *   chain    d = a * b * c                      - what the kernel ships today
 *   named    t = a * b ; d = t * c              - the same, with a name on it
 *   through  store(a*b) ; d = load * c          - what the reuse would compute
 *   right    d = a * (b * c)                    - the other association
 *
 * fastMathEnabled is the default and is what the engine compiles with; the
 * second run turns it off, because which of these the flag decides is the
 * whole question.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>

static NSString *const kSrc = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"kernel void arms(device const float *a, device const float *b,\n"
"                 device const float *c, device float *chain,\n"
"                 device float *named, device float *through,\n"
"                 device float *right, uint i [[thread_position_in_grid]]) {\n"
"    const float x = a[i], y = b[i], z = c[i];\n"
"    chain[i] = x * y * z;\n"
"    const float t = x * y;\n"
"    named[i] = t * z;\n"
"    /* The store the speculation makes, and the load the match makes. */\n"
"    through[i] = t;\n"
"    right[i] = x * (y * z);\n"
"}\n"
"kernel void finish(device float *through, device const float *c,\n"
"                   uint i [[thread_position_in_grid]]) {\n"
"    through[i] = through[i] * c[i];\n"
"}\n";

static id<MTLBuffer> rnd(id<MTLDevice> d, uint32_t n, unsigned seed) {
    id<MTLBuffer> b = [d newBufferWithLength:n * sizeof(float)
                                     options:MTLResourceStorageModeShared];
    float *p = (float *)b.contents;
    srandom(seed);
    for (uint32_t i = 0; i < n; i++) {
        /* Spread over exponents as well as mantissas: rounding differences
         * that only show up near a binade edge would be missed by uniform
         * values in one decade. */
        const double m = (double)random() / (double)RAND_MAX * 2.0 - 1.0;
        const int e = (int)(random() % 21) - 10;
        p[i] = (float)(m * pow(2.0, e));
    }
    return b;
}

static void run(id<MTLDevice> dev, uint32_t n, BOOL fast) {
    NSError *err = nil;
    MTLCompileOptions *opt = [MTLCompileOptions new];
    opt.fastMathEnabled = fast;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kSrc options:opt error:&err];
    if (!lib) { fprintf(stderr, "compile: %s\n", err.description.UTF8String); exit(1); }
    id<MTLComputePipelineState> arms =
        [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"arms"] error:&err];
    id<MTLComputePipelineState> fin =
        [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"finish"] error:&err];
    if (!arms || !fin) { fprintf(stderr, "pipeline: %s\n", err.description.UTF8String); exit(1); }

    id<MTLBuffer> a = rnd(dev, n, 1), b = rnd(dev, n, 2), c = rnd(dev, n, 3);
    id<MTLBuffer> out[4];
    for (int i = 0; i < 4; i++)
        out[i] = [dev newBufferWithLength:n * sizeof(float)
                                  options:MTLResourceStorageModeShared];

    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:arms];
    [e setBuffer:a offset:0 atIndex:0];
    [e setBuffer:b offset:0 atIndex:1];
    [e setBuffer:c offset:0 atIndex:2];
    for (int i = 0; i < 4; i++) [e setBuffer:out[i] offset:0 atIndex:3 + i];
    [e dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
    [e endEncoding];
    /* A second encoder, so the store really is a store: within one dispatch
     * the compiler could keep the value in a register and the arm would be
     * measuring nothing. */
    e = [cb computeCommandEncoder];
    [e setComputePipelineState:fin];
    [e setBuffer:out[2] offset:0 atIndex:0];
    [e setBuffer:c offset:0 atIndex:1];
    [e dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
    [e endEncoding];
    [cb commit];
    [cb waitUntilCompleted];

    const uint32_t *chain = (const uint32_t *)out[0].contents;
    const char *name[3] = { "named   (t = a*b; t*c)", "through (store a*b, *c)",
                            "right   (a*(b*c))" };
    printf("  fast math %s, %u values against `a * b * c`:\n", fast ? "on " : "off", n);
    for (int k = 1; k < 4; k++) {
        const uint32_t *v = (const uint32_t *)out[k].contents;
        uint32_t diff = 0, far = 0;
        for (uint32_t i = 0; i < n; i++) {
            if (v[i] == chain[i]) continue;
            diff++;
            const uint32_t x = v[i], y = chain[i];
            if (x > y ? x - y > 1u : y - x > 1u) far++;
        }
        printf("    %-24s %8u differ (%5.2f%%), %u by more than an ulp\n",
               name[k - 1], diff, 100.0 * diff / n, far);
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const uint32_t n = argc > 1 ? (uint32_t)atoi(argv[1]) : (1u << 20);
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        printf("%s\n", dev.name.UTF8String);
        run(dev, n, YES);
        run(dev, n, NO);
    }
    return 0;
}
