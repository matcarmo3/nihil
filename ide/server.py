#!/usr/bin/env python3
"""Nihil IDE — a small web IDE for the Nihil language (standard library only).

    python3 ide/server.py [--port 8730] [--host 0.0.0.0]

Open http://<host>:8730 in a browser. The server saves files, compiles them
with nihilc1 and runs the programs, streaming their output to the page.
WARNING: it runs whatever code it is given. Keep it on a trusted network.
"""
import argparse, json, os, queue, re, struct, subprocess, tempfile, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))     # the Nihil repository
STATIC = os.path.join(ROOT, 'ide', 'static')
EDITABLE = ['ide/workspace', 'examples']                                 # folders shown and saved
READABLE = EDITABLE + ['tests', 'src1']                                  # also readable (error links)
ERROR_RE = re.compile(r'^nihilc: (.+?):(\d+):(\d+): (.*)$')
MAX_RUN_SECONDS = 600

runs = {}               # id → {'proc', 'frames': Queue}
runs_lock = threading.Lock()


def resolve(rel, allowed):
    """Path inside the repository, restricted to the allowed folders, or None."""
    path = os.path.realpath(os.path.join(ROOT, rel))
    for folder in allowed:
        base = os.path.realpath(os.path.join(ROOT, folder))
        if path == base or path.startswith(base + os.sep):
            return path
    return None


def list_files():
    out = []
    for folder in EDITABLE:
        base = os.path.join(ROOT, folder)
        for dirpath, _, names in os.walk(base):
            for n in sorted(names):
                if n.endswith('.nihil'):
                    out.append(os.path.relpath(os.path.join(dirpath, n), ROOT))
    return sorted(out)


def compile_file(rel, optimize):
    """Compiles rel (relative to ROOT) → (binary path or None, errors, stderr, ms)."""
    fd, binary = tempfile.mkstemp(prefix='nihil-ide-')
    os.close(fd)
    env = dict(os.environ)
    if not optimize:
        env['NIHIL_O0'] = '1'
    t0 = time.time()
    p = subprocess.run([os.path.join(ROOT, 'nihilc1.sh'), rel, binary], cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=60)
    ms = int((time.time() - t0) * 1000)
    errors = []
    for line in p.stderr.splitlines():
        m = ERROR_RE.match(line)
        if m:
            errors.append({'file': m.group(1), 'line': int(m.group(2)), 'col': int(m.group(3)), 'message': m.group(4)})
        elif line.strip():
            errors.append({'file': rel, 'line': 0, 'col': 0, 'message': line.replace('nihilc: ', '', 1)})
    if p.returncode != 0:
        os.unlink(binary)
        return None, errors, p.stderr, ms
    return binary, errors, p.stderr, ms


def pump(stream, kind, frames, t0):
    """Copies a process pipe into the frame queue: 1 = stdout, 2 = stderr.
    Each piece carries the time it was written (ms since the start), so the page
    can replay output at the program's own pace whatever the network does."""
    while True:
        data = os.read(stream.fileno(), 65536)
        if not data:
            break
        frames.put((kind, data, int((time.monotonic() - t0) * 1000)))


def start_run(binary):
    proc = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            cwd=ROOT, bufsize=0)
    frames = queue.Queue()
    t0 = time.monotonic()
    readers = [threading.Thread(target=pump, args=(proc.stdout, 1, frames, t0), daemon=True),
               threading.Thread(target=pump, args=(proc.stderr, 2, frames, t0), daemon=True)]
    for r in readers:
        r.start()

    def wait():
        try:
            code = proc.wait(timeout=MAX_RUN_SECONDS)
        except subprocess.TimeoutExpired:
            proc.kill()
            code = proc.wait()
        for r in readers:
            r.join()
        frames.put((3, str(code).encode(), int((time.monotonic() - t0) * 1000)))
        try:
            os.unlink(binary)
        except OSError:
            pass
    threading.Thread(target=wait, daemon=True).start()
    run_id = uuid.uuid4().hex
    with runs_lock:
        runs[run_id] = {'proc': proc, 'frames': frames}
    return run_id


