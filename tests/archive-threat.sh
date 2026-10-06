#!/bin/bash
# GM ruling 13 red-first threat suite for archive passwords: the canary S3cr3t-canary-1006
# travels the password flows and must appear nowhere but a tool's stdin. Phase A drives the real
# backend, phase B walks both cards offscreen, phase C pins the static shape. Offscreen, no display.
set -u
. "$(dirname "$0")/../tools/flea-sandbox-guard"
cd "$(dirname "$0")/.." || exit 1
BIN=./target/debug/flea
[ -x "$BIN" ] || { echo "archive-threat.sh: $BIN is missing, run cargo build" >&2; exit 1; }
CANARY=S3cr3t-canary-1006
D="$FIXTURE_ROOT/flea-archive-threat-$$"
fail=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL $label"; echo "  expected: $expected"; echo "  actual:   $actual"; fail=1
  else
    echo "ok   $label"
  fi
}

sandbox_make "$D" || exit 1
mkdir -p "$D/src" || exit 1
printf 'alpha' > "$D/src/a.txt"
printf 'beta' > "$D/src/b.txt"
printf 'not a 7z archive' > "$D/src/locked.7z"
printf 'taken' > "$D/dup.7z"

cleanup() {
  exec 3>&- 2>/dev/null
  [ -n "${BACKEND_PID:-}" ] && kill "$BACKEND_PID" 2>/dev/null
  sandbox_remove "$D"
}
trap cleanup EXIT

start_backend() {
  rm -f "$D/out" "$D/err"; : > "$D/out"; : > "$D/err"; rm -f "$D/in"; mkfifo "$D/in"
  $BIN --backend < "$D/in" > "$D/out" 2> "$D/err" &
  BACKEND_PID=$!
  exec 3> "$D/in"
}
stop_backend() { send '{"c":"quit"}'; exec 3>&-; wait "$BACKEND_PID" 2>/dev/null; BACKEND_PID=""; }
send() { printf '%s\n' "$1" >&3; }
await() {
  local pattern="$1" i
  for i in $(seq 1 300); do grep -q -- "$pattern" "$D/out" && return 0; sleep 0.1; done
  echo "  TIMEOUT waiting for: $pattern"; return 1
}
# The same pattern can answer several jobs, so later waits count lines rather than matching stale ones.
await_count() {
  local pattern="$1" want="$2" i
  for i in $(seq 1 300); do [ "$(grep -c -- "$pattern" "$D/out")" -ge "$want" ] 2>/dev/null && return 0; sleep 0.1; done
  echo "  TIMEOUT waiting for $want lines of: $pattern"; return 1
}

echo "--- phase A: the live backend never repeats the secret ---"
echo "  tools: 7z=$([ -x "$(command -v 7z 2>/dev/null)" ] && echo yes || echo no) bwrap=$([ -x "$(command -v bwrap 2>/dev/null)" ] && echo yes || echo no) bsdtar=$([ -x "$(command -v bsdtar 2>/dev/null)" ] && echo yes || echo no)"
start_backend
send '{"c":"formats"}'
await '"t":"formats"' || fail=1
send "{\"c\":\"archive\",\"op\":\"compress\",\"paths\":[\"$D/src/a.txt\",\"$D/src/b.txt\"],\"dest\":\"$D/out.7z\",\"format\":\"7z\",\"password\":\"$CANARY\",\"encryptNames\":true,\"menuId\":0}"
await_count '"t":"archivedone"' 1 || fail=1
send "{\"c\":\"archive\",\"op\":\"extract\",\"path\":\"$D/src/locked.7z\",\"dest\":\"$D/exout\",\"password\":\"$CANARY\",\"menuId\":0}"
await_count '"t":"archivedone"' 2 || fail=1
send "{\"c\":\"archive\",\"op\":\"extract\",\"path\":\"$D/src/locked.7z\",\"dest\":\"$D/exempty\",\"password\":\"\",\"menuId\":0}"
await_count '"t":"archivedone"' 3 || fail=1
send "{\"c\":\"archive\",\"op\":\"compress\",\"paths\":[\"$D/src/a.txt\"],\"dest\":\"$D/plain.tar.zst\",\"format\":\"tar.zst\",\"menuId\":0}"
await_count '"t":"archivedone"' 4 || fail=1
send "{\"c\":\"archive\",\"op\":\"compress\",\"paths\":[\"$D/src/a.txt\"],\"dest\":\"$D/dup.7z\",\"format\":\"7z\",\"password\":\"$CANARY\",\"menuId\":0}"
await_count '"t":"archivedone"' 5 || fail=1
stop_backend
dones=$(grep -c '"t":"archivedone"' "$D/out" | tr -d ' ')
check "every password job answered" "5" "$dones"
check "the wire never repeats the secret" "0" "$(grep -c -- "$CANARY" "$D/out" | tr -d ' ')"
check "stderr never repeats the secret" "0" "$(grep -c -- "$CANARY" "$D/err" | tr -d ' ')"
check "no file under the sandbox holds the secret" "0" "$(grep -r -l -- "$CANARY" "$D/src" "$D/out.7z" "$D/plain.tar.zst" "$D/exout" "$D/exempty" 2>/dev/null | wc -l | tr -d ' ')"
check "the plain control compress wrote its archive" "1" "$([ -f "$D/plain.tar.zst" ] && echo 1 || echo 0)"

