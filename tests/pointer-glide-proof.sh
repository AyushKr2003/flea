#!/usr/bin/env bash
# Compositor-free proof of tests/lib/pointer-glide.sh against a fake hyprctl and an accelerating fake ydotool.
set -u
. "$(dirname "$0")/../tools/flea-sandbox-guard"
cd "$(dirname "$0")/.." || exit 1

# A marked sandbox of its own under the fixture root, so cleanup deletes only what this run owns.
test_root=$(mktemp -d "$FIXTURE_ROOT/flea-pointer-glide-XXXXXX") || exit 1
case $test_root in
  /*/*) ;;
  *) echo "FAIL: mktemp -d gave '$test_root', which is not an absolute path two components deep"; exit 1 ;;
esac
sandbox_require "$test_root" || exit 1
: > "$test_root/$SANDBOX_MARKER" || exit 1
cleanup() { sandbox_remove "$test_root"; }
trap cleanup EXIT

mkdir -p "$test_root/bin" || exit 1
# The fake compositor answers cursorpos from a state file in hyprctl's "640, 360" form, or a refusal when told to.
cat > "$test_root/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == cursorpos ]] || exit 2
[[ -f "$GLIDE_STATE.broken" ]] && { echo "error: no pointer"; exit 0; }
read -r x y < "$GLIDE_STATE"; printf '%s, %s\n' "$x" "$y"
EOF
# The fake uinput device logs each relative move and applies libinput-like acceleration past 4 px, or none when stuck.
cat > "$test_root/bin/ydotool" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == mousemove && "$2" == -x && "$4" == -y ]] || exit 2
echo "$3 $5" >> "$GLIDE_STATE.log"
[[ -f "$GLIDE_STATE.stuck" ]] && exit 0
read -r x y < "$GLIDE_STATE"
accel() { local d=$1; (( d > 4 || d < -4 )) && d=$((d * 9 / 5)); echo "$d"; }
echo "$((x + $(accel "$3"))) $((y + $(accel "$5")))" > "$GLIDE_STATE"
EOF
chmod +x "$test_root/bin/hyprctl" "$test_root/bin/ydotool" || exit 1

export PATH="$test_root/bin:$PATH" GLIDE_STATE="$test_root/pos" XDG_RUNTIME_DIR="$test_root"
. tests/lib/pointer-glide.sh
failed=0
check() {
    if [[ "$2" == "$3" ]]; then printf 'POINTERGLIDE PASS %s\n' "$1"; else printf 'POINTERGLIDE FAIL %s: got %s, want %s\n' "$1" "$2" "$3"; failed=$((failed + 1)); fi
}
start() { [[ "$GLIDE_STATE" == "$test_root/pos" && -n "$test_root" ]] || exit 1; rm -f -- "$GLIDE_STATE.log" "$GLIDE_STATE.stuck" "$GLIDE_STATE.broken"; echo "$1 $2" > "$GLIDE_STATE"; : > "$GLIDE_STATE.log"; }
near() { read -r x y < "$GLIDE_STATE"; (( x >= $1 - 2 && x <= $1 + 2 && y >= $2 - 2 && y <= $2 + 2 )) && echo yes || echo "no at $x,$y"; }

start 10 10; pointer_glide 900 -300; check "a far target past the origin is reached through acceleration" "$? $(near 900 -300)" "0 yes"
start 640 361; pointer_glide 640 360; check "a pointer already there still sends one motion out and back" "$? $(tr '\n' '|' < "$GLIDE_STATE.log")" "0 1 0|-1 0|"
start 0 0; touch "$GLIDE_STATE.broken"; pointer_glide 50 50; check "an unreadable cursorpos refuses before any motion" "$? $(wc -l < "$GLIDE_STATE.log")" "1 0"
start 0 0; touch "$GLIDE_STATE.stuck"; pointer_glide 500 500; check "a pointer that never moves gives up after 32 steps" "$? $(wc -l < "$GLIDE_STATE.log")" "1 32"
start 0 0; pointer_glide x 5; check "a malformed target is refused" "$? $(wc -l < "$GLIDE_STATE.log")" "1 0"
printf 'POINTERGLIDE DONE checks=5 failed=%d\n' "$failed"
[[ "$failed" == 0 ]]
