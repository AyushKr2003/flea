#!/usr/bin/env bash
# tests/ui-captures-dropmods.sh cap_dropmods_wait_target against ipc doubles: a leg lands on its own whole drag sentence and on no other line.
set -u
cd "$(dirname "$0")/.." || exit 1

failed=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; failed=1; }

MARKER=.flea-test-sandbox
box=$(mktemp -d) || exit 1
: > "$box/$MARKER"
# Removes only an absolute, non-empty root that still carries its marker.
cleanup() {
    case $box in
        /?*) [ -f "$box/$MARKER" ] && rm -rf -- "$box" ;;
    esac
}
trap cleanup EXIT

# The helper and the state it reads, cut out of the case file as shipped.
eval "$(sed -n -e '/^cap_dropmods_[a-z_]*=/p' -e '/^cap_dropmods_wait_target()/,/^}/p' tests/ui-captures-dropmods.sh)"

move_line='Move 1 item to sub · ctrl at lift copies'
copy_line='Copy 1 item to sub'

# Sample input, ipc statusActivityState: {"activities":[{"id":0,"text":"Copy 1 item to sub","running":false,...}],...}, a drag line always id 0.
# d_text is the drag line, d_running its transfer flag, d_after the poll it first shows on, d_other a second activity listed before it.
run() {
    local want=$1
    shift
    (
        polls="$box/polls.$BASHPID"
        sleep() { command sleep 0.05; }
        fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
        ipc() {
            [ "$1" = statusActivityState ] || return 1
            local n=0 shown=true
            [ ! -f "$polls" ] || n=$(<"$polls")
            n=$((n + 1))
            printf '%s\n' "$n" > "$polls"
            [ "$n" -ge "$d_after" ] || shown=false
            jq -nc --arg other "$d_other" --arg text "$d_text" --argjson running "$d_running" --argjson shown "$shown" '
                {activities: [(if $other != "" then {id: 7, text: $other, running: false, cancelling: false, ownerPath: "/d", ownerFocused: true} else empty end),
                              (if $shown then {id: 0, text: $text, running: $running, cancelling: false, ownerPath: "/d", ownerFocused: true} else empty end)],
                 errors: 0, notice: ""}'
        }
        d_text="" d_running=false d_after=1 d_other=""
        "$@"
        # SECONDS counts whole seconds, so 3 leaves at least 2 s of polls for the late line.
        cap_dropmods_wait_s=3
        cap_dropmods_wait_target "$want"
        printf 'landed\n'
    )
}

out=$(run "$move_line" eval "d_text='$move_line'")
[ "$out" = landed ] && ok "leg a1 lands on the move sentence a plain lift shows" || bad "the move sentence must land, got: $out"

out=$(run "$copy_line" eval "d_text='$copy_line'")
[ "$out" = landed ] && ok "leg a2 lands on the copy sentence a ctrl lift shows" || bad "the copy sentence must land, got: $out"

out=$(run "$copy_line" eval "d_text='$copy_line' d_after=4")
[ "$out" = landed ] && ok "a line that shows on the fourth poll lands" || bad "a late line must land, got: $out"

out=$(run "$move_line" eval "d_other='Copied 1 item' d_text='$move_line'")
[ "$out" = landed ] && ok "a second activity ahead of the drag line does not hide it" || bad "the drag line beside another activity must land, got: $out"

out=$(run "$copy_line" eval "d_text='$move_line'")
[ "$out" = "FAIL: cap_dropmods: no drag line reading \"$copy_line\" (status lines: $move_line)" ] \
    && ok "the move sentence never answers the copy leg and the failure names what stood" || bad "a move line must not answer the copy leg, got: $out"

out=$(run "$move_line" eval "d_text='$copy_line'")
[ "$out" = "FAIL: cap_dropmods: no drag line reading \"$move_line\" (status lines: $copy_line)" ] \
    && ok "the copy sentence never answers the move leg" || bad "a copy line must not answer the move leg, got: $out"

out=$(run "$copy_line" eval "d_text='$copy_line · too wide to drag out'")
[ "$out" = "FAIL: cap_dropmods: no drag line reading \"$copy_line\" (status lines: $copy_line · too wide to drag out)" ] \
    && ok "a line with the reach note is not the leg's sentence" || bad "a reach note must not answer, got: $out"

out=$(run "$copy_line" eval "d_text='$copy_line' d_running=true")
[ "$out" = "FAIL: cap_dropmods: no drag line reading \"$copy_line\" (status lines: none)" ] \
    && ok "a running transfer carrying the sentence is not a drag line" || bad "a running activity must not answer, got: $out"

out=$(run "$copy_line" eval "d_text='$copy_line' d_after=99")
[ "$out" = "FAIL: cap_dropmods: no drag line reading \"$copy_line\" (status lines: none)" ] \
    && ok "no activity at all never lands" || bad "an empty bar must not land, got: $out"

[ "$failed" = 0 ] || exit 1
printf 'DROPMODSWAIT DONE\n'
