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
# The fake compositor answers clients -j from a file (two Flea windows and the probe), so the pid select is pinned; activewindow answers the focused pid.
printf '%s' '[{"class":"com.thisisgm.flea","address":"0x5","pid":5,"at":[10,20],"size":[800,600]},{"class":"com.thisisgm.flea","address":"0x9","pid":9,"at":[30,40],"size":[640,480]},{"class":"qml6","title":"DropProbe","address":"0x7","pid":7,"at":[100,100],"size":[420,300]}]' > "$test_root/clients.json" || exit 1
printf '9\n' > "$test_root/active-pid" || exit 1
cat > "$test_root/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  cursorpos) echo "230, 100" ;;
  activewindow) [[ -s "$XDG_RUNTIME_DIR/active-fail" ]] && exit 1; printf '{"class":"com.thisisgm.flea","pid":%s}' "$(cat "$XDG_RUNTIME_DIR/active-pid")" ;;
  *) [[ -s "$XDG_RUNTIME_DIR/clients-fail" ]] && exit 1
     if [[ -s "$XDG_RUNTIME_DIR/clients-fail-second" ]]; then
       printf 'call\n' >> "$XDG_RUNTIME_DIR/clients-calls"
       [[ $(wc -l < "$XDG_RUNTIME_DIR/clients-calls") -ge 2 ]] && exit 1
     fi
     cat "$XDG_RUNTIME_DIR/clients.json" ;;
