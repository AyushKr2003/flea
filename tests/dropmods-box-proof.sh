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
printf '%s' '[{"class":"com.thisisgm.flea","pid":5,"at":[10,20],"size":[800,600]},{"class":"com.thisisgm.flea","pid":9,"at":[30,40],"size":[640,480]},{"class":"qml6","title":"DropProbe","pid":7,"at":[100,100],"size":[420,300]}]'
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
# The drag line is matched whole: a move line carries its " · ctrl at lift copies" tail, so a suffix match never saw it.
actstate="$test_root/activity.json"
ipc() { [[ "$1" == statusActivityState ]] && cat "$actstate"; }
cap_dropmods_wait_s=1
printf '%s' '{"activities":[{"id":0,"text":"Move 1 item to sub · ctrl at lift copies","running":false}]}' > "$actstate"
cap_dropmods_before="[]"
( cap_dropmods_wait_line "Move 1 item to sub · ctrl at lift copies" ) || fail "the move line was not matched whole"
( fail() { exit 9; }; cap_dropmods_wait_line "Move 1 item to sub" ) >/dev/null 2>&1
[[ $? -eq 9 ]] || fail "a line that is only a prefix of the status line was accepted"
( fail() { exit 9; }; cap_dropmods_wait_line "Copy 1 item to sub" ) >/dev/null 2>&1
[[ $? -eq 9 ]] || fail "a copy line was accepted for a move status line"
cap_dropmods_before="[0]"
( fail() { exit 9; }; cap_dropmods_wait_line "Move 1 item to sub · ctrl at lift copies" ) >/dev/null 2>&1
[[ $? -eq 9 ]] || fail "a line already present at the mark was taken for a new drag"
printf 'DROPMODSBOX PASS wait_line=whole-line-and-new-only\n'
# The probe stub sits at 100,100 size 420x300: a press inside it fails the case, one outside passes.
( cap_dropmods_probe_clear_of 50 50 ) || fail "a point outside the probe was refused"
( fail() { exit 9; }; cap_dropmods_probe_clear_of 200 200 ) >/dev/null 2>&1
[[ $? -eq 9 ]] || fail "a point inside the probe was accepted"
printf 'DROPMODSBOX PASS probe_clear_of=outside-only\n'
# The pasted image's trash follows HOME's device: stat is stubbed, so each branch runs on its own tree under the marked root.
case_dir="$test_root/case"
mkdir -p "$case_dir" "$test_root/home" || exit 1
name="Pasted image 2026-10-12 at 10.14.32.png"
other="Pasted image 2026-10-12 at 10.14.33.png"
uid=$(id -u)
stat() { case "$2" in %d) [[ "$4" == "$HOME" ]] && echo 11 || echo "${fake_dev:-22}" ;; %m) echo "$test_root" ;; esac; }
want="$test_root/data/Trash"
got=$( HOME="$test_root/home" XDG_DATA_HOME="$test_root/data" fake_dev=11 cap_drops_trash_dirs "$case_dir" )
[[ "$got" == "$want" ]] || fail "a file on HOME's device asked for '$got', want $want"
got=$( HOME="$test_root/home" XDG_DATA_HOME="$test_root/data" fake_dev=22 cap_drops_trash_dirs "$case_dir" | tr '\n' ' ' )
[[ "$got" == "$test_root/.Trash/$uid $test_root/.Trash-$uid " ]] || fail "a file on another device asked for '$got', want the mount top's two trashes"
printf 'DROPMODSBOX PASS trash_dirs=home-device-or-mount-top\n'
mount_trash="$test_root/.Trash-$uid"
mkdir -p "$mount_trash/files" "$mount_trash/info" || exit 1
for n in "$name" "$other"; do printf 'png\n' > "$mount_trash/files/$n"; done
printf '[Trash Info]\nPath=case/Pasted%%20image%%202026-10-12%%20at%%2010.14.32.png\n' > "$mount_trash/info/$name.trashinfo"
printf '[Trash Info]\nPath=elsewhere/Pasted%%20image%%202026-10-12%%20at%%2010.14.33.png\n' > "$mount_trash/info/$other.trashinfo"
real_home=$HOME
export fake_dev=22
export HOME="$test_root/home" XDG_DATA_HOME="$test_root/data"
[[ "$(cap_drops_trash_holding "$case_dir" "$name")" == "$mount_trash" ]] || fail "the mount-top trash holding the name was not found"
cap_drops_trash_remove "$case_dir" "$other" && fail "a trashed file whose Path is outside the case was removed"
[[ -e "$mount_trash/files/$other" && -e "$mount_trash/info/$other.trashinfo" ]] || fail "a foreign trashed file was touched"
cap_drops_trash_remove "$case_dir" "$name" || fail "the case's own trashed file was refused"
[[ ! -e "$mount_trash/files/$name" && ! -e "$mount_trash/info/$name.trashinfo" ]] || fail "the case's own trashed file is still in the mount-top trash"
printf 'DROPMODSBOX PASS trash_remove=own-path-only\n'
# A fail after the Delete still removes the case's own entry, and the exit status survives the trap.
printf 'png\n' > "$mount_trash/files/$name"
printf '[Trash Info]\nPath=case/Pasted%%20image%%202026-10-12%%20at%%2010.14.32.png\n' > "$mount_trash/info/$name.trashinfo"
( cap_drops_dir=$case_dir; cap_drops_pasted=$name; trap cap_drops_trash_exit EXIT; exit 5 )
[[ $? -eq 5 ]] || fail "the trash exit trap lost the exit status"
[[ ! -e "$mount_trash/files/$name" ]] || fail "the exit trap left the pasted image in the mount-top trash"
printf 'DROPMODSBOX PASS trash_exit=removes-own-and-keeps-status\n'
HOME=$real_home
unset -f stat
printf 'DROPMODSBOX DONE checks=9 failed=0\n'
