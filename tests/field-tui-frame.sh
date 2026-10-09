#!/bin/bash
# Gates tools/flea-field-bench's TUI first rows: the poll stamps the first time kitty's dump of the child's output names a fixture entry.
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
writer=""
trap '[ -n "$writer" ] && kill "$writer" 2>/dev/null; rm -rf "$scratch"' EXIT

block=$(sed -n '/^# tui frame begin$/,/^# tui frame end$/p' "$bench")
[ -n "$block" ] || { echo "FAIL: no tui frame block in $bench"; exit 1; }
eval "$(sed -n '/^now_ms() {$/,/^}$/p' "$bench")"
eval "$block"
TUI_DUMP=$scratch/kitty.dump
TUI_NAMES=$scratch/fixture-names
printf '%s\n' some_file_name_000001.txt some_file_name_000002.txt > "$TUI_NAMES"

# A terminal setup and a chrome frame first, then the listing: only the listing's arrival may stamp the rows.
: > "$TUI_DUMP"
{ sleep 0.2; printf '\033[?1049h\033[1;1H Flea  /fixture\033[0m' >> "$TUI_DUMP"
  sleep 0.3; printf '\033[3;1H\033[38;2;1;2;3msome_file_name_000001.txt\033[0m' >> "$TUI_DUMP"; } &
writer=$!
now_ms; t0=$NOW_MS
tui_first_rows "$t0" $(( t0 + 3000 )); rc=$?
wait "$writer"; writer=""
check "the listing's arrival stamps the rows" 0 "$rc"
check "chrome before the listing does not count" yes "$([ "$FIRST_ROWS_MS" -ge 450 ] && [ "$FIRST_ROWS_MS" -lt 1500 ] && echo yes || echo no)"

# A screen that never lists: no rows by the deadline.
printf '\033[?1049h Flea  loading' > "$TUI_DUMP"
now_ms; t0=$NOW_MS
tui_first_rows "$t0" $(( t0 + 300 )); rc=$?
check "output that names no entry gives no rows by the deadline" "1 -1" "$rc $FIRST_ROWS_MS"

# The wiring: the poll starts with the clock, a run never sees the last run's dump, every TUI kitty writes one, and the map clamps.
run_one=$(sed -n '/^run_one() {$/,/^}$/p' "$bench")
poll_line=$(printf '%s\n' "$run_one" | grep -n 'tui_first_rows "\$t0"' | cut -d: -f1)
map_line=$(printf '%s\n' "$run_one" | grep -n 'wait_for_window "\$class"' | cut -d: -f1)
check "the poll starts before the map wait" yes "$([ -n "$poll_line" ] && [ -n "$map_line" ] && [ "$poll_line" -lt "$map_line" ] && echo yes || echo no)"
dump_line=$(printf '%s\n' "$run_one" | grep -n '\[ "\$kind" = tui \] && : > "\$TUI_DUMP"' | cut -d: -f1)
clock_line=$(printf '%s\n' "$run_one" | grep -n 'now_ms; t0=\$NOW_MS' | cut -d: -f1)
check "each TUI run empties the dump before the clock" yes "$([ -n "$dump_line" ] && [ -n "$clock_line" ] && [ "$dump_line" -lt "$clock_line" ] && echo yes || echo no)"
tui_lines=$(grep -c '^  "[a-z-]*|tui|' "$bench")
check "every TUI entrant's kitty writes the dump" "$tui_lines" "$(grep '^  "[a-z-]*|tui|' "$bench" | grep -c -- '--class \$TUI_CLASS --dump-bytes \$TUI_DUMP ')"
check "a window that never mapped shows no rows, and rows before the map are stamped at it" 1 "$(printf '%s\n' "$run_one" | grep -c 'if \[ "\$mapped" -lt 0 \]; then first_rows=-1; elif \[ "\$first_rows" -ge 0 \] && \[ "\$mapped" -gt "\$first_rows" \]; then first_rows=\$mapped; fi')"
check "a window that mapped but listed nothing says so on stderr" 1 "$(printf '%s\n' "$run_one" | grep -c '\[ "\$first_rows" -lt 0 \] && \[ "\$mapped" -ge 0 \] && echo .*no fixture entry name reached kitty.s output.* >&2')"
check "a TUI run refuses a dump on disk" 1 "$(printf '%s\n' "$run_one" | grep -c '\[ "\$kind" = tui \] && \[ "\$TUI_CONF_FS" != tmpfs \] && fail ')"
check "the header ends with first_rows_ms" 1 "$(grep -c '^echo "id,run,.*,rerun,first_rows_ms" >> "\$OUT"$' "$bench")"
check "the row ends with the first rows" 1 "$(grep -c '"\$WG_CLEAN" "\$RERUN_N" "\$first_rows"$' "$bench")"

[ "$bad" = 0 ] && echo "field-tui-frame: all passed" || echo "field-tui-frame: failures above"
exit "$bad"
