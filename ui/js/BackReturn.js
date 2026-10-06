.pragma library

// Back and Forward entries and the landing ui/PaneSwap.qml runs in the rows' turn.

// A stack entry names the directory and the row its cursor stood on; bare paths read as empty rows.
function makeEntry(path, name, index) {
    return { path: String(path), name: String(name || ""), index: Math.max(0, Math.floor(Number(index) || 0)) }
}

function pathOf(entry) {
    return typeof entry === "string" ? entry : String(entry.path || "")
}

function asEntry(target) {
    return typeof target === "string" ? makeEntry(target, "", 0) : target
}

// The departing cursor; leaving a walk names no row, so the landing stays at the top.
function capture(pane) {
    var walk = pane.searchMode === "results" || (pane.searchFrom || "").length > 0
    var row = !walk && pane.rowFor ? pane.rowFor(pane.cursorIndex) : null
    return makeEntry(pane.path, row ? row.n : "", walk ? 0 : pane.cursorIndex)
}

// One step through the stacks after Nav's guard, popping before the open pushes back.
function travel(pane, from, to) {
    var stack = pane[from]
    var target = asEntry(stack[stack.length - 1])
    pane[to] = (pane[to] || []).concat([capture(pane)])
    pane[from] = stack.slice(0, -1)
    pane.openWithoutHistory(pathOf(target), { restore: target })
}

// The landing in the rows reply's turn: name, then clamped index, then the top.
function landRestore(pane, entry) {
    if (!entry)
        return
    if (pane.path !== entry.path || (pane.searchMode || "").length > 0 || pane.total === 0)
        return
    var name = String(entry.name || "")
    if (name.length > 0) {
        for (var i = 0; i < pane.rows.length; i++) {
            if (String(pane.rows[i].n) === name) {
                pane.setCursor(pane.held + i)
                return
            }
        }
    }
    pane.setCursor(Math.min(entry.index, pane.total - 1))
}
