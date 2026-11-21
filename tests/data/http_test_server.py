# http_test_server.py PORTFILE — the other side for tests/stage1/http_client.nihil: an HTTP server
# on 127.0.0.1 (any free port, written to PORTFILE) with answers of every kind the client must read
import http.server, socketserver, sys, os

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args): pass
    def answer(self, code, body, kind="text/plain", extra=()):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(b)))
        for k, v in extra: self.send_header(k, v)
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        if self.path == "/hello":
            self.answer(200, "hello from the client test", extra=[("X-Test", "yes")])
        elif self.path in ("/chunked", "/big"):
            parts = ["one ", "two ", "three"] if self.path == "/chunked" else ["x" * 1000] * 200
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            for p in parts: self.wfile.write(b"%x\r\n%s\r\n" % (len(p), p.encode()))
            self.wfile.write(b"0\r\n\r\n")
        elif self.path == "/stream":
            import time
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Connection", "close")
            self.end_headers()
            for i in (1, 2, 3):
                self.wfile.write(b"line %d\n" % i)
                self.wfile.flush()
                time.sleep(0.2)
            self.close_connection = True
        else:
            self.answer(404, "nothing here")
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode()
        self.answer(200, "POST %s: %s (%s)" % (self.path, body, self.headers.get("Content-Type")))

server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
tmp = sys.argv[1] + ".tmp"
open(tmp, "w").write(str(server.server_address[1]))
os.replace(tmp, sys.argv[1])
server.serve_forever()
