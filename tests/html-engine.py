"""Drive the page request through the real backend and inspect the PNG pixels."""
import json
import pathlib
import os
import shutil
import select
import subprocess
import sys
import time
from collections import Counter
from http.server import BaseHTTPRequestHandler, HTTPServer
import threading
import urllib.request

binary, root = sys.argv[1], pathlib.Path(sys.argv[2])
process = subprocess.Popen([binary, '--backend'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
failures = []

class Listener(BaseHTTPRequestHandler):
    requests = 0
    def do_GET(self):
        Listener.requests += 1
        data = (root / 'remote.png').read_bytes()
        self.send_response(200)
        self.send_header('Content-Type', 'image/png')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *args):
        pass

listener = HTTPServer(('127.0.0.1', 18879), Listener)
threading.Thread(target=listener.serve_forever, daemon=True).start()

def check(name, got, want=True):
    good = got == want
    print(('PASS' if good else 'FAIL') + ' html-engine: ' + name, flush=True)
    if not good:
        failures.append((name, got, want))

def ask(token, width, path=None):
    payload = {'c': 'html', 'slot': 'test', 'token': token, 'path': str(path or root / 'fixture/index.html'), 'width': width}
    process.stdin.write(json.dumps(payload) + '\n')
    process.stdin.flush()
    end = time.monotonic() + 25
    while time.monotonic() < end:
        if not select.select([process.stdout], [], [], 1)[0]:
            continue
        line = process.stdout.readline()
        if not line:
            break
        reply = json.loads(line)
        if reply.get('t') == 'error':
            return reply
        if reply.get('t') == 'html' and reply.get('token') == token:
            return reply
    return {'state': 'timeout'}

try:
    control = urllib.request.urlopen('http://127.0.0.1:18879/remote.png', timeout=2).read()
    check('remote marker listener is reachable outside the jail', control.startswith(b'\x89PNG\r\n\x1a\n'))
    control_requests = Listener.requests
    previous = None
    for token, width in [(1, 984), (2, 300), (3, 984)]:
        reply = ask(token, width)
        check('page rendered at %d pixels' % width, reply.get('state'), 'ready')
        if reply.get('state') != 'ready':
            print('FAIL html-engine: reply ' + json.dumps(reply), flush=True)
            break
        check('whole-file count is 61', reply.get('total'), 61)
        if token != 3:
            check('script marker never set', reply.get('title'), 'Static HTML')
        image = pathlib.Path(reply['file'])
        evidence = os.environ.get('FLEA_CI_SUITE_LOGS')
        if evidence:
            shutil.copyfile(image, pathlib.Path(evidence) / ('html-engine-%d.png' % width))
        dimensions = subprocess.check_output(['magick', 'identify', '-format', '%w %h', str(image)], text=True).split()
        check('PNG width matches request', int(dimensions[0]), width)
        check('PNG contains the tall page', 1800 <= int(dimensions[1]) <= 8000)
        pixels = subprocess.check_output(['magick', str(image), '-alpha', 'off', '-depth', '8', 'rgb:-'])
        colors = Counter(zip(pixels[::3], pixels[1::3], pixels[2::3]))
        check('sibling image loaded with all 1024 pixels', colors[(0x12, 0xab, 0x34)] >= 1024)
        check('outside file and symlink not loaded', colors[(0x34, 0x12, 0xab)], 0)
        check('remote/script image color absent', colors[(0xab, 0x12, 0x34)], 0)
        if token == 1:
            previous = (str(image), image.stat().st_mtime_ns)
        if token == 3:
            check('revisit reused PNG without rewriting it', (str(image), image.stat().st_mtime_ns), previous)
    failed = ask(4, 300, root / 'fixture/missing.html')
    check('unreadable page answers failed', failed.get('state'), 'failed')
    check('preview never connects to the reachable remote marker', Listener.requests, control_requests)
finally:
    listener.shutdown()
    listener.server_close()
    process.stdin.close()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
if failures:
    for failure in failures:
        print('FAIL detail: %r' % (failure,), flush=True)
    sys.exit(1)
