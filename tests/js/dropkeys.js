.import "../../ui/js/Drag.js" as Drag
.import "dragfixture.js" as Fixture
.import "collidefixture.js" as CollideFixture
.import "sourcefixture.js" as Source

// #259: the drop follows the keys held at the drop, not the lift, run against the real ui/DropKeys.qml.
function run(check) {
    var rows = [{ n: "omarchy", d: true }, { n: "flea", d: true }, { n: "a.txt", d: false }, { n: "b.txt", d: false }]

    var plainDropMarker = Drag.markerPayload([0], false, "/d", 56)
    var copyDropMarker = Drag.markerPayload([0], true, "/d", 56)
    check("a drop holding ctrl copies a plain lift", Drag.dropVerb(plainDropMarker, Qt.MoveAction, 56, 1, -1), "copy")
    check("a drop holding shift moves a ctrl lift", Drag.dropVerb(copyDropMarker, Qt.CopyAction, 56, 0, 1), "move")
    check("a drop holding ctrl with shift links a plain lift", Drag.dropVerb(plainDropMarker, Qt.MoveAction, 56, 1, 1), "link")
    check("a drop that released ctrl moves a ctrl lift", Drag.dropVerb(copyDropMarker, Qt.CopyAction, 56, 0, -1), "move")
    check("a drop with no keys seen keeps the lift verb", Drag.dropVerb(plainDropMarker, Qt.MoveAction, 56, -1, -1), "move")
    check("and an absent seen keeps it too", Drag.dropVerb(plainDropMarker, Qt.MoveAction, 56), "move")
    check("dropHeld keeps the lift bit on -1", Drag.dropHeld(false, -1), false)
    check("dropHeld keeps an absent seen too", Drag.dropHeld(true), true)
    check("dropHeld takes a held key over the lift", Drag.dropHeld(false, 1), true)
    check("dropHeld takes a released key over the lift", Drag.dropHeld(true, 0), false)
    var shiftDrop = []
    Drag.dropInto(Fixture.pane(shiftDrop, [], rows), copyDropMarker, ["file:///d/a.txt"], "/d/omarchy", 56, "", "", Qt.CopyAction, 0, 1)
    check("a drop released ctrl and holding shift moves",
        shiftDrop.length === 1 ? shiftDrop[0].op : "nothing sent", "move")

    var parent = Qt.createComponent("QtQuick", "Item").createObject(null)
    var store = CollideFixture.realDropKeys(parent)
    check("a fresh store holds no marker", store.marker, "")
    store.track({ key: Qt.Key_Control }, true)
    check("stray taps outside any drag never arm it", store.ctrl, -1)
    var first = store.stamped({ "text/plain": "a" })
    var second = store.stamped({ "text/plain": "a" })
    check("each lift keeps its payload and gets its own number",
        [first["text/plain"], first[store.liftMime], second[store.liftMime]].join("|"), "a|1|2")
    store.enter("m", "1")
    store.track({ key: Qt.Key_Control }, true)
    store.track({ key: Qt.Key_Shift }, true)
    check("a ctrl press is held", store.ctrl, 1)
    check("and a shift press beside it", store.shift, 1)
    store.track({ key: Qt.Key_Control }, false)
    check("a ctrl release clears it", store.ctrl, 0)
    store.track({ key: Qt.Key_Control }, true)
    // settle() stands in for the turn's end, where a leave's queued settle runs.
    store.leave()
    store.settle()
    store.enter("m", "1")
    check("the same drag at the next target keeps every key seen, the gap between included", store.ctrl + " " + store.shift, "1 1")
    store.enter("m", "2")
    check("a second lift of the same rows starts unseen", store.ctrl + " " + store.shift, "-1 -1")
    store.track({ key: Qt.Key_Control }, true)
    store.enter("n", "2")
    check("a new drag resets ctrl", store.ctrl, -1)
    check("and shift too", store.shift, -1)
    store.enter("f", "")
    store.track({ key: Qt.Key_Control }, true)
    store.leave()
    store.settle()
    check("a drag with no lift ends at a leave no entrance follows", store.marker + " " + store.ctrl, " -1")
    store.enter("f", "")
    store.track({ key: Qt.Key_Control }, true)
    store.leave()
    store.enter("f", "")
    store.settle()
    check("and keeps its keys when it moves on to the next target", store.ctrl, 1)
    store.clear()
    check("a drop consumes the drag", store.marker, "")
    check("and clears what was seen", store.ctrl, -1)

    rowWiring(check)

    var paneSource = Source.source("ui/Pane.qml")
    check("the pane funnels presses into the drop keys",
        paneSource.indexOf("DropKeys.track(event, true)") >= 0, true)
    check("and releases too",
        paneSource.indexOf("DropKeys.track(event, false)") >= 0, true)
    check("DropKeys is a registered singleton",
        Source.source("ui/qmldir").indexOf("singleton DropKeys 1.0 DropKeys.qml") >= 0, true)
}

