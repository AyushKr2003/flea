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
# The stub hold never touches hardware: it exits 0 and logs each call for the order checks.
cat > "$test_root/bin/ydotool" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$XDG_RUNTIME_DIR/ydotool.log"
[[ "$*" == "click 0x80" ]] && printf 'release\n' >> "$XDG_RUNTIME_DIR/order.log"
exit 0
EOF
chmod +x "$test_root/bin/ydotool" || exit 1

export PATH="$test_root/bin:$PATH"
export XDG_RUNTIME_DIR="$test_root"
fail() { printf 'DROPMODSBOX FAIL %s\n' "$*"; exit 1; }
repo="$PWD"
. "$repo/tests/ui-captures-dropmods.sh"
. "$repo/tests/ui-captures-drops.sh"
# Sample input: cap_dropmods_box 5 prints "10<TAB>20<TAB>800<TAB>600".
box=$(cap_dropmods_box 5) || exit 1
[[ "$box" == "$(printf '10\t20\t800\t600')" ]] || fail "box is '$box', want four fields 10 20 800 600"
printf 'DROPMODSBOX PASS box=%s\n' "$box"
# A stub case with no compositor: its EXIT trap must still own the exit after a hold.
window_box() { printf '0 0 800 600\n'; }
assert_focus() { return 0; }
pointer_glide() { return 0; }
settle() { return 0; }
ipc() { printf '{"opened":false}\n'; }
# Each case runs in a subshell of its own, so a failing case cannot swap out this script's own cleanup trap.
ylog="$test_root/ydotool.log"
holdlog="$test_root/hold.log"
# The fake release click and the case trap append to this one log, so it alone says which ran first.
orderlog="$test_root/order.log"
trapstatus="$test_root/trap-status.log"
# Sample input: a case trap set before the press runs on exit and is back after cap_drops_release or cap_drops_abandon.
reset_logs() { : > "$ylog"; : > "$holdlog"; : > "$orderlog"; : > "$trapstatus"; }
# The trap records the status it was entered with, which the chained release must not reset.
case_trap() { local st=$?; printf 'case-trap\n' >> "$holdlog"; printf 'case-trap\n' >> "$orderlog"; printf '%s\n' "$st" >> "$trapstatus"; }
reset_logs
( trap case_trap EXIT
  cap_drops_press 1 1 || fail "stub press refused"
  [[ "$(trap -p EXIT)" == *cap_drops_exit_chain* ]] || fail "press left the exit unreleased: $(trap -p EXIT)"
  cap_drops_release || fail "stub release refused"
  [[ "$(trap -p EXIT)" == "trap -- 'case_trap' EXIT" ]] || fail "release did not restore the case trap: $(trap -p EXIT)"
  : > "$ylog"
  cap_drops_press 1 1 || fail "stub press refused"
  cap_drops_abandon
  [[ "$(trap -p EXIT)" == "trap -- 'case_trap' EXIT" ]] || fail "abandon did not restore the case trap: $(trap -p EXIT)"
) || exit 1
[[ "$(cat "$holdlog")" == "case-trap" ]] || fail "the case trap ran '$(tr '\n' ' ' < "$holdlog")', want once on exit"
printf 'DROPMODSBOX PASS traphold=case_trap\n'
# A fail between the press and the release: the button comes up first, then the case trap runs.
reset_logs
( trap case_trap EXIT
  cap_drops_press 1 1 || fail "stub press refused"
  : > "$ylog"
  exit 3
)
[[ $? -eq 3 ]] || fail "the held exit status was lost"
[[ "$(cat "$ylog")" == "click 0x80" ]] || fail "an exit with a case trap and a held button clicked '$(tr '\n' ' ' < "$ylog")', want click 0x80 once"
[[ "$(cat "$holdlog")" == "case-trap" ]] || fail "an exit with a held button skipped the case trap: '$(tr '\n' ' ' < "$holdlog")'"
[[ "$(tr '\n' ' ' < "$orderlog")" == "release case-trap " ]] || fail "the held exit ran '$(tr '\n' ' ' < "$orderlog")', want release before case-trap"
[[ "$(cat "$trapstatus")" == "3" ]] || fail "the case trap was entered with status '$(cat "$trapstatus")', want the held exit status 3"
printf 'DROPMODSBOX PASS exithold=release-then-case-trap\n'
# A bare press has no trap before it: the press arms the release, release and abandon clear it.
reset_logs
( trap - EXIT
  cap_drops_press 1 1 || fail "stub press refused"
  [[ "$(trap -p EXIT)" == *cap_drops_exit_chain* ]] || fail "a bare press armed no release: '$(trap -p EXIT)'"
  cap_drops_release || fail "stub release refused"
  [[ -z "$(trap -p EXIT)" ]] || fail "release left a trap behind: $(trap -p EXIT)"
  cap_drops_press 1 1 || fail "stub press refused"
  cap_drops_abandon
  [[ -z "$(trap -p EXIT)" ]] || fail "abandon left a trap behind: $(trap -p EXIT)"
  : > "$ylog"
  cap_drops_press 1 1 || fail "stub press refused"
  : > "$ylog"
  exit 4
)
[[ $? -eq 4 ]] || fail "the bare exit status was lost"
[[ "$(cat "$ylog")" == "click 0x80" ]] || fail "a bare held exit clicked '$(tr '\n' ' ' < "$ylog")', want click 0x80"
[[ "$(trap -p EXIT)" == "trap -- 'cleanup' EXIT" ]] || fail "the script's own cleanup trap is gone: $(trap -p EXIT)"
printf 'DROPMODSBOX PASS barepress=armed-and-cleared\n'
printf 'DROPMODSBOX DONE checks=4 failed=0\n'
