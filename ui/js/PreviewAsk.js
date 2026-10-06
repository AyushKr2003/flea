.pragma library

.import "PreviewSettle.js" as PreviewSettle
.import "ExtThumbs.js" as ExtThumbs

// The cursor row's single thumbnail ask, shared by the pre-capture early ask and load()'s own
// askThumb, so both spend the same gates and the second finds the row asked and sends nothing twice.

// Sample input: workFor with canRead, storageKnown, one selection, index 3, rowT, unasked and local
// storage answers {ask: [3], drop: [], cacheOnly: false}.
function workFor(o) {
    if (!o.canRead || !o.storageKnown || o.selectionCount > 1) return null
    if (o.index < 0 || o.rowT !== true || o.asked === true) return null
    if (ExtThumbs.manualHold(o.storageClass, o.preview)) return null
    return { ask: [o.index], drop: [], cacheOnly: ExtThumbs.cacheOnly(o.storageClass, o.preview) }
}

// The idle half of the early ask is the settle's own rule: a walk step trails and asks nothing early.
function earlyWorkFor(o) {
    if (PreviewSettle.plan(o.now, o.lastMoveAt, o.interval, o.key, o.lastMoveKey, o.armed) !== "now")
        return null
    return workFor(o)
}