// The real ui/RowDrag.qml and ui/FileDrag.qml over one store: a shift held over the folder row moves a lift that would copy.
function rowWiring(check) {
    var at = CollideFixture.scene(7)
    var marker = Drag.markerPayload([0], false, "/s", 56)
    check("a folder row takes a path drag", at.target.enter(marker, ["file:///s/a.txt"], "", "", Qt.MoveAction), true)
    at.keys.track({ key: Qt.Key_Shift }, true)
    at.target.dropped(marker, ["file:///s/a.txt"], "", "", Qt.MoveAction)
    check("a path drop onto the row follows the shift held there", at.pane.collide.pending ? at.pane.collide.pending.op : "nothing", "move")
    check("and the drop clears the store", at.keys.marker + " " + at.keys.shift, " -1")
    at.keys.enter("m")
    at.keys.track({ key: Qt.Key_Control }, true)
    check("a refused drop onto the row says why", at.target.refuseDrop(marker, ["file:///d/omarchy"], "", "") !== "", true)
    check("and clears the store too", at.keys.marker + " " + at.keys.ctrl, " -1")
    at.target.enter(marker, ["file:///s/a.txt"], "", "", Qt.MoveAction, "4")
    dropArea(at.target).exited()
    at.keys.settle()
    at.keys.track({ key: Qt.Key_Shift }, true)
    at.target.enter(marker, ["file:///s/a.txt"], "", "", Qt.MoveAction, "4")
    check("a shift pressed after leaving the row counts when the same drag comes back", at.keys.shift, 1)
    at.target.enter(marker, ["file:///s/a.txt"], "", "", Qt.MoveAction, "5")
    check("and a new lift over the row starts unseen", at.keys.shift, -1)
    at.target.enter(marker, ["file:///s/a.txt"], "", "", Qt.MoveAction, "")
    at.keys.track({ key: Qt.Key_Shift }, true)
    dropArea(at.target).exited()
    at.keys.settle()
    check("a drag with no lift that leaves the row ends there", at.keys.marker + " " + at.keys.shift, " -1")
    // The row's shipped entered handler, run as written, hands the drag's own lift number to the entrance.
    var entered = Source.block(Source.source("ui/RowDrag.qml"), "onEntered: function (drag)", "ui/RowDrag.qml")
    var onEntered = eval("(function (root, Tabs, DragOps, DropKeys) { return function (drag) {" + entered + "} })")(
        { enter: function () { return at.target.enter.apply(at.target, arguments) }, hoverAt: function () {} },
        { TAB_MIME: "application/x-flea-tab" }, Drag, at.keys)
    var offered = {}
    offered[Drag.ROWS_MIME] = marker
    offered[at.keys.liftMime] = "6"
    onEntered({ urls: ["file:///s/a.txt"], proposedAction: Qt.MoveAction, getDataAsString: function (type) { return offered[type] || "" } })
    check("the row's entered handler names the drag by its lift", at.keys.lift, "6")
    at.parent.destroy()

    var own = CollideFixture.scene(7)
    var liftNumber = ""
    // Offscreen's platform drag returns at once, so the drop lands inside the lift, as collide.js's wired case does.
    own.session.feedbackChanged.connect(function () {
        if (own.session.feedback === null || own.pane.collide.pending !== null) return
        var lifted = own.session.dragMime[Drag.ROWS_MIME]
        liftNumber = own.session.dragMime[own.keys.liftMime]
        own.target.enter(lifted, [], "", "", Qt.MoveAction, liftNumber)
        own.keys.track({ key: Qt.Key_Shift }, true)
        own.target.dropped(lifted, [], "")
    })
    own.session.liftBegan(0, { modifiers: Qt.NoModifier })
    var sent = own.pane.collide.pending
    check("a by-index drop onto the row follows the shift held there", sent ? sent.c + " " + sent.op : "nothing", "transfer move")
    check("and the drag it started carried the lift's number", liftNumber, "1")
    own.parent.destroy()
}

// The row's own DropArea, whose exited handler is the shipped leave path.
function dropArea(row) {
    for (var i = 0; i < row.children.length; i++) {
        if (row.children[i].containsDrag !== undefined) return row.children[i]
    }
    throw new Error("RowDrag has no DropArea")
}
