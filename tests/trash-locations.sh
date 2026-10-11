#!/usr/bin/env bash
# Focused control: sandbox_trash_files_dir follows g_local_file_trash on both branches,
# and sandbox_trash_remove_own removes only owned mount-top entries.
set -u
set -o pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo/tools/flea-sandbox-guard"

fail() {
    printf 'FAIL trash-locations: %s\n' "$*" >&2
    exit 1
}

sandbox_root_ok
test_root=$(mktemp -d "$SANDBOX_ROOT/flea-trashloc-XXXXXXXX") || fail "mktemp under $SANDBOX_ROOT failed"
: > "$test_root/$SANDBOX_MARKER" || fail "could not mark $test_root"
cleanup() {
    sandbox_remove "$test_root" 2>/dev/null || true
}
trap cleanup EXIT

uid=$(id -u) || fail "no uid"
export XDG_DATA_HOME="$test_root/data"
mkdir -p "$XDG_DATA_HOME" || fail "no data home"

# Home branch: item and HOME on one device, the exact store the dd and ddclick checks named.
home_same="$test_root/home"
mkdir -p "$home_same" || fail "no same-device home"
printf 'body\n' > "$test_root/item.txt" || fail "no fixture item"
got=$(sandbox_trash_files_dir "$test_root/item.txt" "$home_same") || fail "home branch refused"
[[ "$got" == "$XDG_DATA_HOME/Trash/files" ]] || fail "home branch gave $got, not $XDG_DATA_HOME/Trash/files"
echo "ok home branch: $got"

# The default HOME takes the same path when it sits on the item's device.
real_home="$HOME"
HOME="$home_same"
got=$(sandbox_trash_files_dir "$test_root/item.txt") || { HOME="$real_home"; fail "default HOME refused"; }
HOME="$real_home"
[[ "$got" == "$XDG_DATA_HOME/Trash/files" ]] || fail "default HOME gave $got"
echo "ok default HOME: $got"

# Other branch: HOME on another device, so the item's mount top answers.
root_dev=$(stat -c %d -- "$test_root") || fail "no device for $test_root"
home_other=""
for candidate in /dev/shm /tmp; do
    [[ -d "$candidate" ]] || continue
    if [[ "$(stat -c %d -- "$candidate")" != "$root_dev" ]]; then home_other="$candidate/flea-trashloc-home"; break; fi
done
[[ -n "$home_other" ]] || fail "no different-device directory for the other branch"
mkdir -p "$home_other" || fail "no other-device home"
other_dev=$(stat -c %d -- "$home_other") || fail "no device for $home_other"
printf 'devices root=%s other=%s\n' "$root_dev" "$other_dev"
top=$(stat -c %m -- "$test_root") || fail "no mount top for $test_root"
top=${top%/}
if [[ -d "$top/.Trash/$uid" && ! -L "$top/.Trash/$uid" ]] && [[ -k "$top/.Trash/$uid" ]]; then
    want="$top/.Trash/$uid/files"
else
    want="$top/.Trash-$uid/files"
fi
got=$(sandbox_trash_files_dir "$test_root/item.txt" "$home_other") || fail "other branch refused"
[[ "$got" == "$want" ]] || fail "other branch gave $got, not $want"
echo "ok other branch: $got"

# The .Trash/$UID versus .Trash-$UID choice, in a fake top through a stat interposition.
fake_top="$test_root/faketop"
mkdir -p "$fake_top" || fail "no fake top"
printf 'body\n' > "$fake_top/item.txt" || fail "no fake top item"
stat() {
    if [[ "${1:-}" == "-c" && "${2:-}" == "%m" && "${@: -1}" == "$fake_top"* ]]; then
        printf '%s\n' "$fake_top"
        return 0
    fi
    command stat "$@"
}
mkdir -p "$fake_top/.Trash/$uid" || fail "no fake per-user trash"
chmod 1755 "$fake_top/.Trash/$uid" || fail "no sticky bit on the fake per-user trash"
got=$(sandbox_trash_files_dir "$fake_top/item.txt" "$home_other") || fail "sticky choice refused"
[[ "$got" == "$fake_top/.Trash/$uid/files" ]] || fail "sticky choice gave $got"
echo "ok sticky .Trash/\$UID: $got"
chmod 0755 "$fake_top/.Trash/$uid" || fail "could not clear the sticky bit"
got=$(sandbox_trash_files_dir "$fake_top/item.txt" "$home_other") || fail "non-sticky choice refused"
[[ "$got" == "$fake_top/.Trash-$uid/files" ]] || fail "non-sticky choice gave $got"
echo "ok non-sticky .Trash-\$UID: $got"
rm -rf "$fake_top/.Trash" || fail "could not drop the fake per-user trash"
ln -s "$test_root" "$fake_top/.Trash" || fail "no fake trash symlink"
mkdir -p "$fake_top/.Trash-$uid" || fail "no fake fallback trash"
got=$(sandbox_trash_files_dir "$fake_top/item.txt" "$home_other") || fail "symlink choice refused"
[[ "$got" == "$fake_top/.Trash-$uid/files" ]] || fail "symlink choice gave $got"
echo "ok symlinked .Trash falls back: $got"
rm -f "$fake_top/.Trash" || fail "could not drop the fake trash symlink"
got=$(sandbox_trash_files_dir "$fake_top/item.txt" "$home_other") || fail "absent choice refused"
[[ "$got" == "$fake_top/.Trash-$uid/files" ]] || fail "absent choice gave $got"
echo "ok absent .Trash falls back: $got"
unset -f stat

# Own-entry removal: only pairs whose .trashinfo Path sits under the fixture root go.
fake_files="$test_root/top/.Trash-$uid/files"
fake_info="$test_root/top/.Trash-$uid/info"
mkdir -p "$fake_files" "$fake_info" "$test_root/payload" || fail "no fake mount-top trash"
printf 'mine\n' > "$fake_files/own.txt" || fail "no owned files entry"
printf '[Trash Info]\nPath=%s\nDeletionDate=2026-10-11T00:00:00\n' "$test_root/payload/own.txt" > "$fake_info/own.txt.trashinfo" || fail "no owned info entry"
printf 'theirs\n' > "$fake_files/other.txt" || fail "no foreign files entry"
printf '[Trash Info]\nPath=/elsewhere/other.txt\nDeletionDate=2026-10-11T00:00:00\n' > "$fake_info/other.txt.trashinfo" || fail "no foreign info entry"
printf 'unclaimed\n' > "$fake_files/orphan.txt" || fail "no info-less entry"
sandbox_trash_remove_own "$fake_files" "$test_root" own.txt other.txt orphan.txt missing.txt || fail "owned removal refused"
[[ ! -e "$fake_files/own.txt" && ! -e "$fake_info/own.txt.trashinfo" ]] || fail "owned pair survived"
[[ "$(cat "$fake_files/other.txt")" == theirs && -f "$fake_info/other.txt.trashinfo" ]] || fail "foreign pair changed"
[[ -f "$fake_files/orphan.txt" ]] || fail "info-less entry changed"
[[ -d "$fake_files" && -d "$fake_info" ]] || fail "trash directories changed"
echo "ok owned removal keeps foreign entries and the trash itself"
sandbox_trash_remove_own "$fake_files" "$test_root" "../escape.txt" && fail "slash name accepted"
sandbox_trash_remove_own "$test_root/top" "$test_root" own.txt && fail "non-files trash accepted"
echo "ok removal refuses slash names and non-files trashes"
printf 'TRASH_LOCATIONS branches=home,other choice=sticky,plain,symlink,absent removal=owned-only\n'
