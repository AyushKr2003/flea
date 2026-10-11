.import "../../ui/js/Collide.js" as Collide
.import "../../ui/js/Drag.js" as Drag
.import "collidefixture.js" as Fixture
.import "sourcefixture.js" as Source

// The FAT card in the collision flow and the hover seams on the drag session, over the real CollideHost and FileDrag; the cards need the shell, so a stub and source scans stand in.

var BACKEND = "import QtQuick\nimport \"../../ui/js/Swap.js\" as Swap\nQtObject {\n"
    + "    signal collisions(int id, int total, var names, bool mergeable)\n    signal mergeCollisions(int id, int total, var names)\n"
    + "    signal fatnames(int id, var renames, string fstype, string volume)\n"
    + "    signal failed(string where, string input, string message, int mode)\n"
    + "    property real heldListing: 0\n    property var sent: []\n"
    + "    function send(object) { sent.push(Swap.named(object, heldListing)) }\n}\n"
var CARD = "import QtQuick\nQtObject {\n    signal chosen(string choice)\n    property bool opened: false\n    property var shown: []\n"
    + "    function open(title, list, note) { shown.push([title, list.length, note]); opened = true }\n}\n"
var RENAMES = [{ old: "clip: a.mp4", new: "clip_ a.mp4", d: false, i: "video-x-generic" },
               { old: "notes?.md", new: "notes_.md", d: false, i: "text-x-generic" }]
var PATHS = ["/s/clip: a.mp4", "/s/notes?.md"]

function scene() {
    var parent = Qt.createComponent("QtQuick", "Item").createObject(null)
    var backend = Qt.createQmlObject(BACKEND, parent, Qt.resolvedUrl("backend.qml"))
    backend.heldListing = 7
    var out = { parent: parent, backend: backend, focused: 0, said: [] }
    out.pane = { path: "/run/media/gm/USB", backend: backend, clipboard: { paths: PATHS, moving: false },
                 listArea: { forceActiveFocus: function () { out.focused += 1 } },
                 message: function (text) { out.said.push(text) } }
    out.host = Fixture.built("CollideHost.qml", parent, { pane: out.pane })
    out.card = Qt.createQmlObject(CARD, parent, Qt.resolvedUrl("card.qml"))
    out.host.fatCard = out.card
    out.card.chosen.connect(out.host.decideFat)
    out.fresh = function () { return { c: "transfer", op: "copy", paths: PATHS, dest: "/run/media/gm/USB" } }
    return out
}

function flow(check) {
    var at = scene()
    var backend = at.backend, host = at.host, card = at.card
    host.ask(at.fresh(), null, false)
    check("a paste asks the collisions question first, with no FAT answer on it", JSON.stringify(backend.sent),
          JSON.stringify([{ c: "collisions", id: 1, dest: "/run/media/gm/USB", paths: PATHS }]))
    backend.fatnames(1, RENAMES, "exfat", "128GB")
    check("a FAT answer opens the card on the machine's own fields", JSON.stringify(card.shown),
          JSON.stringify([["2 names cannot exist on 128GB (exFAT)", 2, "exFAT refuses : ? * \" < > | and trailing dots or spaces."]]))
    check("the transfer is still waiting behind it", host.pending !== null && backend.sent.length, 1)
    backend.fatnames(9, RENAMES, "exfat", "128GB")
    check("an answer to another question opens nothing", card.shown.length, 1)
    card.chosen("rename")
    check("Rename and copy asks the same question again with the answer on it", JSON.stringify(backend.sent[1]),
          JSON.stringify({ c: "collisions", id: 1, dest: "/run/media/gm/USB", fat: "rename", paths: PATHS }))
    check("and gives the focus back to the listing", at.focused, 1)
    backend.collisions(1, 0, [], false)
    check("no collision sends the transfer with the answer on it", JSON.stringify(backend.sent[2]),
          JSON.stringify({ c: "transfer", op: "copy", paths: PATHS, dest: "/run/media/gm/USB", fat: "rename", collide: Collide.NONE, collideId: 1 }))
    check("and lets go of the wait", host.pending, null)

    host.ask(at.fresh(), null, false)
    backend.fatnames(2, RENAMES, "exfat", "128GB")
    card.chosen("skip")
    check("Skip them rides the question the same way", backend.sent[4].fat + "|" + backend.sent[4].id, "skip|2")
    backend.collisions(2, 0, [], false)
    check("and the transfer", backend.sent[5].fat + "|" + backend.sent[5].collide, "skip|" + Collide.NONE)

    var before = backend.sent.length
    host.ask(at.fresh(), null, false)
    backend.fatnames(3, RENAMES, "exfat", "128GB")
    card.chosen("cancel")
    check("Cancel sends nothing past its question and lets go", (backend.sent.length - before) + "|" + (host.pending === null), "1|true")
    check("so the next paste may ask", host.ask(at.fresh(), null, false), true)
    backend.failed("stale", "collisions", "the listing changed", 0)
    check("a refused question closes the card and ends the wait", card.opened + "|" + (host.pending === null), "false|true")
    at.parent.destroy()
}

