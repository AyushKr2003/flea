# RunFile board captures: the run card for a script, an ELF, an AppImage and a missing-bit file, each with the ring on its default and on every other button.

# Run and Run in terminal are pressed only on a harmless fixture script that writes a marker inside this case's own test root.

# Poll runCardState until .opened matches the want ("true" or "false").
runfile_wait_card() {
    local want="$1" seen="" poll
    for poll in $(seq 1 100); do
        seen=$(ipc runCardState 2>/dev/null || printf '{"opened":"ipc-broken"}')
        if [[ "$want" == "true" ]]; then
            jq -e '.opened == true' <<< "$seen" >/dev/null 2>&1 && return 0
        else
            jq -e '.opened == false' <<< "$seen" >/dev/null 2>&1 && return 0
        fi
        sleep 0.05
    done
    fail "runfile: the run card never became opened=$want, last state $seen"
}

# Assert one jq expression against the open card's runCardState.
runfile_expect() {
    local expression="$1" label="$2" seen
    seen=$(ipc runCardState) || fail "runfile: runCardState unreadable for $label"
    jq -e "$expression" <<< "$seen" >/dev/null \
        || fail "runfile: $label, card state $seen"
}

# Step the card focus to the named button with h/l, the card's own keys.
runfile_focus() {
    local want="$1" seen="" focus="" buttons="" at="" target="" step
    for step in $(seq 1 8); do
        seen=$(ipc runCardState) || fail "runfile: runCardState unreadable seeking $want"
        focus=$(jq -er '.focus' <<< "$seen")
        [[ "$focus" == "$want" ]] && return 0
        buttons=$(jq -er '.buttons | join(" ")' <<< "$seen")
        at=$(jq -er --arg f "$focus" '.buttons | index($f)' <<< "$seen")
        target=$(jq -er --arg f "$want" '.buttons | index($f)' <<< "$seen")
        [[ "$at" =~ ^[0-9]+$ && "$target" =~ ^[0-9]+$ ]] \
            || fail "runfile: focus $focus has no seat beside $want in $buttons"
        if (( at > target )); then key h >/dev/null; else key l >/dev/null; fi
        settle
    done
    fail "runfile: focus never reached $want, last state $seen"
}

# Put the cursor on the named row, press Enter and wait for the card.
runfile_open() {
    local name="$1"
    seek_row_named "$name" || fail "runfile: no row named $name"
    key -k Return >/dev/null
    runfile_wait_card true
    settle
}

# Close the card with Escape and wait for it to leave.
runfile_close() {
    key -k Escape >/dev/null
    runfile_wait_card false
    settle
}

# Poll the Open with dialog until .opened matches the want.
runfile_wait_openwith() {
    local want="$1" seen="" poll
    for poll in $(seq 1 100); do
        seen=$(ipc openWithState 2>/dev/null || printf '{"opened":"ipc-broken"}')
        [[ "$(jq -r '.opened' <<< "$seen" 2>/dev/null)" == "$want" ]] && return 0
        sleep 0.05
    done
    fail "runfile: Open with never became opened=$want, last state $seen"
}

# One Esc dismisses the head sticky error, which otherwise masks every later sentence.
runfile_dismiss_error() {
    local poll
    [[ "$(ipc statusError 2>/dev/null)" == "true" ]] || return 0
    key -k Escape >/dev/null
    for poll in $(seq 1 100); do
        [[ "$(ipc statusError 2>/dev/null)" == "false" ]] && return 0
        sleep 0.05
    done
    fail "runfile: the refusal never left the bar, still showing $(ipc lastMessage)"
}