esac
EOF
chmod +x "$test_root/bin/hyprctl" || exit 1
# The fake qs answers per --pid, so a read that goes to the wrong window gets the wrong answer: pid 5 is the dir window, pid 9 the dir-two window.
cat > "$test_root/bin/qs" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == ipc && "$2" == --pid && "$4" == call && "$5" == flea ]] || exit 2
pid=$3; method=$6; arg=${7:-}
case "$pid:$method" in
  5:total) echo 3 ;;
  9:total) echo 2 ;;
  5:listInFlight|9:listInFlight) echo false ;;
  5:rowAt) case $arg in 0) echo 'a.txt|f' ;; 1) echo 'b1.txt|f' ;; 2) echo 'b2.txt|f' ;; esac ;;
  9:rowAt) case $arg in 0) echo 'pad.txt|f' ;; 1) echo 'sub2|d' ;; esac ;;
  5:rowCentre) echo "100 $((40 + arg * 20))" ;;
  9:rowCentre) echo "200 $((40 + arg * 20))" ;;
  5:path) echo /fix/dir ;;
  9:path) echo /fix/dir-two ;;
  9:statusActivityState) cat "$XDG_RUNTIME_DIR/activity9.json" ;;
  5:lastMessage) echo 'Copied 1 item · z undoes' ;;
  9:lastMessage) echo 'Opened' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$test_root/bin/qs" || exit 1
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
ipc() { printf '{"opened":false,"activities":[]}\n'; }
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
ipc() { case "$1" in statusActivityState) cat "$actstate" ;; columnNames) cat "$test_root/column-$2" ;; esac; }
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
# A probe that is missing, doubled or unreadable is named as that, never as a probe covering the point.
clients_ok=$(cat "$test_root/clients.json")
printf '%s' '[{"class":"com.thisisgm.flea","pid":5,"at":[10,20],"size":[800,600]}]' > "$test_root/clients.json"
out=$( fail() { printf '%s' "$*"; exit 9; }; cap_dropmods_probe_clear_of 50 50 )
[[ $? -eq 9 && "$out" == "cap_dropmods: expected one parked DropProbe window, found 0" ]] || fail "a missing probe read '$out'"
printf '%s' '[{"title":"DropProbe","pid":7,"at":[100,100],"size":[4,3]},{"title":"DropProbe","pid":8,"at":[900,900],"size":[4,3]}]' > "$test_root/clients.json"
out=$( fail() { printf '%s' "$*"; exit 9; }; cap_dropmods_probe_clear_of 50 50 )
[[ $? -eq 9 && "$out" == "cap_dropmods: expected one parked DropProbe window, found 2" ]] || fail "two probes read '$out'"
printf '%s' "$clients_ok" > "$test_root/clients.json"
printf 1 > "$test_root/clients-fail"
out=$( fail() { printf '%s' "$*"; exit 9; }; cap_dropmods_probe_clear_of 50 50 )
[[ $? -eq 9 && "$out" == "cap_dropmods: hyprctl clients was unreadable, so the parked probe could not be located" ]] || fail "an unreadable hyprctl read '$out'"
: > "$test_root/clients-fail"
out=$( fail() { printf '%s' "$*"; exit 9; }; cap_dropmods_probe_clear_of 200 200 )
[[ $? -eq 9 && "$out" == "cap_dropmods: the parked probe covers the source point 200,200, so the press would miss the row" ]] || fail "a covered point read '$out'"
printf 'DROPMODSBOX PASS probe_clear_of=names-missing-doubled-unreadable\n'
# One reading serves both checks: a hyprctl whose second call fails can no longer reach the cover message, and it makes one call.
printf 1 > "$test_root/clients-fail-second"
: > "$test_root/clients-calls"
out=$( fail() { printf '%s' "$*"; exit 9; }; cap_dropmods_probe_clear_of 200 200 )
[[ $? -eq 9 && "$out" == "cap_dropmods: the parked probe covers the source point 200,200, so the press would miss the row" ]] || fail "a point inside the probe read '$out' when only the second hyprctl call fails"
[[ $(wc -l < "$test_root/clients-calls") -eq 1 ]] || fail "probe_clear_of called hyprctl $(wc -l < "$test_root/clients-calls") times, want one reading"
: > "$test_root/clients-calls"
( cap_dropmods_probe_clear_of 50 50 ) || fail "a point outside the probe was refused when only the second hyprctl call fails"
: > "$test_root/clients-fail-second"
printf 'DROPMODSBOX PASS probe_clear_of=one-reading\n'
# A hold marks the status activities first, and the target wait reads the line the drag names, new activities only.
printf '%s' '{"activities":[{"id":3,"text":"Move 1 item to Photos · ctrl at lift copies","running":false}]}' > "$actstate"
cap_dropmods_before="[]"
cap_drops_press 1 1 || fail "stub press refused"
[[ "$cap_dropmods_before" == "[3]" ]] || fail "the press marked '$cap_dropmods_before', want [3]"
cap_drops_abandon
cap_dropmods_before="[]"
( cap_drops_wait_target Photos ) || fail "a move line was not matched to its row"
( fail() { exit 9; }; cap_drops_wait_target Docs ) >/dev/null 2>&1
[[ $? -eq 9 ]] || fail "a line naming another row was accepted"
cap_dropmods_before="[3]"
( fail() { exit 9; }; cap_drops_wait_target Photos ) >/dev/null 2>&1
[[ $? -eq 9 ]] || fail "a line already present at the mark was taken for a new drag"
printf '%s' '{"activities":[{"id":4,"text":"Copy 1 item to outer/","running":false}]}' > "$actstate"
cap_dropmods_before="[3]"
( cap_drops_wait_target outer/ ) || fail "a crumb copy line was not matched"
( fail() { exit 9; }; cap_drops_wait_target outer ) >/dev/null 2>&1
[[ $? -eq 9 ]] || fail "a crumb name without its slash was accepted"
! grep -n 'listingDropActive' "$repo/tests/ui-captures-drops.sh" || fail "ui-captures-drops.sh still reads the listing floor, which a row, crumb or column row leaves dark"
printf 'DROPMODSBOX PASS wait_target=row-crumb-new-only-no-floor\n'
# Two windows are read through their own pids: the fake qs gives pid 5 the dir window and pid 9 the dir-two window.
cap_dropmods_wait_s=1
cap_dropmods_message_s=1
[[ "$(cap_dropmods_row_centre 5 b1.txt)" == "110 80" ]] || fail "b1.txt of window 5 centred at '$(cap_dropmods_row_centre 5 b1.txt)', want 110 80"
[[ "$(cap_dropmods_row_centre 9 sub2)" == "230 100" ]] || fail "sub2 of window 9 centred at '$(cap_dropmods_row_centre 9 sub2)', want 230 100"
( fail() { exit 9; }; cap_dropmods_row_centre 9 b1.txt ) >/dev/null 2>&1
[[ $? -eq 9 ]] || fail "a row of the other window was found through this window's pid"
( cap_dropmods_wait_total 5 3 && cap_dropmods_wait_total 9 2 ) || fail "a window did not settle at its own total"
( fail() { exit 9; }; cap_dropmods_wait_total 9 3 ) >/dev/null 2>&1
[[ $? -eq 9 ]] || fail "window 9 settled at the total of window 5"
( cap_dropmods_wait_message 5 "Copied 1 item · z undoes" ) || fail "window 5 did not read its own message"
( fail() { exit 9; }; cap_dropmods_wait_message 9 "Copied 1 item · z undoes" ) >/dev/null 2>&1
[[ $? -eq 9 ]] || fail "window 9 was credited with the message of window 5"
printf 'DROPMODSBOX PASS two_windows=read-by-own-pid\n'
# Focus is the compositor's: the focused pid and the window's own path must both match; ipc alone never says which window has focus.
hypr_window_focus() { return 0; }
( cap_dropmods_focus_pid 9 /fix/dir-two ) || fail "the focused window was refused"
out=$( fail() { printf '%s' "$*"; exit 9; }; cap_dropmods_focus_pid 5 /fix/dir )
[[ $? -eq 9 && "$out" == "cap_dropmods: focus did not land on window 5 (the compositor focuses 9)" ]] || fail "a window the compositor does not focus read '$out'"
printf '5\n' > "$test_root/active-pid"
( cap_dropmods_focus_pid 5 /fix/dir ) || fail "window 5 was refused once the compositor focused it"
out=$( fail() { printf '%s' "$*"; exit 9; }; cap_dropmods_focus_pid 5 /fix/dir-two )
[[ $? -eq 9 && "$out" == "cap_dropmods: window 5 shows /fix/dir, not /fix/dir-two" ]] || fail "a window with another path read '$out'"
[[ "$(cap_dropmods_active_pid)" == "5" ]] || fail "the active pid read '$(cap_dropmods_active_pid)', want 5"
printf 1 > "$test_root/active-fail"
[[ "$(cap_dropmods_active_pid)" == "unavailable" ]] || fail "an unreadable compositor focus was not reported"
: > "$test_root/active-fail"
printf '9\n' > "$test_root/active-pid"
# The two-window phase of the case holds no call that reads the newest window or refuses two (ipc, key, seek_row_named, row_index_of, wait_listing, wait_message, window_box).
phase=$(sed -n '/^    win1=\$(flea_pid)$/,/^    kill_flea$/p' "$repo/tests/ui-captures-dropmods.sh")
[[ "$(printf '%s\n' "$phase" | wc -l)" -gt 20 ]] || fail "the two-window phase of cap_dropmods was not found"
! printf '%s\n' "$phase" | grep -nE '(^[[:space:]]*|[(;&|{][[:space:]]*)(ipc|key|seek_row_named|row_index_of|wait_listing|wait_message|window_box)[ )]' || fail "the two-window phase reads a window the newest-window way"
printf 'DROPMODSBOX PASS focus=compositor-pid-and-own-path\n'
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
# The runner's own EXIT trap survives the case: armed over it and disarmed, the trap is back as it was; a fail runs the trash removal and then the runner's trap with the status.
reset_logs
runner_trap() { local st=$?; printf 'runner\n' >> "$orderlog"; printf '%s\n' "$st" >> "$trapstatus"; }
( trap runner_trap EXIT
  cap_drops_dir=$case_dir; cap_drops_pasted=""
  cap_drops_trash_arm
  [[ "$(trap -p EXIT)" == *cap_drops_trash_exit* ]] || fail "the case armed no trash trap: $(trap -p EXIT)"
  cap_drops_trash_disarm
  [[ "$(trap -p EXIT)" == "trap -- 'runner_trap' EXIT" ]] || fail "the case end did not put the runner's trap back: $(trap -p EXIT)"
) || exit 1
[[ "$(cat "$orderlog")" == "runner" ]] || fail "the runner trap ran '$(tr '\n' ' ' < "$orderlog")' at a clean exit, want once"
reset_logs
printf 'png\n' > "$mount_trash/files/$name"
printf '[Trash Info]\nPath=case/Pasted%%20image%%202026-10-12%%20at%%2010.14.32.png\n' > "$mount_trash/info/$name.trashinfo"
( trap runner_trap EXIT
  cap_drops_dir=$case_dir; cap_drops_pasted=$name
  cap_drops_trash_arm
  cap_drops_press 1 1 || fail "stub press refused"
  exit 6
)
[[ $? -eq 6 ]] || fail "the chained exits lost the status"
[[ "$(tr '\n' ' ' < "$orderlog")" == "release runner " ]] || fail "a failing case ran '$(tr '\n' ' ' < "$orderlog")', want the release then the runner's trap once"
[[ "$(cat "$trapstatus")" == "6" ]] || fail "the runner trap was entered with status '$(cat "$trapstatus")', want 6"
[[ ! -e "$mount_trash/files/$name" ]] || fail "the failing case left its pasted image in the mount-top trash"
! sed -n '/^case_cap_drops() {/,/^}/p' "$repo/tests/ui-captures-drops.sh" | grep -nE '^ *trap ' || fail "case_cap_drops sets or clears an EXIT trap directly, which replaces the runner's"
printf 'DROPMODSBOX PASS trash_chain=runner-trap-survives\n'
HOME=$real_home
unset -f stat
# A hover line is read from the window it names: window 9 says its row line, the newest-window stub says another.
printf '%s' '{"activities":[{"id":7,"text":"Move 1 item to sub2 · ctrl at lift copies","running":false}]}' > "$test_root/activity9.json"
cap_dropmods_wait_s=1
cap_dropmods_before="[]"
( cap_dropmods_wait_line "Move 1 item to sub2 · ctrl at lift copies" 9 ) || fail "window 9 did not give its own hover line"
( fail() { exit 9; }; cap_dropmods_wait_line "Move 1 item to sub2 · ctrl at lift copies" ) >/dev/null 2>&1
[[ $? -eq 9 ]] || fail "the newest-window stub was credited with the line of window 9"
cap_dropmods_mark 9
[[ "$cap_dropmods_before" == "[7]" ]] || fail "mark of window 9 read '$cap_dropmods_before', want [7]"
( fail() { exit 9; }; cap_dropmods_wait_line "Move 1 item to sub2 · ctrl at lift copies" 9 ) >/dev/null 2>&1
[[ $? -eq 9 ]] || fail "a line already present at the mark of window 9 was taken for a new drag"
cap_dropmods_before="[]"
printf '%s' '{"activities":[{"id":8,"text":"Move 1 item to dir-two · ctrl at lift copies","running":false}]}' > "$test_root/activity9.json"
out=$( fail() { printf '%s' "$*"; exit 9; }; cap_dropmods_wait_line "Move 1 item to sub2 · ctrl at lift copies" 9 )
[[ $? -eq 9 && "$out" == *"status lines: Move 1 item to dir-two · ctrl at lift copies; pointer 230, 100, window 9 box 30"* ]] || fail "a hover on the wrong target read '$out'"
printf 'DROPMODSBOX PASS hover_line=read-by-pid-names-pointer\n'
# A file that never landed names where a file of that name did.
cap_dropmods_file_s=1
mkdir -p "$test_root/two/sub2" || exit 1
: > "$test_root/two/b1.txt"
out=$( fail() { printf '%s' "$*"; exit 9; }; cap_dropmods_wait_file "$test_root/two/sub2/b1.txt" "$test_root/two" )
[[ $? -eq 9 && "$out" == *"never landed (a file of that name exists at: $test_root/two/b1.txt )" ]] || fail "a copy that landed one folder up read '$out'"
: > "$test_root/two/sub2/b1.txt"
( cap_dropmods_wait_file "$test_root/two/sub2/b1.txt" "$test_root/two" ) || fail "a landed file was not found"
printf 'DROPMODSBOX PASS wait_file=names-where-it-landed\n'
# The child column draws the folder under the cursor: a name is waited for in the slot it will be dragged from, and a miss shows what the slot drew.
cap_drops_column_s=1
printf '%s' 'inner|p1.txt|p2.txt' > "$test_root/column-child"
printf '%s' 'deep|Photos|a.txt' > "$test_root/column-parent"
( cap_drops_wait_column child p1.txt && [[ "$cap_drops_names" == "inner|p1.txt|p2.txt" ]] ) || fail "the child column's own names were not found"
( cap_drops_wait_column parent deep && [[ "$cap_drops_names" == "deep|Photos|a.txt" ]] ) || fail "the parent column's own names were not found"
printf '%s' '' > "$test_root/column-child"
out=$( fail() { printf '%s' "$*"; exit 9; }; cap_drops_wait_column child p1.txt )
[[ $? -eq 9 && "$out" == "cap_drops: the child column never listed p1.txt (it drew: )" ]] || fail "an empty child column read '$out'"
printf '%s' 'p1.txt.bak|xp1.txt' > "$test_root/column-child"
( fail() { exit 9; }; cap_drops_wait_column child p1.txt ) >/dev/null 2>&1
[[ $? -eq 9 ]] || fail "a name that only contains p1.txt was taken for p1.txt"
printf 'DROPMODSBOX PASS wait_column=whole-name-in-its-slot\n'
printf 'DROPMODSBOX DONE checks=18 failed=0\n'
