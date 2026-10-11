# Filter and search captures in List, Grid and Columns at text size 14, native only; fixture: 14 top-level entries, 8 names holding ap, 3 without, sub and extra holding matches, one empty folder.
cap_filter_straddle_name=a-very-long-grid-caption-that-wraps.txt
cap_filter_ap_shown=8
cap_filter_search_total=11
cap_filter_full_total=14

# Build the fixture under dir and print the 14 top-level names, one per line.
cap_filter_build() {
    local dir="$1"
    mkdir -p "$dir/sub/deep" "$dir/extra" "$dir/empty-folder"
    printf 'apex notes\nsecond line\nthird line\n' > "$dir/apex.txt"
    printf 'apricot notes\n' > "$dir/apricot.md"
    printf 'capital notes\n' > "$dir/capital.txt"
    printf 'happy notes\n' > "$dir/happy.md"
    printf 'map notes\n' > "$dir/map.png"
    printf 'paper notes\n' > "$dir/paper.txt"
    printf 'snap notes\n' > "$dir/snap.jpg"
    printf 'plain notes\n' > "$dir/notes.txt"
    printf 'plain notes\n' > "$dir/piano.md"
    printf 'plain notes\n' > "$dir/readme.txt"
    printf 'caption notes\n' > "$dir/$cap_filter_straddle_name"
    printf 'sub match\n' > "$dir/sub/apex-sub.txt"
    printf 'deep match\n' > "$dir/sub/deep/happy-sub.md"
    printf 'extra match\n' > "$dir/extra/capital-sub.txt"
    printf '%s\n' "$cap_filter_straddle_name" apex.txt apricot.md capital.txt empty-folder extra happy.md map.png notes.txt paper.txt piano.md readme.txt snap.jpg sub
}

# Pin text size 14 and the live theme before shots, the sweep specimen idiom.
cap_filter_pin() {
    local base body
    base=$(token_of baseSize)
    body=$(ipc bodyPx)
    [[ "$base" == 14 && "$body" == 14 ]] || fail "cap_filter: text size is $base, body $body, expected 14"
    assert_theme
}

# Seed, launch, wait the listing, pin size and theme for one shot group.
cap_filter_launch() {
    local dir="$1" state="$2" patch="$3" want_total="$4"
    seed_ui_state "$state" "$patch"
    launch "$dir"
    wait_listing "$want_total"
    cap_filter_pin
    cap_resize 1320 820
}

# Escape returns to browsing with the full listing back.
cap_filter_escape() {
    key -k Escape >/dev/null
    settle
    wait_listing "$cap_filter_full_total"
    menus_expect keyDeliveryState '.searchMode == "" and (.filterTyping | not)' "escape returns to browsing"
}

# One slash-ap shot; skip_integer skips drawnCount where the list delegate is unbuilt.
cap_filter_slash_ap() {
    local prefix="$1" drawn="$2"
    key / >/dev/null
    menus_expect keyDeliveryState '.filterTyping and .filterQuery == ""' "slash opens the filter in $prefix"
    key ap >/dev/null
    menus_expect keyDeliveryState '.filterTyping and .filterQuery == "ap"' "slash ap typed in $prefix"
    menus_expect listingWindowState ".shownTotal == $cap_filter_ap_shown and .total == $cap_filter_full_total" "slash ap shows in $prefix"
    if [[ "$drawn" == drawn ]]; then cardsize_expect drawnCount "$cap_filter_ap_shown"; fi
    settle
    shot "$prefix-slash-ap"
    printf 'CAP_FILTER %s slash-ap shown=%s\n' "$prefix" "$cap_filter_ap_shown"
}

