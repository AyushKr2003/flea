#!/usr/bin/env python3
"""Prove that the generated fixture reaches the real RAW and Properties paths."""

import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import selectors
import struct
import subprocess
import sys
import time

PHOTO = {
    "make": "Canon", "model": "Canon EOS R6", "lens": "RF35mm F1.8 MACRO IS STM",
    "exp": [1, 250], "fnum": [28, 10], "iso": 400, "focal": [35, 1],
    "taken": "2026:09:12 18:31:00", "w": 6000, "h": 4000,
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def ifd(data, offset):
    count = struct.unpack_from("<H", data, offset)[0]
    entries = {}
    sizes = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 10: 8}
    for index in range(count):
        at = offset + 2 + index * 12
        tag, kind, n = struct.unpack_from("<HHI", data, at)
        length = sizes[kind] * n
        value_at = at + 8 if length <= 4 else struct.unpack_from("<I", data, at + 8)[0]
        entries[tag] = data[value_at:value_at + length]
    return entries


def fixture(path):
    data = path.read_bytes()
    expected = Path(__file__).with_name("SHA256SUMS").read_text().split()[0]
    require(hashlib.sha256(data).hexdigest() == expected, "generated DNG SHA-256 differs")
    root = ifd(data, struct.unpack_from("<I", data, 4)[0])
    sensor_at = struct.unpack("<I", root[0x0111])[0]
    sensor_size = struct.unpack("<I", root[0x0117])[0]
    require(sensor_size == 6000 * 4000 * 2, "the full sensor plane is absent")
    require(len(data[sensor_at:sensor_at + sensor_size]) == sensor_size, "sensor data is truncated")
    require(struct.unpack_from("<4H", data, sensor_at) == (0, 1, 2, 3), "sensor ramp differs")
    preview = ifd(data, struct.unpack("<I", root[0x014A])[0])
    at = struct.unpack("<I", preview[0x0111])[0]
    size = struct.unpack("<I", preview[0x0117])[0]
    seed = base64.b64decode(Path(__file__).with_name("preview.jpg.b64").read_bytes())
    require(data[at:at + size] == seed, "the embedded JPEG differs from the real seed")
    print("raw-fixture: sha256=" + expected + " sensor=6000x4000 preview=1620x1080")


def backend(binary, root, path):
    environment = dict(os.environ, XDG_CACHE_HOME=str(root / "cache"),
                       XDG_STATE_HOME=str(root / "state"), HOME=str(root / "home"),
                       FLEA_UNDO_DIR=str(root / "undo"))
    buffer = bytearray()
    with (root / "backend.log").open("xb") as log:
        process = subprocess.Popen([binary, "--backend"], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=log, env=environment)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)

        def send(request):
            process.stdin.write((json.dumps(request) + "\n").encode())
            process.stdin.flush()

        def receive(predicate):
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if b"\n" in buffer:
                    line, _, rest = buffer.partition(b"\n")
                    buffer[:] = rest
                    reply = json.loads(line)
                    require(reply.get("t") != "error", "backend refused: " + str(reply))
                    if predicate(reply):
                        return reply
                elif selector.select(max(0, deadline - time.monotonic())):
                    chunk = os.read(process.stdout.fileno(), 65536)
                    require(bool(chunk), "backend ended before its reply")
                    buffer.extend(chunk)
            raise ValueError("backend reply timed out")

        try:
            send({"c": "list", "path": str(path.parent), "first": 8})
            listed = receive(lambda r: r.get("t") == "listed")
            require(listed.get("n") == 1, "fixture listing does not contain one RAW")
            send({"c": "meta", "row": 0})
            meta = receive(lambda r: r.get("t") == "meta")
            require(meta.get("photo") == PHOTO, "live meta photo facts differ: " + str(meta))
            raw = meta.get("raw") or {}
            require((raw.get("w"), raw.get("h"), raw.get("orient")) == (1620, 1080, 1),
                    "live RAW extraction did not return the preview dimensions")
            cached = Path(raw["file"]).resolve(strict=True)
            require(cached.is_relative_to(root / "cache"), "extraction escaped the owned cache")
            subprocess.run(["ffmpeg", "-v", "error", "-i", str(cached), "-f", "null", "-"],
                           check=True, timeout=20, stdout=subprocess.DEVNULL)
            send({"c": "menuaction", "op": "snapshot", "id": 41, "rows": [0]})
            snapshot = receive(lambda r: r.get("t") == "menuaction" and r.get("op") == "snapshot")
            require(snapshot.get("ok") is True, "Properties snapshot failed")
            send({"c": "menuaction", "op": "properties", "id": 41})
            props = receive(lambda r: r.get("t") == "menuaction" and r.get("op") == "properties")
            require(props.get("ok") is True and props.get("photo") == PHOTO,
                    "live Properties photo facts differ: " + str(props))
            require(props.get("path") == str(path) and props.get("bytes") == path.stat().st_size,
                    "Properties describes a different file")
            print("raw-fixture: meta and Properties photo=" + json.dumps(PHOTO, separators=(",", ":")))
            print("raw-fixture: extracted JPEG fully decoded")
            process.stdin.close()
            require(process.wait(timeout=10) == 0, "backend shutdown failed")
        finally:
            selector.close()
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)


def main():
    binary, directory = sys.argv[1:]
    root = Path(directory).resolve(strict=True)
    require((root / ".flea-test-sandbox").is_file(), "test root has no marker")
    path = root / "raw" / "L1000921.DNG"
    fixture(path)
    stamp = datetime(2026, 9, 18, 20, 10, tzinfo=timezone.utc).timestamp()
    os.utime(path, (stamp, stamp))
    backend(binary, root, path)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit("FAIL raw-fixture: " + str(error))
