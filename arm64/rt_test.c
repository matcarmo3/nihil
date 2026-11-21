// rt_test.c — the texts, arrays, arithmetic and output of the runtime, against what the x86
// runtime gives (SPEC): each line printed is compared with the expected one.
#include <stdio.h>
#include <string.h>
#include <stdint.h>
typedef int64_t i64;
i64 *nh_alloc(i64); char *nh_concat(const char *, const char *); char *nh_int_text(i64); char *nh_text(const i64 *);
char *nh_sub(const char *, i64, i64); i64 nh_put(char *, i64, const char *); i64 nh_lines(const char *, i64);
i64 nh_text_equal(const char *, const char *); i64 *nh_array_concat(const i64 *, const i64 *); i64 nh_div(i64, i64); i64 nh_mod(i64, i64);
static int fails;
static char *T(const char *c) {                      // a Nihil text from a C one
    i64 n = (i64)strlen(c); i64 *a = nh_alloc((n + 8) >> 3); a[-1] = n; memcpy(a, c, (size_t)n); return (char *)a;
}
static void same(const char *what, const char *t, const char *want) {
    i64 n = ((i64 *)t)[-1];
    int ok = n == (i64)strlen(want) && memcmp(t, want, (size_t)n) == 0 && t[n] == 0;
    printf("%s  %s → \"%.*s\"\n", ok ? "ok  " : "FAIL", what, (int)n, t); fails += !ok;
}
static void eq(const char *what, i64 got, i64 want) { int ok = got == want; printf("%s  %s = %lld\n", ok ? "ok  " : "FAIL", what, (long long)got); fails += !ok; }
int main(void) {
    same("\"ab\" + \"cde\"", nh_concat(T("ab"), T("cde")), "abcde");
    same("\"\" + \"\"", nh_concat(T(""), T("")), "");
    same("$0", nh_int_text(0), "0");
    same("$-42", nh_int_text(-42), "-42");
    same("$MIN", nh_int_text(INT64_MIN), "-9223372036854775808");
    same("$MAX", nh_int_text(INT64_MAX), "9223372036854775807");
    i64 *bytes = nh_alloc(3); bytes[0] = 'N'; bytes[1] = 'i'; bytes[2] = 0xC3;
    same("$[78, 105, 195]", nh_text(bytes), "Ni\xC3");
    same("\"planograma\".slice(2, 6)", nh_sub(T("planograma"), 2, 6), "anog");
    same("slice(5, 3) (empty)", nh_sub(T("planograma"), 5, 3), "");
    char *r = (char *)nh_alloc(2); ((i64 *)r)[-1] = 6;
    eq("put \"abc\" at 0", nh_put(r, 0, T("abc")), 3);
    eq("put \"def\" at 3", nh_put(r, 3, T("def")), 6);
    same("the text built", r, "abcdef");
    eq("lines(\"ab\\ncd\\nef\", 2)", nh_lines(T("ab\ncd\nef"), 2), 3);
    eq("lines(\"ab\\ncd\\n\", 2)", nh_lines(T("ab\ncd\n"), 2), 2);
    eq("lines(\"ab\\ncde\\n\", 2) (one is not 2 wide)", nh_lines(T("ab\ncde\n"), 2), -1);
    eq("lines(\"\", 2)", nh_lines(T(""), 2), 0);
    eq("\"abc\" == \"abc\"", nh_text_equal(T("abc"), T("abc")), 1);
    eq("\"abc\" == \"abd\"", nh_text_equal(T("abc"), T("abd")), 0);
    eq("\"abc\" == \"ab\"", nh_text_equal(T("abc"), T("ab")), 0);
    i64 *x = nh_alloc(2), *y = nh_alloc(3); x[0] = 1; x[1] = 2; y[0] = 3; y[1] = 4; y[2] = 5;
    i64 *z = nh_array_concat(x, y);
    eq("#([1, 2] + [3, 4, 5])", z[-1], 5);
    eq("([1, 2] + [3, 4, 5])[4]", z[4], 5);
    eq("-7 / 2", nh_div(-7, 2), -3);
    eq("-7 % 2", nh_mod(-7, 2), -1);
    eq("MIN / -1", nh_div(INT64_MIN, -1), INT64_MIN);
    eq("MIN % -1", nh_mod(INT64_MIN, -1), 0);
    printf("\n%s\n", fails ? "SOME FAILED" : "all passed");
    return fails != 0;
}