function hover(check) {
    var at = Fixture.scene(7)
    var session = at.session
    var rested = [], stopped = []
    session.hoverTimers = { rest: function () { rested.push(1) }, stopRest: function () { stopped.push(1) } }
    session.hoverBegan(2, "/d/omarchy", 10, 400)
    check("resting on a folder row names it and its band", session.hoverIndex + "|" + session.hoverPath + "|" + session.scrollDir,
          "2|/d/omarchy|-1")
    check("and starts the rest", rested.length, 1)
    session.hoverMoved(200, 400)
    check("a move out of the band stops the scroll", session.scrollDir, 0)
    check("and restarts the rest rather than spending it", rested.length, 2)
    session.hoverMoved(395, 400)
    check("the bottom band scrolls down", session.scrollDir, 1)
    session.hoverEnded()
    check("leaving clears the row, the band and the rest", session.hoverIndex + "|" + session.hoverPath + "|" + session.scrollDir + "|" + stopped.length,
          "-1||0|1")
    session.hoverBegan(2, "/d/omarchy", 395, 400)
    session.liftEnded()
    check("the end of the drag clears them too", session.hoverPath + "|" + session.scrollDir + "|" + stopped.length, "|0|2")
    at.parent.destroy()
}

function built(check) {
    var timers = Source.source("ui/HoverTimers.qml")
    check("the rest reads the live setting", timers.indexOf("ViewState.openFoldersWhileDragging") >= 0, true)
    check("the rest is the module's 0.7 s", timers.indexOf("interval: DragOut.OPEN_MS") >= 0, true)
    check("the scroll runs only while a band is held", timers.indexOf("running: root.session.scrollDir !== 0") >= 0, true)
    check("a view without a scroll position is left alone", timers.indexOf("view.contentY === undefined") >= 0, true)
    var drag = Source.source("ui/FileDrag.qml")
    check("the timers are built on first use, with no placeholder", drag.indexOf('Qt.createComponent("HoverTimers.qml").createObject(root') >= 0
          && drag.indexOf("Loader") < 0, true)
    var crumb = Source.source("ui/Crumb.qml")
    check("a crumb builds its drop target when a drag lifts or it is first hovered",
          crumb.indexOf("onDragLiveChanged: if (crumb.dragLive) crumb.armDrop()") >= 0
          && crumb.indexOf("onHoveredChanged: if (hovered) crumb.armDrop()") >= 0, true)
    check("and hands it the crumb the frame belongs to", crumb.indexOf("{ crumb: crumb, pane: crumb.dropPane") >= 0, true)
    var area = Source.source("ui/CrumbDrop.qml")
    check("the crumb's drop is the floor's own receiver, so it decides the verb and sends the one transfer the floor does",
          area.indexOf("Flea.DropInto {") >= 0 && area.indexOf("text/uri-list") < 0 && area.indexOf("verbFor") < 0, true)
    check("and is named by the crumb's text", Source.source("ui/DropInto.qml").indexOf("root.label || root.dest") >= 0
          && crumb.indexOf("label: String(crumb.modelData.text") >= 0, true)
    var row = Source.source("ui/RowDrag.qml")
    check("a peek row drops through the pane that shows it", row.indexOf("root.dropScope.pane") >= 0 && row.indexOf("root.dropScope.dir") >= 0, true)
    var card = Source.source("ui/FatNamesConfirm.qml")
    check("the card is placed and sized by the shared card rules", card.indexOf("Theme.cardOrigin(root.width, width)") >= 0
          && card.indexOf("Theme.cardSpan(root.contentWidth") >= 0, true)
    check("its buttons are the shared one, in the board's order", card.indexOf("Collide.FAT_BUTTONS.cancel") < card.indexOf("Collide.FAT_BUTTONS.skip")
          && card.indexOf("Collide.FAT_BUTTONS.skip") < card.indexOf("Collide.FAT_BUTTONS.rename"), true)
    check("Rename and copy is the primary and carries the ring as the card opens", card.indexOf("primary: true") >= 0
          && card.indexOf("property string focusName: Collide.FAT_DEFAULT") >= 0, true)
    check("a first-frame file never imports the card", ["ui/Pane.qml", "ui/PaneWire.qml", "ui/WindowBody.qml", "ui/Row.qml"].every(function (file) {
        return Source.source(file).indexOf("FatNamesConfirm") < 0 }), true)
}

function crumbdev(check) {
    var area = Source.source("ui/CrumbDrop.qml")
    check("a crumb above the listing takes no device guess, so a plain drop copies",
          area.indexOf("destDev: 0") >= 0 && area.indexOf("dirDev") < 0, true)
    var marker = Drag.markerPayload([0], false, "/run/media/gm/USB", 42)
    check("a crumb above the mount copies when the source dev equals the listing dev",
          Drag.dropVerb(marker, 0, 0), "copy")
    check("and the same drop moves only once the crumb dev is known equal",
          Drag.dropVerb(marker, 0, 42), "move")
}

function run(check) {
    flow(check)
    hover(check)
    built(check)
    crumbdev(check)
}
