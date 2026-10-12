# Sourced by ui.sh beside the other capture files, but kept out of the default wanted
# list: it runs only by name. Drops: hover-open with the setting on, edge autoscroll, the
# pasted image; the FAT names card needs a FAT mount, so it is a controller-driven skip.
# needs a FAT mount, driven by the controller
. "$repo/tests/lib/pointer-glide.sh"
cap_drops_fat_skip() {
    printf 'CAP SKIP fat-card: needs a FAT mount, driven by the controller\n'
    return 0
}
# The EXIT trap a hold chains: release the button, then run the trap that was set before the press.
cap_drops_exit_chain() {
    local st=$?
    YDOTOOL_SOCKET="$XDG_RUNTIME_DIR/.ydotool_socket" ydotool click 0x80 >/dev/null 2>&1 || true
    [[ -n "${cap_drops_saved_trap:-}" ]] || return "$st"
    # trap -p prints: trap -- 'command' EXIT, so the quoted command is the third word.
    eval "set -- $cap_drops_saved_trap"
    # The saved trap reads $? for the status the script is exiting with, so hand it that status again.
    (exit "$st")
    eval "${3:-:}"
    return "$st"
}
# A press arms the release ahead of whatever EXIT trap exists, which keeps running after it.
cap_drops_arm() {
    [[ "${cap_drops_armed:-0}" == "1" ]] && return 0
    cap_drops_saved_trap=$(trap -p EXIT)
    trap cap_drops_exit_chain EXIT
    cap_drops_armed=1
}
# Put back the EXIT trap the press found; a trap a case installed over the chain since is left alone.
cap_drops_disarm() {
    if [[ "${cap_drops_armed:-0}" == "1" && "$(trap -p EXIT)" == *cap_drops_exit_chain* ]]; then
        if [[ -n "$cap_drops_saved_trap" ]]; then eval "$cap_drops_saved_trap"; else trap - EXIT; fi
    fi
    cap_drops_armed=0
    cap_drops_saved_trap=""
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
# A drag is in flight only once the listing says so; a shot before that is a shot of no drag.
cap_drops_wait_active() {
    local seen="" end=$((SECONDS + 15))
    while (( SECONDS < end )); do
        seen=$(ipc listingDropActive 2>/dev/null || printf unavailable)
        [[ "$seen" == "true" ]] && return 0
        sleep 0.1
    done
    fail "cap_drops: no drag in flight over the listing, saw $seen"
}
# One pasted copy is undone and the copy is awaited away, so the next leg starts clean.
cap_drops_undo_copy() {
    [[ "$#" -eq 1 ]] || fail "cap_drops: undo_copy needs a path, got $#"
    local gone="$1" end=$((SECONDS + 15))
    key z >/dev/null
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
# GLib trashes into the data home only for a file on HOME's own device, whatever XDG_DATA_HOME names, else into the mount top's trash.
cap_drops_trash_dirs() {
    [[ "$#" -eq 1 ]] || fail "cap_drops: trash_dirs needs a directory, got $#"
    local top uid
    if [[ "$(stat -c %d -- "$1")" == "$(stat -c %d -- "$HOME")" ]]; then
        printf '%s\n' "$XDG_DATA_HOME/Trash"
        return 0
    fi
    top=$(stat -c %m -- "$1") || fail "cap_drops: no mount top for $1"
    top=${top%/}
    uid=$(id -u)
    printf '%s\n' "$top/.Trash/$uid" "$top/.Trash-$uid"
}
# Prints the trash that holds the name for a file lifted from the directory, and fails when none does.
cap_drops_trash_holding() {
    [[ "$#" -eq 2 ]] || fail "cap_drops: trash_holding needs a directory and a name, got $#"
    local trash
    while IFS= read -r trash; do
        if [[ -s "$trash/files/$2" ]]; then printf '%s\n' "$trash"; return 0; fi
    done < <(cap_drops_trash_dirs "$1")
    return 1
}
# Removes only the case's own trashed name: its trashinfo Path must be exactly the file the case lifted from its marked directory.
cap_drops_trash_remove() {
    [[ "$#" -eq 2 ]] || fail "cap_drops: trash_remove needs a directory and a name, got $#"
    local dir="$1" name="$2" trash path top
    [[ -n "$name" && "$name" != */* && "$dir" == /*/* && -f "${dir%/*}/$SANDBOX_MARKER" ]] || return 1
    sandbox_require "$dir"
    trash=$(cap_drops_trash_holding "$dir" "$name") || return 0
    # Names here hold letters, digits, spaces, hyphens and dots, so a space is the one escape trashinfo carries.
    path=$(sed -n 's/^Path=//p' "$trash/info/$name.trashinfo" 2>/dev/null | head -n 1)
    path=${path//%20/ }
    if [[ "$path" != /* ]]; then
        top=$(stat -c %m -- "$dir")
        path="${top%/}/$path"
    fi
    [[ "$path" == "$dir/$name" ]] || return 1
    rm -f -- "$trash/files/$name" "$trash/info/$name.trashinfo"
}
# The case's EXIT trap: a pasted image left in a shared mount-top trash is taken out even when the case fails.
cap_drops_trash_exit() {
    local st=$?
    if [[ -n "${cap_drops_pasted:-}" ]] && ! cap_drops_trash_remove "$cap_drops_dir" "$cap_drops_pasted"; then
        printf 'CAP DROPS trashed %s was not removed\n' "$cap_drops_pasted" >&2
    fi
    return "$st"
}
case_cap_drops() {
    local dir="$fixture_root/cap-drops" menus_checks=0 cap_drops_wx=0 cap_drops_wy=0
    local i src_pt dst_pt cx cy tx ty count target names index ax ay aw ah img
    sandbox_scratch "$dir"
    cap_drops_dir=$dir
    cap_drops_pasted=""
    trap cap_drops_trash_exit EXIT
    mkdir -p "$dir/Photos" "$dir/deep/outer/inner"
    printf 'drag me\n' > "$dir/a.txt"
    printf 'p one\n' > "$dir/Photos/p1.txt"
    printf 'p two\n' > "$dir/Photos/p2.txt"
    printf 'note\n' > "$dir/deep/outer/inner/note.txt"
    for i in $(seq -w 1 200); do printf 'pad\n' > "$dir/pad-$i.txt"; done
    seed_ui_state "$fixture_root/cap-drops-state" '{"keys":"default","view":"list"}'
    # On a box whose fixture shares HOME's device the pasted image's Delete goes to this data home, never the operator's.
    export XDG_DATA_HOME="$fixture_root/cap-drops-data"
    sandbox_scratch "$XDG_DATA_HOME"
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
    cap_drops_pasted=$(basename "$img")
    cap_drops_wait_rename "$cap_drops_pasted"
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
    cap_drops_trash_holding "$dir" "$cap_drops_pasted" >/dev/null || fail "cap_drops: the pasted image landed in none of: $(cap_drops_trash_dirs "$dir" | tr '\n' ' ')"
    cap_drops_trash_remove "$dir" "$cap_drops_pasted" || fail "cap_drops: the trashed pasted image is not this case's own file"
    cap_drops_pasted=""
    seek_row_named "a.txt" || fail "cap_drops: a.txt never came under the cursor"
    src_pt=$(cap_drops_centre rowCentre "$(row_index_of a.txt)")
    dst_pt=$(cap_drops_centre rowCentre "$(row_index_of Photos)")
    read -r cx cy <<< "$src_pt"
    read -r tx ty <<< "$dst_pt"
    cap_drops_press "$cx" "$cy"
    cap_drops_steer "$tx" "$ty"
    cap_drops_wait_active
    shot drops-drop-target
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
    cap_drops_wait_active
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
    cap_drops_wait_active
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
    [[ "$(ipc columnNames child)" == *"p1.txt"* ]] || fail "cap_drops: the child column never listed p1.txt"
    names=$(ipc columnNames parent)
    index=$(printf '%s' "$names" | tr '|' '\n' | grep -nx "deep" | head -n 1 | cut -d: -f1 || true)
    [[ -n "$index" ]] || fail "cap_drops: the parent column never listed deep: $names"
    dst_pt=$(cap_drops_centre columnParentRowCentre "$((index - 1))")
    src_pt=$(cap_drops_centre columnChildRowCentre 0)
    read -r tx ty <<< "$dst_pt"
    read -r cx cy <<< "$src_pt"
    cap_drops_press "$cx" "$cy"
    cap_drops_steer "$tx" "$ty"
    cap_drops_wait_active
    shot drops-columns-parent
    names=$(ipc columnNames child)
    index=$(printf '%s' "$names" | tr '|' '\n' | grep -nx "p2.txt" | head -n 1 | cut -d: -f1 || true)
    [[ -n "$index" ]] || { cap_drops_abandon; fail "cap_drops: the child column lost p2.txt"; }
    dst_pt=$(cap_drops_centre columnChildRowCentre "$((index - 1))")
    read -r tx ty <<< "$dst_pt"
    cap_drops_steer "$tx" "$ty"
    cap_drops_release
    [[ ! -e "$dir/deep/p1.txt" ]] || fail "cap_drops: the columns release moved p1.txt"
    [[ -f "$dir/Photos/p1.txt" ]] || fail "cap_drops: the columns leg lost p1.txt"
    cap_drops_fat_skip
    wl-copy --clear >/dev/null 2>&1 || true
    trap - EXIT
    printf 'CAP_DROPS settings=off,on pasted=image target=held hover=open scroll=band crumb=held columns=held fat=skip\n'
    kill_flea
}
