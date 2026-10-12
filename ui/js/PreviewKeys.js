.pragma library

.import "Filter.js" as Filter
.import "Marks.js" as Marks
.import "Search.js" as Search
.import "Thumbs.js" as Thumbs

// What the preview overlay does with a key, split out of Focus.js at its 300-line hard cap the
// same way ui/js/Trash.js was: Focus.js decides which surface owns a key, and this is the surface.

// Left/Right's seek step, Task 22's operator ruling; act is the only reader.
var SEEK_MS = 5000
// The zoom ladder both PDF strips walk: the bottom rung fits the frame, one step a press, up to four times.
var PDF_ZOOM_MIN = 1
var PDF_ZOOM_MAX = 4
var PDF_ZOOM_STEP = 0.25

// A zoom after steps presses (negative steps down), kept on the ladder; the image pane walks the same rungs as the PDF.
function zoomStep(zoom, steps) {
    return Math.max(PDF_ZOOM_MIN, Math.min(PDF_ZOOM_MAX, zoom + steps * PDF_ZOOM_STEP))
}

function pdfAction(action, viewer) {
    var controls = viewer.pdfControls
    if (action === "focusNext" || action === "focusPrevious") {
        var step = action === "focusPrevious" ? -1 : 1
        var next = viewer.pdfControlIndex
        if (next < 0) next = step > 0 ? -1 : 0
        for (var i = 0; i < controls.length; i++) {
            next = (next + step + controls.length) % controls.length
            if (controls[next].enabled && controls[next].visible) {
                viewer.pdfControlIndex = next
                break
            }
        }
    } else if (action === "open" || action === "preview") {
        var control = controls[viewer.pdfControlIndex]
        if (control && control.enabled && control.visible) control.activated()
    } else if (action === "seekBack" || action === "parent") viewer.turnPage(-1)
    else if (action === "seekForward" || action === "pageForward") viewer.turnPage(1)
    else if (action === "zoomOut") viewer.zoomBy(-1)
    else if (action === "zoomIn") viewer.zoomBy(1)
    else if (action === "expand") viewer.toggleExpand()
    else if (action === "cursorDown" || action === "cursorUp") viewer.scrollPage(action === "cursorDown" ? 1 : -1)
}

// Space on a folder is a silent no-op; a file carries its cached thumbnail so the overlay shows it at once.
function open(root) {
    if (!Filter.cursorShown(root)) return
    var row = root.rowFor(root.cursorIndex)
    if (row && !row.d)
        root.quickLook().open(root.join(Search.baseOf(root), row.n), row.i, row.s, root.kindNames[row.k] || "",
            root.thumbState && root.thumbState.file ? Thumbs.fileFor(root.thumbState, root.cursorIndex) : "")
}

// Preview open: j/k move the cursor and the preview follows; escape always closes, and so does a
// second space, on every kind including media (decided 2026-09-11: pressing Space a second time
// closes the preview, the way Finder does). That reverses Task 22, which had space toggle
// play/pause on a media preview; the strip's own play control still does that with the pointer.
// Any key reveals the media strip, even one that does nothing else, matching "move the mouse or
// press anything" from the same ruling.
function act(action, root) {
    root.preview.revealStrip()
    switch (action) {
    case "cursorDown": Filter.moveCursor(root, 1); Marks.follow(root); follow(root); return
    case "cursorUp": Filter.moveCursor(root, -1); Marks.follow(root); follow(root); return
    case "preview": root.preview.close(); return
    // Space closes every kind now, so playback has its own key; it self-guards, because p reaches
    // this only in the media context and a still image has nothing to play.
    case "playPause":
        if (root.preview.isMedia) root.preview.togglePlay()
        return
    case "escape": root.preview.close(); return
    case "seekBack":
        if (root.preview.isPdf) root.preview.turnPage(-1)
        else root.preview.seek(-SEEK_MS)
        return
    case "seekForward":
        if (root.preview.isPdf) root.preview.turnPage(1)
        else root.preview.seek(SEEK_MS)
        return
    // h keeps its own "parent" name from keys.toml; turnPage self-guards, so a media preview
    // ignores both of these rather than seeking on a key the strip never advertised.
    case "parent": root.preview.turnPage(-1); return
    case "pageForward": root.preview.turnPage(1); return
    case "zoomOut": root.preview.zoomBy(-1); return
    case "zoomIn": root.preview.zoomBy(1); return
    case "zoomFit": root.preview.zoomFit(); return
    case "expand": root.preview.toggleExpand(); return
    // MediaMute rule 5: the flag is the preview's to flip, and it silences without pausing.
    case "mute": root.preview.toggleMute(); return
    // Decided 2026-10-03: r flips the open Markdown Quick Look between rendered and source, guarded on kind.
    case "markdownView":
        if (root.preview.isMarkdown) root.preview.toggleMarkdownView()
        return
    // The Markdown bar's close mark is its one control: Tab and Shift+Tab take the keyboard onto it and off it, and Return on it closes.
    case "focusNext":
    case "focusPrevious":
        if (root.preview.isMarkdown) root.preview.toggleMarkdownClose()
        return
    case "open":
        if (root.preview.isMarkdown && root.preview.markdownCloseFocused) root.preview.close()
        return
    }
}

// The row under the moved cursor, handed to Preview.follow so a held key settles before it reloads.
function follow(root) {
    if (!Filter.cursorShown(root)) return
    var row = root.rowFor(root.cursorIndex)
    if (row && !row.d)
        root.preview.follow(root.join(Search.baseOf(root), row.n), row.i, row.s, root.kindNames[row.k] || "",
            root.thumbState && root.thumbState.file ? Thumbs.fileFor(root.thumbState, root.cursorIndex) : "")
}
