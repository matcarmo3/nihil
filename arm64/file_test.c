// file_test.c — files: atomic replace, append, positional write and read, truncate, size and
// stamp, a missing file (optional and fatal), and reading a pipe with no size
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/wait.h>
typedef int64_t i64;
i64 *nh_alloc(i64); char *nh_read_file(const char *); char *nh_read_file_opt(const char *);
void nh_write_file(const char *, const char *); void nh_append_file(const char *, const char *);
void nh_write_at(const char *, const char *, i64); void nh_truncate(const char *, i64);
char *nh_read_at(const char *, i64, i64); i64 nh_last_size(void); i64 nh_last_stamp(void);
static int fails;
static char *T(const char *c) { i64 n = (i64)strlen(c); i64 *a = nh_alloc((n + 8) >> 3); a[-1] = n; memcpy(a, c, (size_t)n); return (char *)a; }
static void same(const char *what, const char *t, const char *want) {
    int ok = t && ((i64 *)t)[-1] == (i64)strlen(want) && memcmp(t, want, strlen(want)) == 0;
    printf("%s  %s → \"%.*s\"\n", ok ? "ok  " : "FAIL", what, t ? (int)((i64 *)t)[-1] : 0, t ? t : ""); fails += !ok;
}
static void yes(const char *what, int ok) { printf("%s  %s\n", ok ? "ok  " : "FAIL", what); fails += !ok; }
int main(void) {
    char *p = T("/tmp/nh_file_test.dat");
    nh_write_file(p, T("abcdefgh\n"));
    same("@>> then @", nh_read_file(p), "abcdefgh\n");
    yes("no temporary file left", access("/tmp/nh_file_test.dat.nihil-tmp", F_OK) != 0);
    nh_append_file(p, T("12345678\n"));
    same("@+>> appends", nh_read_file(p), "abcdefgh\n12345678\n");
    nh_write_at(p, T("XY"), 2);
    same("write at 2", nh_read_file(p), "abXYefgh\n12345678\n");
    i64 s1 = 0;
    same("read 4 at 9", nh_read_at(p, 9, 4), "1234"); s1 = nh_last_stamp();
    yes("size 18", nh_last_size() == 18);
    same("read past the end", nh_read_at(p, 50, 4), "");
    same("read the tail (fewer than asked)", nh_read_at(p, 15, 10), "78\n");
    usleep(20000);
    nh_write_at(p, T("Z"), 0);
    nh_read_at(p, 0, 1);
    yes("the stamp changes when the file is written", nh_last_stamp() != s1);
    nh_truncate(p, 9);
    same("truncate to 9", nh_read_file(p), "ZbXYefgh\n");
    yes("@? of a missing file is _", nh_read_file_opt(T("/tmp/nh_no_such_file")) == 0);
    yes("read_at of a missing file: 0, size -1", nh_read_at(T("/tmp/nh_no_such_file"), 0, 1) == 0 && nh_last_size() == -1);
    // a pipe: no size, read to the end (200 KB, more than one buffer)
    int fds[2]; pipe(fds);
    if (fork() == 0) { close(fds[0]); char b[1000]; memset(b, 'q', 1000); for (int i = 0; i < 200; i++) write(fds[1], b, 1000); _exit(0); }
    close(fds[1]);
    char dev[32]; snprintf(dev, sizeof dev, "/dev/fd/%d", fds[0]);
    char *all = nh_read_file(T(dev));
    yes("@ of a pipe reads all 200,000 bytes", ((i64 *)all)[-1] == 200000 && all[199999] == 'q' && all[200000] == 0);
    wait(0);
    // a fatal read in a child: the message and exit code 2
    if (fork() == 0) { nh_read_file(T("/tmp/nh_no_such_file")); _exit(0); }
    int st; wait(&st);
    yes("@ of a missing file ends with code 2", WIFEXITED(st) && WEXITSTATUS(st) == 2);
    if (fork() == 0) { nh_write_file(T("/nonexistent_dir/x"), T("a")); _exit(0); }
    wait(&st);
    yes("@>> into a missing folder ends with code 2", WIFEXITED(st) && WEXITSTATUS(st) == 2);
    // a zero byte in a path: refused, not cut at the zero
    char *nul = T("/tmp/nh_file_test.dat"); i64 *z = nh_alloc(4); ((i64 *)z)[-1] = 25; memcpy(z, "/tmp/nh_file_test.dat\0abc", 25);
    yes("@? of a path with a zero byte is _ (it would open /tmp/nh_file_test.dat)", nh_read_file_opt((char *)z) == 0 && nh_read_file(nul) != 0);
    yes("read_at of a path with a zero byte: 0", nh_read_at((char *)z, 0, 1) == 0);
    if (fork() == 0) { nh_write_file((char *)z, T("x")); _exit(0); }
    wait(&st);
    yes("@>> to a path with a zero byte ends with code 2 and writes nothing", WIFEXITED(st) && WEXITSTATUS(st) == 2 && ((i64 *)nh_read_file(nul))[-1] == 9);
    unlink("/tmp/nh_file_test.dat");
    printf("\n%s\n", fails ? "SOME FAILED" : "all passed");
    return fails != 0;
}
