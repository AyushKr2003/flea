"""Publish a same-path PNG and hold its test transport until the pending capture."""
import os
from pathlib import Path
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

folder = Path(sys.argv[1])
assert folder.is_absolute() and (folder / '.flea-test-sandbox').is_file()
folder = folder.resolve(strict=True)
target = folder / 'reload.png'
blue = folder / 'reload-blue.png'
assert target.is_file() and not target.is_symlink()
assert blue.is_file() and not blue.is_symlink()
data = blue.read_bytes()
os.replace(blue, target)

class Picture(BaseHTTPRequestHandler):
    def do_GET(self):
        print('reader', flush=True)
        assert sys.stdin.readline() == 'publish\n'
        self.send_response(200)
        self.send_header('Content-Type', 'image/png')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *args):
        pass

with HTTPServer(('127.0.0.1', 0), Picture) as server:
    print('armed ' + str(server.server_address[1]), flush=True)
    server.handle_request()
