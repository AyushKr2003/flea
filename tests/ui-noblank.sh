# Defines the native listing-swap case; tests/ui.sh supplies the guarded fixture and IPC helpers.

# The stub's two late directories: 80 ms is inside Swap.js HOLD_MS and still swaps, 2.5 s outlasts the cap and its IPC reads.
noblank_held_delay_s=0.08
noblank_held_min_ms=80
noblank_slow_delay_s=2.5
# The cap is a QTimer, which may fire up to 5 percent early at this interval.
noblank_cap_min_ms=140

# One read of ui/PaneSwap.qml describe() through ui/Ipc.qml swapState, the record noblank_expect parses.
noblank_state() {
    ipc swapState
}

# A listing that has landed in whichever view is up: the path, the count, and nothing left in flight.
noblank_landed() {
    local want_path="$1" want_total="$2" path=unavailable total=unavailable flight=unavailable
    for _attempt in $(seq 1 300); do
        path=$(ipc path 2>/dev/null || printf unavailable)
        total=$(ipc total 2>/dev/null || printf unavailable)
        flight=$(ipc listInFlight 2>/dev/null || printf true)
        [[ "$path" == "$want_path" && "$total" == "$want_total" && "$flight" == false ]] && return 0
        sleep 0.05
    done
    fail "noblank: the listing never landed on $want_path with $want_total rows; path=$path total=$total inFlight=$flight"
}

# The two records either side of one navigation, held to a jq condition over $b (before) and $a (after).
# Sample input, each of $b and $a: {"holding":false,"fellBack":false,"holds":2,"fallbacks":0,"blankFrames":0,"loadingFrames":0,"last":{"ms":38,"end":"landed"}}
noblank_expect() {
    local name="$1" before="$2" after="$3" condition="$4"
    jq -e -n --argjson b "$before" --argjson a "$after" "$condition" >/dev/null \
        || fail "noblank: $name broke '$condition'; before $before after $after"
}

# One navigation, shot issued and landed: held for at least minimum ms, swapped before the cap, and no frame drawn with no row.
noblank_step() {
    local name="$1" want_path="$2" want_total="$3" minimum="$4" before after
    shift 4
    before=$(noblank_state)
    "$@" >/dev/null
    shot "noblank-$name-issued"
    noblank_landed "$want_path" "$want_total"
    shot "noblank-$name-landed"
    after=$(noblank_state)
    noblank_expect "$name" "$before" "$after" \
        "\$a.holds == \$b.holds + 1 and \$a.last.end == \"landed\" and \$a.last.ms >= $minimum
         and \$a.fallbacks == \$b.fallbacks and \$a.blankFrames == \$b.blankFrames and (\$a.holding | not)"
    printf 'NOBLANK %s held_ms=%s\n' "$name" "$(jq -r '.last.ms' <<< "$after")"
}

# The listing swap, AGENTS.md "The listing swap". Before it, opening a folder cleared the pane at the
# request and drew 3 to 4 frames of an empty list before the rows came back; the pane now holds the
# old rows until the new listing's rows land and swaps path, rows, cursor and selection in one turn.
# ui/PaneSwap.qml counts, from the window's own afterAnimating, every frame handed to the scene graph
# while a listing was out and the pane was drawn in the loading state, and the case requires that
# count not to move across Enter, a double click and BackSpace in a 300-file folder, in all three
# views. The stub backend below answers two directories late: one inside the cap, which must be held
# for its whole wait, and one past it, which must fall back to the loading state and is the control
# that proves the counter sees frames at all, since the loading frames it counts are drawn empty too.
case_noblank() {
    local dir="$fixture_root/noblank" bin="$fixture_root/noblank-bin" real_bin="$flea_bin" i
    local before after
    sandbox_scratch "$dir"
    mkdir -p "$dir/inner" "$dir/held" "$dir/slow"
    for i in $(seq -w 1 300); do printf 'x\n' > "$dir/inner/file-$i.txt"; done
    for i in $(seq -w 1 40); do printf 'x\n' > "$dir/outer-$i.txt"; printf 'x\n' > "$dir/held/held-$i.txt"; done
    for i in 1 2 3; do printf 'x\n' > "$dir/slow/slow-$i.txt"; done

    # A relay to the real binary that holds back the two late directories' list requests and ends on quit.
    sandbox_scratch "$bin"
    cat > "$bin/flea" <<'SH'
#!/usr/bin/env bash
set -u
[[ "${1:-}" == --backend ]] || exec "$NOBLANK_REAL_BIN" "$@"
while IFS= read -r line; do
    case "$line" in
        *'"c":"list"'*"\"path\":\"$NOBLANK_HELD\""*) sleep "$NOBLANK_HELD_DELAY" ;;
        *'"c":"list"'*"\"path\":\"$NOBLANK_SLOW\""*) sleep "$NOBLANK_SLOW_DELAY" ;;
    esac
    printf '%s\n' "$line"
    [[ "$line" == *'"c":"quit"'* ]] && break
