.pragma library
.import "Format.js" as Format

// The Properties card's Size and Contains lines for a folder: the walk's floor while it counts, the whole once it is done.
var TAIL = " · counting…"
var SIZE = {exact: "%1 (%2 bytes)", floor: "> %1 (%2 bytes)"}
var CONTAINS = {exact: ["%1 item", "%1 items"], floor: ["> %1 item", "> %1 items"]}

// Sample input: {bytes: 4096} from the properties reply; the walk's first floor is the folder's own entry.
function begin(facts) {
    return {bytes: facts.bytes, items: 0, partial: false, done: false}
}

// A progress or final reply folded into the walk; a cancelled or refused walk ends as the floor already counted, so the card never counts forever.
function next(walk, reply) {
    if (reply.cancelled)
        return walk.done ? walk : {bytes: walk.bytes, items: walk.items, partial: true, done: true}
    if (!reply.ok)
        return {bytes: walk.bytes, items: walk.items, partial: true, done: true}
    return {bytes: reply.bytes, items: reply.items, partial: reply.partial === true, done: reply.done === true}
}

// Sample input: size(13, null) is a file's own; size(0, walk) reads the walk. A partial walk stays a floor when done.
function size(bytes, walk) {
    var shown = walk ? walk.bytes : bytes
    var template = walk && (!walk.done || walk.partial) ? SIZE.floor : SIZE.exact
    return {value: template.arg(Format.size(shown)).arg(String(shown)), tail: walk && !walk.done ? TAIL : ""}
}

function contains(walk) {
    if (!walk)
        return null
    var forms = !walk.done || walk.partial ? CONTAINS.floor : CONTAINS.exact
    return {value: forms[walk.items === 1 ? 0 : 1].arg(Format.count(walk.items)), tail: walk.done ? "" : TAIL}
}

function escape(text) {
    return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// StyledText: the value in the Text's own colour and only the tail in `muted`, on the value's line.
function styled(line, muted) {
    if (!line.tail)
        return escape(line.value)
    return "%1<font color=\"%2\">%3</font>".arg(escape(line.value)).arg(muted).arg(escape(line.tail))
}