class Handler(BaseHTTPRequestHandler):
    server_version = 'NihilIDE/1.0'

    def log_message(self, fmt, *args):
        pass

    def send_json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body_json(self):
        n = int(self.headers.get('Content-Length') or 0)
        return json.loads(self.rfile.read(n) or b'{}')

    def do_GET(self):
        url = urlparse(self.path)
        q = parse_qs(url.query)
        if url.path in ('/', '/index.html'):
            return self.send_static('index.html')
        if url.path.startswith('/static/'):
            return self.send_static(url.path[len('/static/'):])
        if url.path == '/api/files':
            return self.send_json({'files': list_files()})
        if url.path == '/api/file':
            path = resolve(q.get('path', [''])[0], READABLE)
            if not path or not os.path.isfile(path):
                return self.send_json({'error': 'file not found'}, 404)
            with open(path, encoding='utf-8', errors='replace') as f:
                return self.send_json({'path': q['path'][0], 'content': f.read(),
                                       'editable': resolve(q['path'][0], EDITABLE) is not None})
        if url.path == '/api/stream':
            return self.stream(q.get('id', [''])[0])
        self.send_json({'error': 'not found'}, 404)

    def send_static(self, name):
        path = os.path.realpath(os.path.join(STATIC, name))
        if not path.startswith(os.path.realpath(STATIC)) or not os.path.isfile(path):
            return self.send_json({'error': 'not found'}, 404)
        kind = {'.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png'}.get(os.path.splitext(path)[1], 'application/octet-stream')
        with open(path, 'rb') as f:
            body = f.read()
        self.send_response(200)
        self.send_header('Content-Type', kind if kind.startswith('image/') else kind + '; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        self.wfile.write(body)

    def stream(self, run_id):
        """Binary frames: 1 byte kind (1 stdout, 2 stderr, 3 exit code), 4 bytes length,
        4 bytes time (ms since the program started), then the data."""
        with runs_lock:
            run = runs.get(run_id)
        if not run:
            return self.send_json({'error': 'no such run'}, 404)
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('X-Accel-Buffering', 'no')
        self.end_headers()
        try:
            while True:
                kind, data, ms = run['frames'].get()
                batch = [(kind, data, ms)]
                while kind != 3:                    # join what is already waiting
                    try:
                        kind, data, ms = run['frames'].get_nowait()
                        batch.append((kind, data, ms))
                    except queue.Empty:
                        break
                self.wfile.write(b''.join(struct.pack('>BII', k, len(d), t) + d for k, d, t in batch))
                self.wfile.flush()
                if batch[-1][0] == 3:
                    break
        except (BrokenPipeError, ConnectionResetError):
            run['proc'].kill()                      # the page went away: stop the program
        finally:
            with runs_lock:
                runs.pop(run_id, None)

    def do_POST(self):
        url = urlparse(self.path)
        data = self.body_json()
        if url.path == '/api/file':
            path = resolve(data.get('path', ''), EDITABLE)
            if not path or not path.endswith('.nihil'):
                return self.send_json({'error': 'files can only be saved as .nihil inside ' + ' or '.join(EDITABLE)}, 400)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'w', encoding='utf-8') as f:
                f.write(data.get('content', ''))
            return self.send_json({'ok': True, 'path': os.path.relpath(path, ROOT)})
        if url.path in ('/api/run', '/api/asm'):
            rel = data.get('path', '')
            if not resolve(rel, READABLE):
                return self.send_json({'error': 'cannot compile ' + rel}, 400)
            binary, errors, stderr, ms = compile_file(rel, data.get('optimize', True))
            if not binary:
                return self.send_json({'ok': False, 'errors': errors, 'compile_ms': ms})
            size = os.path.getsize(binary)
            if url.path == '/api/asm':
                p = subprocess.run(['objdump', '-D', '-b', 'binary', '-mi386:x86-64', '-M', 'intel',
                                    '--adjust-vma=0x400000', '--start-address=0x4000b0', binary],
                                   capture_output=True, text=True, env=dict(os.environ, LC_ALL='C'))
                os.unlink(binary)
                lines = [l for l in p.stdout.splitlines() if re.match(r'\s+[0-9a-f]+:', l)]
                return self.send_json({'ok': True, 'asm': '\n'.join(lines), 'size': size, 'compile_ms': ms})
            return self.send_json({'ok': True, 'errors': errors, 'compile_ms': ms, 'size': size, 'run': start_run(binary)})
        if url.path == '/api/stdin':
            with runs_lock:
                run = runs.get(data.get('id', ''))
            if not run:
                return self.send_json({'error': 'no such run'}, 404)
            try:
                if data.get('data'):
                    run['proc'].stdin.write(data['data'].encode())
                    run['proc'].stdin.flush()
                if data.get('eof'):
                    run['proc'].stdin.close()
            except (BrokenPipeError, ValueError):
                pass
            return self.send_json({'ok': True})
        if url.path == '/api/stop':
            with runs_lock:
                run = runs.get(data.get('id', ''))
            if run:
                run['proc'].kill()
            return self.send_json({'ok': True})
        self.send_json({'error': 'not found'}, 404)


def main():
    ap = argparse.ArgumentParser(description='Nihil IDE')
    ap.add_argument('--host', default='0.0.0.0')
    ap.add_argument('--port', type=int, default=8730)
    a = ap.parse_args()
    if not os.path.exists(os.path.join(ROOT, 'build', 'nihilc1')):
        print('build/nihilc1 not found: run "make" in', ROOT)
    os.makedirs(os.path.join(ROOT, 'ide', 'workspace'), exist_ok=True)
    print(f'Nihil IDE on http://{a.host}:{a.port}  (repository: {ROOT})')
    ThreadingHTTPServer((a.host, a.port), Handler).serve_forever()


if __name__ == '__main__':
    main()
