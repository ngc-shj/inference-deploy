/* Does one big no-copy window over the model wire all of itself on first use?
 *
 * If it does not, a layer's 384 experts - which are contiguous in the file -
 * can live behind a single buffer, every one of them addressable, and a miss
 * stops existing. No miss means no repair, and no repair means no stall, which
 * is the 20% the resident path currently gives back.
 *
 * The notes say a large window is an eager load. That was measured before a
 * residency set was known to work here, so it is worth asking again, and asking
 * of both: useResource on the dispatch, and membership of a residency set.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <fcntl.h>
#include <mach/mach.h>
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

/* Resident pages of this process, which is what "wired the whole window" would
 * show up as. */
static uint64_t footprint_bytes(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
        return 0;
    return info.phys_footprint;
}

int main(int argc, char **argv) {
@autoreleasepool {
    const char *path = argc > 1 ? argv[1] : NULL;
    const double win_gib = argc > 2 ? atof(argv[2]) : 3.56;   /* a layer's experts */
    const uint32_t touch = argc > 3 ? (uint32_t)atoi(argv[3]) : 6;
    const int use_set = argc > 4 ? atoi(argv[4]) : 1;
    if (!path) { fprintf(stderr, "usage: window <gguf> [window GiB] [regions] [1=set,0=useResource]\n"); return 1; }

    int fd = open(path, O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st)) { perror("open"); return 1; }
    const size_t fsz = (size_t)st.st_size;
    void *map = mmap(NULL, fsz, PROT_READ, MAP_PRIVATE, fd, 0);
    if (map == MAP_FAILED) { perror("mmap"); return 1; }
    size_t win = (size_t)(win_gib * 1073741824.0);
    win = (win / PAGE) * PAGE;
    if (win > fsz / 2) win = (fsz / 2 / PAGE) * PAGE;

    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    NSError *e = nil;
    NSString *src = [NSString stringWithContentsOfFile:@"residency.metal"
                                              encoding:NSUTF8StringEncoding error:&e];
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&e];
    if (!lib) { fprintf(stderr, "compile: %s\n", e.localizedDescription.UTF8String); return 1; }
    id<MTLComputePipelineState> pso =
        [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"deref_sum"] error:&e];
    if (!pso) { fprintf(stderr, "pso: %s\n", e.localizedDescription.UTF8String); return 1; }
    id<MTLCommandQueue> q = [d newCommandQueue];

    const uint64_t foot0 = footprint_bytes();
    const double t0 = now_ms();
    uint8_t *base = (uint8_t *)map + PAGE;
    id<MTLBuffer> window = [d newBufferWithBytesNoCopy:base length:win
                                               options:MTLResourceStorageModeShared
                                           deallocator:nil];
    if (!window) { fprintf(stderr, "no-copy window of %.2f GiB failed\n", win / 1073741824.0); return 1; }
    const double t_create = now_ms() - t0;
    const uint64_t foot1 = footprint_bytes();

    id<MTLResidencySet> rset = nil;
    double t_resident = 0;
    if (use_set) {
        if (@available(macOS 15.0, *)) {
            MTLResidencySetDescriptor *rd = [MTLResidencySetDescriptor new];
            rd.initialCapacity = 4;
            rset = [d newResidencySetWithDescriptor:rd error:&e];
            if (!rset) { fprintf(stderr, "residency set: %s\n", e.localizedDescription.UTF8String); return 1; }
            const double t1 = now_ms();
            [rset addAllocation:window];
            [rset commit];
            [rset requestResidency];
            [q addResidencySet:rset];
            t_resident = now_ms() - t1;
        }
    }
    const uint64_t foot2 = footprint_bytes();

    id<MTLBuffer> table = [d newBufferWithLength:64 * sizeof(uint64_t) options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [d newBufferWithLength:64 * sizeof(uint64_t) options:MTLResourceStorageModeShared];
    uint64_t *tab = table.contents;
    const size_t region = 3u << 20;
    const uint32_t words = (uint32_t)(region / sizeof(uint32_t));
    const size_t stride = ((win - region) / (touch + 1) / PAGE) * PAGE;
    for (uint32_t i = 0; i < touch && i < 64; i++)
        tab[i] = window.gpuAddress + (uint64_t)(i + 1) * stride;

    const double t2 = now_ms();
    id<MTLCommandBuffer> cb = [q commandBuffer];
    for (uint32_t i = 0; i < touch && i < 64; i++) {
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pso];
        [enc setBuffer:table offset:0 atIndex:0];
        [enc setBuffer:out offset:0 atIndex:1];
        [enc setBytes:&words length:4 atIndex:2];
        [enc setBytes:&i length:4 atIndex:3];
        if (!use_set) [enc useResource:window usage:MTLResourceUsageRead];
        [enc dispatchThreads:MTLSizeMake(256,1,1) threadsPerThreadgroup:MTLSizeMake(256,1,1)];
        [enc endEncoding];
    }
    [cb commit];
    [cb waitUntilCompleted];
    const double t_first = now_ms() - t2;
    const uint64_t foot3 = footprint_bytes();
    if (cb.status == MTLCommandBufferStatusError)
        fprintf(stderr, "dispatch error: %s\n", cb.error.localizedDescription.UTF8String);

    printf("window %.2f GiB, %u regions of %.1f MiB touched, reachability by %s\n",
           win / 1073741824.0, touch, region / 1048576.0,
           use_set ? "residency set" : "useResource");
    printf("  creating the window        : %7.2f ms\n", t_create);
    if (use_set) printf("  adding it to the set      : %7.2f ms\n", t_resident);
    printf("  first dispatch that reads  : %7.2f ms\n", t_first);
    printf("  footprint after create     : %+8.1f MiB\n", (double)(foot1 - foot0) / 1048576.0);
    printf("  footprint after residency  : %+8.1f MiB\n", (double)(foot2 - foot1) / 1048576.0);
    printf("  footprint after the reads  : %+8.1f MiB\n", (double)(foot3 - foot2) / 1048576.0);
    printf("  touched bytes were         : %8.1f MiB\n", touch * region / 1048576.0);
    return 0;
}
}
