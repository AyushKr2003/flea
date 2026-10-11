#!/usr/bin/env bash
# tests/ui-captures-dropmods.sh window helpers against hyprctl and ipc doubles: geometry and focus are read per qs pid, and a lookup that fails ends the case.
set -u
cd "$(dirname "$0")/.." || exit 1

failed=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; failed=1; }

# The helpers and the pid route, cut out of the files that ship them.
eval "$(sed -n -e '/^cap_dropmods_box()/,/^}/p' -e '/^cap_dropmods_addr_of_pid()/,/^}/p' -e '/^cap_dropmods_active_pid()/,/^}/p' -e '/^cap_dropmods_focus_pid()/,/^}/p' tests/ui-captures-dropmods.sh)"
eval "$(sed -n '/^ipc_pid=""$/,/^}$/p' tests/ui.sh)"

# Sample input, hyprctl clients -j: [{"class":"com.thisisgm.flea","pid":11,"address":"0xa1","at":[0,40],"size":[900,700]}], one entry per window.
clients='[{"class":"com.thisisgm.flea","pid":11,"address":"0xa1","at":[0,40],"size":[900,700]},{"class":"com.thisisgm.flea","pid":22,"address":"0xb2","at":[900,40],"size":[950,700]},{"class":"other","pid":33,"address":"0xc3","at":[1,1],"size":[2,2]}]'
active=11
# The newest window answers the path route whichever one has focus, as two windows over one ShellId do.
route_reply=/two
flea_ui=/none
hyprctl() {
    case "$*" in
        "clients -j") printf '%s\n' "$clients" ;;
        "activewindow -j") printf '{"class":"com.thisisgm.flea","pid":%s}\n' "$active" ;;
        *) return 1 ;;
    esac
}
hypr_window_focus() { return 0; }
sleep() { :; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
omarchy-drive() { printf '%s\n' "$route_reply"; }
xw_ipc() {
    case "$1/$2" in
        11/path) printf '/one\n' ;;
        22/path) printf '/two\n' ;;
        *) return 1 ;;
    esac
}

out=$(cap_dropmods_box 22 2>&1)
[ "$out" = "900	40	950	700" ] && ok "the box is read for the qs pid asked for" || bad "box 22 must read the second window, got: $out"

out=$(cap_dropmods_box 99 2>&1)
[ "$out" = "FAIL: cap_dropmods: no native geometry for qs pid 99" ] && ok "a pid with no client fails by name" || bad "an unknown pid must fail by name, got: $out"

clients='[{"class":"com.thisisgm.flea","pid":11,"address":"0xa1","at":[0.5,40],"size":[900,700]}]'
out=$(cap_dropmods_box 11 2>&1)
[ "$out" = "FAIL: cap_dropmods: no native geometry for qs pid 11" ] && ok "a fractional geometry is no geometry" || bad "a fractional box must fail, got: $out"
clients='[{"class":"com.thisisgm.flea","pid":11,"address":"0xa1","at":[0,40],"size":[900,700]},{"class":"com.thisisgm.flea","pid":22,"address":"0xb2","at":[900,40],"size":[950,700]},{"class":"other","pid":33,"address":"0xc3","at":[1,1],"size":[2,2]}]'

# A caller's own read, as the case writes it: a failed lookup must end it, not hand it empty numbers.
site() { local wx wy ww wh; read -r wx wy ww wh < <(cap_dropmods_box "$1") || exit 1; printf 'reached %s\n' "$wx"; }
out=$( (site 99) 2>&1)
[ "$out" = "FAIL: cap_dropmods: no native geometry for qs pid 99" ] && ok "a caller reading a failed box stops there" || bad "a failed box must end the caller, got: $out"
[ -z "$(grep -n '<<< "\$(cap_dropmods_box' tests/ui-captures-dropmods.sh)" ] \
    && ok "no caller reads a box through a here-string, which swallows the failure" || bad "a here-string caller still hides a failed box"

active=11
ipc_pid=""
out=$( { cap_dropmods_focus_pid 11 /one && printf 'landed pid=%s path=%s\n' "$ipc_pid" "$(ipc path)"; } 2>&1)
[ "$out" = "landed pid=11 path=/one" ] && ok "the older window is read through its own pid, not the newest" || bad "focusing window 11 must read /one, got: $out"

active=22
out=$( { cap_dropmods_focus_pid 22 /two && printf 'landed pid=%s path=%s\n' "$ipc_pid" "$(ipc path)"; } 2>&1)
[ "$out" = "landed pid=22 path=/two" ] && ok "the newer window is read through its own pid" || bad "focusing window 22 must read /two, got: $out"

active=22
out=$(cap_dropmods_focus_pid 11 /one 2>&1)
[ "$out" = "FAIL: cap_dropmods: focus did not land on qs pid 11 (the active window is 22)" ] \
    && ok "a focus that stays on the other window fails by pid" || bad "a focus that did not land must fail, got: $out"

active=11
out=$(cap_dropmods_focus_pid 11 /two 2>&1)
[ "$out" = "FAIL: cap_dropmods: qs pid 11 does not show /two (ipc says /one)" ] \
    && ok "a window showing another path fails by pid" || bad "a wrong path must fail, got: $out"

out=$(cap_dropmods_focus_pid 99 /one 2>&1)
[ "$out" = "FAIL: cap_dropmods: no client address for qs pid 99" ] \
    && ok "a pid with no client ends the focus on one failure line" || bad "an unknown pid must end the focus alone, got: $out"

ipc_pid=""
[ "$(ipc path)" = "$route_reply" ] && ok "with no pid set ipc takes the path route" || bad "an empty ipc_pid must take the path route"

[ "$failed" = 0 ] || exit 1
printf 'DROPMODSWINDOWS DONE\n'
