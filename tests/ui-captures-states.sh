#!/usr/bin/env bash
# Native captures for held Columns heroes, system refusals, grid reveal and Columns rename; sourced by ui.sh.
# shellcheck disable=SC2154 # ui.sh supplies the fixture root, the native driver and the shared helpers.

# The entrance fade's own duration token is ui/js/Motion.js durMs.open, so a shot never lands mid fade.
heldcolumns_fade_wait() {
    local open_ms wait_s
    open_ms=$(sed -n 's/^ *open: \([0-9][0-9]*\).*/\1/p' "$repo/ui/js/Motion.js" | head -1)
    [[ "$open_ms" =~ ^[0-9]+$ ]] || fail "heldcolumns: Motion durMs.open is unreadable"
    wait_s=$(awk -v ms="$open_ms" 'BEGIN { printf "%.2f", ms * 2 / 1000 + 0.2 }')
    sleep "$wait_s"
}

# Recording stubs for the release tools: they log their argv and refuse, so the case fails if one runs.
cap_sysrefusal_write_stubs() {
    local bindir="$1" log="$2" tool
    for tool in gio udisksctl umount; do
        cat > "$bindir/$tool" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >> "$log"
exit 1
EOS
        chmod +x "$bindir/$tool"
    done
}

# Columns heroes for a held listing and a denied folder, at 2 to 5 columns.
case_cap_heldcolumns() {
    local dir listing markers real_bin n seen read_by estate err_by denied
    dir="$fixture_root/cap-heldcolumns"
    listing="$dir/listing"
    markers="$dir/markers"
    real_bin="$flea_bin"
    sandbox_scratch "$dir"
    mkdir -p "$listing" "$markers"
    : > "$listing/one.txt"
    : > "$listing/two.txt"
    hanglisting_write_proxy "$dir/flea-proxy"
    trap 'chmod 700 "$dir"/denied-* 2>/dev/null; kill_flea' EXIT
    for n in 2 3 4 5; do
        seed_ui_state "$fixture_root/cap-heldcolumns-state-$n" '{"view":"columns","columnsLimit":'"$n"'}'
        export FLEA_HANGLISTING_REAL="$real_bin" FLEA_HANGLISTING_DELAY=15 FLEA_HANGLISTING_MARKER="$markers/held-$n"
        flea_bin="$dir/flea-proxy"
        launch "$listing"
        flea_bin="$real_bin"
        wait_marker "$markers/held-$n" "heldcolumns: limit $n never held its listing"
        seen=""
        read_by=$(( $(date +%s%3N) + 10000 ))
        while (( $(date +%s%3N) < read_by )); do
            seen=$(ipc state 2>/dev/null || true)
            [[ "$seen" == "loading" ]] && break
            sleep 0.1
        done
        [[ "$seen" == "loading" ]] || fail "heldcolumns: limit $n never read loading, state is $seen"
        [[ "$(ipc viewMode)" == "columns" ]] || fail "heldcolumns: limit $n opened in $(ipc viewMode), not columns"
        # Past the 150 ms hold-off, before the 10 s deadline.
        sleep 1
        [[ "$(ipc state)" == "loading" ]] || fail "heldcolumns: limit $n left loading before its reading shot"
        heldcolumns_fade_wait
        shot "heldcolumns-$n-reading"
        wait_pane_waiting heldcolumns
        [[ "$(ipc stateMessage)" == "That folder is not responding." ]] || fail "heldcolumns: limit $n spoke $(ipc stateMessage)"
        heldcolumns_fade_wait
        shot "heldcolumns-$n-waiting"
        wait_listing 2
        [[ "$(ipc path)" == "$listing" ]] || fail "heldcolumns: limit $n landed at $(ipc path)"
        [[ -z "$(ipc stateMessage)" ]] || fail "heldcolumns: limit $n kept $(ipc stateMessage)"
        kill_flea
        denied="$dir/denied-$n"
        mkdir -p "$denied"
        chmod 000 "$denied" || fail "heldcolumns: limit $n denied setup failed"
        seed_ui_state "$fixture_root/cap-heldcolumns-denied-$n" '{"view":"columns","columnsLimit":'"$n"'}'
        launch "$denied"
        estate=""
        err_by=$(( $(date +%s%3N) + 15000 ))
        while (( $(date +%s%3N) < err_by )); do
            estate=$(ipc state 2>/dev/null || true)
            [[ "$estate" == "locked" || "$estate" == "error" ]] && break
            sleep 0.2
        done
        # A denied scan answers locked, never error, per ui/js/Errors.js denied.
        [[ "$estate" == "locked" ]] || fail "heldcolumns: limit $n denied state is $estate"
        [[ "$(ipc stateMessage)" == "Permission denied" ]] || fail "heldcolumns: limit $n denied sentence is $(ipc stateMessage)"
        heldcolumns_fade_wait
        shot "heldcolumns-$n-error"
        chmod 700 "$denied" || fail "heldcolumns: limit $n denied restore failed"
        kill_flea
        printf 'HELDCOLUMNS limit=%s reading=ok waiting=ok error-denied=ok\n' "$n"
    done
    printf 'HELDCOLUMNS locked-dropped: the denied main-pane hero is shot per limit, and the child-column Locked tile exposes no IPC reader\n'
    trap - EXIT
    kill_flea
}

