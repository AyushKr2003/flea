#!/bin/bash
# Gates tools/flea-field-bench's launch order and its CSV column: each kind's rows rotate a place a run and
# reverse every other full cycle, so every pair leads equally often over 2N runs, and launch_pos is the last column.
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

block=$(sed -n '/^# launch order begin$/,/^# launch order end$/p' "$bench")
[ -n "$block" ] || { echo "FAIL: no launch order block in $bench"; exit 1; }
# The block reads ENTRANTS and nothing else, so each case sets the list it needs.
eval "$block"

check "a rotation starts at place (run - 1) mod N" "b c a" "$(launch_rotation 2 a b c | paste -sd' ')"
check "the third run starts at the third place" "c a b" "$(launch_rotation 3 a b c | paste -sd' ')"
check "the fourth run reverses the first full cycle" "c b a" "$(launch_rotation 4 a b c | paste -sd' ')"
check "a kind with no entrant prints nothing" "" "$(launch_rotation 5)"

# Over 2N runs each entrant leads exactly twice, and each ordered pair leads exactly N times.
balance_case() {
  local n=$1 r i j k lead_ok=yes pair_ok=yes
  local -a ids=() order=()
  local -A first=() before=() pos=()
  for (( i = 0; i < n; i++ )); do ids+=("g$i"); done
  for (( r = 1; r <= 2 * n; r++ )); do
    mapfile -t order < <(launch_rotation "$r" "${ids[@]}")
    first[${order[0]}]=$(( ${first[${order[0]}]:-0} + 1 ))
    for (( k = 0; k < n; k++ )); do pos[${order[$k]}]=$k; done
    for (( i = 0; i < n; i++ )); do
      for (( j = 0; j < n; j++ )); do
        [ "$i" -eq "$j" ] && continue
        [ "${pos[g$i]}" -lt "${pos[g$j]}" ] && before[$i,$j]=$(( ${before[$i,$j]:-0} + 1 ))
      done
    done
  done
  for (( i = 0; i < n; i++ )); do
    [ "${first[g$i]:-0}" -eq 2 ] || lead_ok=no
    for (( j = 0; j < n; j++ )); do
      [ "$i" -eq "$j" ] && continue
      [ "${before[$i,$j]:-0}" -eq "$n" ] || pair_ok=no
    done
  done
  printf 'lead=%s pair=%s' "$lead_ok" "$pair_ok"
}
check "two entrants: each leads twice, each pair leads both ways twice over four runs" "lead=yes pair=yes" "$(balance_case 2)"
check "eight entrants: each leads twice, each pair leads both ways eight times over sixteen runs" "lead=yes pair=yes" "$(balance_case 8)"

# The kinds rotate on their own: gui places run 1 to 3, tui places run 1 to 3, and every row is listed once.
ENTRANTS=(
  "flea|gui|x|sh" "flea-anchor|gui|x|sh" "nautilus|gui|x|sh"
  "flea-tui|tui|x|sh" "yazi|tui|x|sh" "mc|tui|x|sh"
)
# The run order reads the bench's ONLY split, so each case sets ONLY and re-splits before ordering.
only_split=$(grep -E '^(set -f|ONLY_IDS=|set \+f)' "$bench")
only_has_src=$(grep '^only_has() {' "$bench")
with_only() { ONLY="$1"; eval "$only_split"; eval "$only_has_src"; }
with_only ""
run2=$(run_order 2 | while read -r i place; do printf '%s@%s ' "${ENTRANTS[$i]%%|*}" "$place"; done)
check "run 2 places each kind from 1 and lists every row" "flea-anchor@1 nautilus@2 flea@3 yazi@1 mc@2 flea-tui@3 " "$run2"
check "run order lists every ENTRANTS row once" 6 "$(run_order 1 | wc -l)"
# ONLY runs the real filter: excluded rows take no place and the kept rows are placed from 1.
with_only "nautilus yazi"
only_run2=$(run_order 2 | while read -r i place; do printf '%s@%s ' "${ENTRANTS[$i]%%|*}" "$place"; done)
check "ONLY keeps only the named rows, placed from 1 among the entrants that launch" "nautilus@1 yazi@1 " "$only_run2"
with_only ""
# Ghost's comm names no program, so it is retained for SKIP without taking a launch place.
ENTRANTS+=("ghost|gui|x|definitely-not-a-command")
ghost_run1=$(run_order 1 | while read -r i place; do printf '%s@%s ' "${ENTRANTS[$i]%%|*}" "$place"; done)
check "an absent entrant takes no place" "flea@1 flea-anchor@2 nautilus@3 ghost@- flea-tui@1 yazi@2 mc@3 " "$ghost_run1"

