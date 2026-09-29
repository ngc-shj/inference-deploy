// Read-bandwidth probe: sum a large buffer with a simple float4 reduction.
#import <Metal/Metal.h>
#include <stdio.h>
static const char *src =
"#include <metal_stdlib>\nusing namespace metal;\n"
"kernel void rd(device const float4 *a [[buffer(0)]], device float *o [[buffer(1)]],\n"
"               constant uint &n [[buffer(2)]], uint tg [[threadgroup_position_in_grid]],\n"
"               uint ti [[thread_position_in_threadgroup]], uint nt [[threads_per_threadgroup]],\n"
"               uint ng [[threadgroups_per_grid]]) {\n"
"  float4 s = 0; for (uint i = tg*nt + ti; i < n; i += ng*nt) s += a[i];\n"
"  if (dot(s, 1.0f) == 12345.0f) o[0] = 1; }\n";
int main(void) {
  @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    NSError *e = nil;
    id<MTLLibrary> lib = [d newLibraryWithSource:[NSString stringWithUTF8String:src] options:nil error:&e];
    id<MTLComputePipelineState> p = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"rd"] error:&e];
    const NSUInteger bytes = 4ull << 30;
    id<MTLBuffer> a = [d newBufferWithLength:bytes options:MTLResourceStorageModePrivate];
    id<MTLBuffer> o = [d newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q = [d newCommandQueue];
    uint32_t n = (uint32_t)(bytes / 16);
    for (int rep = 0; rep < 6; rep++) {
      id<MTLCommandBuffer> cb = [q commandBuffer];
      id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
      [enc setComputePipelineState:p]; [enc setBuffer:a offset:0 atIndex:0];
      [enc setBuffer:o offset:0 atIndex:1]; [enc setBytes:&n length:4 atIndex:2];
      [enc dispatchThreadgroups:MTLSizeMake(4096,1,1) threadsPerThreadgroup:MTLSizeMake(1024,1,1)];
      [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
      double s = cb.GPUEndTime - cb.GPUStartTime;
      printf("read %.1f GiB in %.2f ms: %.0f GB/s\n", bytes/1073741824.0, s*1e3, bytes/s/1e9);
    }
  }
  return 0;
}
