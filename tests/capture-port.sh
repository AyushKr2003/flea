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
# Escape clears a standing footer unless escape_clears=false; Return (Unmount) shows footer_after when one is set.
key() {
    actions=$((actions + 1))
    case "$2" in
        Escape) [[ "${escape_clears:-true}" == true ]] && footer='' ;;
        Return) [[ -n "${footer_after:-}" ]] && footer=$footer_after ;;
    esac
    return 0
}
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
busy='S1LUKS is busy; close what is using it and try again.'
mount_live=true inuse_receipt=in-use footer='' footer_after=$busy
rail_json=$(jq -cn --arg mount "$mount" '[{path:$mount,label:"Favourite",device:""},{path:$mount,device:"/dev/mapper/fixture",label:"S1LUKS",locked:false}]')
cap_unlock_unmount_in_use "$mount" Unmount > "$scratch/in-use.log"
check "a mounted row uses its filesystem name and captures the refusal" "$? $actions $shots $holder $inuse_receipt" '0 2 1  in-use'
check "a favourite for the mount cannot replace the actual unlocked device row" "$clicked_row" 1
# The open-file leg can leave the same busy sentence standing; only a new one after Unmount counts.
actions=0 shots=0 footer=$busy footer_after=$busy
cap_unlock_unmount_in_use "$mount" Unmount > "$scratch/stale-cleared.log"
check "a standing busy sentence is cleared by Escape before Unmount" "$? $actions $shots $holder $footer" "0 3 1  $busy"
unlock_refused() {
    (
        trap 'if [[ -n "$holder" ]]; then kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true; fi' EXIT
        cap_unlock_unmount_in_use "$mount" Unmount
    ) > "$scratch/$1.log" 2>&1
    printf '%s %s' "$?" "$(grep -c -F -- "$2" "$scratch/$1.log")"
}
footer=$busy footer_after=''
check "a standing busy sentence with no new one after Unmount is refused" \
    "$(unlock_refused stale-only 'did not say it was busy')" '1 1'
footer=$busy footer_after=$busy escape_clears=false
check "a busy sentence that Escape never clears is refused before Unmount" \
    "$(unlock_refused stale-stuck 'the earlier busy sentence never cleared')" '1 1'
escape_clears=true footer='' footer_after='Locked container is busy; close what is using it and try again.'
check "the locked container's name cannot satisfy the mounted-row refusal" \
    "$(unlock_refused wrong-name 'did not say it was busy')" '1 1'
footer_after=''

# Drive the actual themed archive case with its UI steps stubbed; the fixture_home_make stub keeps its real sandbox_scratch guard.
fixture_root="$scratch/fixtures"
sandbox_make "$fixture_root"
flea_bin=/usr/bin/true
# The replay owns its 7z and theme, so the leg never depends on what the host or CI image installs.
mkdir -p "$scratch/bin" && printf '#!/bin/sh\nexit 0\n' > "$scratch/bin/7z" && chmod +x "$scratch/bin/7z"
PATH="$scratch/bin:$PATH"
printf 'foreground = "#dcd7ba"\n' > "$scratch/kanagawa-colors.toml"
kanagawa_colors="$scratch/kanagawa-colors.toml"
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
