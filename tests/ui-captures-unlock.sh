# Unlock board captures (outside the default wanted list); tests/ui.sh supplies fixture, helpers and shots.

# Poll unlockState until its jq filter holds, so every card state is asserted, never assumed.
cap_unlock_expect() {
    local filter="$1" what="$2" state=""
    local end=$((SECONDS + 30))
    while (( SECONDS < end )); do
        state=$(ipc unlockState 2>/dev/null || printf unavailable)
        jq -e "$filter" <<< "$state" >/dev/null 2>&1 && return 0
        sleep 0.05
    done
    fail "cap_unlock: $what, last state $state"
}

# The rail label of the locked row for this device, waited on the lsblk poll, never counted.
cap_unlock_locked_label() {
    local dev="$1" label=""
    local end=$((SECONDS + 30))
    while (( SECONDS < end )); do
        label=$(ipc railEntries 2>/dev/null | jq -r --arg dev "$dev" \
            '[.[] | select(.device == $dev and .locked == true)][0].label // ""' 2>/dev/null || printf "")
        [[ -n "$label" ]] && { printf '%s' "$label"; return 0; }
        sleep 0.2
    done
    fail "cap_unlock: no locked rail row for $dev, entries $(ipc railEntries | jq -c 'map({label,device,locked})')"
}

# Flea's own window keeps the keyboard: a foreign passphrase prompt (udiskie) must never be typed into.
cap_unlock_own_focus() {
    local seen
    seen=$(focused_class || true)
    [[ "$seen" == "$flea_window_class" ]] \
        || fail "cap_unlock: focus is on class '$seen', not $flea_window_class, so nothing is typed"
}

# The test-only passphrase typed with no argv carrying it; the file holds exactly its bytes.
cap_unlock_type_key() {
    local keyfile="$1"
    cap_unlock_own_focus
    YDOTOOL_SOCKET="$XDG_RUNTIME_DIR/.ydotool_socket" ydotool type -f "$keyfile" >/dev/null 2>&1 \
        || fail "cap_unlock: ydotool could not type the key file"
    # Return rides the same uinput queue as the key, since a virtual-keyboard Return can overtake the typing.
    YDOTOOL_SOCKET="$XDG_RUNTIME_DIR/.ydotool_socket" ydotool key 28:1 28:0 >/dev/null 2>&1 \
        || fail "cap_unlock: ydotool could not press Return"
}

# Launch Flea the supported way for one device: flea --unlock names it (FLEA_UNLOCK reaches only its card).
cap_unlock_launch() {
    local dev="$1"
    kill_flea
    cat "$flea_log" >> "$run_log" 2>/dev/null || true
    : > "$flea_log"
    rm -f "$FLEA_UNDO_DIR/undo-journal" "$FLEA_UNDO_DIR/undo-journal.lock"
    FLEA_UI="$flea_ui" FLEA_BIN="$flea_bin" \
        setsid nohup "$flea_bin" --unlock "$dev" >"$flea_log" 2>&1 </dev/null &
    omarchy-drive wait window flea --timeout 15 >/dev/null
    omarchy-drive focus flea >/dev/null
    assert_window
    printf 'LAUNCH unlock dev=%q pid=%s\n' "$dev" "$(flea_pid)"
}

