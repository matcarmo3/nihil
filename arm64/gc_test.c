// gc_test.c — the collector under load, natively: short-lived arrays with rolling roots in the
// globals, a linked list reachable only from the stack, large blocks, and a sparse huge block.
#include <stdio.h>
#include <stdint.h>
#include <time.h>
#include <sys/resource.h>
typedef int64_t i64;
i64 *nh_alloc(i64 n); i64 *nh_array_rep(i64 n, i64 v); i64 nh_gc_collections(void); i64 nh_gc_live(void);
extern i64 nh_globals_start[];
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static long rss_mb(void) { struct rusage u; getrusage(RUSAGE_SELF, &u); return u.ru_maxrss >> 20; }
static int fails;
static void check(const char *what, int ok) { printf("%s  %s\n", ok ? "ok  " : "FAIL", what); fails += !ok; }

__attribute__((noinline)) static i64 *make_list(int n) {
    i64 *head = 0;
    for (int i = 0; i < n; i++) { i64 *node = nh_alloc(2); node[0] = (i64)head; node[1] = i; head = node; }
    return head;
}

int main(void) {
    double t0 = now();
    // 1. 3 million small arrays; 1000 kept in the globals, replaced as they go
    for (i64 i = 0; i < 3000000; i++) {
        i64 *a = nh_array_rep(10, i);
        if (i % 1000 == 7) nh_globals_start[(i / 1000) % 1000] = (i64)a;
    }
    int good = 1;
    for (i64 k = 0; k < 1000; k++) {
        i64 *a = (i64 *)nh_globals_start[k];
        i64 want = 2000000 + k * 1000 + 7;             // the last round wrote these
        for (int j = 0; j < 10; j++) good &= a[j] == want;
        good &= a[-1] == 10;
    }
    check("3M short-lived arrays: the 1000 kept in the globals are intact", good);
    printf("      %lld collections, %.2f s, max RSS %ld MB\n", (long long)nh_gc_collections(), now() - t0, rss_mb());

    // 2. a list of 200k nodes, reachable only from this frame, while garbage is made
    double t1 = now();
    i64 *volatile list = make_list(200000);
    for (int i = 0; i < 500000; i++) nh_alloc(20);      // garbage that forces collections
    i64 sum = 0, count = 0;
    for (i64 *n = list; n; n = (i64 *)n[0]) { sum += n[1]; count++; }
    check("a 200k-node list reachable only from the stack survives the collections", count == 200000 && sum == (i64)199999 * 200000 / 2);
    printf("      %.2f s\n", now() - t1);

    // 3. 200 large blocks of 8 MB, only the last two kept: memory stays bounded
    double t2 = now();
    for (int i = 0; i < 200; i++) {
        i64 *big = nh_alloc(1 << 20);
        for (i64 j = 0; j < (1 << 20); j += 512) big[j] = i;   // touch every 4 KiB
        nh_globals_start[1000 + (i & 1)] = (i64)big;
    }
    i64 *b0 = (i64 *)nh_globals_start[1000], *b1 = (i64 *)nh_globals_start[1001];
    check("200 × 8 MB blocks: the last two are intact", b0[0] == 198 && b1[512] == 199 && b0[-1] == (1 << 20));
    printf("      %.2f s, max RSS %ld MB (1.6 GB were allocated)\n", now() - t2, rss_mb());

    // 4. a sparse 800 MB block: a pointer in its last element keeps a small block alive
    double t3 = now();
    i64 *huge = nh_alloc(100000000);
    nh_globals_start[1002] = (i64)huge;
    i64 *small = nh_array_rep(3, 42);
    huge[99999999] = (i64)small;
    small = 0;
    long before = nh_gc_collections();
    for (int i = 0; i < 400000; i++) nh_alloc(50);       // garbage: collections scan the huge block
    i64 *back = (i64 *)huge[99999999];
    check("a sparse 800 MB block is scanned where it has memory, and keeps what it points to", back[0] == 42 && back[2] == 42 && back[-1] == 3);
    printf("      %lld collections over it in %.2f s, max RSS %ld MB\n", (long long)(nh_gc_collections() - before), now() - t3, rss_mb());

    printf("\n%s (%.2f s in all)\n", fails ? "SOME FAILED" : "all passed", now() - t0);
    return fails != 0;
}
