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

# Writes DIR/lsblk: a loop container lists as a stick (rm, and a name past Devices.js isPseudo); other calls are the real lsblk.
cap_unlock_lsblk_shim() {
    local dir="$1" dev="$2" real="$3"
    [[ "$dev" =~ ^/dev/loop[0-9]+$ && "$real" == /* && -x "$real" ]] || return 1
    mkdir -p -- "$dir" || return 1
    {
        printf '#!/bin/bash\n# Test-only lsblk written by tests/ui-captures-unlock.sh; it dies with its sandbox root.\n'
        printf 'real=%q dev=%q\n' "$real" "$dev"
        cat <<'SHIM'
# Sample input (Flea's argv, ui/DeviceMounts.qml): "--bytes --json -o NAME,PATH,...,UUID"
# Sample input (the real lsblk's reply): {"blockdevices":[{"name":"loop0","path":"/dev/loop0","rm":false,"children":[{"name":"luks-6f1c2a7e","rm":false}]}]}
case " $* " in *" --json "*|*" -J "*) ;; *) exec "$real" "$@" ;; esac
body=$("$real" "$@"; rc=$?; printf x; exit "$rc"); rc=$?; body=${body%x}
pick='(.path // ("/dev/" + (.name // ""))) == $dev'
if (( rc != 0 )) || ! jq -e --arg dev "$dev" "any(.blockdevices[]?; $pick)" <<< "$body" >/dev/null 2>&1; then
    printf '%s' "$body"
    exit "$rc"
fi
mark='def mark: .rm = true | if .children then .children |= map(mark) else . end;'
jq --arg dev "$dev" "$mark .blockdevices |= map(if $pick then (mark | .name = \"cap-\" + .name) else . end)" <<< "$body"
SHIM
    } > "$dir/lsblk" || return 1
    chmod 700 "$dir/lsblk"
}

# Launch Flea the supported way for one device: flea --unlock names it (FLEA_UNLOCK reaches only its card).
cap_unlock_launch() {
    local dev="$1" shim="${2:-}"
    kill_flea
    cat "$flea_log" >> "$run_log" 2>/dev/null || true
    : > "$flea_log"
    rm -f "$FLEA_UNDO_DIR/undo-journal" "$FLEA_UNDO_DIR/undo-journal.lock"
    PATH="${shim:+$shim:}$PATH" FLEA_UI="$flea_ui" FLEA_BIN="$flea_bin" ${flea_launch_wrap[@]+"${flea_launch_wrap[@]}"} \
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
    local end crypt="" shot_done=false shim="" rail_poll_ms="" listing_ms="" unlocking="" stop=""
    # An ssh-started Flea is an inactive polkit subject that udisks refuses, so it starts in the graphical slice.
    local -a flea_launch_wrap=(systemd-run --user --scope --quiet --slice=app-graphical.slice)
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
        printf 'CAP SKIP unlock-ejected-rail: no FLEA_CAP_LUKS_DEV in this environment\n'
        return 0
    fi
    [[ "$dev" == /dev/* ]] || fail "cap_unlock: FLEA_CAP_LUKS_DEV names [$dev], not a device path"
    [[ -n "$key" ]] || fail "cap_unlock: FLEA_CAP_LUKS_DEV is set but FLEA_CAP_LUKS_KEY is empty"
    [[ "$wrong" != "$key" ]] || wrong="wrong-passphrase-2"
    command -v udisksctl >/dev/null || fail "cap_unlock: udisksctl is not on PATH, so relock cannot be asserted"
    # A loop device has no rm or tran, so the rail lists it only through the shim; the real stick never takes it.
    if [[ "$dev" =~ ^/dev/loop[0-9]+$ ]]; then
        shim="$fixture_root/cap-unlock-shim"
        sandbox_scratch "$shim"
        cap_unlock_lsblk_shim "$shim" "$dev" "$(command -v lsblk)" || fail "cap_unlock: the lsblk shim for $dev could not be written"
        printf 'CAP NOTE unlock: lsblk shim marks %s removable, listed as cap-%s\n' "$dev" "${dev#/dev/}"
    fi
    printf 'one\n' > "$dir/a.txt"
    printf 'two\n' > "$dir/b.txt"
    seed_ui_state "$fixture_root/cap-unlock-state" '{"keys":"default","view":"list"}'
    PATH="${shim:+$shim:}$PATH" launch "$dir"
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
    # Tab walks the card's own order, field then Cancel then Unlock, and comes back to the field.
    for stop in cancel unlock field; do
        key -k Tab >/dev/null
        cap_unlock_expect ".focus == \"$stop\"" "Tab never reached $stop on the card"
    done
    key -k Return >/dev/null
    cap_unlock_expect '.phase == "wrong"' "a wrong passphrase never ended in the wrong state"
    state=$(ipc unlockState)
    [[ "$(jq -r .note <<< "$state")" == "That passphrase did not unlock $label." ]] \
        || fail "cap_unlock: the wrong note reads $(jq -r .note <<< "$state")"
    jq -e '.masked == true and .focus == "field"' <<< "$state" >/dev/null \
        || fail "cap_unlock: the wrong state lost its masked dots or the field, state $state"
    shot unlock-card-wrong
    keyfile="$dir/.cap-key"
    # The path is expanded here because the trap runs after this function's locals are gone.
    trap "rm -f -- ${keyfile@Q}" EXIT
    printf '%s' "$key" > "$keyfile"
    chmod 600 "$keyfile" || fail "cap_unlock: the key file could not be locked down"
    cap_unlock_type_key "$keyfile"
    rm -f "$keyfile"
    trap - EXIT
    keyfile=""
    end=$((SECONDS + 15))
    while (( SECONDS < end )); do
        state=$(ipc unlockState 2>/dev/null || printf unavailable)
        [[ "$(jq -r .phase <<< "$state" 2>/dev/null)" == "unlocking" ]] && { shot unlock-card-unlocking; shot_done=true; unlocking=$state; break; }
        [[ "$(jq -r .opened <<< "$state" 2>/dev/null)" == "false" ]] && break
        sleep 0.05
    done
    [[ "$shot_done" == true ]] || fail "cap_unlock: unlocking never showed before the dialog closed, last $state"
    # The right passphrase typed straight over the held dots unlocks, so the first key replaced the refused answer.
    jq -e '.masked == true' <<< "$unlocking" >/dev/null \
        || fail "cap_unlock: Unlocking must keep the masked dots, state $unlocking"
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
    end=$((SECONDS + 3))
    while (( SECONDS < end )); do
        ipc railEntries 2>/dev/null | jq -e '[.[] | select((.path | endswith("/S1LUKS")) and .locked == false)] | length == 1' >/dev/null 2>&1 && break
        sleep 0.05
    done
    ipc railEntries | jq -e '[.[] | select((.path | endswith("/S1LUKS")) and .locked == false)] | length == 1' >/dev/null \
        || fail "cap_unlock: the rail never drew the unlocked row, entries $(ipc railEntries | jq -c 'map({label,device,locked})')"
    jq -e --argjson at "$(ipc railCursor)" '.[$at].path | endswith("/S1LUKS")' <<< "$(ipc railEntries)" >/dev/null \
        || fail "cap_unlock: the rail cursor is at $(ipc railCursor), not on the unlocked row"
    # The fixture's container is named apart from its filesystem, so one name on the row and the footer is the container's.
    ipc railEntries | jq -e --arg label "$label" '[.[] | select((.path | endswith("/S1LUKS")) and .label == $label)] | length == 1' >/dev/null \
        || fail "cap_unlock: the unlocked row is not named $label, entries $(ipc railEntries | jq -c 'map({label,device,locked})')"
    shot unlock-unlocked-row
    [[ "$(ipc focusView)" == "list" ]] || fail "cap_unlock: focus is on $(ipc focusView), not the unlocked listing"
    crypt=$(ipc railEntries | jq -r '[.[] | select(.path | endswith("/S1LUKS")) | .device][0] // ""')
    [[ "$crypt" == /dev/* ]] || fail "cap_unlock: the unlocked row names no cleartext device"
    # Eject on a stick unmounts, locks and powers it off, so the cleartext device going away is the lock.
    if [[ -n "$shim" ]]; then
        # A loop container has no drive for gio to eject, so the loop lane locks it the way udisks does and shoots the rail.
        printf 'CAP SKIP unlock eject: %s is a loop container with no drive to eject; locked through udisksctl\n' "$dev"
        "${flea_launch_wrap[@]}" udisksctl unmount --no-user-interaction -b "$crypt" >/dev/null 2>&1 \
            || fail "cap_unlock: udisksctl could not unmount $crypt on the loop lane"
        "${flea_launch_wrap[@]}" udisksctl lock --no-user-interaction -b "$dev" >/dev/null 2>&1 \
            || fail "cap_unlock: udisksctl could not lock $dev on the loop lane"
    else
        key -M ctrl -k E -m ctrl >/dev/null
    fi
    end=$((SECONDS + 60))
    while (( SECONDS < end )); do
        status=$(ipc statusPrimary 2>/dev/null || printf "")
        [[ "$status" == *"could not be locked"* ]] && fail "cap_unlock: Eject left the container unlocked: [$status]"
        [[ -e "$crypt" ]] || break
        sleep 0.5
    done
    [[ -e "$crypt" ]] && fail "cap_unlock: $crypt is still open after Eject, status [$(ipc statusPrimary)]"
    # Sample input: "    readonly property int pollMs: 5000", the rail's device poll in ui/DeviceMounts.qml.
    rail_poll_ms=$(sed -n 's/^ *readonly property int pollMs: \([0-9]*\)$/\1/p' "$repo/ui/DeviceMounts.qml")
    [[ "$rail_poll_ms" =~ ^[0-9]+$ ]] || fail "cap_unlock: ui/DeviceMounts.qml names no pollMs"
    # Flea's Eject re-lists the rail as its unmount exits; the loop lane locks outside Flea, so it waits one device poll (ms clock).
    listing_ms=1000
    end=$(( $(date +%s%3N) + listing_ms ))
    [[ -n "$shim" ]] && end=$(( end + rail_poll_ms ))
    while (( $(date +%s%3N) < end )); do
        ipc railEntries 2>/dev/null | jq -e --arg crypt "$crypt" '[.[] | select(.device == $crypt)] | length == 0' >/dev/null 2>&1 && break
        sleep 0.05
    done
    ipc railEntries | jq -e --arg crypt "$crypt" '[.[] | select(.device == $crypt)] | length == 0' >/dev/null \
        || fail "cap_unlock: the rail still lists $crypt after Eject"
    status=$(ipc statusPrimary)
    [[ "$status" == *"could not be locked"* ]] && fail "cap_unlock: the status reports a lock failure: [$status]"
    settle
    shot unlock-ejected-rail
    kill_flea
    cap_unlock_launch "$dev" "$shim"
    cap_unlock_expect '.opened == true' "flea --unlock never opened the card on $dev"
    cap_unlock_expect ".label == $(jq -cn --arg l "$label" '$l') and (.subtitle | startswith($(jq -cn --arg l "$label · " '$l')) and test(" · [0-9][0-9.]* [kKMGT]?B · "))" \
        "flea --unlock never named the card after the rail row $label with its size"
    cap_resize 1100 700
    shot unlock-card-unlock
    key -k Escape >/dev/null
    cap_unlock_expect '.opened == false' "Escape never closed the card flea --unlock opened"
    printf 'CAP_UNLOCK locked=row card=typing,text,wrong,unlocking,unlock unlocked=row eject=locked,ejected\n'
    kill_flea
}
