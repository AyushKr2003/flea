import QtQuick
import QtQuick.Pdf
import qs.Commons
import "js/Format.js" as Format
import "js/PreviewSettle.js" as PreviewSettle
import "js/PreviewSwap.js" as PreviewSwap
import "js/Swap.js" as Swap

// A page of a PDF, rendered into the preview column's frame. QtPdf ships inside the already
// installed qt6-webengine and needs no package of its own; proven to import and render under
// Quickshell itself on this box, not only under qml6.
Item {
    id: root

    property string path: ""
    property bool active: false
    // The backend a slow document is fetched through, null where no fetch runs.
    property var backend: null
    // Which viewer this is, so the backend's copy cleanup never touches the other's.
    property string viewerSlot: ""
    // True on a storage class that can hang: the document loads from the fetched copy.
    property bool fetchFirst: false
    // The fetch in flight, the local copy it handed back, and what its failure says.
    property int fetchId: 0
    property string localCopy: ""
    property string copyError: ""
    // Decided once per opened document, so a later class change neither blanks nor reloads it.
    property bool fetchedCopy: false
    // The backend's flag for a fetch that never answered; any other copy failure could not be read.
    property bool copyStalled: false
    readonly property string failSentence: root.copyStalled ? "This file is not responding."
        : "This file could not be read."
    // Which page the frame is showing, zero-based, always inside the document it belongs to.
    property int page: 0
    // The Flickable the page scrolls in, so the loading mark stands in the visible frame at any zoom.
    property Item viewport: null

    // What the facts table shows as Pages; 0 until the document is ready, or if it never becomes so.
    readonly property int pageCount: doc.status === PdfDocument.Ready ? doc.pageCount : 0
    readonly property bool failed: doc.status === PdfDocument.Error || root.copyError.length > 0

    // The page whose render is on screen, -1 until one has landed for this document.
    property int shownPage: -1
    // A render slower than the listing swap's cap stops passing the old page off as the one asked for.
    property bool fellBack: false
    // When the loading state went up, 0 while none stands; the page that replaces it waits behind it for Swap.MIN_SHOW_MS.
    property double fellBackAt: 0
    // What the chrome counts: the page on screen, or the one asked for once nothing else stands in for it.
    readonly property int drawnPage: root.shownPage >= 0 && !root.fellBack ? root.shownPage : root.page

    // The page's proportions come from the document, never from the rendered image. Reading the
    // image's implicit size closed a loop through the width binding below: sourceSize changed the
    // implicit size, which re-evaluated width, which re-set sourceSize. Qt broke that binding, and a
    // broken width binding is a page that never resizes when the frame or the zoom changes.
    // corner: a document mixing page shapes draws the old page in the new page's box until its render lands.
    readonly property real pageAspect: {
        if (doc.status !== PdfDocument.Ready || root.pageCount <= 0)
            return 1
        var box = doc.pagePointSize(Math.min(root.page, root.pageCount - 1))
        return box.height > 0 ? box.width / box.height : 1
    }

    // A new document starts at its first page; an idle press opens on the next frame, a walk or a render in flight waits for the settle.
    onPathChanged: { root.page = 0; root.requestOpen() }
    onOpenedChanged: root.fetchForOpened()

    // A hangable document is fetched once per opening; anything else loads in place.
    function fetchForOpened() {
        root.localCopy = ""
        root.copyError = ""
        root.copyStalled = false
        root.fetchedCopy = root.opened.length > 0 && root.fetchFirst === true && root.backend !== null
        if (!root.fetchedCopy)
            return
        root.fetchId = root.backend.pdfCopy(root.opened, root.viewerSlot)
    }

    Connections {
        target: root.backend
        function onPdfCopied(id, path, err, stalled) {
            if (id !== root.fetchId || root.fetchedCopy !== true)
                return
            if (err.length > 0) {
                root.copyError = err
                root.copyStalled = stalled
            } else {
                root.localCopy = path
            }
        }
    }

    // The copy, once it lands; in place while no fetch runs, and nothing while one is out.
    function docSource() {
        if (root.opened.length === 0)
            return ""
        if (root.fetchedCopy !== true)
            return Format.fileUri(root.opened)
        return root.localCopy.length > 0 ? Format.fileUri(root.localCopy) : ""
    }
    onPageCountChanged: if (root.pageCount > 0) root.page = Math.min(root.page, root.pageCount - 1)
    // A turn arms the cap for a page other than the one on screen; with no page shown yet it does nothing, and turning back onto the shown page stops the cap instead.
    onPageChanged: {
        if (page.status !== Image.Loading) return
        if (root.shownPage < 0) return
        if (root.page !== root.shownPage) renderCap.start()
        else { renderCap.stop(); root.endFallBack() }
    }

    // The loading state leaves once it has stood Swap.MIN_SHOW_MS; until then the page waits behind it.
    function endFallBack() {
        var left = root.fellBack ? Swap.showLeft(root.fellBackAt, Date.now()) : 0
        if (left > 0) {
            renderMin.interval = left
            renderMin.restart()
            return
        }
        renderMin.stop()
        root.fellBack = false
        root.fellBackAt = 0
    }

    function turn(delta) {
        if (root.pageCount <= 0)
            return
        root.page = Math.max(0, Math.min(root.pageCount - 1, root.page + delta))
    }

    // Loading a page other than the one on screen starts the cap; a landed or failed render ends it.
    function renderChanged() {
        if (page.status === Image.Loading) {
            if (root.shownPage >= 0 && page.currentFrame !== root.shownPage) {
                renderMin.stop()
                renderCap.restart()
            }
            return
        }
        renderCap.stop()
        root.endFallBack()
        // A document switch reports Ready for loads that drew nothing, or that drew the last file.
        var landed = page.status === Image.Ready && page.implicitWidth > 0
                     && page.source.toString() === doc.source.toString()
        root.shownPage = landed ? page.currentFrame : -1
    }

    // Issue 117, vianney-g: a source change while an async page render is in flight can destroy the
    // carrier device under Qt's own reader thread, which aborts the process, so a walk through a
    // folder of PDFs settles before a document is opened rather than opening one per cursor step.
    property string opened: ""
    readonly property int settleMs: PreviewSwap.DOCUMENT_SETTLE_MS
    // The last path or active change, so an isolated press opens at once and a walk still settles.
    property double lastRequestAt: 0
    onActiveChanged: root.requestOpen()

    // One opener for the timer and the idle fast path, so both switch the same way.
    function openPending() {
        var next = root.active ? root.path : ""
        if (next === root.opened)
            return
        // Another document's page is never this one's: it is dropped, and kept by no render, before the switch.
        renderCap.stop()
        renderMin.stop()
        root.fellBack = false
        root.fellBackAt = 0
        root.shownPage = -1
        root.opened = next
    }

    // An idle press opens on the next presented frame, so that frame shows the page Quick Look has; the settle is the backstop.
    property bool fastArmed: false
    // Opens taken by the fast path, so a test tells them from the settle by count, never by time.
    property int fastOpens: 0
    function runFast() {
        if (!root.fastArmed)
            return
        root.fastArmed = false
        pdfSettle.stop()
        root.fastOpens += 1
        root.openPending()
    }
    Connections {
        target: root.fastArmed ? root.Window.window : null
        function onFrameSwapped() { root.runFast() }
    }

    // An idle press with no render in flight opens at once, and a change that opens nothing stamps nothing.
    function requestOpen() {
        if ((root.active ? root.path : "") === root.opened)
            return
        var now = Date.now()
        root.fastArmed = PreviewSettle.pdfOpenNow(now, root.lastRequestAt, root.settleMs, page.status === Image.Loading)
        root.lastRequestAt = now
        pdfSettle.restart()
    }
    Timer {
        id: pdfSettle
        interval: root.settleMs
        onTriggered: { root.fastArmed = false; root.openPending() }
    }

    // The cap draws the loading state by 100 ms, as the listing swap's does, and it then stands Swap.MIN_SHOW_MS.
    Timer {
        id: renderCap
        objectName: "renderCap"
        interval: Swap.CAP_MS
        onTriggered: {
            if (!root.fellBack)
                root.fellBackAt = Date.now()
            root.fellBack = true
        }
    }

    // The loading state has stood its minimum, so the page that landed meanwhile shows now.
    Timer {
        id: renderMin
        objectName: "renderMin"
        onTriggered: { root.fellBack = false; root.fellBackAt = 0 }
    }

    PdfDocument {
        id: doc
        // Format.fileUri, not a concatenation: a path can carry a # or a ? and either one truncates
        // a hand-built URI at that character. A document is only opened while the column shows one.
        source: root.docSource()
    }

    // The page's own paper under the raster: on this box a rendered page can arrive with text drawn
    // and no background, and the dark frame showed through it. Paper is the document's, not a theme
    // role, so the colour is a constant; visible only with the page, so a loading document draws none.
    Rectangle {
        anchors.centerIn: parent
        visible: page.visible
        width: page.width
        height: page.height
        color: "#ffffff"
    }

    // The drawn page itself, for the geometry gate: sized to the contain of the viewport at the
    // zoom, so its rect is the picture and not the frame it is centred in.
    readonly property Item pageItem: page
    // The page is the only light surface in the app, which is exactly what the canvas draws.
    PdfPageImage {
        id: page
        anchors.centerIn: parent
        // Drawn once a render has landed: the paper alone before it was the white flash on every turn.
        visible: root.shownPage >= 0 && !root.fellBack
        document: doc
        // Qt ignores a frame at or past frameCount, which is 0 until the first render lands, so the binding reads it to reapply a turn made during that render.
        currentFrame: page.frameCount > 0 ? Math.min(root.page, page.frameCount - 1) : 0
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        // Qt 6.8's double buffer: the page on screen stays until the next render is ready, where
        // without it Qt dropped the old pixmap at the turn and the paper showed white for the render.
        // Off until this document has a page on screen, so no render can keep another document's.
        retainWhileLoading: root.shownPage >= 0
        onStatusChanged: root.renderChanged()
        // Fit inside the frame without ever upscaling past the page's own resolution.
        width: Math.min(parent.width, parent.height * root.pageAspect)
        height: Math.min(parent.height, parent.width / root.pageAspect)

        // Rasterised at the size it is drawn at, so a zoomed page sharpens instead of scaling up a
        // page-point-sized bitmap; the deadband and the assignment (not a binding) are both Qt's
        // own PdfPageView.qml reRenderIfNecessary, without which a resize re-renders every frame.
        onWidthChanged: page.rerenderIfNeeded()
        // PdfPageImage copies the document's source into its own inherited source property only as
        // the document turns Ready, and a re-render that beats that copy makes Qt warn that the two
        // are in conflict; the guard below waits for the copy and this re-renders once it lands.
        onSourceChanged: page.rerenderIfNeeded()

        function rerenderIfNeeded() {
            // source is a url, so it is converted before comparing: a bare === against a
            // string is false forever and would stop this guard from ever firing. Opening the
            // next document leaves the last one's source here until the copy, and the page box
            // resizing meanwhile (pageAspect is 1 while it loads) was that warning, twice a switch.
            if (page.source.toString() === "" || page.source.toString() !== doc.source.toString())
                return
            var target = Math.round(page.width)
            if (target <= 0)
                return
            var ratio = page.sourceSize.width > 0 ? target / page.sourceSize.width : 0
            if (ratio > 1.1 || ratio < 0.9)
                page.sourceSize = Qt.size(target, 0)
        }
    }

    // Past the cap the loading mark takes the frame, the fallback ui/PaneSwap.qml gives a slow listing.
    LoadingState {
        parent: root.viewport ? root.viewport : root
        anchors.fill: parent
        visible: root.fellBack
        heldOff: true
    }
}
