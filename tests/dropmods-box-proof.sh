#!/usr/bin/env bash
# Compositor-free proof of cap_dropmods_box and of the case trap surviving the shared hold helpers.
set -u
. "$(dirname "$0")/../tools/flea-sandbox-guard"
cd "$(dirname "$0")/.." || exit 1

# A marked sandbox of its own under the fixture root, so cleanup deletes only what this run owns.
test_root=$(mktemp -d "$FIXTURE_ROOT/flea-dropmods-box-XXXXXX") || exit 1
case $test_root in
  /*/*) ;;
  *) echo "FAIL: mktemp -d gave '$test_root', which is not an absolute path two components deep"; exit 1 ;;
esac
sandbox_require "$test_root" || exit 1
: > "$test_root/$SANDBOX_MARKER" || exit 1
cleanup() { sandbox_remove "$test_root"; }
trap cleanup EXIT

mkdir -p "$test_root/bin" || exit 1
# The fake compositor answers clients -j with two windows, so the pid select is pinned.
cat > "$test_root/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
printf '%s' '[{"class":"com.thisisgm.flea","pid":5,"at":[10,20],"size":[800,600]},{"class":"com.thisisgm.flea","pid":9,"at":[30,40],"size":[640,480]}]'
EOF
chmod +x "$test_root/bin/hyprctl" || exit 1
# The stub hold never touches hardware: press and release only need ydotool to exit 0, and each call is logged.
cat > "$test_root/bin/ydotool" <<'EOF'
#!/usr/bin/env bash
printf 'ydotool %s\n' "$*" >> "$YDOTOOL_EVENTS"
exit 0
EOF
chmod +x "$test_root/bin/ydotool" || exit 1

export PATH="$test_root/bin:$PATH"
export XDG_RUNTIME_DIR="$test_root"
export YDOTOOL_EVENTS="$test_root/events.log"
fail() { printf 'DROPMODSBOX FAIL %s\n' "$*"; exit 1; }
repo="$PWD"
. "$repo/tests/ui-captures-dropmods.sh"
. "$repo/tests/ui-captures-drops.sh"
# Sample input: cap_dropmods_box 5 prints "10<TAB>20<TAB>800<TAB>600".
box=$(cap_dropmods_box 5) || fail "cap_dropmods_box 5 answered no box: $box"
[[ "$box" == "$(printf '10\t20\t800\t600')" ]] || fail "box is '$box', want four fields 10 20 800 600"
printf 'DROPMODSBOX PASS box=%s\n' "$box"
# A stub case with no compositor: its EXIT trap must still own the exit after a hold.
window_box() { printf '0 0 800 600\n'; }
assert_focus() { return 0; }
pointer_glide() { return 0; }
settle() { return 0; }
ipc() { printf '{"opened":false}\n'; }
cap_dropmods_probe_pid=""
trap cap_dropmods_cleanup EXIT
case_trap=$(trap -p EXIT)
cap_drops_press 1 1 || fail "stub press refused"
held_trap=$(trap -p EXIT)
[[ "$held_trap" == *"click 0x80"*"cap_dropmods_cleanup"* ]] || fail "press did not chain the release before the case trap: $held_trap"
cap_drops_release || fail "stub release refused"
[[ "$(trap -p EXIT)" == "$case_trap" ]] || fail "release did not restore the case trap exactly: $(trap -p EXIT)"
trap cleanup EXIT
printf 'DROPMODSBOX PASS traphold=cap_dropmods_cleanup\n'
# A generic EXIT command that never releases, and an exit mid-hold: the release click runs, then the command, which still sees the exit status.
: > "$YDOTOOL_EVENTS"
( trap - EXIT; trap 'printf "generic %s\n" "$?" >> "$YDOTOOL_EVENTS"' EXIT; cap_drops_press 1 1; exit 3 )
[[ $? == 3 ]] || fail "the mid-hold exit status was lost"
[[ "$(tr '\n' ',' < "$YDOTOOL_EVENTS")" == "ydotool click 0x40,ydotool click 0x80,generic 3," ]] \
    || fail "a generic trap exit did not release then run with status 3: $(tr '\n' ',' < "$YDOTOOL_EVENTS")"
printf 'DROPMODSBOX PASS genericexit=release-then-generic\n'
# The same exit under errexit, which tests/ui.sh sets for every case: the relayed status must not end the chain before the command runs.
: > "$YDOTOOL_EVENTS"
( trap - EXIT; set -e; trap 'printf "generic %s\n" "$?" >> "$YDOTOOL_EVENTS"' EXIT; cap_drops_press 1 1; exit 3 )
[[ $? == 3 ]] || fail "the mid-hold exit status was lost under errexit"
[[ "$(tr '\n' ',' < "$YDOTOOL_EVENTS")" == "ydotool click 0x40,ydotool click 0x80,generic 3," ]] \
    || fail "under errexit the exit did not release then run with status 3: $(tr '\n' ',' < "$YDOTOOL_EVENTS")"
printf 'DROPMODSBOX PASS genericexit-errexit=release-then-generic\n'
# A bare press arms the release alone and a release clears it; an abandon puts a generic trap back exactly.
( trap - EXIT; cap_drops_press 1 1; [[ "$(trap -p EXIT)" == *"click 0x80"* ]] || exit 4
  cap_drops_release; [[ -z "$(trap -p EXIT)" ]] || exit 5 ) || fail "a bare hold left or lost its trap, status $?"
: > "$YDOTOOL_EVENTS"
( trap - EXIT; trap 'printf "generic\n" >> "$YDOTOOL_EVENTS"' EXIT; generic_trap=$(trap -p EXIT)
  cap_drops_press 1 1; cap_drops_abandon; [[ "$(trap -p EXIT)" == "$generic_trap" ]] || exit 4 ) \
    || fail "abandon did not restore the generic trap exactly, status $?"
[[ "$(tr '\n' ',' < "$YDOTOOL_EVENTS")" == "ydotool click 0x40,ydotool click 0x80,generic," ]] \
    || fail "an abandoned hold logged $(tr '\n' ',' < "$YDOTOOL_EVENTS")"
printf 'DROPMODSBOX PASS bare=armed-then-cleared abandon=restored\n'
# A second press while held keeps the first save, so one release still puts the generic trap back exactly.
( trap - EXIT; trap 'printf "generic\n" >> "$YDOTOOL_EVENTS"' EXIT; generic_trap=$(trap -p EXIT)
  cap_drops_press 1 1; cap_drops_press 2 2; cap_drops_release; [[ "$(trap -p EXIT)" == "$generic_trap" ]] || exit 4 ) \
    || fail "a second press while held lost the saved trap, status $?"
printf 'DROPMODSBOX PASS doublepress=first-save-kept\n'
printf 'DROPMODSBOX DONE checks=7 failed=0\n'
