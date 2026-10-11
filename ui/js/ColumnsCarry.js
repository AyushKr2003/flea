.pragma library
.import "Columns.js" as Columns
.import "FolderSorts.js" as FolderSorts

// The columns view's peek-map reads, and Back's carry across a listing. A Back names the parent of
// the shown path, so its request asks the incoming ancestors before the list goes out, and its landing
// keeps them and seeds the folder left as the child column: the landing frame draws all three
// columns whole. Enter, a rail hop and a search exit plan nothing and clear the maps as before.

// A peek answers at most this many rows, src/backend/peek.rs PEEK_CAP.
var PEEK_CAP = 512

// The folder order a column asks under, as the tag its peek key and reply carry.
// Sample input: orderOf({ folderSorts: {}, rememberSort: true }, "/a", []) is "" for a folder with no order of its own.
function orderOf(state, path, drawn) {
    var order = FolderSorts.peekOrder(state.folderSorts, path, state.rememberSort, drawn)
    return Columns.orderTag(order.by, order.desc)
}

// A read of the peeked rows that a binding re-evaluates when a peek lands; version is the trigger.
function rowsFor(peeked, key, path, version) {
    return version >= 0 && path.length > 0 && peeked[key] ? peeked[key] : []
}

// -1 for a path that was not denied, so mode 0, the denial whose stat failed too, stays its own answer.
function deniedMode(denials, key, version) {
    return version >= 0 && denials[key] !== undefined ? denials[key] : -1
}

// What a drag from a peek column's row needs. Sample input: peekSource(pane, "/a", { "/a": { v: 7, w: false } }, 0).
function peekSource(pane, path, facts, version) {
    var held = version >= 0 ? facts[path] : undefined
    return path.length > 0 ? { pane: pane, dir: path, v: held ? held.v : 0, w: held ? held.w : true } : null
}

// True when the target is the parent of the shown path: the one hop whose child is the folder left.
// Sample input: isBack("/a/b/c", "/a/b") is true, isBack("/a/b", "/a/b/c") and isBack("/", "/") are false.
function isBack(here, target) {
    return String(target) !== String(here) && String(target) === Columns.ancestorParent(here)
}

// A peek sorts by name, folders first, unless the folder remembers its own order; the listing has to
// match that exactly or its rows would land in another order than the column's own reply.
// Sample input: sameOrder({ by: "name", desc: false, foldersFirst: true, groupByKind: false }, "") is true.
function sameOrder(list, tag) {
    return list.by === "name" && list.desc !== true && list.foldersFirst !== false && list.groupByKind !== true
        && (tag === "" || tag === "name0")
}

// The held first window as the rows a peek of that folder answers: n, d and i alone. A link's icon
// follows its target and an executable's follows its mode in a listing but not in a peek, so a
// window holding either seeds nothing. Sample input: peekRows([{ n: "a", d: false, i: "text-x-generic", s: 1 }], 1).
function peekRows(rows, count) {
    var out = []
    for (var i = 0; i < count; i++) {
        var row = rows[i]
        if (!row || row.l !== undefined || (Number(row.p) & 61440) === 40960 || (row.d !== true && row.i === "application-x-executable"))
            return null
        out.push({ n: row.n, d: row.d === true, i: row.i })
    }
    return out
}

// A request's plan, or null when it is no Back: the ancestors to ask beside the list, and the carry
// the landing reads. area is the columns view (its pane, peekKey and orderOf); asks are the
// ancestors the target shows. A scrolled, filtered or searched window, or one in another order, seeds nothing.
// Sample input: plan(area at "/a/b/c" listing "/a/b", ["/a"], { foldersFirst: true, groupByKind: false }).pre is ["/a"].
function plan(area, asks, state) {
    var p = area.pane, here = p.path, target = p.listingPath
    if (!isBack(here, target))
        return null
    var tag = area.orderOf(here), count = Math.min(p.windowSize, PEEK_CAP, p.total)
    var list = { by: p.backend.sortBy, desc: p.backend.sortDesc, foldersFirst: state.foldersFirst, groupByKind: state.groupByKind }
    var clean = p.held === 0 && p.filterQuery === "" && p.searchMode === "" && p.rows.length >= count && sameOrder(list, tag)
    return { target: target, seed: here, tag: tag, pre: asks.filter(function (path) { return path !== target && path !== here }),
             rows: clean ? peekRows(p.rows, count) : null, facts: { v: p.backend.dirDev || 0, w: p.backend.dirWritable !== false } }
}

// A new listing's peek maps: empty, except that a Back's landing keeps the answered ancestors it
// shows and seeds the folder left when its rows were carried under its present order. The asks
// still out are never kept: a reply that lands after this is asked again by the flight's refresh.
function landing(carry, area, asks) {
    var next = { peeked: {}, denials: {}, orders: {}, facts: {} }
    if (!carry || carry.target !== area.pane.path)
        return next
    for (var i = 0; i < asks.length; i++) {
        var path = asks[i], key = area.peekKey(path)
        if (area.peeked[key] === undefined)
            continue
        next.peeked[key] = area.peeked[key]
        next.orders[key] = area.peekOrders[key]
        if (area.denials[key] !== undefined) next.denials[key] = area.denials[key]
        if (area.peekFacts[path] !== undefined) next.facts[path] = area.peekFacts[path]
    }
    var seedKey = area.peekKey(carry.seed), seedTag = area.orderOf(carry.seed)
    if (carry.rows !== null && carry.tag === seedTag && next.peeked[seedKey] === undefined) {
        next.peeked[seedKey] = carry.rows
        next.orders[seedKey] = seedTag
        next.facts[carry.seed] = carry.facts
    }
    return next
}
