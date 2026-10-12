#!/usr/bin/env bash
# Sourced by ui.sh, runs only by name: Tab walks the ring through the chrome bar and the tab strip, Ctrl+4 is Dual, Ctrl+Shift+Z is redo.
# shellcheck disable=SC2154 # ui.sh supplies the fixture root and the native driver helpers.
keyreach_tab() {
    key -k Tab >/dev/null
    settle
}
keyreach_expect() {
    local want="$1" why="$2" got
    got=$(ipc focusStop)
    [[ "$got" == "$want" ]] || fail "keyreach: $why: the keyboard is on '$got', not '$want'"
}
case_keyreach() {
    local dir="$fixture_root/keyreach" tabs
    sandbox_scratch "$dir"
    mkdir "$dir/sub"
    printf 'one\n' > "$dir/note.txt"
    printf 'two\n' > "$dir/other.txt"
    seed_ui_state "$fixture_root/keyreach-state" '{"keys":"default","view":"list"}'
    launch "$dir"
    wait_listing 3
    settle
    echo "-- one tab: list, rail, chrome bar, list --"
    keyreach_tab; keyreach_expect rail "Tab from the list"
    keyreach_tab; keyreach_expect "chrome:arrow-up" "Tab from the rail"
    shot keyreach-chrome-back
    keyreach_tab; keyreach_expect list "a strip of one tab is no stop"
    echo "-- two tabs: the strip joins the ring --"
    click_row 0 left
    settle
    key -M ctrl -k Return -m ctrl >/dev/null
    for _attempt in $(seq 1 40); do [[ "$(ipc tabCount)" == "2" ]] && break; sleep 0.25; done
    tabs=$(ipc tabCount)
    [[ "$tabs" == "2" ]] || fail "keyreach: Ctrl+Return opened $tabs tabs, not 2"
    settle
    keyreach_tab; keyreach_tab; keyreach_tab
    keyreach_expect "strip:$(ipc tabIndex)" "Tab from the bar"
    shot keyreach-tab
    keyreach_tab; keyreach_expect list "Tab from the strip"
    key -M shift -k Tab -m shift >/dev/null
    settle
    keyreach_expect "strip:2" "Shift+Tab from the list"
    key -k Escape >/dev/null
    settle
    keyreach_expect list "Escape from the strip"
    echo "-- Right Arrow from a rail row to its eject mark --"
    keyreach_tab
    key -k Right >/dev/null
    settle
    shot keyreach-rail-eject
    key -k Escape >/dev/null
    settle
    echo "-- Ctrl+4 is Dual --"
    key -k Escape >/dev/null
    key -M ctrl -k 4 -m ctrl >/dev/null
    settle
    [[ "$(ipc dualState | jq -r .active)" == "true" ]] || fail "keyreach: Ctrl+4 did not open the dual view"
    keyreach_tab
    keyreach_tab
    shot keyreach-chrome-dual
    key -M ctrl -k 1 -m ctrl >/dev/null
    settle
    echo "-- Ctrl+Shift+Z redoes an undone rename --"
    click_row "$(row_index_of note.txt)" left
    settle
    key r >/dev/null
    settle
    printf '%s' "renamed" | omarchy-drive key --window flea - >/dev/null || fail "keyreach: typing the new name failed"
    key -k Return >/dev/null
    for _attempt in $(seq 1 40); do [[ -e "$dir/renamed" || -e "$dir/renamed.txt" ]] && break; sleep 0.25; done
    [[ -e "$dir/renamed.txt" ]] || fail "keyreach: the rename never landed"
    key z >/dev/null
    for _attempt in $(seq 1 40); do [[ -e "$dir/note.txt" ]] && break; sleep 0.25; done
    [[ -e "$dir/note.txt" && ! -e "$dir/renamed.txt" ]] || fail "keyreach: z did not undo the rename"
    key -M ctrl -M shift -k z -m shift -m ctrl >/dev/null
    for _attempt in $(seq 1 40); do [[ -e "$dir/renamed.txt" ]] && break; sleep 0.25; done
    [[ -e "$dir/renamed.txt" && ! -e "$dir/note.txt" ]] || fail "keyreach: Ctrl+Shift+Z did not redo the rename"
    printf 'KEYREACH ok\n'
    kill_flea
}
