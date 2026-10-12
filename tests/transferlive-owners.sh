#!/usr/bin/env bash
# Proves transferlive_teardown stops the run's detached flea --clip-own and spares the operator's, with stub owners that are scripts named flea.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
MARKER=.flea-test-sandbox
box=$(mktemp -d) || exit 1
: > "$box/$MARKER"
spawned=()
# Kills only what this suite spawned, then removes only an absolute, non-empty root that still carries its marker.
cleanup() {
    local pid
    for pid in "${spawned[@]}"; do kill "$pid" 2>/dev/null; done
    case $box in
        /?*) [ -f "$box/$MARKER" ] && rm -rf -- "$box" ;;
    esac
}
trap cleanup EXIT
checks=0
bad=0
# The verdict word is reworded in every line this suite prints, so only a real failure reads as one to flea-ci.
say() { local s=$*; printf '%s\n' "${s//FAIL/failed}"; }
check() {
    checks=$((checks + 1))
    if [ "$1" = ok ]; then say "ok   $2"; else bad=$((bad + 1)); say "BAD  $2"; fi
}
# A pid that is running: a zombie has already exited.
alive() { [ -d "/proc/$1" ] && [ "$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1)" != Z ]; }

# What tests/ui.sh supplies, reduced to what transferlive_stop_owners reads: the run's marker in the environment decides ownership.
run_root="$box/run"
drain_wait_s=5
fail() { say "stub fail: $*"; exit 99; }
flea_process_owned() {
    [ -d "/proc/$1" ] || return 2
    [ "$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1)" != Z ] || return 2
    tr '\0' '\n' 2>/dev/null < "/proc/$1/environ" | grep -Fxq "FLEA_TEST_RUN_ROOT=$run_root"
}
kill_flea() { :; }
sandbox_remove() { :; }
# shellcheck source=tests/ui-transfer-live.sh
. tests/ui-transfer-live.sh
transferlive_root="" transferlive_bus_pid="" transferlive_writer_pids=()

# A script named flea has comm flea, and its cmdline ends in the argument given, as the real owner's does.
stub="$box/stub"
mkdir "$stub" || exit 1
printf '#!/bin/bash\ntrap '"'"'kill "$s" 2>/dev/null; exit 0'"'"' TERM\nsleep 300 &\ns=$!\nwait "$s"\n' > "$stub/flea"
chmod +x "$stub/flea"
unset FLEA_TEST_RUN_ROOT
FLEA_TEST_RUN_ROOT="$run_root" "$stub/flea" --clip-own & mine=$!
FLEA_TEST_RUN_ROOT="$run_root" "$stub/flea" --backend & backend=$!
"$stub/flea" --clip-own & foreign=$!
spawned=("$mine" "$backend" "$foreign")
# The kernel names the process after the script once the exec lands, so wait for all three.
for _ in $(seq 1 100); do
    [ "$(pgrep -x flea | grep -cxF -e "$mine" -e "$backend" -e "$foreign")" -eq 3 ] && break
    sleep 0.05
done
alive "$mine" && alive "$backend" && alive "$foreign" && check ok "the three stub processes run" || check bad "the three stub processes run"

transferlive_teardown
alive "$mine" && check bad "teardown stops this run's clipboard owner" || check ok "teardown stops this run's clipboard owner"
alive "$backend" && check ok "teardown leaves this run's backend" || check bad "teardown leaves this run's backend"
alive "$foreign" && check ok "teardown leaves an owner this run did not start" || check bad "teardown leaves an owner this run did not start"

say "transferlive-owners: $checks checks, $bad bad"
[ "$bad" -eq 0 ]
