#!/usr/bin/env bash

# A remote start enumerates the share once: an adopted prefetch costs zero backend gio spawns, a missing or stale one costs exactly one.
set -u
# Hard rule 9's guard, which owns FIXTURE_ROOT and every create and delete below.
. "$(dirname "$0")/../tools/flea-sandbox-guard"

cd "$(dirname "$0")/.." || exit 1

BIN=${BIN:-./target/debug/flea}
# A clean git archive export carries no target/, so without this guard every case reports a missing binary as product failures.
if [ ! -x "$BIN" ]; then
    printf 'remote-start.sh: no binary at %s\n' "$BIN" >&2
    printf 'remote-start.sh: build it (cargo build) or set BIN to one; refusing to report on nothing\n' >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo 'remote-start.sh: python3 is required for the launch-start clock' >&2
    exit 1
fi
if ! command -v timeout >/dev/null 2>&1; then
    echo 'remote-start.sh: timeout is required so a hung adopt fails instead of hanging the suite' >&2
    exit 1
fi
SB="$FIXTURE_ROOT/flea-remote-start-$$"
# The hermetic runtime dir: adopt_in only trusts a dest inside it.
export XDG_RUNTIME_DIR="$SB/runtime"
export XDG_CACHE_HOME="$SB/cache"
# STALE_SECS is 10 in src/gvfsprefetch.rs, so 60 reads as stale on any clock.
STALE_SECS=60
# GIO_TIMEOUT is 15 s in src/backend/gvfslist.rs; the suite must never wait that out.
BACK_TIMEOUT=120
fail=0
passed=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL $label"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    fail=$((fail + 1))
  else
    echo "ok   $label"
    passed=$((passed + 1))
  fi
}

sandbox_make "$SB"
SHARE="$XDG_RUNTIME_DIR/gvfs/smb-share:server=t,share=u/dir"
RUNTIMEDIR="$XDG_RUNTIME_DIR/flea"
mkdir -p "$RUNTIMEDIR"
chmod 700 "$RUNTIMEDIR"

# Sample gio bytes: "smb://h/share/a.txt\t3\t(regular)\ttime::modified=100".
stage_dest() {
  local dest="$1"
  printf 'smb://h/share/a.txt\t3\t(regular)\ttime::modified=100\nsmb://h/share/b.txt\t4\t(regular)\ttime::modified=200\n' > "$dest"
  chmod 600 "$dest"
}

# Sample rows line: {"t":"rows",...,"rows":[{"n":"a.txt",...},{"n":"b.txt",...}]}.
rows_names() {
  grep -o '"n":"[a-z.]*"' | sort | tr '\n' ' '
}

# A fake gio that must never run: any call records itself and refuses, so the rows assertion fails alongside the count.
failing_gio() {
  local fake="$1" calls="$2"
  printf '#!/bin/sh\necho called >> "%s"\nexit 1\n' "$calls" > "$fake"
  chmod +x "$fake"
}

# A fake gio answering two rows: single quotes keep the tabs and newlines for the fake's own printf to interpret.
printing_gio() {
  local fake="$1" calls="$2"
  {
    printf '#!/bin/sh\necho called >> "%s"\n' "$calls"
    printf '%s\n' 'printf "smb://h/share/a.txt\t3\t(regular)\ttime::modified=100\nsmb://h/share/b.txt\t4\t(regular)\ttime::modified=200\n"'
  } > "$fake"
  chmod +x "$fake"
}

gio_calls() {
  local calls="$1"
  if [ -f "$calls" ]; then wc -l < "$calls" | tr -d ' '; else printf '0'; fi
}

now_ms() {
  python3 -c 'import time; print(int(time.time() * 1000))'
}

# Case 1: the stage is stamped a second past the launch because a reader refuses an older dest and a coarse mount clock can report a just-written file as older than the start clock.
START1=$(now_ms)
DEST="$RUNTIMEDIR/gvfs-adopt.list"
stage_dest "$DEST"
touch -d "@$((START1 / 1000 + 1))" "$DEST"
FAKE1="$SB/fake1-gio"
CALLS1="$SB/fake1-calls"
failing_gio "$FAKE1" "$CALLS1"
out1=$(printf '{"c":"list","path":"%s","first":10}\n{"c":"quit"}\n' "$SHARE" | FLEA_GIO_BIN="$FAKE1" FLEA_GVFS_PREFETCH="$DEST" FLEA_GVFS_PATH="$SHARE" FLEA_GVFS_START="$START1" timeout "$BACK_TIMEOUT" "$BIN" --backend 2>/dev/null)
got1="$(printf '%s\n' "$out1" | sed -n 2p | rows_names)"
check "adopted listing answers its rows" '"n":"a.txt" "n":"b.txt" ' "$got1"
if [ "$got1" != '"n":"a.txt" "n":"b.txt" ' ]; then printf '%s\n' "$out1" | head -3 | cut -c1-200; fi
check "adopted listing spawns gio zero times" "0" "$(gio_calls "$CALLS1")"

# Case 2: with no prefetch the backend lists the share itself, the one enumeration the launch costs.
FAKE2="$SB/fake2-gio"
CALLS2="$SB/fake2-calls"
printing_gio "$FAKE2" "$CALLS2"
out2=$(printf '{"c":"list","path":"%s","first":10}\n{"c":"quit"}\n' "$SHARE" | FLEA_GIO_BIN="$FAKE2" timeout "$BACK_TIMEOUT" "$BIN" --backend 2>/dev/null)
got2="$(printf '%s\n' "$out2" | sed -n 2p | rows_names)"
check "unadopted listing answers its rows" '"n":"a.txt" "n":"b.txt" ' "$got2"
if [ "$got2" != '"n":"a.txt" "n":"b.txt" ' ]; then printf '%s\n' "$out2" | head -3 | cut -c1-200; fi
check "unadopted listing spawns gio exactly once" "1" "$(gio_calls "$CALLS2")"

# Case 3: a dest older than the launch is a leftover and is never adopted.
DEST3="$RUNTIMEDIR/gvfs-stale.list"
stage_dest "$DEST3"
START3=$(now_ms)
touch -d "@$((START3 / 1000 - STALE_SECS))" "$DEST3"
FAKE3="$SB/fake3-gio"
CALLS3="$SB/fake3-calls"
printing_gio "$FAKE3" "$CALLS3"
out3=$(printf '{"c":"list","path":"%s","first":10}\n{"c":"quit"}\n' "$SHARE" | FLEA_GIO_BIN="$FAKE3" FLEA_GVFS_PREFETCH="$DEST3" FLEA_GVFS_PATH="$SHARE" FLEA_GVFS_START="$START3" timeout "$BACK_TIMEOUT" "$BIN" --backend 2>/dev/null)
got3="$(printf '%s\n' "$out3" | sed -n 2p | rows_names)"
check "stale prefetch answers the live rows" '"n":"a.txt" "n":"b.txt" ' "$got3"
if [ "$got3" != '"n":"a.txt" "n":"b.txt" ' ]; then printf '%s\n' "$out3" | head -3 | cut -c1-200; fi
check "stale prefetch spawns gio exactly once" "1" "$(gio_calls "$CALLS3")"

echo "remote-start: $passed passed, $fail failed"
sandbox_remove "$SB"
exit $fail
