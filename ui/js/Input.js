.pragma library

// Delete carries DEL through libxkbcommon; retain SheetQuery's single-character semantics.
function isPrintable(text) {
    var s = String(text || "")
    return s.length === 1 && s >= " " && s !== "\u007f"
}

// Issue 287 pastes here: the two chords, read the way ui/js/Keymap.js matches keys.
// Only the four real modifiers count, so a keypad bit never changes the answer.
function isPasteKey(event) {
    var mods = event.modifiers & (Qt.ControlModifier | Qt.ShiftModifier | Qt.AltModifier | Qt.MetaModifier)
    return (event.key === Qt.Key_V && mods === Qt.ControlModifier)
        || (event.key === Qt.Key_Insert && mods === Qt.ShiftModifier)
}

// Pasted query text, first line only with control characters dropped, so a paste types
// exactly what typing the survivors would: the same isPrintable gate both query lines use,
// and lone surrogates dropped because neither line can type half a character.
function cleanPaste(text) {
    var line = String(text || "").split(/\r\n|[\r\n]/)[0]
    var out = ""
    for (var i = 0; i < line.length; i++) {
        var code = line.charCodeAt(i)
        if (code >= 0xd800 && code <= 0xdfff) {
            continue
        }
        var c = line.charAt(i)
        if (isPrintable(c)) {
            out += c
        }
    }
    return out
}
