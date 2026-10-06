# Sourced by ui.sh beside the other case files, runs only by name: Archives040 submenu, password dialog, extract card and ISO Quick Look, fixtures in its own root.
case_cap_archives() {
    local dir="$fixture_root/cap-archives" menus_checks=0 submenu="" glyphs="" names="" end
    command -v 7z >/dev/null || { printf 'CAP SKIP cap-archives: 7z is not installed\n'; return 0; }
    sandbox_scratch "$dir"
    printf 'one\n' > "$dir/a.txt"
    printf 'two\n' > "$dir/b.txt"
    printf 'three\n' > "$dir/c.txt"
    printf 'secret\n' > "$dir/secret.txt"
    # One stdin line carries the password; 7z never sees it in argv.
    ( cd "$dir" && printf 'pw\n' | 7z a -p -mhe=on backup.7z secret.txt >/dev/null ) \
        || fail "cap_archives: 7z could not make the password fixture"
    local iso_ok=false iso_src="$fixture_root/cap-archives-isosrc"
    if command -v bsdtar >/dev/null; then
        sandbox_scratch "$iso_src"
        printf 'one\n' > "$iso_src/a.txt"
        printf 'two\n' > "$iso_src/b.txt"
        if ( cd "$iso_src" && bsdtar --format=iso9660 -cf "$dir/image.iso" . >/dev/null 2>&1 ); then iso_ok=true; fi
    fi
    seed_ui_state "$fixture_root/cap-archives-state" '{"keys":"default","view":"list"}'
    launch "$dir"
    local listed=5 extracted=6
    if [[ "$iso_ok" == true ]]; then listed=6; extracted=7; fi
    wait_listing "$listed"
    cap_resize 1100 700
    [[ "$(ipc archiveFormats)" == *"7z"* ]] \
        || fail "cap_archives: 7z installed but no 7z in archiveFormats [$(ipc archiveFormats)]"
    # Three rows selected, so the dialog titles itself for 3 items.
    click_row "$(row_index_of a.txt)" left
    settle
    click_row "$(row_index_of b.txt)" left --mods ctrl
    settle
    click_row "$(row_index_of c.txt)" left --mods ctrl
    settle
    [[ "$(ipc selectionCount)" == "3" ]] || fail "cap_archives: three ctrl clicks selected $(ipc selectionCount), not 3"
    click_row "$(row_index_of a.txt)" right
    settle
    menus_expect menuState '.opened and .hasRow' "the file menu opens over the selection"
    menu_seek Compress
    key -k Right >/dev/null
    settle
    # The submenu is the probed table with With password last under its separator.
    menus_expect menuState '.submenu and ([.submenuEntries[] | select(.label == "With password…")] | length) == 1' "the Compress flyout ends in With password"
    submenu=$(ipc menuState | jq -r '[.submenuEntries[] | .label // "-"] | join("|")')
    [[ "$submenu" == *"|-|With password…" ]] \
        || fail "cap_archives: With password is not last under its separator: $submenu"
    glyphs=$(ipc contextMenuSubmenuGlyphs)
    [[ "$glyphs" == *"|key" ]] || fail "cap_archives: With password wears no key mark: $glyphs"
    shot archives-compress-submenu
    menu_seek_submenu "With password…"
    key -k Return >/dev/null
    # The dialog opens over the three resolved paths with 7z selected.
    menus_expect archiveCardsState '.compressOpened and .compressCount == 3 and .compressFormat == "7z"' "the password dialog opens for 3 items in 7z"
    [[ "$(ipc contextMenuVisible)" == "false" ]] || fail "cap_archives: the menu stayed open behind the dialog"
    settle
    shot archives-compress-dialog
    # Mismatched confirmations refuse with the error frame and no submit.
    key "pw" >/dev/null
    key -k Tab >/dev/null
    settle
    key "nope" >/dev/null
    key -k Return >/dev/null
    menus_expect archiveCardsState '.compressOpened and (.compressError | contains("do not match"))' "a mismatched confirm refuses"
    settle
    shot archives-compress-mismatch
    # Matching pair enables Compress; Tab reaches the Encrypt row with its focus.
    key -M ctrl -k a -m ctrl -k BackSpace >/dev/null
    settle
    key "pw" >/dev/null
    key -k Tab >/dev/null
    settle
    menus_expect archiveCardsState '.compressOpened and .canCompress' "a matching pair enables Compress"
    # The Tab above already reached the Encrypt row; no second Tab, which would move on to Cancel.
    menus_expect archiveCardsState '.compressOpened and .compressFocus == 4' "Tab reaches the Encrypt file names row"
    settle
    shot archives-compress-focus
    key -k Escape >/dev/null
    menus_expect archiveCardsState '.compressOpened | not' "Escape closes the password dialog"
    settle
    # Extracting the encrypted archive opens the password card for its leaf.
    click_row "$(row_index_of secret.txt)" left
    settle
    click_row "$(row_index_of backup.7z)" left
    settle
    click_row "$(row_index_of backup.7z)" right
    settle
    menus_expect menuState '.opened and .hasRow' "the menu opens over backup.7z"
    menu_seek Extract
    key -k Return >/dev/null
    menus_expect archiveCardsState '.extractOpened and .extractLeaf == "backup.7z" and .extractError == ""' "the encrypted archive asks for its password"
    settle
    shot archives-extract-password
    # A wrong answer reopens the card with its sentence and Extract still primary.
    key "nope" >/dev/null
    key -k Return >/dev/null
    menus_expect archiveCardsState '.extractOpened and (.extractError | contains("did not open backup.7z"))' "a wrong password asks again"
    settle
    shot archives-extract-wrong
    # The right password extracts beside the archive; nothing lands before it does.
    [[ ! -e "$dir/backup" ]] || fail "cap_archives: a refused extract already wrote $dir/backup"
    key -M ctrl -k a -m ctrl -k BackSpace >/dev/null
    settle
    key "pw" >/dev/null
    key -k Return >/dev/null
    wait_listing "$extracted"
    [[ -f "$dir/backup/secret.txt" ]] || fail "cap_archives: the right password extracted nothing to $dir/backup"
    # needs an ISO writer the case cannot assume: bsdtar without iso9660 support.
    if [[ "$iso_ok" != true ]]; then
        printf 'CAP SKIP archives-iso-quicklook: no ISO writer made image.iso\n'
    else
        seek_row_named "image.iso" || fail "cap_archives: could not find image.iso"
        key -k space >/dev/null
        end=$((SECONDS + 15))
        while (( SECONDS < end )); do
            names=$(ipc previewArchiveNames) || fail "cap_archives: the archive names reader failed"
            [[ -n "$names" ]] && break
            sleep 0.05
        done
        [[ -n "$names" ]] || fail "cap_archives: the ISO listed no entries in Quick Look"
        [[ "$(ipc previewOpen)" == "true" ]] || fail "cap_archives: Space opened no Quick Look over image.iso"
        settle
        shot archives-iso-quicklook
        key -k Escape >/dev/null
        settle
    fi
    # needs a volume with less free space than the unpacked archive, driven by the controller.
    printf 'CAP SKIP archives-free-space-refusal: no nearly-full filesystem in the test root\n'
    printf 'CAP_ARCHIVES submenu=with-password-last dialog=rest,mismatch,focus extract=card,wrong iso=%s\n' "$iso_ok"
    kill_flea
}