# System refusals through Ctrl+E: the volume sentence in a listing, the drive sentence on the rail.
case_cap_sysrefusal() {
    local dir listing stub_log saved_path entries label
    dir="$fixture_root/cap-sysrefusal"
    listing="$dir/listing"
    stub_log="$dir/stub.log"
    saved_path="$PATH"
    sandbox_scratch "$dir"
    mkdir -p "$listing" "$dir/bin"
    : > "$listing/one.txt"
    : > "$listing/two.txt"
    : > "$stub_log"
    cap_sysrefusal_write_stubs "$dir/bin" "$stub_log"
    export PATH="$dir/bin:$PATH"
    seed_ui_state "$fixture_root/cap-sysrefusal-state" '{"view":"list"}'
    launch "$listing"
    wait_listing 2
    key -M ctrl -k e -m ctrl >/dev/null
    wait_message "This folder is on a system volume, which Flea never unmounts."
    shot sysrefusal-listing
    entries=$(ipc railEntries) || fail "sysrefusal: the rail has no entries"
    label=$(jq -er '[.[] | select(.group == "device" and .kind == "disk") | .label] | first // empty' <<< "$entries") || fail "sysrefusal: the system disk row is unreadable"
    if [[ -z "$label" ]]; then
        printf 'CAP SKIP sysrefusal-rail: no system disk row on this box\n'
    else
        rail_focus
        key g >/dev/null
        settle
        rail_seek "$label"
        key -M ctrl -k e -m ctrl >/dev/null
        wait_message "$label is the system drive, which Flea never unmounts."
        shot sysrefusal-rail
    fi
    [[ ! -s "$stub_log" ]] || fail "sysrefusal: a release stub ran: $(cat "$stub_log")"
    export PATH="$saved_path"
    printf 'SYSREFUSAL listing=ok rail=%s stubs=silent\n' "$([[ -z "$label" ]] && printf skipped || printf ok)"
    kill_flea
}

# Grid cursor reveal by plain key moves past the fold, ending on End.
case_cap_gridreveal() {
    local dir menus_checks=0 index total guard
    dir="$fixture_root/cap-gridreveal"
    sandbox_scratch "$dir"
    : > "$dir/a.txt"
    : > "$dir/b.txt"
    for ((index = 0; index < 1200; index++)); do
        printf -v total '%s/f%04d.txt' "$dir" "$index"
        : > "$total"
    done
    seed_ui_state "$fixture_root/cap-gridreveal-state" '{"view":"list"}'
    launch "$dir"
    wait_listing 1202
    switch_view grid
    key -k Home >/dev/null
    menus_expect renameState '.cursor == 0' "gridreveal starts at the top"
    guard=0
    while [[ "$(ipc viewContentY)" == "0" ]]; do
        (( guard >= 400 )) && fail "gridreveal: 400 Downs never left the first screen"
        key -k Down >/dev/null
        guard=$((guard + 1))
    done
    rename_far_whole "gridreveal-down" "$(ipc cursor)"
    shot gridreveal-down
    key -k End >/dev/null
    rename_design_still
    menus_expect renameState '.cursorName == "f1199.txt"' "gridreveal End reaches the last tile"
    shot gridreveal-end
    printf 'GRIDREVEAL down=ok end=ok\n'
    kill_flea
}

# Rename ending in Columns with focus back on the active column.
case_cap_columnsrename() {
    local menu_box menu_dir menus_checks=0
    menu_box="$fixture_root/cap-columnsrename-box"
    menu_dir="$menu_box/listing"
    sandbox_scratch "$menu_box"
    printf 'native rename fixture\n' > "$menu_box/.flea-test-sandbox"
    mkdir -p "$menu_dir"
    printf 'original bytes\n' > "$menu_dir/a-original.md"
    printf 'existing bytes\n' > "$menu_dir/b-existing.md"
    : > "$menu_dir/c-third.md"
    seed_ui_state "$fixture_root/cap-columnsrename-state" '{"view":"columns"}'
    launch "$menu_dir"
    wait_listing 3
    [[ "$(ipc viewMode)" == "columns" ]] || fail "columnsrename: opened in $(ipc viewMode), not columns"
    key -k Home >/dev/null
    menus_expect renameState '.cursor == 0 and .cursorName == "a-original.md"' "columnsrename starts on the first file"
    key -k F2 >/dev/null
    menus_expect renameState '.index >= 0 and .focused and (.pending | not) and .error == ""' "columnsrename F2 opens the inline editor"
    key -M ctrl -k a -m ctrl -k BackSpace >/dev/null
    key "a-renamed.md" >/dev/null
    menus_guard "$menu_dir/a-original.md"
    menus_guard "$menu_dir/a-renamed.md"
    key -k Return >/dev/null
    wait_marker "$menu_dir/a-renamed.md" "columnsrename: the rename never wrote a-renamed.md"
    menus_expect renameState '.index == -1 and (.pending | not) and (.loading | not) and .cursorName == "a-renamed.md"' "columnsrename lands on the renamed file"
    menus_expect keyDeliveryState '(.paneFocus or .listFocus)' "columnsrename hands focus back to the active column"
    [[ -n "$(ipc columnActiveRect)" ]] || fail "columnsrename: the active column has no rectangle"
    shot columnsrename-ended
    printf 'COLUMNSRENAME landed=ok focus=ok\n'
    kill_flea
}
