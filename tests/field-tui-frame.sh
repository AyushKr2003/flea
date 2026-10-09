#!/bin/bash
# Gates tools/flea-field-bench's TUI first frame: the poll finds the live bench terminal's socket and stamps the first poll that shows any text.
set -u
cd "$(dirname "$0")/.." || exit 1
bench="$PWD/tools/flea-field-bench"

bad=0
check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL $label"; echo "  expected: $expected"; echo "  actual:   $actual"; bad=1
  else
    echo "ok   $label"
  fi
}

# The scratch root is a mktemp -d of its own, and its one delete is checked absolute and two deep before the trap exists.
scratch=$(mktemp -d) || exit 1
case $scratch in
  /*/*) ;;
  *) echo "FAIL: mktemp -d gave '$scratch', which is not an absolute path two components deep"; exit 1 ;;
esac
started=()
trap 'kill -9 "${started[@]}" 2>/dev/null; rm -rf "$scratch"' EXIT

block=$(sed -n '/^# tui frame begin$/,/^# tui frame end$/p' "$bench")
[ -n "$block" ] || { echo "FAIL: no tui frame block in $bench"; exit 1; }
eval "$(sed -n '/^now_ms() {$/,/^}$/p' "$bench")"
eval "$block"

# A stand-in for the bench terminal: a live process named as TUI_TERM, its socket, and a dead pid's socket left behind.
TUI_TERM=sleep
TUI_CONF=$scratch/conf
mkdir -p "$TUI_CONF/kitty"
printf 'allow_remote_control yes\nlisten_on unix:%s\n' "$scratch/sock" > "$TUI_CONF/kitty/kitty.conf"
TUI_SOCKET=$scratch/sock
sleep 300 &
live=$!; started+=("$live")
mksock() { python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"; }
mksock "$TUI_SOCKET-1"
mksock "$TUI_SOCKET-$live"
# The stub kitten answers blank screens until its third call, then a listing row, and logs where it was sent.
mkdir "$scratch/bin"
cat > "$scratch/bin/kitten" <<'EOF'
#!/bin/bash
n=$(( $(cat "$STUB_DIR/calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$STUB_DIR/calls"
echo "$3" >> "$STUB_DIR/to"
if [ "$n" -ge "${STUB_TEXT_AT:-3}" ]; then printf '\n  file-00001.txt\n'; else printf '\n   \n\n'; fi
EOF
chmod +x "$scratch/bin/kitten"
export STUB_DIR=$scratch PATH="$scratch/bin:$PATH"

now_ms; t0=$NOW_MS
tui_first_frame "$t0" $(( t0 + 5000 )); rc=$?
check "the first poll with text ends the wait" "0 3" "$rc $(cat "$scratch/calls")"
check "the frame is stamped from the launch clock" yes "$([ "$FIRST_FRAME_MS" -ge 0 ] && [ "$FIRST_FRAME_MS" -lt 5000 ] && echo yes || echo no)"
check "every poll went to the live terminal's socket, never the dead pid's" "unix:$TUI_SOCKET-$live" "$(sort -u "$scratch/to")"

# A terminal whose child never draws: the wait ends at the deadline with no frame.
printf '0\n' > "$scratch/calls"
now_ms; t0=$NOW_MS
STUB_TEXT_AT=1000000 tui_first_frame "$t0" $(( t0 + 300 )); rc=$?
check "a screen that stays blank gives no frame by the deadline" "1 -1" "$rc $FIRST_FRAME_MS"

# No live terminal at all: no socket is taken and no poll is sent.
kill "$live"; wait "$live" 2>/dev/null
: > "$scratch/to"
now_ms; t0=$NOW_MS
tui_first_frame "$t0" $(( t0 + 200 )); rc=$?
check "with no live terminal nothing is polled" "1 0" "$rc $(grep -c . "$scratch/to")"

# A kitty.conf with no socket: nothing to poll, so the wait ends at once.
mv "$TUI_CONF/kitty/kitty.conf" "$TUI_CONF/kitty/kitty.conf.keep"
printf 'allow_remote_control yes\n' > "$TUI_CONF/kitty/kitty.conf"
: > "$scratch/to"
now_ms; t0=$NOW_MS
tui_first_frame "$t0" $(( t0 + 5000 )); rc=$?
now_ms
check "a kitty.conf with no listen_on gives no frame at once" "1 -1 0 yes" "$rc $FIRST_FRAME_MS $(grep -c . "$scratch/to") $([ $(( NOW_MS - t0 )) -lt 1000 ] && echo yes || echo no)"
mv "$TUI_CONF/kitty/kitty.conf.keep" "$TUI_CONF/kitty/kitty.conf"

# The wiring: the poll starts with the clock, the map clamps a frame drawn before it, and the row and header carry the column.
run_one=$(sed -n '/^run_one() {$/,/^}$/p' "$bench")
check "the poll starts before the map wait" yes "$(printf '%s\n' "$run_one" | awk '/tui_first_frame "\$t0"/ { p = NR } /wait_for_window "\$class"/ { w = NR } END { print (p && w && p < w) ? "yes" : "no" }')"
check "a frame before the map is stamped at the map" 1 "$(printf '%s\n' "$run_one" | grep -c '\[ "\$mapped" -gt "\$first_frame" \] && first_frame=\$mapped')"
check "kitten is paged in before the clock" yes "$(printf '%s\n' "$run_one" | awk '/kitten --version/ { k = NR } /now_ms; t0=\$NOW_MS/ { c = NR } END { print (k && c && k < c) ? "yes" : "no" }')"
check "the header ends with first_frame_ms" 1 "$(grep -c '^echo "id,run,.*,rerun,first_frame_ms" >> "\$OUT"$' "$bench")"
check "the row ends with the first frame" 1 "$(grep -c '"\$WG_CLEAN" "\$RERUN_N" "\$first_frame"$' "$bench")"
check "the socket path comes from the kitty.conf kitty loads" 1 "$(printf '%s\n' "$block" | grep -c "^  base=\$(sed -n 's/^listen_on unix://p' \"\$TUI_CONF/kitty/kitty.conf\")$")"

[ "$bad" = 0 ] && echo "field-tui-frame: all passed" || echo "field-tui-frame: failures above"
exit "$bad"
