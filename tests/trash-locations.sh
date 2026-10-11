#!/usr/bin/env bash
# sandbox_trash_files_dir follows g_local_file_trash on both branches,
# and sandbox_trash_remove_own removes only owned mount-top entries.
set -u
set -o pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo/tools/flea-sandbox-guard"

checks=0
ok() {
    checks=$((checks + 1))
    printf 'ok %s\n' "$*"
}
fail() {
    printf 'TRASHLOC FAIL %s\n' "$*" >&2
    exit 1
}

sandbox_root_ok
test_root=$(mktemp -d "$SANDBOX_ROOT/flea-trashloc-XXXXXXXX") || fail "mktemp under $SANDBOX_ROOT failed"
: > "$test_root/$SANDBOX_MARKER" || fail "could not mark $test_root"
# The other-device home lives in a second marked root, so cleanup leaves nothing outside a marked root.
second_parent=""
second_root=""
second_dev=""
root_dev=$(stat -c %d -- "$test_root") || fail "no device for $test_root"
home_dev=$(stat -c %d -- "$HOME") || fail "no device for $HOME"
for candidate in /tmp /dev/shm; do
    [[ -d "$candidate" ]] || continue
    candidate_dev=$(stat -c %d -- "$candidate" 2>/dev/null) || continue
    [[ "$candidate_dev" != "$root_dev" && "$candidate_dev" != "$home_dev" ]] || continue
    second_parent=$(mktemp -d "$candidate/flea-trashloc-XXXXXXXX") || fail "mktemp under $candidate failed"
    second_root="$second_parent/root"
    mkdir -p "$second_root" || fail "could not make $second_root"
    : > "$second_root/$SANDBOX_MARKER" || fail "could not mark $second_root"
    second_dev=$candidate_dev
    break
