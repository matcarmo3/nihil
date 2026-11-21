// sys_test.c — the prelude's kernel calls through the translation, used as the prelude uses
// them (Linux numbers and layouts), and nh_rec_parse
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
typedef int64_t i64;
i64 *nh_alloc(i64); i64 nh_syscall(const i64 *); i64 nh_rec_parse(const char *, i64, const i64 *);
static int fails;
static void yes(const char *what, int ok) { printf("%s  %s\n", ok ? "ok  " : "FAIL", what); fails += !ok; }
// an ARRAY of INT from the values (each converted to 64 bits: a literal 0 passed through "..."
// would arrive as 32 bits with garbage above)
static i64 *A_(const i64 *v, int n) { i64 *a = nh_alloc(n); for (int i = 0; i < n; i++) a[i] = v[i]; return a; }
#define A(n, ...) A_((const i64[]){__VA_ARGS__}, n)
static char *T(const char *c) { i64 n = (i64)strlen(c); i64 *a = nh_alloc((n + 8) >> 3); a[-1] = n; memcpy(a, c, (size_t)n); return (char *)a; }
static uint32_t u32(const unsigned char *b, int i) { return b[i] | b[i + 1] << 8 | b[i + 2] << 16 | (uint32_t)b[i + 3] << 24; }
int main(void) {
    system("rm -rf /tmp/nh_sys && mkdir -p /tmp/nh_sys && touch /tmp/nh_sys/b.txt /tmp/nh_sys/a.txt && printf 12345 > /tmp/nh_sys/c.dat");
    // path.list: openat(O_DIRECTORY | O_CLOEXEC) + getdents64, reading the records as the prelude does
    i64 fd = nh_syscall(A(4, 257, -100, (i64)"/tmp/nh_sys", 0x90000));
    unsigned char buf[32768]; int names = 0, dots = 0;
    for (;;) {
        i64 got = nh_syscall(A(4, 217, fd, (i64)buf, 32768));
        if (got <= 0) break;
        for (i64 o = 0; o < got;) { int len = buf[o + 16] | buf[o + 17] << 8; const char *nm = (const char *)buf + o + 19;
            if (!strcmp(nm, ".") || !strcmp(nm, "..")) dots++; else names++; o += len; }
    }
    nh_syscall(A(2, 3, fd));
    yes("list: 3 names (and . ..) through getdents64 records", names == 3 && dots == 2);
    // a small buffer: entries come over several calls, none lost
    fd = nh_syscall(A(4, 257, -100, (i64)"/tmp/nh_sys", 0x90000)); int total = 0;
    for (;;) { i64 got = nh_syscall(A(4, 217, fd, (i64)buf, 40)); if (got <= 0) break;
        for (i64 o = 0; o < got;) { total++; o += buf[o + 16]; } }
    nh_syscall(A(2, 3, fd));
    yes("list with a 40-byte buffer: the 5 entries over several calls", total == 5);
    unsigned char st[144];
    yes("stat of a directory: mode 0x4000", nh_syscall(A(5, 262, -100, (i64)"/tmp/nh_sys", (i64)st, 0)) == 0 && (u32(st, 24) & 0xF000) == 0x4000);
    yes("stat of a file: mode 0x8000, size 5 at +48", nh_syscall(A(5, 262, -100, (i64)"/tmp/nh_sys/c.dat", (i64)st, 0)) == 0 && (u32(st, 24) & 0xF000) == 0x8000 && u32(st, 48) == 5);
    yes("stat of nothing: -ENOENT", nh_syscall(A(5, 262, -100, (i64)"/tmp/nh_sys/none", (i64)st, 0)) == -2);
    yes("mkdir 0755", nh_syscall(A(3, 83, (i64)"/tmp/nh_sys/d", 493)) == 0);
    yes("unlinkat removes a file", nh_syscall(A(4, 263, -100, (i64)"/tmp/nh_sys/a.txt", 0)) == 0 && access("/tmp/nh_sys/a.txt", F_OK) != 0);
    // O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, then pread through openat(O_RDONLY | O_CLOEXEC)
    fd = nh_syscall(A(5, 257, -100, (i64)"/tmp/nh_sys/w.txt", 0x80241, 420));
    nh_syscall(A(4, 1, fd, (i64)"hello world", 11)); nh_syscall(A(2, 3, fd));
    fd = nh_syscall(A(4, 257, -100, (i64)"/tmp/nh_sys/w.txt", 0x80000));
    char rb[8] = {0};
    yes("lseek(SEEK_END) = 11", nh_syscall(A(4, 8, fd, 0, 2)) == 11);
    yes("pread 5 at 6 = world", nh_syscall(A(5, 17, fd, (i64)rb, 5, 6)) == 5 && !strcmp(rb, "world"));
    nh_syscall(A(2, 3, fd));
    // cmd.start as the prelude does it: pipe2, fork, dup2 in the child, close_range, execve; wait4
    int pb[2];
    nh_syscall(A(3, 293, (i64)pb, 0x80000));
    i64 out = nh_syscall(A(5, 257, -100, (i64)"/tmp/nh_sys/out.txt", 0x80241, 420));
    i64 pid = nh_syscall(A(1, 57));
    if (pid == 0) {
        nh_syscall(A(3, 33, pb[0], 0)); nh_syscall(A(3, 33, out, 1));
        nh_syscall(A(4, 436, 3, 4294967295LL, 0));
        char *argv[] = {"/usr/bin/tr", "a-z", "A-Z", 0}; char *envp[] = {0};
        nh_syscall(A(4, 59, (i64)argv[0], (i64)argv, (i64)envp));
        nh_syscall(A(2, 231, 127));
    }
    nh_syscall(A(2, 3, pb[0])); nh_syscall(A(2, 3, out));
    nh_syscall(A(4, 1, pb[1], (i64)"nihil on the mac\n", 17)); nh_syscall(A(2, 3, pb[1]));
    unsigned char sb[8];
    i64 r = nh_syscall(A(5, 61, pid, (i64)sb, 0, 0));
    FILE *f = fopen("/tmp/nh_sys/out.txt", "r"); char line[64] = {0}; fgets(line, 64, f); fclose(f);
    yes("a child with its input from a pipe and its output to a file: tr gave NIHIL ON THE MAC", r == pid && !strcmp(line, "NIHIL ON THE MAC\n"));
    yes("its exit code 0 (status as on Linux)", ((u32(sb, 0) >> 8) & 255) == 0 && (u32(sb, 0) & 127) == 0);
    pid = nh_syscall(A(1, 57));
    if (pid == 0) { char *argv[] = {"/bin/sleep", "5", 0}; char *envp[] = {0}; nh_syscall(A(4, 59, (i64)argv[0], (i64)argv, (i64)envp)); nh_syscall(A(2, 231, 127)); }
    yes("wait4(WNOHANG) while it runs: 0", nh_syscall(A(5, 61, pid, (i64)sb, 1, 0)) == 0);
    yes("kill 9", nh_syscall(A(3, 62, pid, 9)) == 0);
    yes("then wait4: killed by signal 9", nh_syscall(A(5, 61, pid, (i64)sb, 0, 0)) == pid && (u32(sb, 0) & 127) == 9);
    pid = nh_syscall(A(1, 57));
    if (pid == 0) { char *argv[] = {"/nonexistent", 0}; char *envp[] = {0}; nh_syscall(A(4, 59, (i64)argv[0], (i64)argv, (i64)envp)); nh_syscall(A(2, 231, 127)); }
    nh_syscall(A(5, 61, pid, (i64)sb, 0, 0));
    yes("a program that does not exist: exit 127", ((u32(sb, 0) >> 8) & 255) == 127);
    yes("access(X_OK) of /bin/ls", nh_syscall(A(3, 21, (i64)"/bin/ls", 1)) == 0);
    yes("an unknown call: -ENOSYS", nh_syscall(A(1, 999)) == -78);
    system("rm -rf /tmp/nh_sys");
    // records: INT(5) BOOL STRING(6) FLOAT(10)
    i64 *schema = A(9, 4, 1, 5, 2, 1, 3, 6, 4, 10);
    char *line1 = T("  -42T  ab      123.25");
    i64 *rec = (i64 *)nh_rec_parse(line1, 0, schema);
    double x; memcpy(&x, &rec[3], 8);
    char *s = (char *)rec[2];
    yes("record: -42, true, \"  ab\" (leading spaces kept), 123.25", rec[0] == -42 && rec[1] == 1 && ((i64 *)s)[-1] == 4 && !memcmp(s, "  ab", 4) && x == 123.25);
    memcpy(&x, &((i64 *)nh_rec_parse(T("    0F          -0.000"), 0, schema))[3], 8);
    yes("FLOAT -0.000 keeps its sign", x == 0 && __builtin_signbit(x));
    memcpy(&x, &((i64 *)nh_rec_parse(T("    0F          0.1000"), 0, schema))[3], 8);
    yes("FLOAT 0.1000 is the double nearest 0.1", x == 0.1);
    yes("an exponent goes to the prelude (-1)", nh_rec_parse(T("    0F          1e5   "), 0, schema) == -1);
    yes("16 digits go to the prelude (-1)", nh_rec_parse(T("1234567890.123456"), 0, A(3, 1, 4, 17)) == -1);
    yes("15 digits stay native", nh_rec_parse(T("12345678.9012345"), 0, A(3, 1, 4, 16)) != -1);
    yes("an INT that overflows goes to the prelude", nh_rec_parse(T("99999999999999999999"), 0, A(3, 1, 1, 20)) == -1);
    yes("a BOOL that is not T or F goes to the prelude", nh_rec_parse(T("    0X"), 0, A(5, 2, 1, 5, 2, 1)) == -1);
    printf("\n%s\n", fails ? "SOME FAILED" : "all passed");
    return fails != 0;
}