# Unlock: the locked row, the card wrong-then-right, the unlocked row and the Eject that relocks it.
case_cap_unlock() {
    # The container is FLEA_CAP_LUKS_DEV (LUKS2 over a vfat labelled S1LUKS); its test-only passphrase is FLEA_CAP_LUKS_KEY.
    local dir="$fixture_root/cap-unlock" dev="${FLEA_CAP_LUKS_DEV:-}" key="${FLEA_CAP_LUKS_KEY:-}"
    local label="" keyfile="" state="" status="" wrong="no-such-passphrase"
    local end shot_done=false
    sandbox_scratch "$dir"
    if [[ -z "$dev" ]]; then
        # needs a real LUKS container, driven by the controller
        printf 'CAP SKIP unlock-locked-row: no FLEA_CAP_LUKS_DEV in this environment\n'
        printf 'CAP SKIP unlock-card-typing: no FLEA_CAP_LUKS_DEV in this environment\n'
        printf 'CAP SKIP unlock-card-typing-text: no FLEA_CAP_LUKS_DEV in this environment\n'
        printf 'CAP SKIP unlock-card-wrong: no FLEA_CAP_LUKS_DEV in this environment\n'
        printf 'CAP SKIP unlock-card-unlocking: no FLEA_CAP_LUKS_DEV in this environment\n'
        printf 'CAP SKIP unlock-card-unlock: no FLEA_CAP_LUKS_DEV in this environment\n'
        printf 'CAP SKIP unlock-unlocked-row: no FLEA_CAP_LUKS_DEV in this environment\n'
        printf 'CAP SKIP unlock-relocked-row: no FLEA_CAP_LUKS_DEV in this environment\n'
        return 0
    fi
    [[ "$dev" == /dev/* ]] || fail "cap_unlock: FLEA_CAP_LUKS_DEV names [$dev], not a device path"
    [[ -n "$key" ]] || fail "cap_unlock: FLEA_CAP_LUKS_DEV is set but FLEA_CAP_LUKS_KEY is empty"
    [[ "$wrong" != "$key" ]] || wrong="wrong-passphrase-2"
    command -v udisksctl >/dev/null || fail "cap_unlock: udisksctl is not on PATH, so relock cannot be asserted"
    printf 'one\n' > "$dir/a.txt"
    printf 'two\n' > "$dir/b.txt"
    seed_ui_state "$fixture_root/cap-unlock-state" '{"keys":"default","view":"list"}'
    launch "$dir"
    wait_listing 2
    cap_resize 1100 700
    label=$(cap_unlock_locked_label "$dev")
    key -k Tab >/dev/null
    settle
    [[ "$(ipc focusView)" == "rail" ]] || fail "cap_unlock: Tab did not reach the rail"
    rail_seek "$label"
    settle
    shot unlock-locked-row
    key -k Return >/dev/null
    cap_unlock_expect '.opened == true' "the Unlock card never opened on $label"
    cap_resize 1100 700
    shot unlock-card-typing
    key "$wrong" >/dev/null
    settle
    shot unlock-card-typing-text
    key -k Return >/dev/null
    cap_unlock_expect '.phase == "wrong"' "a wrong passphrase never ended in the wrong state"
    state=$(ipc unlockState)
    [[ "$(jq -r .note <<< "$state")" == "That passphrase did not unlock $label." ]] \
        || fail "cap_unlock: the wrong note reads $(jq -r .note <<< "$state")"
    shot unlock-card-wrong
    keyfile="$dir/.cap-key"
    trap 'rm -f "$dir/.cap-key"' EXIT
    printf '%s' "$key" > "$keyfile"
    chmod 600 "$keyfile" || fail "cap_unlock: the key file could not be locked down"
    cap_unlock_type_key "$keyfile"
    rm -f "$keyfile"
    keyfile=""
    end=$((SECONDS + 15))
    while (( SECONDS < end )); do
        state=$(ipc unlockState 2>/dev/null || printf unavailable)
        [[ "$(jq -r .phase <<< "$state" 2>/dev/null)" == "unlocking" ]] && { shot unlock-card-unlocking; shot_done=true; break; }
        [[ "$(jq -r .opened <<< "$state" 2>/dev/null)" == "false" ]] && break
        sleep 0.05
    done
    [[ "$shot_done" == true ]] || fail "cap_unlock: unlocking never showed before the dialog closed, last $state"
    cap_unlock_expect '.opened == false' "the dialog never closed after the right passphrase"
    status=$(ipc statusPrimary)
    [[ "$status" == "Unlocked and mounted $label." ]] \
        || fail "cap_unlock: the unlocked footer reads [$status]"
    [[ "$(ipc path)" == */S1LUKS ]] || fail "cap_unlock: the pane is at $(ipc path), not the unlocked volume"
    end=$((SECONDS + 10))
    while (( SECONDS < end )); do
        [[ "$(ipc listInFlight 2>/dev/null)" == "false" ]] && break
        sleep 0.05
    done
    shot unlock-unlocked-row
    [[ "$(ipc focusView)" == "list" ]] || fail "cap_unlock: focus is on $(ipc focusView), not the unlocked listing"
    key -M ctrl -k E -m ctrl >/dev/null
    end=$((SECONDS + 60))
    while (( SECONDS < end )); do
        status=$(ipc statusPrimary 2>/dev/null || printf "")
        [[ "$status" == *"could not be locked"* ]] && fail "cap_unlock: Eject left the container unlocked: [$status]"
        if ! udisksctl info --block-device "$dev" 2>/dev/null | grep -q "CleartextDevice"; then
            state=$(ipc railEntries 2>/dev/null || printf "[]")
            jq -e --arg dev "$dev" '[.[] | select(.device == $dev and .locked == true)] | length == 1' \
                <<< "$state" >/dev/null 2>&1 && break
        fi
        sleep 0.5
    done
    if udisksctl info --block-device "$dev" 2>/dev/null | grep -q "CleartextDevice"; then
        fail "cap_unlock: $dev still has a cleartext device after Eject"
    fi
    state=$(ipc railEntries)
    jq -e --arg dev "$dev" '[.[] | select(.device == $dev and .locked == true)] | length == 1' \
        <<< "$state" >/dev/null || fail "cap_unlock: the rail never locked $dev again, entries $(jq -c 'map({label,device,locked})' <<< "$state")"
    status=$(ipc statusPrimary)
    [[ "$status" == *"could not be locked"* ]] && fail "cap_unlock: the status reports a lock failure: [$status]"
    shot unlock-relocked-row
    kill_flea
    cap_unlock_launch "$dev"
    cap_unlock_expect '.opened == true' "flea --unlock never opened the card on $dev"
    cap_resize 1100 700
    shot unlock-card-unlock
    key -k Escape >/dev/null
    cap_unlock_expect '.opened == false' "Escape never closed the card flea --unlock opened"
    printf 'CAP_UNLOCK locked=row card=typing,text,wrong,unlocking,unlock unlocked=row eject=relocked\n'
    kill_flea
}
