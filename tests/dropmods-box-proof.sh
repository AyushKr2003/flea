#!/usr/bin/env bash
# Compositor-free proof of cap_dropmods_box against a fake hyprctl listing two windows.
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

export PATH="$test_root/bin:$PATH"
fail() { printf 'DROPMODSBOX FAIL %s\n' "$*"; exit 1; }
repo="$PWD"
. "$repo/tests/ui-captures-dropmods.sh"
# Sample input: cap_dropmods_box 5 prints "10<TAB>20<TAB>800<TAB>600".
box=$(cap_dropmods_box 5) || exit 1
[[ "$box" == "$(printf '10\t20\t800\t600')" ]] || fail "box is '$box', want four fields 10 20 800 600"
printf 'DROPMODSBOX PASS box=%s\n' "$box"
printf 'DROPMODSBOX DONE checks=1 failed=0\n'