echo "--- phase B: the offscreen card walk clears every terminal path ---"
command -v qs >/dev/null || { echo "archive-threat.sh: qs is not installed, cannot walk the cards"; exit 1; }
mkdir -p "$D/config" "$D/home" || exit 1
ln -s "$PWD/ui" "$D/config/flea" || exit 1
ln -s "$(readlink -f ui/boot/Commons)" "$D/config/Commons" || exit 1
ln -s "$(readlink -f ui/boot/Ui)" "$D/config/Ui" || exit 1
cp tests/archive-threat.qml "$D/config/shell.qml" || exit 1
run_timeout_s=60
output=$( ( env -u DISPLAY -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
    HOME="$D/home" XDG_STATE_HOME="$D" XDG_CACHE_HOME="$D" \
    XDG_DATA_HOME="$D" XDG_CONFIG_HOME="$D/home/.config" \
    XDG_RUNTIME_DIR="$D" ARCHIVETHREAT_TIMEOUT_S="$run_timeout_s" \
    QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=generic QT_QUICK_BACKEND=software QT_FORCE_STDERR_LOGGING=1 \
    timeout "$run_timeout_s" qs -p "$D/config" 2>&1 ) 2>/dev/null )
printf '%s\n' "$output" | grep -q 'ARCHIVETHREAT DONE checks=[0-9][0-9]* failed=0' || { echo "FAIL the walk did not finish clean:"; printf '%s\n' "$output" | grep ARCHIVETHREAT | head -20; fail=1; }
check "the walk ran its checks" "1" "$(printf '%s\n' "$output" | grep -c 'ARCHIVETHREAT DONE')"
check "no probe log repeats the secret" "0" "$(printf '%s\n' "$output" | grep -c -- "$CANARY")"

echo "--- phase C: the static shape ---"
check "Ipc.qml exposes no archive card" "0" "$(grep -ci 'archivepassworddialog\|archivecompressdialog\|archivecards' ui/Ipc.qml || true)"
check "the host builds on first open only" "1" "$(grep -c 'Qt.createComponent("ArchiveCards.qml")' ui/WindowBody.qml)"
check "and nothing instantiates it at startup" "0" "$(grep -ch 'Flea\.ArchiveCards {' ui/WindowBody.qml ui/ArchiveCards.qml | awk -F: '{s+=$NF} END {print s+0}')"
check "no new surface logs" "0" "$(grep -ch 'console\.log' ui/ArchiveCompressDialog.qml ui/ArchivePasswordDialog.qml ui/ArchiveCards.qml ui/js/Archive.js ui/js/ArchiveOps.js ui/js/Kinds.js | awk -F: '{s+=$NF} END {print s+0}')"

echo
if [ "$fail" = 0 ]; then echo "archive-threat.sh: all checks passed"; else echo "archive-threat.sh: FAILURES above"; fi
exit "$fail"