# One slash-nomatch shot with the miss line up.
cap_filter_slash_nomatch() {
    local prefix="$1" drawn="$2"
    key / >/dev/null
    menus_expect keyDeliveryState '.filterTyping and .filterQuery == ""' "slash opens the filter in $prefix"
    key qqq >/dev/null
    menus_expect keyDeliveryState '.filterTyping and .filterQuery == "qqq"' "slash qqq typed in $prefix"
    menus_expect listingWindowState ".shownTotal == 0 and .total == $cap_filter_full_total" "slash qqq shows none in $prefix"
    if [[ "$drawn" == drawn ]]; then cardsize_expect drawnCount 0; fi
    menus_expect stateLayers '.message and (.empty | not)' "slash qqq raises the miss line in $prefix"
    settle
    shot "$prefix-slash-nomatch"
    printf 'CAP_FILTER %s slash-nomatch shown=0\n' "$prefix"
}

# One search-ap shot, typed with no Enter.
cap_filter_search_ap() {
    local prefix="$1" drawn="$2"
    key f >/dev/null
    menus_expect keyDeliveryState '.searchMode == "typing" and .searchQuery == ""' "search opens typing in $prefix"
    key ap >/dev/null
    menus_expect keyDeliveryState '.searchMode == "typing" and .searchQuery == "ap" and (.searchRunning | not)' "search ap lands in $prefix"
    wait_listing "$cap_filter_search_total"
    if [[ "$drawn" == drawn ]]; then cardsize_expect drawnCount "$cap_filter_search_total"; fi
    settle
    shot "$prefix-search-ap"
    printf 'CAP_FILTER %s search-ap total=%s\n' "$prefix" "$cap_filter_search_total"
}

# One search-nomatch shot; the hero wait polls the settled caption past the entrance fade.
cap_filter_search_nomatch() {
    local prefix="$1" drawn="$2"
    key f >/dev/null
    menus_expect keyDeliveryState '.searchMode == "typing" and .searchQuery == ""' "search opens typing in $prefix"
    key apzqq >/dev/null
    menus_expect keyDeliveryState '.searchMode == "typing" and .searchQuery == "apzqq" and (.searchRunning | not)' "search apzqq lands in $prefix"
    wait_listing 0
    sweep_wait listingState empty
    menus_expect emptyHeroState '.visible and .captionOpacity == 1' "search apzqq hero settles in $prefix"
    if [[ "$drawn" == drawn ]]; then cardsize_expect drawnCount 0; fi
    settle
    shot "$prefix-search-nomatch"
    printf 'CAP_FILTER %s search-nomatch total=0\n' "$prefix"
}

# One empty-folder hero shot over the launched folder.
cap_filter_empty() {
    local prefix="$1"
    wait_listing 0
    sweep_wait listingState empty
    menus_expect emptyHeroState '.visible and .captionOpacity == 1' "empty hero settles in $prefix"
    settle
    shot "$prefix-empty-folder"
    printf 'CAP_FILTER %s empty-folder total=0\n' "$prefix"
}

# The four states in List.
cap_filter_list() {
    local dir="$1"
    cap_filter_launch "$dir" "$fixture_root/cap-filter-state-list" '{"keys":"default","view":"list","display":{"textSize":{"mode":14}}}' "$cap_filter_full_total"
    sweep_wait viewMode list
    cap_filter_slash_ap filter-list drawn
    cap_filter_escape
    cap_filter_slash_nomatch filter-list drawn
    cap_filter_escape
    cap_filter_search_ap filter-list drawn
    cap_filter_escape
    cap_filter_search_nomatch filter-list drawn
    cap_filter_escape
    kill_flea
}

# The four states in Grid.
cap_filter_grid() {
    local dir="$1"
    cap_filter_launch "$dir" "$fixture_root/cap-filter-state-grid" '{"keys":"default","view":"grid","display":{"textSize":{"mode":14}}}' "$cap_filter_full_total"
    sweep_wait viewMode grid
    cap_filter_slash_ap filter-grid drawn
    cap_filter_escape
    cap_filter_slash_nomatch filter-grid drawn
    cap_filter_escape
    cap_filter_search_ap filter-grid drawn
    cap_filter_escape
    cap_filter_search_nomatch filter-grid drawn
    cap_filter_escape
    kill_flea
}

