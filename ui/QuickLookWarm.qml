import QtQuick
import "." as Flea
import "js/MarkdownPrepared.js" as Prepared
import "js/QuickLookKinds.js" as LookKinds

// What Quick Look's first Space needs before it opens: the rested file's prepared entry and held pictures, the compiled units, and the card itself built closed.
Item {
    id: root

    // WindowBody builds this on the cursor's first landing on a file: a Markdown file at once, any other once a key has moved the cursor.
    property var pane: null
    // False while Quick Look is open: the entry is for the next Space.
    readonly property bool resting: !(root.look !== null && root.look.active)
    readonly property alias prepare: prepare
    // Quick Look's own unit and the swap wrapper, held from the first idle after the window settles on a file Quick Look opens, and never instantiated, so the first Space compiles and loads no unit.
    property var previewUnit: null
    property var swapUnit: null
    // The unit the rested file's kind opens its content from, "" for a folder or a kind with none (ui/js/QuickLookKinds.js).
    readonly property string kindUnit: LookKinds.unitOf(root.pane ? root.pane.cursorRow : null)
    onKindUnitChanged: if (unitTimer.running) unitTimer.restart()
    // The kind units the cursor has rested on, held by file name as the two above are: the Markdown pane, PdfViewer (QtQuick.Pdf), PreviewMedia (QtMultimedia), PreviewImage, PreviewText.
    // A kind the window never rested on is never compiled, so a folder without a PDF or a clip never imports QtQuick.Pdf or QtMultimedia.
    property var kindUnits: ({})
    readonly property var markdownUnit: root.kindUnits[LookKinds.MARKDOWN] || null
    readonly property int unitWarmMs: 1000
    readonly property bool unitsReady: root.previewUnit !== null && root.previewUnit.status === Component.Ready
        && root.markdownUnit !== null && root.markdownUnit.status === Component.Ready
        && root.swapUnit !== null && root.swapUnit.status === Component.Ready
    // The cursor has rested on a Markdown file with every unit compiled: the card is built now, hidden and inactive, so the first Space only opens it.
    readonly property bool cardDue: root.unitsReady && prepare.rested && root.pane !== null && Prepared.isMarkdownRow(root.pane.cursorRow)
    onCardDueChanged: if (root.cardDue && root.pane.previewLoader) root.pane.previewLoader.active = true
    readonly property bool windowSettled: root.pane !== null && root.pane.listingState === "ready" && !root.pane.listInFlight

    // Counts from the last move onto a file with a unit, so a cursor passing over a kind holds none of it.
    Timer {
        id: unitTimer
        running: root.windowSettled && root.previewUnit === null && root.kindUnit !== ""
        interval: root.unitWarmMs
        onTriggered: {
            root.previewUnit = Qt.createComponent("Preview.qml", Component.Asynchronous)
            root.swapUnit = Qt.createComponent("QuickLookSwap.qml", Component.Asynchronous)
            root.holdKind()
        }
    }
    // The cursor's file kind unit, held once and kept; the key that lands on a file never compiles it.
    function holdKind() {
        var file = root.kindUnit
        if (file === "" || root.kindUnits[file] !== undefined)
            return
        var held = Object.assign({}, root.kindUnits)
        held[file] = Qt.createComponent(file, Component.Asynchronous)
        root.kindUnits = held
    }
    // Quick Look's own unit is held and the cursor has rested on a file whose kind has a unit: the first landing on a new kind holds its unit. A move clears rested, so a held key compiles none.
    readonly property bool kindDue: root.previewUnit !== null && prepare.rested && root.kindUnit !== ""
    onKindDueChanged: if (root.kindDue) root.holdKind()
    Flea.QuickLookPrepare { id: prepare; pane: root.pane; resting: root.resting }
    // The card Quick Look opens; resting reads it so a rest never prepares over an open card.
    readonly property var look: root.pane ? root.pane.preview : null
    // The cursor is already on its file when this is built, so the first rest starts here and not on a move.
    Component.onCompleted: prepare.moved()
}
