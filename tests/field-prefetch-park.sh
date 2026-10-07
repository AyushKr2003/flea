#!/bin/bash
# Gates tools/flea-field-bench's prefetch park and restore on a scratch HOME: the operator's list leaves for the run and comes back unchanged.
set -u
cd "$(dirname "$0")/.." || exit 1
bench="$PWD/tools/flea-field-bench"

# The fixture root is a mktemp -d of its own, and its one delete is checked absolute and two deep before the trap exists.
scratch=$(mktemp -d) || exit 1
case $scratch in
  /*/*) ;;
  *) echo "FAIL: mktemp -d gave '$scratch', which is not an absolute path two components deep"; exit 1 ;;
esac
trap 'rm -rf "$scratch"' EXIT

fail=0
check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL $label"; echo "  expected: $expected"; echo "  actual:   $actual"; fail=1
  else
    echo "ok   $label"
  fi
}

block=$(sed -n '/^# prefetch park begin$/,/^# prefetch park end$/p' "$bench")
[ -n "$block" ] || { echo "FAIL: no prefetch park block in $bench"; exit 1; }
# The globals the block reads, as the bench names them, evaluated under a HOME of the test's own.
globals=$(grep -E '^(PREFETCH|PREFETCH_PARKED_PREFIX|PREFETCH_PARKED|PREFETCH_PARKED_OK)=' "$bench")
check "the bench names the four prefetch globals" 4 "$(printf '%s\n' "$globals" | grep -c .)"

# One case per subshell, so a fail() inside the block ends that case and not the suite.
run_case() {
  ( HOME="$scratch/home-$1"; mkdir -p "$HOME/.cache/flea"
    fail() { printf 'refused: %s\n' "$*"; exit 3; }
    eval "$globals"; eval "$block"; shift; "$@" )
}

# The operator had a list: parked during the run, the warm launch's list replaces it, and the restore brings back the original bytes.
op_case() {
  printf 'operator list\n/usr/bin/flea 0 4096\n' > "$PREFETCH"
  park_prefetch
  printf 'parked=%s present=%s ' "$(head -1 "$PREFETCH_PARKED")" "$([ -e "$PREFETCH" ] && echo yes || echo no)"
  printf 'arm list\n' > "$PREFETCH"
  restore_prefetch
  printf 'restored=%s leftover=%s' "$(head -1 "$PREFETCH")" "$(ls "$HOME/.cache/flea" | grep -c parked)"
}
check "an operator list is parked, then restored unchanged" "parked=operator list present=no restored=operator list leftover=0" "$(run_case a op_case)"

# The operator had none: the run's list is removed at the end, so no tested Flea's list outlives the run.
none_case() {
  park_prefetch
  printf 'arm list\n' > "$PREFETCH"
  restore_prefetch
  printf 'present=%s' "$([ -e "$PREFETCH" ] && echo yes || echo no)"
}
check "with no operator list the run leaves none behind" "present=no" "$(run_case b none_case)"

# A list parked by a killed run is never parked over.
orphan_case() {
  printf 'older operator list\n' > "${PREFETCH_PARKED_PREFIX}1"
  printf 'newer\n' > "$PREFETCH"
  park_prefetch
  echo "parked anyway"
}
out=$(run_case c orphan_case); rc=$?
check "an orphaned park refuses the run" 3 "$rc"
check "the refusal names the orphan" 1 "$(printf '%s\n' "$out" | grep -c 'prefetch-parked-1 was parked by an invocation that was killed')"
check "the orphan and the live list are untouched" "older operator list|newer" "$(cat "$scratch/home-c/.cache/flea/prefetch-parked-1")|$(cat "$scratch/home-c/.cache/flea/prefetch")"

# A restore with nothing parked, as the EXIT trap runs it after an early failure, touches nothing.
early_case() {
  printf 'operator list\n' > "$PREFETCH"
  restore_prefetch
  printf 'kept=%s' "$(cat "$PREFETCH")"
}
check "a restore before any park keeps the operator's list" "kept=operator list" "$(run_case d early_case)"

# A failed restore is refused once, not again from the EXIT trap; a directory in the list's place fails the mv even for root.
retry_case() {
  printf 'operator list\n' > "$PREFETCH"
  park_prefetch
  mkdir -p "$PREFETCH/in-the-way"
  ( fail() { echo refused; exit 3; }; trap 'restore_prefetch 2>/dev/null' EXIT; restore_prefetch 2>/dev/null )
  printf 'kept=%s\n' "$(cat "$PREFETCH_PARKED")"
}
out=$(run_case e retry_case)
check "a failed restore is refused once" 1 "$(printf '%s\n' "$out" | grep -c '^refused$')"
check "a failed restore leaves the operator's list parked" 1 "$(printf '%s\n' "$out" | grep -c '^kept=operator list$')"

# The cache home guard, as the bench names it: unset or ~/.cache runs, anywhere else refuses before anything is parked.
guard=$(grep -E '^\[ "\$\{XDG_CACHE_HOME:-' "$bench")
check "the bench has one cache home guard" 1 "$(printf '%s\n' "$guard" | grep -c .)"
cache_home() { ( HOME="$scratch/home-f"; fail() { exit 3; }; if [ -n "$1" ]; then XDG_CACHE_HOME="$1"; else unset XDG_CACHE_HOME; fi; eval "$guard" ); echo $?; }
check "an unset cache home runs" 0 "$(cache_home '')"
check "a cache home of ~/.cache runs" 0 "$(cache_home "$scratch/home-f/.cache")"
check "a cache home elsewhere refuses" 3 "$(cache_home "$scratch/elsewhere")"

# The wiring: parked beside the thumbnails and before the warm launch, restored on both exits, and the warm launch must have recorded a list.
park_line=$(grep -n '^park_prefetch$' "$bench" | cut -d: -f1)
warm_line=$(grep -n 'then warm_qml_cache; fi$' "$bench" | cut -d: -f1)
check "park_prefetch runs once at setup" 1 "$(printf '%s\n' "$park_line" | grep -c .)"
check "the warm launch is called once" 1 "$(printf '%s\n' "$warm_line" | grep -c .)"
check "the list is parked before the warm launch records one" yes "$([ "${park_line:-0}" -gt 0 ] && [ "${park_line:-0}" -lt "${warm_line:-0}" ] && echo yes || echo no)"
check "restore_prefetch runs at the end" 1 "$(grep -c '^restore_prefetch$' "$bench")"
check "the EXIT trap restores in a subshell, so a failure there skips no later step" 1 "$(grep -c '^  ( restore_prefetch )$' "$bench")"
check "the warm launch refuses to leave no list" 1 "$(grep -c 'the warm launch recorded no prefetch list' "$bench")"

[ "$fail" = 0 ] && echo "field-prefetch-park: all passed" || echo "field-prefetch-park: failures above"
exit "$fail"
