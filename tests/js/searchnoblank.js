.import "../../ui/js/Swap.js" as Swap
.import "../../ui/js/Filter.js" as Filter
.import "filterfixture.js" as Fixture

// Search and "/" draw no blank or partial frame: the counter shapes ui/PaneSwap.qml reads per frame.

function run(check) {
    // The navigation arm is unchanged: a listing out drawn loading is blank, past the cap it is loading.
    check("a listing out drawn in the loading state before the cap is the blank frame",
        Swap.frameKind(true, "loading", false, 0, 0, false), "blank")
    check("after the cap it is the loading state a slow folder always showed",
        Swap.frameKind(true, "loading", true, 0, 0, false), "loading")
    check("held rows are no blank frame, and neither is a pane at rest",
        Swap.frameKind(true, "ready", false, 5, 40, false) + "|" + Swap.frameKind(false, "ready", false, 5, 40, false), "|")
    // A live answer holds old rows until its own rows land, so drawn never reaches zero beside a live count.
    check("search live with its rows drawn is no blank frame",
        Swap.frameKind(false, "ready", false, 3, 3, true), "")
    check("search live with rows cleared beside a count naming them is the blank frame",
        Swap.frameKind(false, "ready", false, 0, 3, true), "blank")
    check("an honest search zero carries its own zero, so it is no blank frame",
        Swap.frameKind(false, "empty", false, 0, 0, true), "")
    // "/" narrows in JS and never touches rows, so drawn stays the held window whatever matches.
    check("a filter with matches and its rows drawn is no blank frame",
        Swap.frameKind(false, "ready", false, 40, 40, true), "")
    check("a filter with no match keeps the held window drawn, so it is no blank frame either",
        Swap.frameKind(false, "ready", false, 40, 40, true), "")
    check("a filter with its rows cleared beside the directory count is the blank frame",
        Swap.frameKind(false, "ready", false, 0, 40, true), "blank")
    // Without a live session or a standing query the new arm stays silent, whatever rows say.
    check("no session and no query counts nothing even with no row drawn",
        Swap.frameKind(false, "ready", false, 0, 40, false), "")
    // Columns "/" narrows through shown with the held rows standing: the active column models shownTotal over pane.rows.
    var narrowed = Fixture.pane()
    Fixture.typeInto(narrowed, "screen")
    check("a Columns '/' narrowing never touches rows or total",
        narrowed.rows.length + "/" + narrowed.total + "/" + narrowed.shownTotal, "7/7/3")
    check("its frame is no blank: rows stand beside the directory count under the standing query",
        Swap.frameKind(false, "ready", false, narrowed.rows.length, narrowed.total, narrowed.filterQuery.length > 0), "")
    check("every drawn view position resolves to a held row",
        [0, 1, 2].map(function (v) { return narrowed.rowFor(Filter.at(narrowed.shown, v)) !== null }).join(","), "true,true,true")
    var nomatch = Fixture.pane()
    Fixture.typeInto(nomatch, "zzz")
    check("a Columns '/' no-match keeps the held window too, so the message draws over standing rows",
        nomatch.rows.length + "/" + nomatch.total + "/" + nomatch.shownTotal, "7/7/0")
    check("and the counter stays silent there as well",
        Swap.frameKind(false, "ready", false, nomatch.rows.length, nomatch.total, nomatch.filterQuery.length > 0), "")
    check("a Columns frame emptied for one turn under the standing query is the blank frame",
        Swap.frameKind(false, "ready", false, 0, nomatch.total, nomatch.filterQuery.length > 0), "blank")
}
