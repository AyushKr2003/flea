#!/usr/bin/env bash
# CSV and TSV as a table in the preview column and in Quick Look over the real backend: the header, the numbers, the frozen widths across a 49,999-row scroll, the quoted newline, the binary, large and empty frames. Offscreen, in the flea-ci image.
set -uo pipefail
. "$(dirname "$0")/../tools/flea-sandbox-guard"
. "$(dirname "$0")/qslog-gate.sh"
cd "$(dirname "$0")/.." || exit 1
for tool in qs dbus-run-session; do
    command -v "$tool" >/dev/null || { printf 'FAIL csv-preview: %s is required; this suite runs in the flea-ci image\n' "$tool"; exit 1; }
done
bin=${FLEA_BIN:-$PWD/target/debug/flea}
[ -x "$bin" ] || { printf 'FAIL csv-preview: build the backend first: %s\n' "$bin"; exit 1; }
sandbox_root_ok
test_root=$(mktemp -d "$SANDBOX_ROOT/flea-csv-preview.XXXXXXXX") || exit 1
: > "$test_root/$SANDBOX_MARKER"
sandbox_make "$test_root"
cleanup() { sandbox_remove "$test_root"; }
trap cleanup EXIT
mkdir -p "$test_root"/{config,fixture,home,state/flea,cache,runtime} || exit 1
chmod 700 "$test_root/runtime" || exit 1
ln -s "$(readlink -m ui/boot/Commons)" "$test_root/config/Commons" || exit 1
ln -s "$(readlink -m ui/boot/Ui)" "$test_root/config/Ui" || exit 1
cp -a ui "$test_root/config/flea" || exit 1
cp tests/csv-preview.qml "$test_root/config/shell.qml" || exit 1
printf '{}\n' > "$test_root/state/flea/ui.json"

# bench.csv is the board's 24-row table; long.csv has a long first cell; big.csv has 49,999 rows with long names at rows 60 to 64.
fixture="$test_root/fixture"
awk 'BEGIN { print "fixture,files,folders,depth"; split("photos music code mixed nested flat", names); split("3 4 9 6 12 1", depths); split("1k 10k 100k 1m", suffixes); for (g = 1; g <= 6; g++) { files = 1000; for (s = 1; s <= 4; s++) { printf "%s-%s,%d,%d,%d\n", names[g], suffixes[s], files, files / 50, depths[g]; files *= 10 } } }' > "$fixture/bench.csv"
awk 'BEGIN { print "name,size,kind,modified"; for (i = 1; i <= 24; i++) { n = (i == 1) ? "a-first-name-long-enough-to-stretch-the-first-column-well-past-its-header-and-keep-going-on-and-on" : sprintf("file-%02d.txt", i); printf "%s,%d,%s,2026-09-%02d\n", n, i * 1234 % 99991, (i % 3 ? "text" : "image"), i } }' > "$fixture/long.csv"
awk 'BEGIN { for (c = 1; c <= 12; c++) printf "%sc%02d", (c > 1 ? "," : ""), c; print ""; for (r = 1; r <= 3; r++) { for (c = 1; c <= 12; c++) printf "%svalue-%d-%02d-xxxxxx", (c > 1 ? "," : ""), r, c; print "" } }' > "$fixture/wide.csv"
awk 'BEGIN { print "id,name,size"; for (i = 1; i <= 49999; i++) { n = (i >= 60 && i <= 64) ? sprintf("%0120d", i) : sprintf("f%05d", i); printf "%d,%s,%d\n", i, n, i * 7 } }' > "$fixture/big.csv"
[ "$(stat -c %s "$fixture/big.csv")" -le 1048576 ] || { printf 'FAIL csv-preview: big.csv must stay under 1 MiB\n'; exit 1; }
printf 'id,note\n1,"two\nlines",3\n2,plain\n' > "$fixture/quoted.csv"
printf 'a\tb\tc\n1\tx,y\t3\n4\t5\t6\n' > "$fixture/fixture.tsv"
printf 'a,b\0c\n1,2\n' > "$fixture/nul.csv"
yes 'a,b,c' | head -c 1048577 > "$fixture/over.csv"
: > "$fixture/empty.csv"
printf 'plain text\n' > "$fixture/plain.txt"

failures=0
log="$test_root/csv-preview.log"
( env -u DISPLAY -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
    HOME="$test_root/home" XDG_STATE_HOME="$test_root/state" XDG_CACHE_HOME="$test_root/cache" \
    XDG_RUNTIME_DIR="$test_root/runtime" FLEA_BIN="$bin" FLEA_REDUCED_MOTION=1 \
    CSVPREV_DIR="$fixture" \
    QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=generic QT_QUICK_BACKEND=software QT_FORCE_STDERR_LOGGING=1 \
    dbus-run-session -- bash -c 'timeout 240 qs -p "$1" > "$2" 2>&1' _ "$test_root/config" "$log" 2> "$test_root/bus.log" ) 2>/dev/null
status=$?
[ -z "${FLEA_CI_SUITE_LOGS:-}" ] || cp "$log" "$FLEA_CI_SUITE_LOGS/csv-preview.log" 2>/dev/null
grep -a 'CSVPREV \(PASS\|FAIL\|DONE\)' "$log" | sed 's/^/csv-preview: /'
loops=$(grep -ac 'Binding loop detected' "$log")
if [ "$loops" -ne 0 ]; then
    printf 'FAIL csv-preview: %s binding loop(s)\n' "$loops"
    failures=$((failures + 1))
fi
qslog_crash "csv-preview" "$log" || failures=$((failures + 1))
if [ "$status" -ne 0 ] || [ "$(grep -ac 'CSVPREV DONE' "$log")" -ne 1 ] || grep -aqE 'CSVPREV FAIL|TypeError|ReferenceError|Unable to assign|Cannot assign' "$log"; then
    printf 'FAIL csv-preview: the run did not hold (qs exit %s)\n' "$status"
    grep -aE 'TypeError|ReferenceError|Unable to assign|Cannot assign' "$log" | head -5
    failures=$((failures + 1))
fi
printf 'csv-preview: %s failed\n' "$failures"
[ "$failures" -eq 0 ]