done | "$NOBLANK_REAL_BIN" --backend
SH
    chmod +x "$bin/flea"

    seed_ui_state "$fixture_root/noblank-state" '{"keys":"default","view":"list"}'
    local -x NOBLANK_REAL_BIN="$real_bin" NOBLANK_HELD="$dir/held" NOBLANK_SLOW="$dir/slow"
    local -x NOBLANK_HELD_DELAY="$noblank_held_delay_s" NOBLANK_SLOW_DELAY="$noblank_slow_delay_s"
    flea_bin="$bin/flea"
    launch "$dir"
    flea_bin="$real_bin"
    # held, inner, slow, then outer-01 to outer-40.
    wait_listing 43
    settle
    printf 'NOBLANK launch %s\n' "$(noblank_state)"

    goto_row 1
    noblank_step enter "$dir/inner" 300 0 key -k Return
    noblank_step backspace "$dir" 43 0 key -k BackSpace
    # The parent listing put the cursor back on inner, row 1, which is the row the double click lands on.
    noblank_step doubleclick "$dir/inner" 300 0 click_row 1 left --double
    noblank_step doubleclick-back "$dir" 43 0 key -k BackSpace

    key k >/dev/null
    settle
    noblank_step held "$dir/held" 40 "$noblank_held_min_ms" key -k Return
    noblank_step held-back "$dir" 43 0 key -k BackSpace

    # Past the cap: held first, then the loading state at once rather than after its own hold-off.
    key j >/dev/null
    key j >/dev/null
    settle
    before=$(noblank_state)
    key -k Return >/dev/null
    shot noblank-slow-issued
    for _attempt in $(seq 1 100); do
        [[ "$(noblank_state | jq -r '.fellBack')" == true ]] && break
        sleep 0.05
    done
    [[ "$(ipc state)" == loading && "$(noblank_state | jq -r '.fellBack')" == true ]] \
        || fail "noblank: the late listing never fell back to the loading state; $(noblank_state), state $(ipc state)"
    shot noblank-slow-loading
    noblank_landed "$dir/slow" 3
    shot noblank-slow-landed
    after=$(noblank_state)
    noblank_expect slow "$before" "$after" \
        "\$a.holds == \$b.holds + 1 and \$a.fallbacks == \$b.fallbacks + 1 and \$a.last.end == \"expired\"
         and \$a.last.ms >= $noblank_cap_min_ms and \$a.blankFrames == \$b.blankFrames
         and \$a.loadingFrames > \$b.loadingFrames and (\$a.fellBack | not)"
    printf 'NOBLANK slow held_ms=%s loading_frames=%s\n' "$(jq -r '.last.ms' <<< "$after")" \
        "$(jq -n --argjson b "$before" --argjson a "$after" '$a.loadingFrames - $b.loadingFrames')"
    noblank_step slow-back "$dir" 43 0 key -k BackSpace

    key k >/dev/null
    settle
    switch_view grid
    noblank_step grid-enter "$dir/inner" 300 0 key -k Return
    noblank_step grid-back "$dir" 43 0 key -k BackSpace
    switch_view columns
    noblank_step columns-enter "$dir/inner" 300 0 key -k Return
    noblank_step columns-back "$dir" 43 0 key -k BackSpace
    switch_view list

    printf 'NOBLANK enter=ok doubleclick=ok backspace=ok held=ok slow=ok grid=ok columns=ok %s\n' "$(noblank_state)"
    kill_flea
}

