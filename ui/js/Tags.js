.pragma library

// Flea's seven tag names in menu order, which is also the 1 to 7 key order; src/backend/tags.rs NAMES is the same list.
var NAMES = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"]

// The digit each name answers to, "" when no digit names it.
function keyFor(name) {
    var at = NAMES.indexOf(name)
    return at < 0 ? "" : String(at + 1)
}

var APPLIED = "applied"
var MIXED = "mixed"
var ABSENT = "absent"

// Across a selection: applied when every file carries it, mixed when some do, absent otherwise.
function stateFor(files, name) {
    var have = 0
    for (var i = 0; i < files.length; i++) {
        if (files[i].indexOf(name) >= 0) {
            have++
        }
    }
    if (have === 0) {
        return ABSENT
    }
    return have === files.length ? APPLIED : MIXED
}

function statesFor(files) {
    var states = {}
    for (var i = 0; i < NAMES.length; i++) {
        states[NAMES[i]] = stateFor(files, NAMES[i])
    }
    return states
}

// The same states from a backend read: the names every target carries, then the names only some carry.
function statesFrom(applied, mixed) {
    var states = {}
    for (var i = 0; i < NAMES.length; i++)
        states[NAMES[i]] = applied.indexOf(NAMES[i]) >= 0 ? APPLIED : mixed.indexOf(NAMES[i]) >= 0 ? MIXED : ABSENT
    return states
}

// One function fills every placeholder, so no sentence is ever joined from fragments.
function fill(template) {
    var out = template
    for (var i = 1; i < arguments.length; i++)
        out = out.split("%" + i).join(String(arguments[i]))
    return out
}

// The status bar's own sentence after a tag change; the count agrees with ui/js/Ops.js nouns.
function statusLine(ok, name) {
    if (ok === 1) return fill("Tagged %1 item %2 \u00b7 z undoes", ok, name)
    return fill("Tagged %1 items %2 \u00b7 z undoes", ok, name)
}

// The same sentence for clearing every tag off the named rows.
function clearedLine(ok) {
    if (ok === 1) return fill("Removed all tags from %1 item \u00b7 z undoes", ok)
    return fill("Removed all tags from %1 items \u00b7 z undoes", ok)
}

// The same sentence for taking one tag off the named rows.
function removedLine(ok, name) {
    if (ok === 1) return fill("Removed %1 from %2 item \u00b7 z undoes", name, ok)
    return fill("Removed %1 from %2 items \u00b7 z undoes", name, ok)
}

// The line for a settagged answer, read from the op the backend applied rather than from the UI's guess.
function changedLine(op, ok, name) {
    if (op === "clear") return clearedLine(ok)
    return op === "remove" ? removedLine(ok, name) : statusLine(ok, name)
}

// The flyout's rows: seven swatches with digit hints, then Remove all tags under a separator.
var CLEAR_ID = "__clear__"
function tagEntries(states, fallback) {
    var out = []
    for (var i = 0; i < NAMES.length; i++) {
        out.push({ id: NAMES[i], label: NAMES[i], glyph: "tag", keyHint: String(i + 1), tagRow: { swatch: NAMES[i], fallback: fallback === true,
                   state: (states || {})[NAMES[i]] || ABSENT, digit: String(i + 1) } })
    }
    out.push({ separator: true })
    out.push({ id: CLEAR_ID, label: "Remove all tags", glyph: "x" })
    return out
}

// One rows reply: every row learns whether the folder's slot stands, and inUse gains the tags seen; fresh starts the latch over.
function stamp(items, latched, inUse, fresh) {
    var tagged = false
    var grew = false
    for (var i = 0; i < items.length; i++) {
        var names = items[i].tg
        if (names === undefined) continue
        tagged = true
        for (var j = 0; j < names.length; j++) {
            if (inUse[names[j]] === true) continue
            inUse[names[j]] = true
            grew = true
        }
    }
    var stands = tagged || (latched && !fresh)
    for (var k = 0; k < items.length; k++) items[k].shown = stands
    return { latched: stands, grew: grew }
}

// The TAGS section lists only tags in use, each row the rail's own entry shape.
function railEntries(inUse) {
    var out = []
    for (var i = 0; i < NAMES.length; i++) {
        if (inUse[NAMES[i]] === true)
            out.push({ label: NAMES[i], kind: "tag", tag: NAMES[i], glyph: "tag", swatch: NAMES[i], digit: String(i + 1) })
    }
    return out
}
