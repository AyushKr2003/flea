.import "../../ui/js/Drag.js" as Drag
.import "dragfixture.js" as Fixture
.import "collidefixture.js" as CollideFixture
.import "sourcefixture.js" as Source

// #259: the drop follows the keys held at the drop, not the lift. track/enter/clear run
// here against the real ui/DropKeys.qml, loaded the way the dragwire fixtures load it.
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
    store.enter("m")
    store.track({ key: Qt.Key_Control }, true)
    store.track({ key: Qt.Key_Shift }, true)
    check("a ctrl press is held", store.ctrl, 1)
    check("and a shift press beside it", store.shift, 1)
    store.track({ key: Qt.Key_Control }, false)
    check("a ctrl release clears it", store.ctrl, 0)
    store.enter("m")
    check("re-entering the same drag keeps what was seen", store.shift, 1)
    store.enter("n")
    check("a new drag resets ctrl", store.ctrl, -1)
    check("and shift too", store.shift, -1)
    store.track({ key: Qt.Key_Control }, true)
    store.clear()
    check("a drop consumes the drag", store.marker, "")
    check("and clears what was seen", store.ctrl, -1)

    var paneSource = Source.source("ui/Pane.qml")
    check("the pane funnels presses into the drop keys",
        paneSource.indexOf("DropKeys.track(event, true)") >= 0, true)
    check("and releases too",
        paneSource.indexOf("DropKeys.track(event, false)") >= 0, true)
    check("DropKeys is a registered singleton",
        Source.source("ui/qmldir").indexOf("singleton DropKeys 1.0 DropKeys.qml") >= 0, true)
}
