// net_test.c — a TCP server on 127.0.0.1: accept, read a request, answer; a client that leaves
// before the answer must not end the server (no SIGPIPE); and nh_json_end
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/wait.h>
#include <time.h>
#include <signal.h>
typedef int64_t i64;
i64 *nh_alloc(i64); i64 nh_net_listen(i64, i64); i64 nh_net_accept(i64); char *nh_fd_read(i64, i64);
i64 nh_fd_send(i64, const char *); void nh_fd_close(i64); i64 nh_json_end(const char *, i64); i64 nh_net_connect(i64, i64);
static int fails;
static char *T(const char *c) { i64 n = (i64)strlen(c); i64 *a = nh_alloc((n + 8) >> 3); a[-1] = n; memcpy(a, c, (size_t)n); return (char *)a; }
static void yes(const char *what, int ok) { printf("%s  %s\n", ok ? "ok  " : "FAIL", what); fails += !ok; }
static int client(int port, const char *req, char *answer, int cap, int leave) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = {0}; a.sin_len = sizeof a; a.sin_family = AF_INET; a.sin_port = htons(port); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0) return -1;
    write(fd, req, strlen(req));
    if (leave) { close(fd); return 0; }
    int n = 0, k;
    while ((k = (int)read(fd, answer + n, cap - 1 - n)) > 0) n += k;
    answer[n] = 0; close(fd); return n;
}
int main(void) {
    i64 s = nh_net_listen(8799, 0);
    yes("listen on 127.0.0.1:8799", s >= 0);
    yes("a second listen on the same port is -errno", nh_net_listen(8799, 0) < 0);
    if (fork() == 0) {                               // the clients
        char ans[1 << 20];
        usleep(50000);
        int n = client(8799, "GET /health HTTP/1.1\r\n\r\n", ans, sizeof ans, 0);
        _exit(n > 0 && strstr(ans, "\"ok\": true") ? 10 : 11);
    }
    i64 c = nh_net_accept(s);
    char *req = nh_fd_read(c, 0);
    yes("the request arrives", strncmp(req, "GET /health", 11) == 0);
    yes("the answer is sent", nh_fd_send(c, T("HTTP/1.1 200 OK\r\nContent-Length: 12\r\n\r\n{\"ok\": true}")) == 0);
    nh_fd_close(c);
    int st; wait(&st);
    yes("the client got it", WIFEXITED(st) && WEXITSTATUS(st) == 10);
    if (fork() == 0) { usleep(50000); char x[8]; client(8799, "GET / HTTP/1.1\r\n\r\n", x, 8, 1); _exit(0); }
    c = nh_net_accept(s);
    nh_fd_read(c, 0);
    usleep(100000);                                  // the client is gone
    char big[300000]; memset(big, 'x', sizeof big - 1); big[sizeof big - 1] = 0;
    i64 r1 = nh_fd_send(c, T(big)), r2 = nh_fd_send(c, T(big));
    yes("sending to a client that left gives -errno, and the server lives on", r1 < 0 || r2 < 0);
    nh_fd_close(c); wait(&st);
    // a connection that sends nothing: the read gives up (15 s) and the next client is served
    if (fork() == 0) { int fd = socket(AF_INET, SOCK_STREAM, 0); struct sockaddr_in a = {0}; a.sin_len = sizeof a; a.sin_family = AF_INET;
        a.sin_port = htons(8799); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK); connect(fd, (struct sockaddr *)&a, sizeof a); sleep(30); _exit(0); }
    c = nh_net_accept(s);
    time_t t0 = time(0);
    char *nothing = nh_fd_read(c, 0);
    time_t waited = time(0) - t0;
    yes("a silent connection: the read gives up after about 15 s with nothing", ((i64 *)nothing)[-1] == 0 && waited >= 14 && waited <= 17);
    nh_fd_close(c);
    nh_fd_close(s);
    // the client side: connect to a listening socket of this process, then to a closed port
    i64 srv = nh_net_listen(8798, 0);
    i64 cl = nh_net_connect(0x7F000001, 8798);
    i64 acc = nh_net_accept(srv);
    nh_fd_send(cl, T("ping"));
    yes("connect to 127.0.0.1:8798 and send: the server reads it", cl >= 0 && strcmp(nh_fd_read(acc, 0), "ping") == 0);
    nh_fd_close(cl); nh_fd_close(acc); nh_fd_close(srv);
    yes("connect to a closed port gives -errno", nh_net_connect(0x7F000001, 8797) < 0);
    const char *cases[][2] = {{"  \"a\\\"b\" , 1", "8"}, {"{\"x\": [1, {\"y\": \"}\"}], \"z\": 2} tail", "30"}, {"123,4", "3"},
                              {"true}", "4"}, {"[1, [2, 3]]", "11"}, {"\"open", "-1"}, {"[1, 2", "-1"}, {"   ", "-1"}, {",", "-1"}};
    for (int k = 0; k < 9; k++) {
        i64 got = nh_json_end(T(cases[k][0]), 0), want = atoll(cases[k][1]);
        char what[80]; snprintf(what, sizeof what, "json_end(%s) = %lld", cases[k][0], (long long)got);
        yes(what, got == want);
    }
    printf("\n%s\n", fails ? "SOME FAILED" : "all passed");
    return fails != 0;
}