# The preview swap, AGENTS.md "The preview swap". Before it, a cursor move drew the
# next preview half-built: v0.3.4 shows 145 to 151 mid frames over 18 column moves and
# 13 to 15 over 16 Quick Look moves headless. The column holds the old picture until
# the new preview is whole and falls back to loading past Swap.HOLD_MS; Quick Look
# holds in follow() the same way. This reads ui/Ipc.qml previewSwapState, the same
# record tests/preview-swap.sh judges headless: holds, fallbacks and midFrames.
case_previewswap() {
    local dir="$fixture_root/previewswap"
    sandbox_scratch "$dir"
    mkdir -p "$dir/0-folder"
    # Real media, made the way case_views makes its clip: a zero-byte image or video fails to decode and Qt logs it.
    ffmpeg -y -f lavfi -i "testsrc=size=64x64" -frames:v 1 "$dir/a-image.jpg" >/dev/null 2>&1 || fail "previewswap: ffmpeg could not make a-image.jpg"
    ffmpeg -y -f lavfi -i "testsrc=duration=1:size=64x64:rate=10" "$dir/b-video.mp4" >/dev/null 2>&1 || fail "previewswap: ffmpeg could not make b-video.mp4"
    : > "$dir/c-doc.pdf"
    printf 'hello from flea\n' > "$dir/d-notes.txt"
    printf 'fn main() {}\n' > "$dir/e-main.rs"
    : > "$dir/f-report.odt"
    : > "$dir/g-font.ttf"
    : > "$dir/h-archive.zip"
    ffmpeg -y -f lavfi -i "testsrc=size=64x64" -frames:v 1 "$dir/i-photo.png" >/dev/null 2>&1 || fail "previewswap: ffmpeg could not make i-photo.png"

    seed_ui_state "$fixture_root/previewswap-state" '{"keys":"default","view":"columns"}'
    launch "$dir"
    wait_listing 10
    settle
    [[ "$(ipc viewMode)" == columns ]] || fail "previewswap: fixture did not open its columns view"

    local before after before_mid after_mid frame_rect picture_rect
    before=$(ipc previewSwapState)
    # Walk the whole preview row: each j holds the old picture until the new one is whole.
    goto_row 0
    settle
    local i
    for i in $(seq 1 9); do
        key j >/dev/null
        settle
    done
    for i in $(seq 1 9); do
        key k >/dev/null
        settle
    done
    shot previewswap-column-landed
    after=$(ipc previewSwapState)
    before_mid=$(jq -r '.column.midFrames // 0' <<< "$before")
    after_mid=$(jq -r '.column.midFrames // 0' <<< "$after")
    [[ "$(jq -r '.column.holds // 0' <<< "$after")" -gt "$(jq -r '.column.holds // 0' <<< "$before")" ]] \
        || fail "previewswap: the column walk took no hold; before $before after $after"
    [[ "$after_mid" == "$before_mid" ]] \
        || fail "previewswap: the column walk drew $((after_mid - before_mid)) half-built frame(s); before $before after $after"
    printf 'PREVIEWSWAP column holds=%s mid=%s fallbacks=%s\n' \
        "$(jq -r '.column.holds' <<< "$after")" "$after_mid" "$(jq -r '.column.fallbacks' <<< "$after")"

    # Quick Look follows the cursor the same way: Space opens, j/k move under the held picture.
    goto_row 1
    settle
    key -k space >/dev/null
    settle
    [[ "$(ipc previewOpen)" == "true" ]] || fail "previewswap: space did not open Quick Look"
    before=$(ipc previewSwapState)
    key j >/dev/null
    settle
    key j >/dev/null
    settle
    key k >/dev/null
    settle
    shot previewswap-look-landed
    key -k Escape >/dev/null
    settle
    after=$(ipc previewSwapState)
    before_mid=$(jq -r '.look.midFrames // 0' <<< "$before")
    after_mid=$(jq -r '.look.midFrames // 0' <<< "$after")
    [[ "$(jq -r '.look.holds // 0' <<< "$after")" -gt "$(jq -r '.look.holds // 0' <<< "$before")" ]] \
        || fail "previewswap: Quick Look took no hold across its moves; before $before after $after"
    [[ "$after_mid" == "$before_mid" ]] \
        || fail "previewswap: Quick Look drew $((after_mid - before_mid)) half-built frame(s); before $before after $after"
    printf 'PREVIEWSWAP look holds=%s mid=%s fallbacks=%s\n' \
        "$(jq -r '.look.holds' <<< "$after")" "$after_mid" "$(jq -r '.look.fallbacks' <<< "$after")"

    # A small clip's poster fills the frame the way its player does; a small image keeps its own size.
    seek_row_named "b-video.mp4"
    settle
    for _attempt in $(seq 1 60); do
        [[ "$(ipc previewColumnState)" == "video" && "$(ipc columnThumbShown)" == "true" ]] && break
        sleep 0.1
    done
    [[ "$(ipc previewColumnState)" == "video" && "$(ipc columnThumbShown)" == "true" ]] \
        || fail "previewswap: b-video.mp4 shows $(ipc previewColumnState), thumb shown $(ipc columnThumbShown)"
    for _attempt in $(seq 1 60); do
        [[ "$(ipc columnFrameReady)" == "true" ]] && break
        sleep 0.1
    done
    [[ "$(ipc columnFrameReady)" == "true" ]] \
        || fail "previewswap: b-video.mp4 frame never read Ready"
    frame_rect=$(ipc columnFrameRect)
    picture_rect=$(ipc columnPictureRect)
    [[ "$frame_rect" =~ ^-?[0-9]+\ -?[0-9]+\ [0-9]+\ [0-9]+$ ]] \
        || fail "previewswap: b-video.mp4 frame has no valid rectangle: $frame_rect"
    [[ "$picture_rect" =~ ^-?[0-9]+\ -?[0-9]+\ [0-9]+\ [0-9]+$ ]] \
        || fail "previewswap: b-video.mp4 picture has no valid rectangle: $picture_rect"
    read -r fx fy fw fh <<< "$frame_rect"
    read -r px py pw ph <<< "$picture_rect"
    printf 'PREVIEWSWAP poster frame=%s,%s,%s,%s picture=%s,%s,%s,%s\n' "$fx" "$fy" "$fw" "$fh" "$px" "$py" "$pw" "$ph"
    (( ph >= fh - 4 && ph <= fh )) \
        || fail "previewswap: the 64x64 clip poster is $pw x $ph in a $fw x $fh frame, not filled on its limiting side"
    (( 2 * px + pw - (2 * fx + fw) >= -4 && 2 * px + pw - (2 * fx + fw) <= 4 )) \
        || fail "previewswap: the clip poster is not centred horizontally in its frame"
    (( 2 * py + ph - (2 * fy + fh) >= -4 && 2 * py + ph - (2 * fy + fh) <= 4 )) \
        || fail "previewswap: the clip poster is not centred vertically in its frame"
    seek_row_named "a-image.jpg"
    settle
    for _attempt in $(seq 1 60); do
        [[ "$(ipc previewColumnState)" == "image" && "$(ipc columnThumbShown)" == "true" ]] && break
        sleep 0.1
    done
    [[ "$(ipc previewColumnState)" == "image" && "$(ipc columnThumbShown)" == "true" ]] \
        || fail "previewswap: a-image.jpg shows $(ipc previewColumnState), thumb shown $(ipc columnThumbShown)"
    for _attempt in $(seq 1 60); do
        [[ "$(ipc columnFrameReady)" == "true" ]] && break
        sleep 0.1
    done
    [[ "$(ipc columnFrameReady)" == "true" ]] \
        || fail "previewswap: a-image.jpg frame never read Ready"
    picture_rect=$(ipc columnPictureRect)
    [[ "$picture_rect" =~ ^-?[0-9]+\ -?[0-9]+\ [0-9]+\ [0-9]+$ ]] \
        || fail "previewswap: a-image.jpg picture has no valid rectangle: $picture_rect"
    read -r px py pw ph <<< "$picture_rect"
    printf 'PREVIEWSWAP still frame=%s,%s,%s,%s picture=%s,%s,%s,%s\n' "$fx" "$fy" "$fw" "$fh" "$px" "$py" "$pw" "$ph"
    (( pw >= 62 && pw <= 66 && ph >= 62 && ph <= 66 )) \
        || fail "previewswap: the 64x64 image draws at $pw x $ph, not its own size"

    printf 'PREVIEWSWAP column=ok look=ok %s\n' "$(ipc previewSwapState)"
    kill_flea
}

