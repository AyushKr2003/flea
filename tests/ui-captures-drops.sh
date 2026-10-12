# Sourced by ui.sh, runs only by name: drops hover-open with the setting on, edge autoscroll and the pasted image; the FAT names card is a controller-driven skip.
. "$repo/tests/lib/pointer-glide.sh"
cap_drops_fat_skip() {
    printf 'CAP SKIP fat-card: needs a FAT mount, driven by the controller\n'
    return 0
}
# Chain the release ahead of the EXIT command in force, so an exit mid-hold releases the button, then runs it as saved.
cap_drops_arm() {
    [[ "${cap_drops_held:-0}" == "1" ]] && return 0
    eval "set -- $(trap -p EXIT)"
    cap_drops_saved_exit=${3-}
    trap 'YDOTOOL_SOCKET="$XDG_RUNTIME_DIR/.ydotool_socket" ydotool click 0x80 >/dev/null 2>&1 || true; '"$cap_drops_saved_exit" EXIT
    cap_drops_held=1
}
# Put back the exact EXIT command cap_drops_arm saved.
cap_drops_disarm() {
    [[ "${cap_drops_held:-0}" == "1" ]] || return 0
    if [[ -n "$cap_drops_saved_exit" ]]; then trap -- "$cap_drops_saved_exit" EXIT; else trap - EXIT; fi
    cap_drops_held=0
}
# Press the pointer onto a window-relative point and hold it; the caller shots, then releases.
cap_drops_press() {
    [[ "$#" -eq 2 ]] || fail "cap_drops: press needs x and y, got $#"
    local wx wy ww wh
    read -r wx wy ww wh < <(window_box) || fail "cap_drops: native window coordinates unavailable"
    assert_focus
    cap_drops_wx=$wx
    cap_drops_wy=$wy
    # Through ydotool, never Hyprland's move, which sends Qt no pointer frame.
    pointer_glide "$((wx + $1))" "$((wy + $2))" || fail "cap_drops: pointer move failed"
    sleep 0.2
    YDOTOOL_SOCKET="$XDG_RUNTIME_DIR/.ydotool_socket" ydotool click 0x40 >/dev/null 2>&1 || fail "cap_drops: pointer press failed"
    cap_drops_arm
}
# Steer a held press onto a window-relative point through the same uinput glide as the press.
cap_drops_steer() {
    [[ "$#" -eq 2 ]] || fail "cap_drops: steer needs x and y, got $#"
    pointer_glide "$((cap_drops_wx + $1))" "$((cap_drops_wy + $2))" || { cap_drops_abandon; fail "cap_drops: the drag never reached [$1,$2]"; }
}
# Release a held press without failing, so a failure path never leaves the button down.
cap_drops_abandon() {
    YDOTOOL_SOCKET="$XDG_RUNTIME_DIR/.ydotool_socket" ydotool click 0x80 >/dev/null 2>&1 || true
    cap_drops_disarm
}
# Release a held press and settle; a drop that collided is cancelled before it can act.
cap_drops_release() {
    YDOTOOL_SOCKET="$XDG_RUNTIME_DIR/.ydotool_socket" ydotool click 0x80 >/dev/null 2>&1 || fail "cap_drops: pointer release failed"
    cap_drops_disarm
    settle
    if [[ "$(ipc collideState | jq -r .opened)" == "true" ]]; then key -k Escape >/dev/null; settle; fi
}
# Seconds a drag-line or undo wait polls; statusActivityState prints {"activities":[{"id":0,"text":"Copy 1 item to sub","running":false,...}],...}, a drag line always id 0.
cap_drops_wait_s=15
# A row, a crumb or a column under the drag takes it above the floor and keeps the floor signal dark, so the status line a drag shows there, in the target's own words, is the hover.
cap_drops_wait_target() {
    [[ "$#" -eq 1 ]] || fail "cap_drops: wait_target needs the drag line, got $#"
    local want="$1" seen="" end=$((SECONDS + cap_drops_wait_s))
    while (( SECONDS < end )); do
        seen=$(ipc statusActivityState 2>/dev/null | jq -r --arg w "$want" '.activities[] | select(.id == 0 and .running == false and .text == $w) | .text' 2>/dev/null | head -n 1 || true)
        [[ -n "$seen" ]] && return 0
        sleep 0.1
    done
    seen=$(ipc statusActivityState 2>/dev/null | jq -r '[.activities[] | select(.running == false) | .text] | join(" | ")' 2>/dev/null || true)
    # A case holding the pointer names its release here, so a timeout never leaves the drag held.
    "${cap_drops_wait_abort:-:}"
    fail "cap_drops: no drag line reading \"$want\" (status lines: ${seen:-none})"
}
# One dropped file is awaited in, undone and awaited away, so the next leg starts clean.
cap_drops_undo_copy() {
    [[ "$#" -eq 1 ]] || fail "cap_drops: undo_copy needs a path, got $#"
    local gone="$1" end=$((SECONDS + cap_drops_wait_s))
    while (( SECONDS < end )); do [[ -e "$gone" ]] && break; sleep 0.1; done
    [[ -e "$gone" ]] || fail "cap_drops: the drop never landed $gone, so z has no drop to undo (said $(ipc lastMessage 2>/dev/null); found at $(find "$fixture_root" -maxdepth 3 -name "$(basename "$gone")" | tr '\n' ' '))"
    key z >/dev/null
    end=$((SECONDS + cap_drops_wait_s))
    while (( SECONDS < end )); do
        [[ ! -e "$gone" ]] && return 0
        sleep 0.1
    done
    fail "cap_drops: undo left $gone behind"
}
# Total and settled only: after a paste the view parks on the rename row, so row 0 has no delegate for wait_listing.
cap_drops_wait_settled() {
    [[ "$#" -eq 1 ]] || fail "cap_drops: wait_settled needs a total, got $#"
    local want="$1" total="" flight="" end=$((SECONDS + 15))
    while (( SECONDS < end )); do
        total=$(ipc total 2>/dev/null || printf unavailable)
        flight=$(ipc listInFlight 2>/dev/null || printf unavailable)
        [[ "$total" == "$want" && "$flight" == "false" ]] && return 0
        sleep 0.05
    done
    fail "cap_drops: listing never settled at $want, total=$total inFlight=$flight message=$(ipc lastMessage 2>/dev/null) collide=$(ipc collideState 2>/dev/null | jq -c '{opened, title}' 2>/dev/null)"
}
# A paste names its file through the rename editor it opens on arrival, which is the state the shot needs.
cap_drops_wait_rename() {
    [[ "$#" -eq 1 ]] || fail "cap_drops: wait_rename needs a name, got $#"
    local want="$1" live="" text="" end=$((SECONDS + 15))
    while (( SECONDS < end )); do
        live=$(ipc renameEditorLive 2>/dev/null || printf false)
        text=$(ipc renameEditorText 2>/dev/null || printf "")
        [[ "$live" == "true" && "$text" == "$want"* ]] && return 0
        sleep 0.05
    done
    fail "cap_drops: rename never opened on $want, live=$live text=$text"
}
# A window-relative centre is read only once it exists; read on empty aborts the case silent.
cap_drops_centre() {
    [[ "$#" -eq 2 ]] || fail "cap_drops: centre needs a reader and a row, got $#"
    local reader="$1" arg="$2" point=""
    point=$(ipc "$reader" "$arg" 2>/dev/null || true)
    [[ -n "$point" ]] || fail "cap_drops: $reader $arg has no centre"
    printf '%s\n' "$point"
}
# Makes the Flea HOME and data home for the case's trash, and fails unless both sit on the folder's device, which is what decides GLib's trash (g_local_file_trash, glocalfile.c).
cap_drops_trash_home() {
    [[ "$#" -eq 3 ]] || fail "cap_drops: trash_home needs a folder, a home and a data home, got $#"
    local dir="$1" home="$2" data="$3" dir_dev home_dev data_dev
    fixture_home_make "$home"
    sandbox_scratch "$data"
    dir_dev=$(stat -c %d "$dir") || fail "cap_drops: stat could not read the device of $dir"
    home_dev=$(stat -c %d "$home") || fail "cap_drops: stat could not read the device of $home"
    data_dev=$(stat -c %d "$data") || fail "cap_drops: stat could not read the device of $data"
    [[ "$home_dev" == "$dir_dev" ]] || fail "cap_drops: the Flea HOME $home is on device $home_dev and the folder $dir on device $dir_dev, so GLib would trash the pasted image into that mount's own trash and not into the case's."
    [[ "$data_dev" == "$dir_dev" ]] || fail "cap_drops: the data home $data is on device $data_dev and the folder $dir on device $dir_dev, so GLib could not move the pasted image into the case's trash."
}
case_cap_drops() {
    local dir="$fixture_root/cap-drops" menus_checks=0 cap_drops_wx=0 cap_drops_wy=0
    local i src_pt dst_pt cx cy tx ty count target names index ax ay aw ah img
    sandbox_scratch "$dir"
    mkdir -p "$dir/Photos" "$dir/deep/outer/inner"
    printf 'drag me\n' > "$dir/a.txt"
    printf 'p one\n' > "$dir/Photos/p1.txt"
    printf 'p two\n' > "$dir/Photos/p2.txt"
    printf 'note\n' > "$dir/deep/outer/inner/note.txt"
    for i in $(seq -w 1 200); do printf 'pad\n' > "$dir/pad-$i.txt"; done
    seed_ui_state "$fixture_root/cap-drops-state" '{"keys":"default","view":"list"}'
    # The pasted image's Delete goes to this case's own trash, never the operator's: GLib takes $XDG_DATA_HOME/Trash only for a file on $HOME's device, so Flea gets a HOME on the fixture's.
    local fixture_home="$fixture_root/cap-drops-home" data_home="$fixture_root/cap-drops-data"
    local -a flea_launch_wrap=(env "HOME=$fixture_home" "XDG_DATA_HOME=$data_home")
    cap_drops_trash_home "$dir" "$fixture_home" "$data_home"
    launch "$dir"
    wait_listing 203
    cap_resize 1100 700
    settings_open_key
    settle
    settings_section view
    [[ "$(ipc settingsRows)" == *"Open folders while dragging"* ]] || fail "cap_drops: View lists no Open folders while dragging"
    [[ "$(ipc settingsModel | jq -er '[.[] | select(.id == "openFoldersWhileDragging")][0].on')" == "false" ]] || fail "cap_drops: Open folders while dragging ships on"
    shot drops-settings-view
    settings_click_control "openFoldersWhileDragging"
    settings_wait_value '.openFoldersWhileDragging == true'
    shot drops-settings-on
    key -k Escape >/dev/null
    settle
    wl-copy --clear >/dev/null 2>&1 || fail "cap_drops: wl-copy could not clear the clipboard"
    printf '%s' "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==" | base64 -d > "$dir/.seed.png" || fail "cap_drops: the seed PNG could not be written"
    wl-copy --type image/png < "$dir/.seed.png" >/dev/null 2>&1 || fail "cap_drops: wl-copy could not seed an image"
    key p >/dev/null
    img=""
    for i in $(seq 1 100); do img=$(ls -t "$dir"/Pasted\ image*.png 2>/dev/null | head -n 1); [[ -n "$img" ]] && break; sleep 0.1; done
    [[ -n "$img" ]] || fail "cap_drops: p with an image on the clipboard pasted no file"
    cap_drops_wait_rename "$(basename "$img")"
    [[ "$(ipc renameState | jq -r .selectedText)" == "$(basename "$img" .png)" ]] || fail "cap_drops: rename selects '$(ipc renameState | jq -r .selectedText)', not the stem"
    shot drops-pasted-image
    key -k Escape >/dev/null
    settle
    key g >/dev/null
    settle
    wait_listing 204
    seek_row_named "$(basename "$img")" || fail "cap_drops: the pasted image never came under the cursor"
    key -k Delete >/dev/null
    settle
    cap_drops_wait_settled 203
    [[ -s "$data_home/Trash/files/$(basename "$img")" ]] || fail "cap_drops: the pasted image did not land in $data_home/Trash/files"
    seek_row_named "a.txt" || fail "cap_drops: a.txt never came under the cursor"
    src_pt=$(cap_drops_centre rowCentre "$(row_index_of a.txt)")
    dst_pt=$(cap_drops_centre rowCentre "$(row_index_of Photos)")
    read -r cx cy <<< "$src_pt"
    read -r tx ty <<< "$dst_pt"
    cap_drops_press "$cx" "$cy"
    cap_drops_steer "$tx" "$ty"
    cap_drops_wait_target "Move 1 item to Photos · ctrl at lift copies"
    # The setting is on, so a rest of 700 ms (DragOut.OPEN_MS) opens Photos; one ipc round trip alone is 190 to 565 ms, so a steer to the same point (a move restarts the rest) leaves the shot and then the release their own 700 ms.
    cap_drops_steer "$tx" "$ty"
    shot drops-drop-target
    cap_drops_steer "$tx" "$ty"
    cap_drops_release
    cap_drops_undo_copy "$dir/Photos/a.txt"
    wait_listing 203
    seek_row_named "a.txt" || fail "cap_drops: a.txt never came back under the cursor"
    src_pt=$(cap_drops_centre rowCentre "$(row_index_of a.txt)")
    dst_pt=$(cap_drops_centre rowCentre "$(row_index_of Photos)")
    read -r cx cy <<< "$src_pt"
    read -r tx ty <<< "$dst_pt"
    cap_drops_press "$cx" "$cy"
    cap_drops_steer "$tx" "$ty"
    cap_drops_wait_target "Move 1 item to Photos · ctrl at lift copies"
    wait_path "$dir/Photos"
    shot drops-hover-open
    cap_drops_release
    cap_drops_undo_copy "$dir/Photos/a.txt"
    key -k BackSpace >/dev/null
    wait_path "$dir"
    cap_drops_wait_settled 203
    key g >/dev/null
    for i in $(seq 1 100); do [[ "$(ipc viewContentY)" == "0" ]] && break; sleep 0.05; done
    [[ "$(ipc viewContentY)" == "0" ]] || fail "cap_drops: the listing did not start at the top"
    seek_row_named "a.txt" || fail "cap_drops: a.txt never came under the cursor for the scroll"
    src_pt=$(cap_drops_centre rowCentre "$(row_index_of a.txt)")
    read -r cx cy <<< "$src_pt"
    read -r ax ay aw ah <<< "$(ipc listAreaRect)"
    cap_drops_press "$cx" "$cy"
    cap_drops_steer "$((ax + aw / 2))" "$((ay + ah - 10))"
    for i in $(seq 1 100); do [[ "$(ipc viewContentY)" != "0" ]] && break; sleep 0.1; done
    [[ "$(ipc viewContentY)" != "0" ]] || { cap_drops_abandon; fail "cap_drops: the bottom band never scrolled"; }
    shot drops-autoscroll
    cap_drops_steer "$((ax + aw / 2))" "$((ay + 10))"
    cap_drops_release
    [[ -f "$dir/a.txt" ]] || fail "cap_drops: the scroll leg lost a.txt"
    key g >/dev/null
    settle
    seek_row_named "deep" || fail "cap_drops: deep never came under the cursor"
    key -k Return >/dev/null
    wait_path "$dir/deep"
    seek_row_named "outer" || fail "cap_drops: outer never came under the cursor"
    key -k Return >/dev/null
    wait_path "$dir/deep/outer"
    seek_row_named "inner" || fail "cap_drops: inner never came under the cursor"
    key -k Return >/dev/null
    wait_path "$dir/deep/outer/inner"
    wait_listing 1
    count=$(ipc crumbCount)
    [[ "$count" =~ ^[0-9]+$ && "$count" -ge 2 ]] || fail "cap_drops: inner shows no parent crumb"
    target=$((count - 2))
    dst_pt=$(cap_drops_centre crumbCentre "$target")
    src_pt=$(cap_drops_centre rowCentre 0)
    read -r tx ty <<< "$dst_pt"
    read -r cx cy <<< "$src_pt"
    cap_drops_press "$cx" "$cy"
    cap_drops_steer "$tx" "$ty"
    cap_drops_wait_target "Copy 1 item to outer/"
    shot drops-crumb
    read -r ax ay aw ah <<< "$(ipc listAreaRect)"
    cap_drops_steer "$((ax + aw / 2))" "$((ay + ah - 20))"
    cap_drops_release
    [[ ! -e "$dir/deep/outer/note.txt" ]] || fail "cap_drops: the crumb release moved note.txt"
    key -k BackSpace >/dev/null
    wait_path "$dir/deep/outer"
    key -k BackSpace >/dev/null
    wait_path "$dir/deep"
    key -k BackSpace >/dev/null
    wait_path "$dir"
    cap_drops_wait_settled 203
    seek_row_named "Photos" || fail "cap_drops: Photos never came under the cursor"
    key -k Return >/dev/null
    wait_path "$dir/Photos"
    wait_listing 2
    click_chrome columns
    settle
    [[ "$(ipc viewMode)" == "columns" ]] || fail "cap_drops: the chrome never reached columns"
    # Photos holds files only, so the child slot is undrawn; the active column lists p1.txt after its own read, so the check waits for it, up to 5 s.
    local child_end=$((SECONDS + 5))
    while index=$(row_index_of p1.txt 2>/dev/null); [[ -z "$index" ]] && (( SECONDS < child_end )); do sleep 0.1; done
    [[ -n "$index" ]] \
        || fail "cap_drops: the active column never listed p1.txt (parent '$(ipc columnNames parent)', path $(ipc path))"
    names=$(ipc columnNames parent)
    local deep_index
    deep_index=$(printf '%s' "$names" | tr '|' '\n' | grep -nx "deep" | head -n 1 | cut -d: -f1 || true)
    [[ -n "$deep_index" ]] || fail "cap_drops: the parent column never listed deep: $names"
    dst_pt=$(cap_drops_centre columnParentRowCentre "$((deep_index - 1))")
    src_pt=$(cap_drops_centre rowCentre "$index")
    printf 'CAP_DROPS columns src=%s active=%s cursor=%s\n' "$src_pt" "$(ipc columnActiveRect)" "$(ipc visibleRowName "$(ipc cursor)")"
    read -r tx ty <<< "$dst_pt"
    read -r cx cy <<< "$src_pt"
    cap_drops_press "$cx" "$cy"
    cap_drops_steer "$tx" "$ty"
    cap_drops_wait_target "Move 1 item to deep · ctrl at lift copies"
    shot drops-columns-parent
    index=$(row_index_of p2.txt 2>/dev/null) || { cap_drops_abandon; fail "cap_drops: the active column lost p2.txt"; }
    dst_pt=$(cap_drops_centre rowCentre "$index")
    read -r tx ty <<< "$dst_pt"
    cap_drops_steer "$tx" "$ty"
    cap_drops_release
    [[ ! -e "$dir/deep/p1.txt" ]] || fail "cap_drops: the columns release moved p1.txt"
    [[ -f "$dir/Photos/p1.txt" ]] || fail "cap_drops: the columns leg lost p1.txt"
    cap_drops_fat_skip
    wl-copy --clear >/dev/null 2>&1 || true
    printf 'CAP_DROPS settings=off,on pasted=image target=held hover=open scroll=band crumb=held columns=held fat=skip\n'
    kill_flea
}
