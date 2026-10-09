#!/usr/bin/env bash
# The TUI draws the first listing when the backend answers, not when its input wait runs out: with that wait set to 5 s,
# the rows must still arrive at once.
set -u
cd "$(dirname "$0")/.." || exit 1
bin=${FLEA_BIN:-$PWD/target/debug/flea}
[[ -x "$bin" ]] || { echo 'FAIL tui-wake needs the candidate binary'; exit 1; }

# The scratch root is a mktemp -d of its own, and its one delete is checked absolute and two deep before the trap exists.
scratch=$(mktemp -d) || exit 1
case $scratch in
  /*/*) ;;
  *) echo "FAIL: mktemp -d gave '$scratch', which is not an absolute path two components deep"; exit 1 ;;
esac
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch"/{home,state,config,cache,runtime,fixture} && chmod 700 "$scratch/runtime" || exit 1
for name in wake-alpha.txt wake-beta.txt wake-gamma.txt; do printf 'tui wake fixture\n' > "$scratch/fixture/$name"; done

fail=0
check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL $label"; echo "  expected: $expected"; echo "  actual:   $actual"; fail=1
  else
    echo "ok   $label"
  fi
}

# Sample output: "rows_ms=4.1 exit=0"; rows_ms is -1 when no fixture name reached the screen within 4 s.
result=$(env -i PATH=/usr/bin:/bin HOME="$scratch/home" XDG_STATE_HOME="$scratch/state" XDG_CONFIG_HOME="$scratch/config" \
  XDG_CACHE_HOME="$scratch/cache" XDG_RUNTIME_DIR="$scratch/runtime" TERM=xterm-256color FLEA_TUI_INPUT_TIMEOUT_MS=5000 \
  /usr/bin/python3 - "$bin" "$scratch/fixture" <<'PY'
import os, pty, select, signal, struct, sys, time, fcntl, termios
binary, fixture = sys.argv[1], sys.argv[2]
start = time.monotonic()
pid, fd = pty.fork()
if pid == 0:
    os.execv(binary, [binary, "--tui", fixture])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
seen, rows_ms = b"", -1
while time.monotonic() - start < 4.0 and rows_ms < 0:
    ready, _, _ = select.select([fd], [], [], 0.05)
    if not ready:
        continue
    try:
        seen += os.read(fd, 65536)
    except OSError:
        break
    if b"wake-alpha" in seen:
        rows_ms = (time.monotonic() - start) * 1000
os.kill(pid, signal.SIGTERM)
deadline = time.monotonic() + 3
status = None
while time.monotonic() < deadline:
    done, status = os.waitpid(pid, os.WNOHANG)
    if done:
        break
    try:
        os.read(fd, 65536)
    except OSError:
        pass
    time.sleep(0.02)
else:
    os.kill(pid, signal.SIGKILL)
print("rows_ms=%.1f exit=%s" % (rows_ms, "0" if status is not None and os.WIFEXITED(status) else "killed"))
PY
)
rows_ms=$(printf '%s\n' "$result" | sed -n 's/^rows_ms=\([-0-9.]*\) .*/\1/p')
check "the first listing reached the screen" yes "$(awk -v r="${rows_ms:--1}" 'BEGIN { print (r >= 0) ? "yes" : "no" }')"
# Well under the 5 s wait, so only a wake from the backend explains rows this early; the margin absorbs a loaded box.
check "the rows did not wait for the input timeout" yes "$(awk -v r="${rows_ms:--1}" 'BEGIN { print (r >= 0 && r < 2500) ? "yes" : "no" }')"
check "the TUI left on SIGTERM" "exit=0" "$(printf '%s\n' "$result" | grep -o 'exit=[a-z0-9]*')"

# The wiring the timing rests on: raw mode never blocks a read, and every backend line rings the loop's wake socket.
check "raw mode reads without a timer" 1 "$(grep -c '"raw", "-echo", "min", "0", "time", "0"' src/tui/terminal.rs)"
check "the reader thread rings once per event" 2 "$(grep -c 'let _ = (&ring).write(&\[1\]);' src/tui/wire.rs)"
check "the loop waits on the wake socket" 1 "$(grep -c 'terminal.read(wire.wake_fd(), timeout_ms)' src/tui/mod.rs)"

echo "rows at ${rows_ms:-?} ms with a 5000 ms input wait"
[ "$fail" = 0 ] && echo "tui-wake: all passed" || echo "tui-wake: failures above"
exit "$fail"