# One launch on the lookopen fixture in a view, from its own state seeded with patch.
lookopen_launch() {
    local dir="$1" view="$2" label="$3" patch="$4"
    seed_ui_state "$fixture_root/lookopen-state-$view-$label" "$patch"
    launch "$dir"
    wait_listing 4
    settle
    [[ "$(ipc viewMode)" == "$view" ]] || fail "lookopen: fixture did not open its $view view"
}

# One Space open and close of a row, held to previewSwapState's lookOpen; want_caps is the cap reveals it adds.
lookopen_step() {
    local view="$1" name="$2" want_caps="$3" before after empty0 empty1 caps0 caps1
    seek_row_named "$name"
    settle
    before=$(ipc previewSwapState)
    key -k space >/dev/null
    shot "lookopen-$view-$name-issued"
    settle
    [[ "$(ipc previewOpen)" == "true" ]] || fail "lookopen: space did not open Quick Look on $name in $view"
    # A cap reveal shows the loading state first, so a slow source lands after settle: wait up to 15 s for it.
    for _ in $(seq 60); do [[ "$(ipc previewSwapState | jq -r '.lookOpen.landed')" == true ]] && break; sleep 0.25; done
    shot "lookopen-$view-$name-landed"
    after=$(ipc previewSwapState)
    key -k Escape >/dev/null
    settle
    # Sample input: previewSwapState {"look":{...},"lookOpen":{"revealed":true,"landed":true,"lookEmptyFrames":0,"revealCaps":0},...}.
    empty0=$(jq -r '.lookOpen.lookEmptyFrames' <<< "$before"); empty1=$(jq -r '.lookOpen.lookEmptyFrames' <<< "$after")
    caps0=$(jq -r '.lookOpen.revealCaps' <<< "$before"); caps1=$(jq -r '.lookOpen.revealCaps' <<< "$after")
    [[ "$empty1" =~ ^[0-9]+$ && "$empty0" =~ ^[0-9]+$ ]] || fail "lookopen: previewSwapState carries no lookOpen counter: $after"
    [[ "$(jq -r '.lookOpen.revealed' <<< "$after")" == true && "$(jq -r '.lookOpen.landed' <<< "$after")" == true ]] \
        || fail "lookopen: $name in $view never revealed or landed: $after"
    [[ "$empty1" == "$empty0" ]] || fail "lookopen: $name in $view drew $((empty1 - empty0)) empty card or dim frame(s): $after"
    if (( want_caps )); then
        [[ "$caps1" == "$((caps0 + want_caps))" ]] || fail "lookopen: the slow $name in $view did not reveal by the cap: $after"
    else
        [[ "$caps1" == "$caps0" ]] || fail "lookopen: $name in $view revealed by the cap, not by its content: $after"
    fi
    printf 'LOOKOPEN view=%s file=%s empty=%s cap=%s\n' "$view" "$name" "$((empty1 - empty0))" "$((caps1 - caps0))"
}

