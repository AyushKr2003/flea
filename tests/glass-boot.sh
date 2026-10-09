#!/usr/bin/env bash
# The real entry, offscreen: a glass launch makes the window clear before it exists, any other launch keeps the
# opaque literal, read back through the IPC seam's glass reader once the first listing has answered.
set -u
cd "$(dirname "$0")/.." || exit 1
. "$PWD/tools/flea-sandbox-guard"
command -v qs >/dev/null || { echo 'FAIL glass-boot needs qs'; exit 1; }
command -v dbus-run-session >/dev/null || { echo 'FAIL glass-boot needs a private D-Bus session'; exit 1; }
command -v jq >/dev/null || { echo 'FAIL glass-boot needs jq'; exit 1; }
bin=${FLEA_BIN:-$PWD/target/debug/flea}
[[ -x "$bin" ]] || { echo 'FAIL glass-boot needs the built backend'; exit 1; }
# A short root under /tmp, the way tests/shellload.sh makes one: the seam's socket path must fit the 108-byte sun_path.
sandbox_forbidden /tmp && sandbox_refuse "glass-boot: /tmp is inside a forbidden test target"
probe_root=$(mktemp -d /tmp/flea-gb.XXXXXX) || exit 1
FIXTURE_ROOT=$probe_root
sandbox_root_ok
probe_root=$SANDBOX_ROOT
: > "$probe_root/$SANDBOX_MARKER" || exit 1
work=$probe_root/w
runner=""
# The seam is built after the first rows, so readiness is polled; each call is bounded the way tests/xwstate.sh bounds it.
ready_polls=200
poll_s=0.1
call_timeout_s=5
cleanup() {
    [[ -n "$runner" ]] && kill -TERM -- "-$runner" 2>/dev/null
    [[ -n "$runner" ]] && wait "$runner" 2>/dev/null
    sandbox_remove "$work"
    # The root holds only its marker now; rmdir refuses anything that is not empty.
    rm -f -- "$probe_root/$SANDBOX_MARKER" && rmdir -- "$probe_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

failed=0
# leg NAME THEME_VALUE CLEAR WINDOW EARLY: THEME_VALUE "-" writes no shell.toml; EARLY is whether the colour was cleared before the window was shown.
leg() {
    local name=$1 value=$2 want_clear=$3 want_window=$4 want_early=$5
    local probe="$work/$name" answer attempt
    mkdir -p "$probe"/{home/fixture,state,data,cache,runtime,config} "$probe/home/.local/state/omarchy/current/theme" || return 1
    chmod 700 "$probe/runtime"
    printf 'a\n' > "$probe/home/fixture/a.txt"
    printf 'background = "#1e2030"\nforeground = "#d0d4e0"\naccent = "#7aa2f7"\n' > "$probe/home/.local/state/omarchy/current/theme/colors.toml"
    [[ "$value" != - ]] && printf '[flea]\nbackground-alpha = %s\n' "$value" > "$probe/home/.local/state/omarchy/current/theme/shell.toml"
    env HOME="$probe/home" XDG_STATE_HOME="$probe/state" "$bin" --ui-state '{"updates":{"autoCheck":false}}' >/dev/null || return 1
    # No FUSE bridge: gvfs would mount one in the runtime dir that can outlive the shell and block the cleanup.
    setsid env -u DISPLAY -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u FLEA_SELECT \
        HOME="$probe/home" XDG_CONFIG_HOME="$probe/config" XDG_STATE_HOME="$probe/state" \
        XDG_DATA_HOME="$probe/data" XDG_CACHE_HOME="$probe/cache" XDG_RUNTIME_DIR="$probe/runtime" \
        FLEA_PATH="$probe/home/fixture" FLEA_BIN="$bin" GVFS_DISABLE_FUSE=1 \
        QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=generic QT_FORCE_STDERR_LOGGING=1 \
        dbus-run-session -- qs -p "$PWD/ui/boot" > "$probe/qs.log" 2>&1 < /dev/null &
    runner=$!
    answer=""
    # qs ipc matches only instances on its own display, so the call goes without one, as the shell does.
    for ((attempt = 0; attempt < ready_polls; attempt++)); do
        answer=$(env -u DISPLAY -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE XDG_RUNTIME_DIR="$probe/runtime" QT_QPA_PLATFORM=offscreen timeout "$call_timeout_s" qs ipc -p "$PWD/ui/boot" call flea glass 2>/dev/null) && [[ "$answer" == '{'* ]] && break
        answer=""
        sleep "$poll_s"
    done
    kill -TERM -- "-$runner" 2>/dev/null
    wait "$runner" 2>/dev/null
    runner=""
    if [[ -z "$answer" ]]; then
        printf 'FAIL glass-boot %s: the seam never answered; log tail:\n' "$name"
        tail -10 "$probe/qs.log"
        failed=$((failed + 1))
        return 0
    fi
    local clear window early
    clear=$(jq -r .clear <<< "$answer")
    window=$(jq -r .window <<< "$answer")
    early=$(jq -r .early <<< "$answer")
    if [[ "$clear" == "$want_clear" && "$window" == "$want_window" && "$early" == "$want_early" ]]; then
        printf 'ok   glass-boot %s: clear=%s window=%s early=%s\n' "$name" "$clear" "$window" "$early"
    else
        printf 'FAIL glass-boot %s: clear=%s window=%s early=%s, expected clear=%s window=%s early=%s\n' "$name" "$clear" "$window" "$early" "$want_clear" "$want_window" "$want_early"
        failed=$((failed + 1))
    fi
}

leg glass 0.34 true '#00000000' true
leg stock - false '#101315' false
leg rounds 0.999 false '#101315' false
printf 'glass-boot: failed=%s\n' "$failed"
[[ "$failed" -eq 0 ]]
