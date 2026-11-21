// bench_rec.c — reading a table natively: 2 million lines like the monthly sales
// (INT(20) INT(3) INT(16) INT(6) FLOAT(14) FLOAT(20) = 79 bytes + "\n"), checked and parsed
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
typedef int64_t i64;
i64 *nh_alloc(i64); i64 nh_rec_parse(const char *, i64, const i64 *); i64 nh_lines(const char *, i64);
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
int main(void) {
    const i64 rows = 2000000, w = 79;
    i64 bytes = rows * (w + 1);
    char *text = (char *)nh_alloc((bytes + 8) >> 3); ((i64 *)text)[-1] = bytes;
    char line[96];
    for (i64 i = 0; i < rows; i++) {
        snprintf(line, sizeof line, "%20lld%3lld%16lld%6lld%14.1f%20.2f\n", (long long)(i * 7), (long long)(i % 50), (long long)(1000000 + i % 90000),
                 (long long)(202201 + i % 48), (double)(i % 997) + 0.5, (double)(i % 100003) * 3.17);
        memcpy(text + i * (w + 1), line, (size_t)(w + 1));
    }
    i64 schema[13] = {6, 1, 20, 1, 3, 1, 16, 1, 6, 4, 14, 4, 20};
    double t0 = now();
    i64 n = nh_lines(text, w);
    i64 *table = nh_alloc(n);
    double sum = 0;
    for (i64 i = 0; i < n; i++) {
        i64 r = nh_rec_parse(text, i * (w + 1), schema);
        if (r < 0) { printf("fallback at %lld\n", (long long)i); return 1; }
        table[i] = r;
        double x; memcpy(&x, &((i64 *)r)[5], 8); sum += x;
    }
    double dt = now() - t0;
    printf("%lld records, %.0f MB in %.3f s: %.0f MB/s, %.1f M records/s (sum %.2f)\n", (long long)n, bytes / 1e6, dt, bytes / 1e6 / dt, n / dt / 1e6, sum);
    return 0;
}