# No Quick Look open draws its card or dim before its content (lookEmptyFrames); only the 8000x8000 PNG, thumbnails off, reveals by the cap.
case_lookopen() {
    local dir="$fixture_root/lookopen" view name
    sandbox_scratch "$dir"
    magick \( -size 440x354 xc:white -fill black -font Liberation-Sans -pointsize 24 -annotate +30+45 PAGEONE \) \
           \( -size 440x354 xc:white -fill black -font Liberation-Sans -pointsize 24 -annotate +30+45 PAGETWO \) "$dir/a-doc.pdf" \
        || fail "lookopen: magick could not make a-doc.pdf"
    ffmpeg -y -f lavfi -i "testsrc=size=320x240" -frames:v 1 "$dir/b-image.jpg" >/dev/null 2>&1 || fail "lookopen: ffmpeg could not make b-image.jpg"
    printf 'hello from flea\n' > "$dir/c-notes.txt"
    ffmpeg -y -f lavfi -i "testsrc=size=8000x8000" -frames:v 1 "$dir/d-large.png" >/dev/null 2>&1 || fail "lookopen: ffmpeg could not make d-large.png"
    for view in list columns; do
        lookopen_launch "$dir" "$view" default "{\"keys\":\"default\",\"view\":\"$view\"}"
        for name in a-doc.pdf b-image.jpg c-notes.txt; do lookopen_step "$view" "$name" 0; done
        lookopen_launch "$dir" "$view" thumbsoff "{\"keys\":\"default\",\"view\":\"$view\",\"preview\":{\"thumbnails\":\"off\"}}"
        lookopen_step "$view" d-large.png 1
        kill_flea
    done
}
