#include <stdint.h>
typedef int64_t i64;
void nh_put_int(i64); void nh_put_bool(i64); void nh_put_int_opt(i64, i64); void nh_put_text_opt(const char *, i64); void nh_write_byte(i64);
void nh_err_int(i64); void nh_err_bool_opt(i64, i64); i64 nh_read_byte(void); void nh_exit(i64); void nh_sleep(i64); i64 nh_div(i64, i64);
int main(void) {
    nh_put_int(-12); nh_write_byte(' '); nh_put_bool(1); nh_write_byte(' '); nh_put_bool(0); nh_write_byte(' ');
    nh_put_int_opt(5, 1); nh_write_byte(' '); nh_put_int_opt(5, 0); nh_write_byte('\n');
    nh_err_int(7); nh_err_bool_opt(0, 0); nh_err_bool_opt(1, 1);
    i64 c, n = 0; while ((c = nh_read_byte()) >= 0) { nh_write_byte(c >= 'a' && c <= 'z' ? c - 32 : c); n++; }
    nh_write_byte('\n'); nh_put_int(n); nh_write_byte('\n');
    nh_sleep(50);
    nh_div(1, 0);
    nh_exit(0);
}