# The real entrant loop must name each missing row exactly once per run, including a missing Strata binary.
scratch=$(mktemp -d /tmp/flea-launch-order.XXXXXX) || exit 1
: > "$scratch/.flea-test-sandbox"
trap 'case $scratch in /tmp/?*) [ -f "$scratch/.flea-test-sandbox" ] && rm -rf -- "$scratch" ;; esac' EXIT
run_text=$(sed -n '/^# entrant runs begin$/,/^# entrant runs end$/p' "$bench")
[ -n "$run_text" ] || { echo "FAIL: no entrant run block in $bench"; exit 1; }
STRATA_BIN="$scratch/absent-strata"
ENTRANTS=("ghost|gui|x|definitely-not-a-command" "strata|gui|x|strata" "present|gui|x|sh" "ghost-tui|tui|x|definitely-not-a-command")
run_guarded() { printf '%s@%s\n' "$1" "$LAUNCH_POS"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
RUNS=3
eval "$run_text" > "$scratch/launched" 2> "$scratch/skips"
check "a missing GUI command prints one SKIP per run" 3 "$(grep -cxF 'SKIP: ghost is not installed' "$scratch/skips")"
check "a missing TUI command prints one SKIP per run" 3 "$(grep -cxF 'SKIP: ghost-tui is not installed' "$scratch/skips")"
check "a missing Strata binary prints one SKIP per run" 3 "$(grep -cxF "SKIP: strata is not built at $STRATA_BIN" "$scratch/skips")"
check "the three absent rows print exactly nine SKIPs" 9 "$(wc -l < "$scratch/skips")"
check "missing rows never launch or consume a place" 'present@1 present@1 present@1' "$(paste -sd' ' "$scratch/launched")"
with_only present
eval "$run_text" > "$scratch/launched-only" 2> "$scratch/skips-only"
check "ONLY excludes absent entrants without naming or launching them" 0 "$(wc -l < "$scratch/skips-only")"
check "ONLY still launches the selected entrant in each run" 3 "$(grep -cx 'present@1' "$scratch/launched-only")"
with_only ""

# The CSV: the header ends with launch_pos, and the row format writes one value per header column.
header=$(grep -m1 '^echo "id,run,' "$bench" | sed 's/^echo "//; s/" >> .*//')
check "the header ends with first_rows_ms,launch_pos" "first_rows_ms,launch_pos" "$(printf '%s' "$header" | rev | cut -d, -f1-2 | rev)"
cols=$(printf '%s\n' "$header" | tr ',' '\n' | grep -c .)
fmt=$(sed -n "s/^  printf '\([^']*\)' \"\\\$id\".*/\1/p" "$bench" | head -1)
fmt_cols=$(printf '%s' "$fmt" | grep -o '%s' | grep -c .)
check "the row format writes one field per header column" "$cols" "$fmt_cols"
check "the row format passes launch_pos as its last value" 1 "$(grep -cF '"$first_rows" "$LAUNCH_POS"' "$bench")"
check "each run reads launch_pos from the run order" 1 "$(grep -cF 'read -r i LAUNCH_POS <<< "$line"' "$bench")"

# Printed for the report: the place each entrant holds, two and eight entrants over five and ten runs.
show() {
  local n=$1 runs=$2 r i
  local -a ids=()
  for (( i = 0; i < n; i++ )); do ids+=("e$i"); done
  for (( r = 1; r <= runs; r++ )); do
    printf '  run %2d:' "$r"
    launch_rotation "$r" "${ids[@]}" | while read -r id; do printf ' %s' "$id"; done
    printf '\n'
  done
}
ENTRANTS=()
echo "order example, 2 entrants, 5 runs:"; show 2 5
echo "order example, 2 entrants, 10 runs:"; show 2 10
echo "order example, 8 entrants, 5 runs:"; show 8 5
echo "order example, 8 entrants, 10 runs:"; show 8 10

[ "$bad" = 0 ] && echo "field-launch-order: all passed" || echo "field-launch-order: failures above"
exit "$bad"
