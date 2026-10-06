.pragma library

// The columnsfilter fixture: matches interleave with non-matches in name order, so
// every step from a kept row must skip a hidden row. Query "ap" keeps rows 0, 2, 4,
// 6, 8 and 10: 6 of the 12 below.
function buildRows() {
    return [
        { n: "Apps", d: true, i: "folder", p: 493, s: 0, m: 1, t: false, k: 0 },
        { n: "Clips", d: true, i: "folder", p: 493, s: 0, m: 2, t: false, k: 0 },
        { n: "Maps", d: true, i: "folder", p: 493, s: 0, m: 2, t: false, k: 0 },
        { n: "balsam.txt", d: false, i: "text-x-generic", p: 420, s: 3, m: 3, t: false, k: 0 },
        { n: "caption.png", d: false, i: "text-x-generic", p: 420, s: 4, m: 4, t: false, k: 0 },
        { n: "drift.txt", d: false, i: "text-x-generic", p: 420, s: 5, m: 5, t: false, k: 0 },
        { n: "gap.md", d: false, i: "text-x-generic", p: 420, s: 6, m: 6, t: false, k: 0 },
        { n: "hold.txt", d: false, i: "text-x-generic", p: 420, s: 7, m: 7, t: false, k: 0 },
        { n: "napkin.txt", d: false, i: "text-x-generic", p: 420, s: 8, m: 8, t: false, k: 0 },
        { n: "orbit.md", d: false, i: "text-x-generic", p: 420, s: 9, m: 9, t: false, k: 0 },
        { n: "paper.pdf", d: false, i: "text-x-generic", p: 420, s: 10, m: 10, t: false, k: 0 },
        { n: "quince.txt", d: false, i: "text-x-generic", p: 420, s: 11, m: 11, t: false, k: 0 }
    ]
}

function buildParentRows() {
    return [
        { n: "studio", d: true, i: "folder", p: 493, s: 0, m: 1, t: false, k: 0 },
        { n: "field", d: true, i: "folder", p: 493, s: 0, m: 2, t: false, k: 0 },
        { n: "notes.txt", d: false, i: "text-x-generic", p: 420, s: 1, m: 3, t: false, k: 0 }
    ]
}
