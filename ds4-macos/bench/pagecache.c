/* How much of a file the page cache holds, and dropping it.
 *
 *   pagecache <file> [drop]
 *
 * Maps the file shared and read-only, counts its resident pages with mincore,
 * and with "drop" invalidates them (msync MS_INVALIDATE, then MADV_FREE) and
 * counts again. Prints "resident X GiB of Y GiB" before and, with drop, after,
 * so a run can start from a recorded file-cache state. */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static double resident_gib(const char *map, size_t len, size_t page) {
    const size_t chunk = (size_t)1 << 30;
    unsigned long long pages = 0;
    char *vec = malloc(chunk / page + 1);
    if (!vec) return -1;
    for (size_t off = 0; off < len; off += chunk) {
        const size_t n = len - off < chunk ? len - off : chunk;
        if (mincore((void *)(map + off), n, vec) != 0) { free(vec); return -1; }
        for (size_t i = 0; i < (n + page - 1) / page; i++) pages += (vec[i] & MINCORE_INCORE) != 0;
    }
    free(vec);
    return (double)pages * page / (1024.0 * 1024.0 * 1024.0);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s file [drop]\n", argv[0]); return 2; }
    const int fd = open(argv[1], O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0) { perror(argv[1]); return 2; }
    const size_t len = (size_t)st.st_size, page = (size_t)getpagesize();
    char *map = mmap(NULL, len, PROT_READ, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) { perror("mmap"); return 2; }
    const double gib = (double)len / (1024.0 * 1024.0 * 1024.0);
    printf("resident %.2f GiB of %.2f GiB\n", resident_gib(map, len, page), gib);
    if (argc > 2 && strcmp(argv[2], "drop") == 0) {
        if (msync(map, len, MS_INVALIDATE) != 0) perror("msync");
        (void)madvise(map, len, MADV_FREE);
        printf("after drop: resident %.2f GiB of %.2f GiB\n", resident_gib(map, len, page), gib);
    }
    munmap(map, len);
    close(fd);
    return 0;
}
