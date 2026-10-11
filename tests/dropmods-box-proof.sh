#!/usr/bin/env bash
# Compositor-free proof of cap_dropmods_box and of the case trap surviving the shared hold helpers.
set -u
. "$(dirname "$0")/../tools/flea-sandbox-guard"
cd "$(dirname "$0")/.." || exit 1

# A marked sandbox of its own under the fixture root, so cleanup deletes only what this run owns.
test_root=$(mktemp -d "$FIXTURE_ROOT/flea-dropmods-box-XXXXXX") || exit 1
case $test_root in
  /*/*) ;;
  *) echo "FAIL: mktemp -d gave '$test_root', which is not an absolute path two components deep"; exit 1 ;;
esac
sandbox_require "$test_root" || exit 1
: > "$test_root/$SANDBOX_MARKER" || exit 1
cleanup() { sandbox_remove "$test_root"; }
trap cleanup EXIT

mkdir -p "$test_root/bin" || exit 1
# The fake compositor answers clients -j with two windows, so the pid select is pinned.
cat > "$test_root/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
printf '%s' '[{"class":"com.thisisgm.flea","pid":5,"at":[10,20],"size":[800,600]},{"class":"com.thisisgm.flea","pid":9,"at":[30,40],"size":[640,480]}]'
EOF
chmod +x "$test_root/bin/hyprctl" || exit 1
# The stub hold never touches hardware: press and release only need ydotool to exit 0.
cat > "$test_root/bin/ydotool" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$test_root/bin/ydotool" || exit 1

export PATH="$test_root/bin:$PATH"
export XDG_RUNTIME_DIR="$test_root"
fail() { printf 'DROPMODSBOX FAIL %s\n' "$*"; exit 1; }
repo="$PWD"
. "$repo/tests/ui-captures-dropmods.sh"
. "$repo/tests/ui-captures-drops.sh"
# Sample input: cap_dropmods_box 5 prints "10<TAB>20<TAB>800<TAB>600".
box=$(cap_dropmods_box 5) || exit 1
[[ "$box" == "$(printf '10\t20\t800\t600')" ]] || fail "box is '$box', want four fields 10 20 800 600"
printf 'DROPMODSBOX PASS box=%s\n' "$box"
# A stub case with no compositor: its EXIT trap must still own the exit after a hold.
window_box() { printf '0 0 800 600\n'; }
assert_focus() { return 0; }
pointer_glide() { return 0; }
settle() { return 0; }
ipc() { printf '{"opened":false}\n'; }
cap_dropmods_probe_pid=""
trap cap_dropmods_cleanup EXIT
cap_drops_press 1 1 || fail "stub press refused"
[[ "$(trap -p EXIT)" == *"cap_dropmods_cleanup"* ]] || fail "press replaced the case trap: $(trap -p EXIT)"
cap_drops_release || fail "stub release refused"
[[ "$(trap -p EXIT)" == *"cap_dropmods_cleanup"* ]] || fail "release cleared the case trap: $(trap -p EXIT)"
trap cleanup EXIT
printf 'DROPMODSBOX PASS traphold=cap_dropmods_cleanup\n'
printf 'DROPMODSBOX DONE checks=2 failed=0\n'