case_cap_runfile() {
    local dir="$fixture_root/cap-runfile" saved_path="$PATH" poll
    sandbox_scratch "$dir"
    mkdir -p "$dir/bin"
    # A gio that never opens: run-card kinds exit before it, data.bin is refused into Open with.
    printf '#!/bin/sh\nif [ "$1" = open ]; then exit 1; fi\nexec /usr/bin/gio "$@"\n' > "$dir/bin/gio"
    chmod +x "$dir/bin/gio"
    # The one harmless script Run may press: it writes one marker beside itself and nothing else.
    printf '#!/bin/sh\nprintf ok > "$(dirname "$0")/tool.ran"\n' > "$dir/tool.sh"
    chmod +x "$dir/tool.sh"
    printf '#!/bin/sh\nprintf ok > "$(dirname "$0")/changed.ran"\n' > "$dir/changed.sh"
    chmod +x "$dir/changed.sh"
    printf '#!/nonexistent/interp\nprintf ok > "$(dirname "$0")/badinterp.ran"\n' > "$dir/badinterp.sh"
    chmod 755 "$dir/badinterp.sh"
    printf '#!/bin/sh\necho ran >> "$(dirname "$0")/slow.ran"\nsleep 3\n' > "$dir/slow.sh"
    chmod +x "$dir/slow.sh"
    cp /bin/true "$dir/elfprog" || fail "runfile: no /bin/true to copy the ELF from"
    chmod +x "$dir/elfprog"
    # A fake AppImage: ELF magic with the AI tag at offset 8, whatever the name.
    python3 - "$dir/app.AppImage" <<'PY'
import sys
open(sys.argv[1], 'wb').write(b'\x7fELF\x02\x01\x01\x00AI\x01' + b'\x00' * 200)
PY
    chmod +x "$dir/app.AppImage"
    printf '#!/bin/sh\nprintf hi\n' > "$dir/plain.sh"
    chmod 644 "$dir/plain.sh"
    printf 'not-a-program-binary-blob' > "$dir/data.bin"
    seed_ui_state "$fixture_root/cap-runfile-state" '{"keys":"default","view":"list"}'
    export PATH="$dir/bin:$PATH"
    launch "$dir"
    export PATH="$saved_path"
    wait_listing 9
    cap_resize 1100 700
    # A script with a shebang: Cancel, Open as text, Run and Run in terminal, ring on the default.
    runfile_open tool.sh
    runfile_expect '.opened == true and .kind == "script" and (.buttons | join(",") == "cancel,text,run,terminal") and .focus == "terminal" and .default == "terminal" and .title == "tool.sh is a program"' "script default"
    shot cap-runfile-script-default
    runfile_focus run
    runfile_expect '.focus == "run" and .default == "terminal"' "script focus run"
    shot cap-runfile-script-focus-run
    runfile_focus text
    runfile_expect '.focus == "text" and .default == "terminal"' "script focus text"
    shot cap-runfile-script-focus-text
    runfile_focus cancel
    runfile_expect '.focus == "cancel" and .default == "terminal"' "script focus cancel"
    shot cap-runfile-script-focus-cancel
    runfile_close
    # Opening the card spawns nothing: the marker may only appear after a deliberate Run below.
    [[ ! -e "$dir/tool.ran" ]] || fail "runfile: tool.sh spawned on open, before any Run"
    # An ELF: the same four buttons the script draws.
    runfile_open elfprog
    runfile_expect '.opened == true and .kind == "elf" and (.buttons | join(",") == "cancel,text,run,terminal") and .focus == "terminal" and .default == "terminal" and .title == "elfprog is a program"' "elf default"
    shot cap-runfile-elf-default
    runfile_focus run
    shot cap-runfile-elf-focus-run
    runfile_focus text
    shot cap-runfile-elf-focus-text
    runfile_focus cancel
    shot cap-runfile-elf-focus-cancel
    runfile_close
    # An AppImage with no handler: Open as text stays off, Run in terminal stays the default.
    runfile_open app.AppImage
    runfile_expect '.opened == true and .kind == "appimage" and (.buttons | join(",") == "cancel,run,terminal") and .focus == "terminal" and .default == "terminal" and .title == "app.AppImage is a program"' "appimage default"
    shot cap-runfile-appimage-default
    runfile_focus run
    runfile_expect '.focus == "run" and .default == "terminal"' "appimage focus run"
    shot cap-runfile-appimage-focus-run
    runfile_focus cancel
    runfile_expect '.focus == "cancel" and .default == "terminal"' "appimage focus cancel"
    shot cap-runfile-appimage-focus-cancel
    runfile_close
    # A program-shaped file missing its bit gains the Make executable path.
    runfile_open plain.sh
    runfile_expect '.opened == true and .kind == "script" and (.buttons | join(",") == "cancel,text,make,run,terminal") and .focus == "terminal" and .default == "terminal" and .title == "plain.sh is a program"' "make default"
    shot cap-runfile-make-default
    runfile_focus run
    shot cap-runfile-make-focus-run
    runfile_focus make
    runfile_expect '.focus == "make" and .default == "terminal"' "make focus make"
    shot cap-runfile-make-focus-make
    runfile_focus text
    shot cap-runfile-make-focus-text
    runfile_focus cancel
    shot cap-runfile-make-focus-cancel
    runfile_close
    # A file no app claims opens the approved Open with dialog instead of an error.
    seek_row_named data.bin || fail "runfile: no row named data.bin"
    key -k Return >/dev/null
    runfile_wait_openwith true
    settle
    # The registry is merged from the installed apps, so only one app row and eyebrow-shaped nulls are asserted.
    [[ "$(ipc openWithState | jq -er '[.rows[] | select(.label != null)] | length')" -ge 1 ]] \
        || fail "runfile: Open with offers no application for data.bin"
    [[ "$(ipc openWithState | jq -er '[.rows[] | select(.label == null and .eyebrow == null)] | length')" == "0" ]] \
        || fail "runfile: Open with draws an app row with no name, which is a product defect"
    shot cap-runfile-openwith
    key -k Escape >/dev/null
    runfile_wait_openwith false
    settle
    # The one allowed Run: the harmless script writes its marker and the card closes silent.
    runfile_open tool.sh
    runfile_focus run
    key -k Return >/dev/null
    runfile_wait_card false
    for poll in $(seq 1 200); do [[ -s "$dir/tool.ran" ]] && break; sleep 0.05; done
    [[ -s "$dir/tool.ran" ]] || fail "runfile: Run never wrote the marker, bar says $(ipc lastMessage)"
    printf 'RUNFILE ran marker=%s\n' "$(cat "$dir/tool.ran")"
    # A file changed since the card asked is refused instead of run.
    runfile_open changed.sh
    printf '# touched\n' >> "$dir/changed.sh"
    runfile_focus run
    key -k Return >/dev/null
    wait_message "That file changed since the card asked, so it was not run."
    [[ ! -e "$dir/changed.ran" ]] || fail "runfile: the changed file still ran"
    shot cap-runfile-refused-changed
    runfile_dismiss_error
    # A program the system cannot spawn fails at Run; it is built before the ask so the card names it as Run meets it.
    runfile_open badinterp.sh
    runfile_focus run
    key -k Return >/dev/null
    wait_message "Nothing on this system could run that file."
    [[ ! -e "$dir/badinterp.ran" ]] || fail "runfile: the bad-interpreter file still ran"
    shot cap-runfile-refused-spawn
    runfile_dismiss_error
    # A second Run while the slow one still runs starts a second copy: each spawn appends one line as it starts.
    runfile_open slow.sh
    # The card opened, nothing started yet: the marker may only land after the Run below.
    [[ ! -e "$dir/slow.ran" ]] || fail "runfile: slow.sh spawned on open, before any Run"
    runfile_focus run
    key -k Return >/dev/null
    runfile_wait_card false
    for poll in $(seq 1 200); do [[ -s "$dir/slow.ran" ]] && break; sleep 0.05; done
    [[ "$(wc -l < "$dir/slow.ran" 2>/dev/null)" == 1 ]] || fail "runfile: the first run never landed, bar says $(ipc lastMessage)"
    # The lane is per-press by detached-launch design: flea --run spawns and exits, so a second Run starts a second copy instead of refusing one already running.
    runfile_open slow.sh
    runfile_focus run
    key -k Return >/dev/null
    runfile_wait_card false
    for poll in $(seq 1 200); do [[ "$(wc -l < "$dir/slow.ran")" == 2 ]] && break; sleep 0.05; done
    [[ "$(wc -l < "$dir/slow.ran")" == 2 ]] || fail "runfile: the second run never landed, bar says $(ipc lastMessage)"
    # Make executable reuses the menu batch path, so one undo restores the bit.
    runfile_open plain.sh
    runfile_focus make
    key -k Return >/dev/null
    runfile_wait_card false
    wait_message "Made it executable."
    [[ "$(stat -c '%a' "$dir/plain.sh")" == "744" ]] \
        || fail "runfile: plain.sh stayed $(stat -c '%a' "$dir/plain.sh"), not 744"
    shot cap-runfile-made-executable
    key z >/dev/null
    wait_message "Undid the permissions."
    [[ "$(stat -c '%a' "$dir/plain.sh")" == "644" ]] \
        || fail "runfile: undo left $(stat -c '%a' "$dir/plain.sh"), not 644"
    # the generic line follows a launcher failure that is none of spawn, noexec or a change, which no fixture makes
    printf 'CAP SKIP runfile-refused-other: That program could not be run. needs a launcher failure no fixture makes\n'
    # needs a noexec volume, driven by the controller
    printf 'CAP SKIP runfile-refused-noexec: a noexec volume cannot be made safely here\n'
    # needs a text editor the harness must not launch outside the test root, driven by the controller
    printf 'CAP SKIP runfile-open-text: Open as text would launch outside the test root\n'
    # needs a terminal the harness must not open on the display, driven by the controller
    printf 'CAP SKIP runfile-run-terminal: Run in terminal would open outside the test root\n'
    # needs a desktop handler claiming the AppImage type, driven by the controller
    printf 'CAP SKIP runfile-appimage-handler: no installed handler names this AppImage type here\n'
    printf 'CAP_RUNFILE script=4 elf=4 appimage=3 make=5 openwith=1 run=2 refused=2 made=1\n'
    kill_flea
}