done
[[ -n "$second_root" ]] || fail "no different-device directory for the other branch"
cleanup() {
    sandbox_remove "$test_root" 2>/dev/null || true
    if [[ -n "$second_root" && -n "$second_parent" ]]; then
        FIXTURE_ROOT=$second_parent sandbox_remove "$second_root" 2>/dev/null || true
        case "$second_parent" in /tmp/*|/dev/shm/*) rmdir -- "$second_parent" 2>/dev/null || true ;; esac
    fi
}
trap cleanup EXIT
# Only under a marked root, absolute and non-empty in the command.
wipe() {
    case "${1:-}" in "$test_root/"*|"$second_root/"*) rm -rf -- "$1" || fail "could not remove $1" ;; *) fail "refusing to remove outside a marked root: ${1:-}" ;; esac
}

uid=$(id -u) || fail "no uid"
export XDG_DATA_HOME="$test_root/data"
mkdir -p "$XDG_DATA_HOME" || fail "no data home"

# Home branch: item and HOME on one device.
home_same="$test_root/home"
mkdir -p "$home_same" || fail "no same-device home"
printf 'body\n' > "$test_root/item.txt" || fail "no fixture item"
got=$(sandbox_trash_files_dir "$test_root/item.txt" "$home_same") || fail "home branch refused"
[[ "$got" == "$XDG_DATA_HOME/Trash/files" ]] || fail "home branch gave $got, not $XDG_DATA_HOME/Trash/files"
ok "home branch: $got"

# The default HOME takes the same path when it sits on the item's device.
real_home="$HOME"
HOME="$home_same"
got=$(sandbox_trash_files_dir "$test_root/item.txt") || { HOME="$real_home"; fail "default HOME refused"; }
HOME="$real_home"
[[ "$got" == "$XDG_DATA_HOME/Trash/files" ]] || fail "default HOME gave $got"
ok "default HOME: $got"

# Other branch: HOME on another device, so the item's mount top answers.
home_other="$second_root/home"
mkdir -p "$home_other" || fail "no other-device home"
printf 'devices root=%s other=%s\n' "$root_dev" "$second_dev"

# One literal expectation per GLib layout, through a stat interposition for %m.
fake_top="$test_root/faketop"
slash_top="$test_root/slashtop"
mkdir -p "$fake_top" "$slash_top" || fail "no fake tops"
printf 'body\n' > "$fake_top/item.txt" || fail "no fake top item"
printf 'body\n' > "$slash_top/item.txt" || fail "no slash top item"
stat() {
    if [[ "${1:-}" == "-c" && "${2:-}" == "%m" ]]; then
        case "${@: -1}" in
            "$fake_top"*) printf '%s\n' "$fake_top"; return 0 ;;
            "$slash_top"*) printf '%s\n' "/"; return 0 ;;
        esac
    fi
    command stat "$@"
}
# Spec layout: sticky .Trash holding a user-owned plain .Trash/$UID.
wipe "$fake_top/.Trash"
mkdir -p "$fake_top/.Trash/$uid" || fail "no spec per-user trash"
chmod 1755 "$fake_top/.Trash" || fail "no sticky bit on the fake global trash"
got=$(sandbox_trash_files_dir "$fake_top/item.txt" "$home_other") || fail "spec layout refused"
[[ "$got" == "$fake_top/.Trash/$uid/files" ]] || fail "spec layout gave $got"
ok "sticky .Trash with owned .Trash/\$UID: $got"
# Sticky .Trash with no .Trash/$UID: GLib creates it, so it is usable.
wipe "$fake_top/.Trash"
mkdir -p "$fake_top/.Trash" || fail "no global trash"
chmod 1755 "$fake_top/.Trash" || fail "no sticky bit on the global trash"
got=$(sandbox_trash_files_dir "$fake_top/item.txt" "$home_other") || fail "absent per-user trash refused"
[[ "$got" == "$fake_top/.Trash/$uid/files" ]] || fail "absent per-user trash gave $got"
ok "sticky .Trash without .Trash/\$UID: $got"
# Sticky .Trash whose $UID entry is a file: not a directory, so not usable.
printf 'blocking\n' > "$fake_top/.Trash/$uid" || fail "no blocking file"
got=$(sandbox_trash_files_dir "$fake_top/item.txt" "$home_other") || fail "file entry refused"
[[ "$got" == "$fake_top/.Trash-$uid/files" ]] || fail "file entry gave $got"
ok "sticky .Trash with file .Trash/\$UID: $got"
# Sticky .Trash whose $UID entry is a symlink: lstat is not a directory, so not usable.
wipe "$fake_top/.Trash/$uid"
ln -s "$test_root" "$fake_top/.Trash/$uid" || fail "no per-user trash symlink"
got=$(sandbox_trash_files_dir "$fake_top/item.txt" "$home_other") || fail "symlink entry refused"
[[ "$got" == "$fake_top/.Trash-$uid/files" ]] || fail "symlink entry gave $got"
ok "sticky .Trash with symlinked .Trash/\$UID: $got"
# Non-sticky .Trash with a plain per-user dir: the sticky bit belongs on .Trash, so fallback.
wipe "$fake_top/.Trash"
mkdir -p "$fake_top/.Trash/$uid" || fail "no plain per-user trash"
chmod 0755 "$fake_top/.Trash" || fail "could not clear the sticky bit"
got=$(sandbox_trash_files_dir "$fake_top/item.txt" "$home_other") || fail "non-sticky choice refused"
[[ "$got" == "$fake_top/.Trash-$uid/files" ]] || fail "non-sticky choice gave $got"
ok "non-sticky .Trash: $got"
# Symlinked .Trash: lstat is not a directory, so fallback.
wipe "$fake_top/.Trash"
ln -s "$test_root" "$fake_top/.Trash" || fail "no global trash symlink"
mkdir -p "$fake_top/.Trash-$uid" || fail "no fake fallback trash"
got=$(sandbox_trash_files_dir "$fake_top/item.txt" "$home_other") || fail "symlink choice refused"
[[ "$got" == "$fake_top/.Trash-$uid/files" ]] || fail "symlink choice gave $got"
ok "symlinked .Trash falls back: $got"
# Absent .Trash: no global dir, so fallback.
wipe "$fake_top/.Trash"
got=$(sandbox_trash_files_dir "$fake_top/item.txt" "$home_other") || fail "absent choice refused"
[[ "$got" == "$fake_top/.Trash-$uid/files" ]] || fail "absent choice gave $got"
ok "absent .Trash falls back: $got"
# The root top names its trash with one slash.
got=$(sandbox_trash_files_dir "$slash_top/item.txt" "$home_other") || fail "slash top refused"
[[ "$got" == "/.Trash-$uid/files" ]] || fail "slash top gave $got"
ok "slash top: $got"
unset -f stat

# Own-entry removal: mount-top .trashinfo Path is relative to the mount top, as GLib writes it.
fake_files="$test_root/top/.Trash-$uid/files"
fake_info="$test_root/top/.Trash-$uid/info"
mkdir -p "$fake_files" "$fake_info" "$test_root/top/payload" || fail "no fake mount-top trash"
printf 'mine\n' > "$fake_files/own.txt" || fail "no owned files entry"
printf 'mine\n' > "$test_root/top/payload/own.txt" || fail "no owned payload"
printf '[Trash Info]\nPath=payload/own.txt\nDeletionDate=2026-10-11T00:00:00\n' > "$fake_info/own.txt.trashinfo" || fail "no owned info entry"
printf 'absolute\n' > "$fake_files/abs.txt" || fail "no absolute files entry"
printf 'absolute\n' > "$test_root/top/payload/abs.txt" || fail "no absolute payload"
printf '[Trash Info]\nPath=%s\nDeletionDate=2026-10-11T00:00:00\n' "$test_root/top/payload/abs.txt" > "$fake_info/abs.txt.trashinfo" || fail "no absolute info entry"
printf 'theirs\n' > "$fake_files/other.txt" || fail "no foreign files entry"
printf '[Trash Info]\nPath=/elsewhere/other.txt\nDeletionDate=2026-10-11T00:00:00\n' > "$fake_info/other.txt.trashinfo" || fail "no foreign info entry"
printf 'escaped\n' > "$fake_files/escape.txt" || fail "no escaping files entry"
printf '[Trash Info]\nPath=../../outside.txt\nDeletionDate=2026-10-11T00:00:00\n' > "$fake_info/escape.txt.trashinfo" || fail "no escaping info entry"
printf 'unclaimed\n' > "$fake_files/orphan.txt" || fail "no info-less entry"
sandbox_trash_remove_own "$fake_files" "$test_root" own.txt abs.txt other.txt escape.txt orphan.txt missing.txt || fail "owned removal refused"
[[ ! -e "$fake_files/own.txt" && ! -e "$fake_info/own.txt.trashinfo" ]] || fail "owned relative pair survived"
[[ ! -e "$fake_files/abs.txt" && ! -e "$fake_info/abs.txt.trashinfo" ]] || fail "owned absolute pair survived"
[[ "$(cat "$fake_files/other.txt")" == theirs && -f "$fake_info/other.txt.trashinfo" ]] || fail "foreign pair changed"
[[ -f "$fake_files/escape.txt" && -f "$fake_info/escape.txt.trashinfo" ]] || fail "escaping pair changed"
[[ -f "$fake_files/orphan.txt" ]] || fail "info-less entry changed"
[[ -d "$fake_files" && -d "$fake_info" ]] || fail "trash directories changed"
ok "owned removal keeps foreign entries and the trash itself"
# A per-user mount-top trash resolves its relative Path against the same top.
pu_files="$test_root/top/.Trash/$uid/files"
pu_info="$test_root/top/.Trash/$uid/info"
mkdir -p "$pu_files" "$pu_info" "$test_root/top/payload2" || fail "no fake per-user trash"
printf 'mine\n' > "$pu_files/pu.txt" || fail "no per-user files entry"
printf 'mine\n' > "$test_root/top/payload2/pu.txt" || fail "no per-user payload"
printf '[Trash Info]\nPath=payload2/pu.txt\nDeletionDate=2026-10-11T00:00:00\n' > "$pu_info/pu.txt.trashinfo" || fail "no per-user info entry"
sandbox_trash_remove_own "$pu_files" "$test_root" pu.txt || fail "per-user removal refused"
[[ ! -e "$pu_files/pu.txt" && ! -e "$pu_info/pu.txt.trashinfo" ]] || fail "per-user pair survived"
ok "per-user mount-top removal resolves relative Path"
sandbox_trash_remove_own "$fake_files" "$test_root" "../escape.txt" && fail "slash name accepted"
sandbox_trash_remove_own "$test_root/top" "$test_root" own.txt && fail "non-files trash accepted"
ok "removal refuses slash names and non-files trashes"

# Real cross-check: gio trash off the home device lands where the helper says; the test root first (a sandbox subvolume), else the second root.
gio_dir=$second_root
[[ "$root_dev" != "$home_dev" ]] && gio_dir=$test_root
gio_dev=$(stat -c %d -- "$gio_dir") || fail "no device for $gio_dir"
if ! command -v gio >/dev/null 2>&1; then
    printf 'skip gio cross-check: gio is not installed\n'
elif [[ "$gio_dev" == "$home_dev" ]]; then
    printf 'skip gio cross-check: no device outside $HOME\n'
else
    gio_name="gio-own-$uid-$$.txt"
    printf 'gio payload\n' > "$gio_dir/$gio_name" || fail "no gio payload"
    gio_out=$(gio trash "$gio_dir/$gio_name" 2>&1) || {
        wipe "$gio_dir/$gio_name"
        [[ "$gio_out" == *"not supported"* ]] || fail "gio trash refused $gio_name: $gio_out"
        printf 'skip gio cross-check: gio refuses trash here: %s\n' "$gio_out"
        printf 'TRASHLOC PASS checks=%s\n' "$checks"
        exit 0
    }
    [[ -e "$gio_dir/$gio_name" ]] && fail "gio trash left $gio_name in place"
    gio_top=$(stat -c %m -- "$gio_dir") || fail "no mount top for $gio_dir"
    gio_top=${gio_top%/}
    gio_trash=""
    for candidate in "$gio_top/.Trash/$uid" "$gio_top/.Trash-$uid"; do
        if [[ -f "$candidate/files/$gio_name" && -f "$candidate/info/$gio_name.trashinfo" ]]; then gio_trash="$candidate/files"; break; fi
    done
    [[ -n "$gio_trash" ]] || fail "gio put $gio_name outside $gio_top/.Trash and $gio_top/.Trash-$uid"
    got=$(sandbox_trash_files_dir "$gio_dir/probe" "$HOME") || fail "helper refused the gio branch"
    [[ "$got" == "$gio_trash" ]] || fail "helper named $got, gio used $gio_trash"
    sandbox_trash_remove_own "$gio_trash" "$gio_dir" "$gio_name" || fail "owned removal refused the gio entry"
    [[ ! -e "$gio_trash/$gio_name" && ! -e "${gio_trash%/files}/info/$gio_name.trashinfo" ]] || fail "gio entry survived owned removal"
    ok "gio cross-check: helper names gio's trash and removal clears the entry"
fi
printf 'TRASHLOC PASS checks=%s\n' "$checks"
