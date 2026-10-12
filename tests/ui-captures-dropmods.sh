# #259's native case, run only by name on minipc; legs a pin the lift verb in one window (its QDrag.exec loop starves QML of keys, ROOTCAUSE.md), b flip it across two, c pin the frozen offer to a foreign DropArea.
. "$repo/tests/lib/pointer-glide.sh"
cap_dropmods_box() {
    [[ "$#" -eq 1 ]] || fail "cap_dropmods: box needs a qs pid, got $#"
    local geometry
    geometry=$(hyprctl clients -j | jq -er --argjson pid "$1" '
        [.[] | select(.class == "com.thisisgm.flea" and .pid == $pid)]
        | select(length == 1) | .[0] | [.at[0], .at[1], .size[0], .size[1]]
        | select(all(.[]; type == "number" and . == floor)) | @tsv') \
        || fail "cap_dropmods: no native geometry for qs pid $1"
    printf '%s\n' "$geometry"
}
# Press, hold and steer in absolute screen coordinates, so two windows need no shared origin.
cap_dropmods_press_at() {
    [[ "$#" -eq 2 ]] || fail "cap_dropmods: press needs x and y, got $#"
    # Through ydotool, never a compositor move, which sends Qt no pointer frame.
    pointer_glide "$1" "$2" || fail "cap_dropmods: pointer move to $1,$2 failed"
    sleep 0.2
    YDOTOOL_SOCKET="$XDG_RUNTIME_DIR/.ydotool_socket" ydotool click 0x40 >/dev/null 2>&1 || fail "cap_dropmods: pointer press failed"
}
cap_dropmods_steer_to() {
    [[ "$#" -eq 2 ]] || fail "cap_dropmods: steer needs x and y, got $#"
    pointer_glide "$1" "$2" || { cap_dropmods_abandon; fail "cap_dropmods: the drag never reached [$1,$2]"; }
}
cap_dropmods_abandon() {
    YDOTOOL_SOCKET="$XDG_RUNTIME_DIR/.ydotool_socket" ydotool click 0x80 >/dev/null 2>&1 || true
    YDOTOOL_SOCKET="$XDG_RUNTIME_DIR/.ydotool_socket" ydotool key 29:0 42:0 >/dev/null 2>&1 || true
}
# The case's one exit trap: a fail anywhere lets go of the pointer and keys and closes the probe window if it runs.
cap_dropmods_cleanup() {
    cap_dropmods_abandon
    [[ -z "$cap_dropmods_probe_pid" ]] || kill "$cap_dropmods_probe_pid" 2>/dev/null || true
    cap_dropmods_probe_pid=""
}
cap_dropmods_release() {
    YDOTOOL_SOCKET="$XDG_RUNTIME_DIR/.ydotool_socket" ydotool click 0x80 >/dev/null 2>&1 || fail "cap_dropmods: pointer release failed"
    settle
}
# statusActivityState prints {"activities":[{"id":3,"text":"Copy 1 item to sub","running":false,...}],...}.
cap_dropmods_before="[]"
cap_dropmods_wait_s=15
# A copy or move across two windows says its message after the transfer, as ui.sh wait_message allows.
cap_dropmods_message_s=25
cap_dropmods_mark() {
    cap_dropmods_before=$(ipc statusActivityState | jq -ce '[.activities[].id]') || fail "cap_dropmods: statusActivityState unreadable at the mark"
}
# Same-window rows keep the floor signal dark, so a status activity reading the whole line, one not seen at the mark, shows the hover.
cap_dropmods_wait_line() {
    [[ "$#" -eq 1 ]] || fail "cap_dropmods: wait_line needs a line, got $#"
    local want="$1" seen="" end=$((SECONDS + cap_dropmods_wait_s))
    while (( SECONDS < end )); do
        seen=$(ipc statusActivityState 2>/dev/null | jq -r --arg w "$want" --argjson before "$cap_dropmods_before" \
            '.activities[] | select(.running == false and (.id as $i | $before | index([$i]) | not)) | .text | select(. == $w)' 2>/dev/null | head -n 1 || true)
        [[ -n "$seen" ]] && return 0
        sleep 0.1
    done
    fail "cap_dropmods: no drag line reading '$want' (status lines: $(ipc statusActivityState 2>/dev/null | jq -r '[.activities[].text] | join(" | ")' 2>/dev/null))"
}
# A press that lands on the parked probe starts no drag, so a probe covering the source point fails the case before the press.
cap_dropmods_probe_clear_of() {
    [[ "$#" -eq 2 ]] || fail "cap_dropmods: probe_clear_of needs x and y, got $#"
    local found
    found=$(hyprctl clients -j 2>/dev/null | jq -er '[.[] | select(.title == "DropProbe")] | length') \
        || fail "cap_dropmods: hyprctl clients was unreadable, so the parked probe could not be located"
    [[ "$found" == "1" ]] || fail "cap_dropmods: expected one parked DropProbe window, found $found"
    hyprctl clients -j 2>/dev/null | jq -e --argjson x "$1" --argjson y "$2" '[.[] | select(.title == "DropProbe")] | .[0]
        | (.at[0] <= $x and $x < .at[0] + .size[0] and .at[1] <= $y and $y < .at[1] + .size[1]) | not' >/dev/null \
        || fail "cap_dropmods: the parked probe covers the source point $1,$2, so the press would miss the row"
}
# ydotool key 29 is left Ctrl and 42 left Shift.
cap_dropmods_key() {
    [[ "$#" -eq 2 ]] || fail "cap_dropmods: key needs a code and 1 or 0, got $#"
    YDOTOOL_SOCKET="$XDG_RUNTIME_DIR/.ydotool_socket" ydotool key "$1:$2" >/dev/null 2>&1 || fail "cap_dropmods: key $1:$2 refused"
    sleep 0.3
}
cap_dropmods_wait_file() {
    [[ "$#" -eq 1 ]] || fail "cap_dropmods: wait_file needs a path, got $#"
    local end=$((SECONDS + 15))
    while (( SECONDS < end )); do [[ -e "$1" ]] && return 0; sleep 0.1; done
    fail "cap_dropmods: $1 never landed"
}
cap_dropmods_wait_gone() {
    [[ "$#" -eq 1 ]] || fail "cap_dropmods: wait_gone needs a path, got $#"
    local end=$((SECONDS + 15))
    while (( SECONDS < end )); do [[ ! -e "$1" ]] && return 0; sleep 0.1; done
    fail "cap_dropmods: $1 survived the drop"
}
# launch()'s twin that keeps the first window; pids come from flea_pids as window_box's do, never $!, which names the setsid shim.
cap_dropmods_launch_second() {
    [[ "$#" -eq 1 ]] || fail "cap_dropmods: launch_second needs a path, got $#"
    FLEA_UI="$flea_ui" FLEA_BIN="$flea_bin" \
        setsid nohup "$flea_bin" --gui "$1" >"$flea_log.second" 2>&1 </dev/null &
    local count="" end=$((SECONDS + 20))
    while (( SECONDS < end )); do
        count=$(hyprctl clients -j 2>/dev/null | jq '[.[] | select(.class == "com.thisisgm.flea")] | length' 2>/dev/null || printf "")
        [[ "$count" == "2" ]] && return 0
        sleep 0.2
    done
    fail "cap_dropmods: the second window never arrived (saw $count flea clients)"
}
cap_dropmods_addr_of_pid() {
    [[ "$#" -eq 1 ]] || fail "cap_dropmods: addr needs a qs pid, got $#"
    hyprctl clients -j 2>/dev/null | jq -er --argjson pid "$1" \
        '[.[] | select(.class == "com.thisisgm.flea" and .pid == $pid)] | select(length == 1) | .[0].address' \
        || fail "cap_dropmods: no client address for qs pid $1"
}
# The ipc and key helpers of ui.sh answer for the newest window or refuse two, so a two-window phase reads each window through its own pid.
# Sample input: cap_dropmods_ipc 4242 rowAt 3 prints "b1.txt|..." from the window whose qs pid is 4242.
cap_dropmods_ipc() {
    [[ "$#" -ge 2 ]] || fail "cap_dropmods: ipc needs a pid and a method, got $#"
    local pid="$1"; shift
    timeout 3 qs ipc --pid "$pid" call flea "$@" 2>/dev/null
}
# The compositor's focused window, the one fact the newest-window ipc cannot tell.
cap_dropmods_active_pid() {
    hyprctl activewindow -j 2>/dev/null | jq -er '.pid' 2>/dev/null || printf unavailable
}
cap_dropmods_wait_total() {
    [[ "$#" -eq 2 ]] || fail "cap_dropmods: wait_total needs a pid and a total, got $#"
    local total="" flight="" end=$((SECONDS + cap_dropmods_wait_s))
    while (( SECONDS < end )); do
        total=$(cap_dropmods_ipc "$1" total || printf unavailable)
        flight=$(cap_dropmods_ipc "$1" listInFlight || printf unavailable)
        [[ "$total" == "$2" && "$flight" == "false" ]] && return 0
        sleep 0.05
    done
    fail "cap_dropmods: window $1 never settled at $2 rows, total=$total inFlight=$flight"
}
# Prints the screen centre of a named row of one window: its rowCentre plus that window's origin.
cap_dropmods_row_centre() {
    [[ "$#" -eq 2 ]] || fail "cap_dropmods: row_centre needs a pid and a name, got $#"
    local total i row cx cy wx wy ww wh
    total=$(cap_dropmods_ipc "$1" total) || fail "cap_dropmods: window $1 answers no total"
    [[ "$total" =~ ^[0-9]+$ ]] || fail "cap_dropmods: window $1 total is '$total'"
    for (( i = 0; i < total; i++ )); do
        row=$(cap_dropmods_ipc "$1" rowAt "$i")
        [[ "$row" == "$2|"* ]] || continue
        read -r cx cy <<< "$(cap_dropmods_ipc "$1" rowCentre "$i")"
        [[ "$cx" =~ ^-?[0-9]+$ && "$cy" =~ ^-?[0-9]+$ ]] || fail "cap_dropmods: window $1 row $2 has no centre"
        read -r wx wy ww wh <<< "$(cap_dropmods_box "$1")"
        printf '%s %s\n' "$((cx + wx))" "$((cy + wy))"
        return 0
    done
    fail "cap_dropmods: window $1 lists no row named $2 among $total"
}
# lastMessage of one window, so a message is read from the window that raised it.
cap_dropmods_wait_message() {
    [[ "$#" -eq 2 ]] || fail "cap_dropmods: wait_message needs a pid and a text, got $#"
    local seen="" end=$((SECONDS + cap_dropmods_message_s))
    while (( SECONDS < end )); do
        seen=$(cap_dropmods_ipc "$1" lastMessage || true)
        [[ "$seen" == "$2" ]] && return 0
        sleep 0.1
    done
    fail "cap_dropmods: window $1 never said: $2 (the last thing it said was: $seen)"
}
cap_dropmods_focus_pid() {
    [[ "$#" -eq 2 ]] || fail "cap_dropmods: focus needs a pid and a path, got $#"
    local addr seen
    addr=$(cap_dropmods_addr_of_pid "$1")
    hypr_window_focus "$addr" >/dev/null || fail "cap_dropmods: focuswindow $addr refused"
    sleep 0.4
    seen=$(cap_dropmods_active_pid)
    [[ "$seen" == "$1" ]] || fail "cap_dropmods: focus did not land on window $1 (the compositor focuses $seen)"
    seen=$(cap_dropmods_ipc "$1" path || printf unavailable)
    [[ "$seen" == "$2" ]] || fail "cap_dropmods: window $1 shows $seen, not $2"
}
case_cap_dropmods() {
    local dir="$fixture_root/cap-dropmods" dir2="$fixture_root/cap-dropmods-two"
    local src_pt dst_pt cx cy tx ty wx wy ww wh seen win1 win2 probe_log probe_box
    cap_dropmods_probe_pid=""
    trap cap_dropmods_cleanup EXIT
    sandbox_scratch "$dir"
    sandbox_scratch "$dir2"
    mkdir -p "$dir/sub" "$dir2/sub2"
    printf 'a one\n' > "$dir/a1.txt"
    printf 'a two\n' > "$dir/a2.txt"
    printf 'b one\n' > "$dir/b1.txt"
    printf 'b two\n' > "$dir/b2.txt"
    printf 'pad\n' > "$dir2/pad.txt"
    printf 'probe me\n' > "$dir/probe1.txt"
    printf 'probe me too\n' > "$dir/probe2.txt"
    seed_ui_state "$fixture_root/cap-dropmods-state" '{"keys":"default","view":"list"}'
    launch "$dir"
    wait_listing 7
    seek_row_named "a1.txt" || fail "cap_dropmods: a1.txt never came under the cursor"
    src_pt=$(ipc rowCentre "$(row_index_of a1.txt)"); read -r cx cy <<< "$src_pt"
    dst_pt=$(ipc rowCentre "$(row_index_of sub)"); read -r tx ty <<< "$dst_pt"
    cap_dropmods_mark
    cap_drops_press "$cx" "$cy"
    cap_drops_steer "$tx" "$ty"
    cap_dropmods_wait_line "Move 1 item to sub · ctrl at lift copies"
    cap_dropmods_key 29 1
    cap_drops_release
    cap_dropmods_key 29 0
    wait_message "Moved 1 item · z undoes"
    cap_dropmods_wait_gone "$dir/a1.txt"
    cap_dropmods_wait_file "$dir/sub/a1.txt"
    printf 'CAP_DROPMODS a1: same-window ctrl at drop keeps the lift move\n'
    wait_listing 6
    seek_row_named "a2.txt" || fail "cap_dropmods: a2.txt never came under the cursor"
    src_pt=$(ipc rowCentre "$(row_index_of a2.txt)"); read -r cx cy <<< "$src_pt"
    dst_pt=$(ipc rowCentre "$(row_index_of sub)"); read -r tx ty <<< "$dst_pt"
    cap_dropmods_key 29 1
    cap_dropmods_mark
    cap_drops_press "$cx" "$cy"
    cap_drops_steer "$tx" "$ty"
    cap_dropmods_wait_line "Copy 1 item to sub"
    cap_dropmods_key 29 0
    cap_dropmods_key 42 1
    cap_drops_release
    cap_dropmods_key 42 0
    wait_message "Copied 1 item · z undoes"
    cap_dropmods_wait_file "$dir/a2.txt"
    cap_dropmods_wait_file "$dir/sub/a2.txt"
    rm -f "$dir/sub/a2.txt"
    printf 'CAP_DROPMODS a2: same-window shift at drop keeps the ctrl-lift copy\n'
    wait_listing 6
    win1=$(flea_pid)
    cap_dropmods_launch_second "$dir2"
    win2=$(flea_pids | grep -vx "$win1" | head -n 1)
    [[ -n "$win2" ]] || fail "cap_dropmods: the second window has no surviving qs pid"
    cap_dropmods_wait_total "$win2" 2
    dst_pt=$(cap_dropmods_row_centre "$win2" sub2); read -r tx ty <<< "$dst_pt"
    cap_dropmods_wait_total "$win1" 6
    src_pt=$(cap_dropmods_row_centre "$win1" b1.txt); read -r cx cy <<< "$src_pt"
    cap_dropmods_focus_pid "$win1" "$dir"
    cap_dropmods_press_at "$cx" "$cy"
    cap_dropmods_steer_to "$tx" "$ty"
    sleep 0.5
    seen=$(cap_dropmods_active_pid)
    [[ "$seen" == "$win2" ]] || { cap_dropmods_abandon; fail "cap_dropmods: focus never followed the drag to window $win2 (the compositor focuses $seen), so no mid-drag key could reach it"; }
    cap_dropmods_key 29 1
    cap_dropmods_release
    cap_dropmods_key 29 0
    cap_dropmods_wait_message "$win2" "Copied 1 item · z undoes"
    cap_dropmods_wait_file "$dir/b1.txt"
    cap_dropmods_wait_file "$dir2/sub2/b1.txt"
    printf 'CAP_DROPMODS b1: cross-window ctrl at drop copies a plain lift\n'
    rm -f "$dir2/sub2/b1.txt"
    src_pt=$(cap_dropmods_row_centre "$win1" b2.txt); read -r cx cy <<< "$src_pt"
    dst_pt=$(cap_dropmods_row_centre "$win2" sub2); read -r tx ty <<< "$dst_pt"
    cap_dropmods_focus_pid "$win1" "$dir"
    cap_dropmods_key 29 1
    cap_dropmods_press_at "$cx" "$cy"
    cap_dropmods_steer_to "$tx" "$ty"
    sleep 0.5
    seen=$(cap_dropmods_active_pid)
    [[ "$seen" == "$win2" ]] || { cap_dropmods_abandon; fail "cap_dropmods: focus never followed the drag to window $win2 (the compositor focuses $seen), so no mid-drag key could reach it"; }
    cap_dropmods_key 29 0
    cap_dropmods_key 42 1
    cap_dropmods_release
    cap_dropmods_key 42 0
    cap_dropmods_wait_message "$win2" "Moved 1 item · z undoes"
    cap_dropmods_wait_file "$dir2/sub2/b2.txt"
    cap_dropmods_wait_gone "$dir/b2.txt"
    printf 'CAP_DROPMODS b2: cross-window shift at drop moves a ctrl lift\n'
    kill_flea
    launch "$dir"
    wait_listing 5
    probe_log="$run_root/dropprobe.log"
    qml6 "$repo/tests/dropmods-probe.qml" >"$probe_log" 2>&1 &
    cap_dropmods_probe_pid=$!
    local probe_end=$((SECONDS + 15)) probe_addr=""
    while (( SECONDS < probe_end )); do
        probe_addr=$(hyprctl clients -j 2>/dev/null | jq -er '[.[] | select(.title == "DropProbe")] | select(length == 1) | .[0].address' 2>/dev/null || printf "")
        [[ -n "$probe_addr" ]] && break
        sleep 0.2
    done
    [[ -n "$probe_addr" ]] || fail "cap_dropmods: the probe window never arrived"
    hypr_window_focus "$probe_addr" >/dev/null || fail "cap_dropmods: the probe window would not focus"
    sleep 0.3
    hypr_window_float "$probe_addr" on >/dev/null || fail "cap_dropmods: the probe window would not float"
    sleep 0.3
    read -r wx wy ww wh <<< "$(window_box)"
    hypr_window_move_absolute "$probe_addr" "$((wx + ww - 480))" "$((wy + wh - 360))" >/dev/null \
        || fail "cap_dropmods: the probe window would not park"
    sleep 0.5
    probe_box=$(hyprctl clients -j 2>/dev/null | jq -er '[.[] | select(.title == "DropProbe")] | select(length == 1) | .[0] | [.at[0] + .size[0] / 2, .at[1] + .size[1] / 2] | select(all(.[]; . == floor)) | @tsv' 2>/dev/null || printf "")
    [[ -n "$probe_box" ]] || fail "cap_dropmods: the probe window has no geometry to aim at"
    read -r tx ty <<< "$probe_box"
    cap_dropmods_focus_pid "$(flea_pid)" "$dir"
    seek_row_named "probe1.txt" || fail "cap_dropmods: probe1.txt never came under the cursor"
    src_pt=$(ipc rowCentre "$(row_index_of probe1.txt)"); read -r cx cy <<< "$src_pt"
    read -r wx wy ww wh <<< "$(window_box)"
    cap_dropmods_probe_clear_of "$((cx + wx))" "$((cy + wy))"
    cap_dropmods_mark
    cap_dropmods_press_at "$((cx + wx))" "$((cy + wy))"
    cap_dropmods_steer_to "$tx" "$ty"
    cap_dropmods_wait_line "Move 1 item to a folder · ctrl at lift copies"
    sleep 0.5
    cap_dropmods_release
    local offered1="" offered2=""
    probe_end=$((SECONDS + 10))
    while (( SECONDS < probe_end )); do
        offered1=$(grep -a "PROBE drop#1" "$probe_log" 2>/dev/null | sed -n 's/.*offered=\([0-9]*\) proposed=\([0-9]*\).*/\1 \2/p' | head -n 1 || printf "")
        [[ -n "$offered1" ]] && break
        sleep 0.2
    done
    [[ -n "$offered1" ]] || fail "cap_dropmods: the probe never logged the plain drop (log: $(head -c 500 "$probe_log" 2>/dev/null))"
    grep -aq "PROBE drop#1 .*formats=.*text/uri-list" "$probe_log" || fail "cap_dropmods: the plain drop carried no uri-list"
    grep -aq "PROBE drop#1 .*formats=.*application/x-flea-rows" "$probe_log" || fail "cap_dropmods: the plain drop carried no Flea marker"
    grep -aq "PROBE drop#1 chose=copy" "$probe_log" || fail "cap_dropmods: the plain drop chose no copy"
    printf 'CAP_DROPMODS c1: foreign drop offers %s\n' "$offered1"
    seek_row_named "probe2.txt" || fail "cap_dropmods: probe2.txt never came under the cursor"
    src_pt=$(ipc rowCentre "$(row_index_of probe2.txt)"); read -r cx cy <<< "$src_pt"
    read -r wx wy ww wh <<< "$(window_box)"
    cap_dropmods_probe_clear_of "$((cx + wx))" "$((cy + wy))"
    cap_dropmods_mark
    cap_dropmods_press_at "$((cx + wx))" "$((cy + wy))"
    cap_dropmods_steer_to "$tx" "$ty"
    cap_dropmods_wait_line "Move 1 item to a folder · ctrl at lift copies"
    sleep 0.5
    cap_dropmods_key 29 1
    cap_dropmods_release
    cap_dropmods_key 29 0
    probe_end=$((SECONDS + 10))
    while (( SECONDS < probe_end )); do
        offered2=$(grep -a "PROBE drop#2" "$probe_log" 2>/dev/null | sed -n 's/.*offered=\([0-9]*\) proposed=\([0-9]*\).*/\1 \2/p' | head -n 1 || printf "")
        [[ -n "$offered2" ]] && break
        sleep 0.2
    done
    [[ -n "$offered2" ]] || fail "cap_dropmods: the probe never logged the ctrl drop"
    printf 'CAP_DROPMODS c2: ctrl at drop offers %s\n' "$offered2"
    [[ "$offered1" == "1 1" ]] || fail "cap_dropmods: the plain lift offered $offered1, not the copy singleton 1 1"
    [[ "$offered2" == "$offered1" ]] || fail "cap_dropmods: the ctrl drop changed the platform offer to $offered2, so the freeze the root cause states did not hold"
    grep -aq "PROBE drop#2 chose=copy" "$probe_log" || fail "cap_dropmods: the ctrl drop chose no copy"
    printf 'CAP_DROPMODS settings=off a1=lift-move a2=lift-copy b1=drop-copy b2=drop-move c=frozen-offer\n'
    cap_dropmods_cleanup
    trap - EXIT
    kill_flea
}
