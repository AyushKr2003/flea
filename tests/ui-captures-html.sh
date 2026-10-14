# The rendered HTML board's three native specimens, run only by name.
cap_html_expect() {
    local column="$1" expression="$2" label="$3" state="" deadline=$((SECONDS + 20))
    while (( SECONDS < deadline )); do
        state=$(ipc htmlState "$column") || fail "HTML: observer failed"
        if jq -e "$expression" <<< "$state" >/dev/null; then
            menus_checks=$((menus_checks + 1))
            printf 'HTML_CHECK %s %s\n' "$menus_checks" "$label"
            return
        fi
        sleep 0.1
    done
    fail "HTML: $label: $state"
}
cap_html_dir=""
cap_html_open() {
    local view="$1" dir
    dir=$(mktemp -d "$fixture_root/html.XXXXXXXX") || fail "HTML: cannot create specimen sandbox"
    sandbox_require "$dir"
    cap_html_dir=$dir
    : > "$dir/$SANDBOX_MARKER"
    trap cap_html_close EXIT
    python3 "$repo/tests/html-specimen.py" "$dir/page" || fail "HTML: specimen creation failed"
    seed_ui_state "$dir/state" '{"keys":"default","view":"list","display":{"textSize":{"mode":14}}}'
    launch "$dir/page"
    wait_listing 1
    cap_resize 1100 700
    cap_unlock_still
    seek_row_named index.html
    key -k space >/dev/null
    cap_html_expect false '.visible and .ready and .view == "rendered" and .lines == 61 and .count == "61 lines" and .mark == "html" and (.file | length) > 0' "HTML renders with its bar"
    if [[ "$view" == source ]]; then
        key r >/dev/null
        cap_html_expect false '.visible and .ready and .view == "source" and .lines == 61' "HTML Source draws all lines"
    fi
}
cap_html_close() {
    kill_flea
    if [[ -n "$cap_html_dir" ]]; then sandbox_remove "$cap_html_dir"; fi
    cap_html_dir=""
    trap - EXIT
}
case_cap_html() {
    local menus_checks=0
    cap_html_open rendered
    shot ql-html
    cap_html_close
}
case_cap_html_source() {
    local menus_checks=0
    cap_html_open source
    shot ql-html-source
    key -k Escape >/dev/null
    switch_view columns
    cap_html_expect true '.visible and .ready and .view == "rendered"' "the column renders after Quick Look Source closes"
    switch_view list
    seek_row_named index.html
    key -k space >/dev/null
    cap_html_expect false '.visible and .ready and .view == "rendered"' "Quick Look reopens rendered after Source closes"
    key -k Escape >/dev/null
    cap_html_close
}
case_cap_cols_html() {
    local menus_checks=0
    cap_html_open rendered
    key -k Escape >/dev/null
    switch_view columns
    cap_html_expect true '.visible and .ready and .view == "rendered" and .lines == 61 and .facts == "HTML document · 1.6 kB · 61 lines"' "the tall column shows the board facts"
    shot cols-html
    cap_html_close
}
