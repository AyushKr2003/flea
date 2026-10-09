// Pixel pairs for tests/glass.qml, [r1, g1, b1, r2, g2, b2] over magenta then green, each channel c = p*a + m*(1 - a).
.pragma library

// Sample input: [174, 6, 175, 5, 174, 7], the plane #101315 at 0.34, solves to alpha 87 and colour [15, 18, 21].
function solvePair(v) {
    var a = 1 - ((v[0] - v[3]) + (v[4] - v[1]) + (v[2] - v[5])) / (3 * 255)
    var colour = a > 0 ? [v[3] / a, v[1] / a, v[5] / a].map(Math.round) : [0, 0, 0]
    return { alpha: Math.round(a * 255), colour: colour }
}

// The modal pixel pair of a box inside a w by h grab, solved; null for a box with no pixels.
function solve(px, box, w, h) {
    var counts = {}, best = "", bestCount = 0
    var x1 = Math.max(0, box.x), y1 = Math.max(0, box.y)
    var x2 = Math.min(w, box.x + box.w), y2 = Math.min(h, box.y + box.h)
    for (var y = y1; y < y2; y++)
        for (var x = x1; x < x2; x++) {
            var key = px(x, y).join(",")
            var n = (counts[key] || 0) + 1
            counts[key] = n
            if (n > bestCount) { bestCount = n; best = key }
        }
    if (bestCount === 0) return null
    return solvePair(best.split(",").map(Number))
}

// Pixels the backdrops reach untouched: no ground at all under them.
function holes(px, w, h) {
    var n = 0
    for (var y = 0; y < h; y++)
        for (var x = 0; x < w; x++) {
            var v = px(x, y)
            if (v[0] === 255 && v[1] === 0 && v[2] === 255 && v[3] === 0 && v[4] === 255 && v[5] === 0) n++
        }
    return n
}

// Pixels that differ between the backdrops: anything not fully opaque.
function seeThrough(px, w, h) {
    var n = 0
    for (var y = 0; y < h; y++)
        for (var x = 0; x < w; x++) {
            var v = px(x, y)
            if (v[0] !== v[3] || v[1] !== v[4] || v[2] !== v[5]) n++
        }
    return n
}