# The four states in Columns at one limit; drawnCount is skipped, the list delegate is unbuilt there.
cap_filter_columns() {
    local dir="$1" n="$2"
    cap_filter_launch "$dir" "$fixture_root/cap-filter-state-columns$n" '{"keys":"default","view":"columns","columnsLimit":'"$n"',"display":{"textSize":{"mode":14}},"preview":{"column":true,"loadOn":"automatic","thumbSize":"medium"}}' "$cap_filter_full_total"
    sweep_wait viewMode columns
    sweep_wait columnCount "$n"
    cap_filter_slash_ap "filter-columns$n" skip
    cap_filter_escape
    cap_filter_slash_nomatch "filter-columns$n" skip
    cap_filter_escape
    cap_filter_search_ap "filter-columns$n" skip
    cap_filter_escape
    cap_filter_search_nomatch "filter-columns$n" skip
    cap_filter_escape
    kill_flea
}

# The empty-folder hero at every column limit.
cap_filter_empties() {
    local dir="$1" n
    for n in 2 3 4 5; do
        cap_filter_launch "$dir/empty-folder" "$fixture_root/cap-filter-state-empty$n" '{"keys":"default","view":"columns","columnsLimit":'"$n"',"display":{"textSize":{"mode":14}}}' 0
        sweep_wait viewMode columns
        sweep_wait columnCount "$n"
        cap_filter_empty "filter-columns$n"
        kill_flea
    done
}

# Item 2: a file first so the preview column is laid out, then the search miss.
cap_filter_preview() {
    local dir="$1" after after_path
    cap_filter_launch "$dir" "$fixture_root/cap-filter-state-preview" '{"keys":"default","view":"columns","columnsLimit":2,"display":{"textSize":{"mode":14}},"preview":{"column":true,"loadOn":"automatic","thumbSize":"medium"}}' "$cap_filter_full_total"
    sweep_wait viewMode columns
    sweep_wait columnCount 2
    column_expect apex.txt text
    key f >/dev/null
    menus_expect keyDeliveryState '.searchMode == "typing" and .searchQuery == ""' "preview search opens typing"
    key apzqq >/dev/null
    menus_expect keyDeliveryState '.searchMode == "typing" and .searchQuery == "apzqq" and (.searchRunning | not)' "preview search apzqq lands"
    wait_listing 0
    sweep_wait listingState empty
    menus_expect emptyHeroState '.visible and .captionOpacity == 1' "preview search apzqq hero settles"
    # previewColumnState is a bare kind string, so the kind compares raw; the path pins apex.txt.
    after=$(ipc previewColumnState) || fail "cap_filter: the preview state could not be read"
    [[ "$after" == "text" ]] || fail "cap_filter: the preview shows $after on the miss, not the kept text"
    after_path=$(ipc previewSelectionState | jq -er .path) || fail "cap_filter: the preview path could not be read"
    [[ "$after_path" == *apex.txt ]] || fail "cap_filter: the preview keeps $after_path on the miss, not apex.txt"
    printf 'CAP_FILTER columns2 preview kept on the miss: %s %s\n' "$after" "$after_path"
    settle
    shot filter-columns2-search-nomatch-preview
    key -k Escape >/dev/null
    settle
    wait_listing "$cap_filter_full_total"
    kill_flea
}

# Count top-level fixture names holding the candidate, case blind.
cap_filter_matches() {
    local cand="$1" name matches=0
    for name in "$cap_filter_straddle_name" apex.txt apricot.md capital.txt happy.md map.png paper.txt snap.jpg notes.txt piano.md readme.txt sub extra empty-folder; do
        if [[ "${name,,}" == *"${cand,,}"* ]]; then matches=$((matches + 1)); fi
    done
    printf '%s' "$matches"
}

