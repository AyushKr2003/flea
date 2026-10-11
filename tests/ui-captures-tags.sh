# Tags and TagsThemes captures (slots, Tags row and flyout, toggles, rail, search, untagged).

# Sets one fixture file's tags through user.xdg.tags and reads them back.
cap_tags_set() {
    local file="$1" value="$2"
    [[ "$file" == "$fixture_root/"* ]] || fail "cap_tags: refusing a path outside the fixture root: $file"
    python3 - "$file" "$value" <<'EOF' || fail "cap_tags: user.xdg.tags did not land"
import os, sys
path, value = sys.argv[1], sys.argv[2]
os.setxattr(path, "user.xdg.tags", value.encode())
assert os.getxattr(path, "user.xdg.tags") == value.encode(), "read-back mismatch"
EOF
}

# needs a vfat or exfat mount, driven by the controller
cap_tags_skip_nosupport() {
    printf 'CAP SKIP tags-nosupport: the Tags row hides where user xattrs fail, which needs a real vfat mount\n'
    return 0
}

# needs the operator theme switch, driven by the controller
cap_tags_skip_themes() {
    printf 'CAP SKIP tags-themes: per-theme 3x swatches and digit fallbacks need the live theme switch\n'
    return 0
}

# Tags040 states: slots, Tags row and flyout, toggles, rail, search, untagged.
case_cap_tags() {
    local dir="$fixture_root/cap-tags" menus_checks=0 waited
    sandbox_scratch "$dir"
    printf 'one\n' > "$dir/red-holiday-1.txt"
    printf 'two\n' > "$dir/red-holiday-2.txt"
    printf 'three\n' > "$dir/yellow-holiday.txt"
    printf 'plain\n' > "$dir/plain.txt"
    # ruling A: six tags overflow the 88 px slot, which keeps the 5 whole swatches that fit
    printf 'many\n' > "$dir/many-tags.txt"
    mkdir -p "$dir/plain-sub"
    printf 'a\n' > "$dir/plain-sub/a.txt"
    printf 'b\n' > "$dir/plain-sub/b.txt"
    cap_tags_set "$dir/red-holiday-1.txt" "Red"
    cap_tags_set "$dir/red-holiday-2.txt" "Red,Blue"
    cap_tags_set "$dir/yellow-holiday.txt" "Yellow,Green,Purple"
    cap_tags_set "$dir/many-tags.txt" "Orange,Yellow,Green,Blue,Purple,Gray"
    seed_ui_state "$fixture_root/cap-tags-state" '{"keys":"default","view":"list","keyHints":true}'
    launch "$dir"
    wait_listing 6
    cap_resize 1100 700
    seek_row_named "yellow-holiday.txt" || fail "cap_tags: could not find yellow-holiday.txt"
    [[ "$(ipc rowAt "$(ipc cursor)")" == "yellow-holiday.txt|"* ]] \
        || fail "cap_tags: the cursor is not on yellow-holiday.txt"
    shot tags-list
    click_row "$(row_index_of red-holiday-1.txt)" left
    settle
    click_row "$(row_index_of red-holiday-2.txt)" left --mods ctrl
    settle
    [[ "$(ipc selectionCount)" == "2" ]] || fail "cap_tags: two ctrl clicks selected $(ipc selectionCount), not 2"
    click_row "$(row_index_of red-holiday-1.txt)" right
    settle
    [[ "$(ipc contextMenuVisible)" == "true" ]] || fail "cap_tags: the file menu never opened"
    [[ "|$(ipc contextMenuEntries)|" == *"|Tags|"* ]] \
        || fail "cap_tags: the file menu offers no Tags, got $(ipc contextMenuEntries)"
    [[ "|$(ipc contextMenuHints)|" == *"|T|"* ]] \
        || fail "cap_tags: the Tags row shows no T hint, got $(ipc contextMenuHints)"
    shot tags-menu
    menu_seek "Tags"
    key -k Right >/dev/null
    settle
    cap_menu_expect '.opened and .submenu' "tags: the Tags flyout never opened"
    cap_menu_expect '([.submenuEntries[] | select(.separator != true) | .label] | join("|")) == "Red|Orange|Yellow|Green|Blue|Purple|Gray|Remove all tags"' "tags: the flyout lists another row than the seven colours and the clear"
    cap_menu_expect '([.submenuEntries[] | select(.id == "Red")][0].tagRow.state) == "applied"' "tags: Red is not checked over two Red files"
    cap_menu_expect '([.submenuEntries[] | select(.id == "Blue")][0].tagRow.state) == "mixed"' "tags: Blue shows no mixed bar over one of two files"
    shot tags-flyout
    # toggling the mixed tag applies it to both selected items, with its own line
    key 5 >/dev/null
    for waited in $(seq 1 100); do
        [[ "$(ipc statusPrimary)" == *"Tagged 2 items Blue"* ]] && break
        sleep 0.05
    done
    [[ "$(ipc statusPrimary)" == *"Tagged 2 items Blue"* ]] \
        || fail "cap_tags: digit 5 applied no Blue, status reads $(ipc statusPrimary)"
    shot tags-mixed-apply
    key -k Escape >/dev/null
    settle
    key -k Escape >/dev/null
    settle
    [[ "$(ipc contextMenuVisible)" == "false" ]] || fail "cap_tags: the Tags menu stayed open"
    click_row "$(row_index_of plain.txt)" left
    settle
    key T >/dev/null
    settle
    cap_menu_expect '.opened and .submenu' "tags: T opened no flyout from the listing"
    cap_menu_expect '([.submenuEntries[] | select(.id == "Red")][0].tagRow.state) == "absent"' "tags: Red is not unchecked on the untagged row"
    shot tags-t-open
    key 3 >/dev/null
    for waited in $(seq 1 100); do
        [[ "$(ipc statusPrimary)" == *"Tagged 1 item Yellow"* ]] && break
        sleep 0.05
    done
    [[ "$(ipc statusPrimary)" == *"Tagged 1 item Yellow"* ]] \
        || fail "cap_tags: digit 3 toggled no Yellow, status reads $(ipc statusPrimary)"
    shot tags-digit-toggle
    # ruling A: removing the tag prints the Removed line with its z hint
    key 3 >/dev/null
    for waited in $(seq 1 100); do
        [[ "$(ipc statusPrimary)" == *"Removed Yellow from 1 item"* ]] && break
        sleep 0.05
    done
    [[ "$(ipc statusPrimary)" == *"Removed Yellow from 1 item"* ]] \
        || fail "cap_tags: digit 3 removed no Yellow, status reads $(ipc statusPrimary)"
    shot tags-removed
    key -k Escape >/dev/null
    settle
    key -k Escape >/dev/null
    settle
    [[ "$(ipc contextMenuVisible)" == "false" ]] || fail "cap_tags: the toggled menu stayed open"
    # tagging is journaled, so z restores the tags from before the removal
    key z >/dev/null
    settle
    key T >/dev/null
    settle
    cap_menu_expect '([.submenuEntries[] | select(.id == "Yellow")][0].tagRow.state) == "applied"' "tags: z restored no Yellow on plain.txt"
    shot tags-undo
    key -k Escape >/dev/null
    settle
    key -k Escape >/dev/null
    settle
    [[ "$(ipc contextMenuVisible)" == "false" ]] || fail "cap_tags: the undo check left the menu open"
    settings_open_key
    settle
    settings_section places
    [[ "$(ipc settingsRows)" == *"Show tags"* ]] || fail "cap_tags: Places lists no Show tags"
    settings_click_control "places.showTags"
    settings_wait_value '.places.showTags == true'
    key -k Escape >/dev/null
    settle
    wait_rail_label "Red"
    [[ "|$(ipc railLabels)|" == *"|Red|"* && "|$(ipc railLabels)|" == *"|Blue|"* ]] \
        || fail "cap_tags: the TAGS section lists no Red and Blue, rail reads $(ipc railLabels)"
    shot tags-rail
    click_rail_row "$(rail_row_of "Red")" left
    settle
    menus_expect keyDeliveryState '.searchMode == "results" and (.searchRunning | not)' "tags: the Red rail row walks for its tag"
    menus_expect keyDeliveryState '.searchQuery == "tag:Red"' "tags: the Red rail row searches another query than tag:Red"
    [[ "$(ipc total)" == "2" ]] || fail "cap_tags: the Red rail walk found $(ipc total), not 2"
    shot tags-rail-search
    key -k Escape >/dev/null
    settle
    wait_listing 6
    key f >/dev/null
    menus_expect keyDeliveryState '.searchMode == "typing"' "tags: f opened no query line"
    key tag:red >/dev/null
    key -k Space >/dev/null
    key holiday >/dev/null
    menus_expect keyDeliveryState '.searchQuery == "tag:red holiday"' "tags: the query reads $(ipc keyDeliveryState)"
    key -k Return >/dev/null
    menus_expect keyDeliveryState '.searchMode == "results" and (.searchRunning | not)' "tags: tag:red holiday never settled its walk"
    [[ "$(ipc total)" == "2" ]] || fail "cap_tags: tag:red holiday found $(ipc total), not 2"
    shot tags-search
    key -k Escape >/dev/null
    settle
    wait_listing 6
    click_chrome grid
    settle
    [[ "$(ipc viewMode)" == "grid" ]] || fail "cap_tags: the chrome never reached grid"
    shot tags-grid
    click_chrome columns
    settle
    [[ "$(ipc viewMode)" == "columns" ]] || fail "cap_tags: the chrome never reached columns"
    shot tags-columns
    click_chrome list
    settle
    [[ "$(ipc viewMode)" == "list" ]] || fail "cap_tags: the chrome never returned to list"
    # the overflow slot keeps the 5 whole swatches that fit, never past the slot
    seek_row_named "many-tags.txt" || fail "cap_tags: could not find many-tags.txt"
    [[ "$(ipc rowAt "$(ipc cursor)")" == "many-tags.txt|"* ]] \
        || fail "cap_tags: the cursor is not on many-tags.txt"
    shot tags-overflow
    seek_row_named "plain-sub" || fail "cap_tags: could not find plain-sub"
    key -k Return >/dev/null
    wait_path "$dir/plain-sub"
    wait_listing 2
    shot tags-untagged
    cap_tags_skip_nosupport
    cap_tags_skip_themes
    printf 'CAP_TAGS list=slot menu=T flyout=7+clear mixed=apply t=open digit=toggle removed=line undo=z rail=section search=tag:red grid=tile columns=row overflow=5slot untagged=noslot\n'
    kill_flea
}
