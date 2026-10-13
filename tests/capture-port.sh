#!/usr/bin/env bash
# Replays capture assertions against controlled replies, including scaled controls and both outcomes of the open-file unmount.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
. "$repo/tools/flea-sandbox-guard"
sandbox_root_ok
scratch=$(mktemp -d "$SANDBOX_ROOT/flea-capture-port.XXXXXXXX") || exit 1
: > "$scratch/$SANDBOX_MARKER"
holder=""
cleanup() {
    if [[ -n "$holder" ]]; then kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true; fi
    sandbox_remove "$scratch"
}
trap cleanup EXIT
. "$repo/tests/ui-captures-cohesion.sh"
. "$repo/tests/ui-captures-b72.sh"
. "$repo/tests/ui-captures-unlock.sh"
. "$repo/tests/ui-captures-archives.sh"
checks=0
failed=0
coh_theme=replay
check() {
    checks=$((checks + 1))
    if [[ "$2" == "$3" ]]; then printf 'CAPTUREPORT PASS %s\n' "$1"; else
        printf 'FAIL capture-port %s: got [%s], expected [%s]\n' "$1" "$2" "$3"
        failed=$((failed + 1))
    fi
}
fail() { printf 'refused capture: %s\n' "$*" >&2; exit 1; }
settle() { :; }
# Real holder processes retain their cwd; only polling advances the clock to bound negative controls.
sleep() { if [[ "$1" == 60 ]]; then command sleep "$@"; else SECONDS=$((SECONDS + 5)); command sleep 0.01; fi; }
ipc() {
    case "$1" in
        cohesionControls) printf '%s\n' "$control_json" ;;
        railEntries) printf '%s\n' "$rail_json" ;;
        statusPrimary) printf '%s\n' "$footer" ;;
    esac
}
key() { actions=$((actions + 1)); }
click_rail_row() { actions=$((actions + 1)); clicked_row="$1"; }
menu_seek() { :; }
shot() { shots=$((shots + 1)); }
mountpoint() { [[ "$mount_live" == true ]]; }

target='{"kind":"DialogButton","name":"Open","x":100,"y":100,"w":80,"h":30,"targetX":140,"targetY":115}'
control_json='{"controls":[{"kind":"DialogButton","name":"Open","x":102,"y":101,"w":80,"h":30,"pressed":true}]}'
coh_wait_flag "$target" pressed >/dev/null; check "a scaled held button keeps its identity at the hit point" "$?" 0
control_json='{"controls":[{"kind":"DialogButton","name":"Cancel","x":102,"y":101,"w":80,"h":30,"pressed":true}]}'
coh_wait_flag "$target" pressed >/dev/null; check "another control at the same point cannot satisfy the press" "$?" 1
control_json='{"controls":[{"kind":"DialogButton","name":"Open","x":250,"y":101,"w":80,"h":30,"pressed":true}]}'
coh_wait_flag "$target" pressed >/dev/null; check "the same name at another point cannot satisfy the press" "$?" 1
control_json='{"controls":[{"kind":"DialogButton","name":"Open","x":102,"y":101,"w":80,"h":30,"pressed":false}]}'
coh_wait_flag "$target" pressed >/dev/null; check "an unpressed control cannot satisfy the press" "$?" 1
control_json='{"controls":[{"kind":"MediaPlay","name":"Play","x":100,"y":100,"w":24,"h":24,"exposed":true,"hoverable":false,"pressable":true,"pressed":true}]}'
b72_flag_at 112 112 hovered media >/dev/null; check "media hover requires its actual exposed play target" "$?" 0
b72_flag_at 112 112 pressed media >/dev/null; check "media held press requires the actual TapHandler state" "$?" 0
control_json='{"controls":[]}'
b72_flag_at 112 112 hovered media >/dev/null; check "an absent media target never passes" "$?" 1

mount="$scratch/S1LUKS"
label="Locked container"
actions=0 shots=0 inuse_receipt=in-use mount_live=false rail_json='[]' footer=''
cap_unlock_unmount_in_use "$mount" Unmount > "$scratch/row-gone.log"
check "a removed unlocked row skips without navigating or starting a cwd holder" "$? $actions $shots $holder $inuse_receipt" '0 0 0  skipped'
grep -q '^CAP SKIP unlock-unmount-in-use:' "$scratch/row-gone.log"; check "the removed-row skip records its reason" "$?" 0
rail_json=$(jq -cn --arg mount "$mount" '[{path:$mount,device:"/dev/mapper/fixture",label:"S1LUKS",locked:false}]')
cap_unlock_unmount_in_use "$mount" Unmount > "$scratch/mount-gone.log"
check "a stale row with no actual mount also skips before cd" "$? $actions $shots $holder $inuse_receipt" '0 0 0  skipped'
mkdir "$mount"
mount_live=true inuse_receipt=in-use footer='S1LUKS is busy; close what is using it and try again.'
rail_json=$(jq -cn --arg mount "$mount" '[{path:$mount,label:"Favourite",device:""},{path:$mount,device:"/dev/mapper/fixture",label:"S1LUKS",locked:false}]')
cap_unlock_unmount_in_use "$mount" Unmount > "$scratch/in-use.log"
check "a mounted row uses its filesystem name and captures the refusal" "$? $actions $shots $holder $inuse_receipt" '0 2 1  in-use'
check "a favourite for the mount cannot replace the actual unlocked device row" "$clicked_row" 1
footer='Locked container is busy; close what is using it and try again.'
(
    trap 'if [[ -n "$holder" ]]; then kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true; fi' EXIT
    cap_unlock_unmount_in_use "$mount" Unmount
) > "$scratch/wrong-name.log" 2>&1
check "the locked container's name cannot satisfy the mounted-row refusal" "$?" 1

# Drive the actual themed archive case with its UI steps stubbed; fixture_home_make still enforces the real destructive-path guard.
fixture_root="$scratch/fixtures"
sandbox_make "$fixture_root"
flea_bin=/usr/bin/true
fixture_home_make() { sandbox_scratch "$1"; mkdir -p "$1/.local/state/omarchy/current/theme"; }
cap_archives_format_hue() { :; }
cap_archives_format_open() { :; }
cap_archives_format_walk() { :; }
assert_theme() { :; }
kill_flea() { :; }
case_cap_archives_format_kanagawa > "$scratch/archive.log" 2>&1
check "the nested theme HOME passes the unchanged guard in the real archive case" "$?" 0
check "the theme HOME has a marked direct parent" "$([[ -f "$fixture_root/cap-archives-format-kanagawa-home/$SANDBOX_MARKER" ]] && echo yes || echo no)" yes
printf 'CAPTUREPORT DONE checks=%s failed=%s\n' "$checks" "$failed"
[[ "$failed" == 0 ]]