# Item 1: the wash across the wrapped Grid label, cursor parked off the tile.
cap_filter_straddle() {
    local dir="$1" idx caption lines line0 line1 a b cand matches best best_n holder total want cur prev guard
    cap_filter_launch "$dir" "$fixture_root/cap-filter-state-straddle" '{"keys":"default","view":"grid","display":{"textSize":{"mode":14}}}' "$cap_filter_full_total"
    sweep_wait viewMode grid
    idx=$(row_index_of "$cap_filter_straddle_name")
    caption=$(ipc gridCaptionState "$idx" | jq -er .name) || fail "cap_filter: the long tile has no caption"
    lines=$(ipc gridCaptionState "$idx" | jq -er .lines) || fail "cap_filter: the long tile has no line count"
    [[ "$lines" == 2 ]] || fail "cap_filter: the long name lays out on $lines lines, not a wrapped pair"
    line0=${caption%%$'\n'*}
    line1=${caption#*$'\n'}
    line1=${line1%%$'\n'*}
    [[ -n "$line0" && -n "$line1" ]] || fail "cap_filter: the long caption has no two lines to straddle"
    best=""
    best_n=0
    for a in 3 2 1; do
        for b in 1 2; do
            cand=${line0: -$a}${line1:0:$b}
            [[ "$cand" == -* || "$cand" == *'*'* || "$cand" == *'?'* ]] && continue
            matches=$(cap_filter_matches "$cand")
            if (( matches > best_n )); then best=$cand; best_n=$matches; fi
        done
    done
    [[ -n "$best" ]] || fail "cap_filter: no query straddles the wrap"
    total=$cap_filter_full_total
    if (( best_n < 2 )); then
        holder="zz-$best-holder.txt"
        printf 'holder\n' > "$dir/$holder" || fail "cap_filter: the co-match holder could not be made"
        kill_flea
        launch "$dir"
        total=$((cap_filter_full_total + 1))
        wait_listing "$total"
        sweep_wait viewMode grid
        cap_filter_pin
        cap_resize 1320 820
        cap_seek_named "$holder"
    else
        cap_seek_named notes.txt
    fi
    click_chrome filter
    key "$best" >/dev/null
    menus_expect keyDeliveryState ".filterTyping and .filterQuery == \"$best\"" "straddle query typed"
    want=$best_n
    if (( best_n < 2 )); then want=2; fi
    cardsize_expect drawnCount "$want"
    key -k Return >/dev/null
    menus_expect keyDeliveryState "(.filterTyping | not) and .filterQuery == \"$best\"" "straddle query committed"
    menus_expect listingWindowState ".shownTotal == $want and .total == $total" "straddle filter still applied"
    prev=""
    for guard in $(seq 1 "$total"); do
        cur=$(ipc renameState | jq -er .cursorName) || fail "cap_filter: the cursor name could not be read"
        [[ "$cur" != "$cap_filter_straddle_name" ]] && break
        if [[ "$cur" == "$prev" ]]; then key j >/dev/null; else key l >/dev/null; fi
        prev=$cur
        settle
    done
    cur=$(ipc renameState | jq -er .cursorName) || fail "cap_filter: the cursor name could not be read"
    [[ "$cur" != "$cap_filter_straddle_name" ]] || fail "cap_filter: the cursor never left the straddle tile"
    menus_expect keyDeliveryState ".filterQuery == \"$best\"" "straddle query unchanged by cursor moves"
    settle
    shot filter-grid-slash-straddle
    printf 'CAP_FILTER straddle query=%s cursor=%s\n' "$best" "$cur"
    key -k Escape >/dev/null
    settle
    kill_flea
}

# Slash and search as you type in List, Grid and Columns, 30 shots, native only.
case_cap_filter() {
    local dir="$fixture_root/cap-filter" menus_checks=0 n
    sandbox_scratch "$dir"
    cap_filter_build "$dir" > /dev/null
    sandbox_require "$dir/apex.txt"
    cap_filter_list "$dir"
    cap_filter_grid "$dir"
    for n in 2 3 4 5; do cap_filter_columns "$dir" "$n"; done
    cap_filter_empties "$dir"
    cap_filter_preview "$dir"
    cap_filter_straddle "$dir"
    printf 'CAP_FILTER list=ok grid=ok columns=ok empties=ok preview=ok straddle=ok\n'
    kill_flea
}
