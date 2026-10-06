//@ pragma ShellId flea-pdf-idle-test

import Quickshell
import QtQuick

// r35-pdfidle: the real PreviewPdf opens an isolated document before the settle, holds a walk
// for it, and refuses an instant switch while a render is in flight. PdfViewer shares the rule.
ShellRoot {
    id: shell

    readonly property string uiDir: Quickshell.env("PDF_IDLE_UI")
    readonly property string pdfA: Quickshell.env("PDF_IDLE_A")
    readonly property string pdfB: Quickshell.env("PDF_IDLE_B")
    readonly property string pdfHeavy: Quickshell.env("PDF_IDLE_HEAVY")

    property var failures: []
    property int stage: 0
    property double mark: 0
    property double pressedAt: 0

    function log(line) { console.log("PDFIDLE " + line) }
    function quit() { Quickshell.execDetached(["kill", String(Quickshell.processId)]) }
    function check(name, cond) {
        log((cond ? "PASS " : "FAIL ") + name)
        if (!cond)
            failures.push(name)
    }
    function done() {
        log("DONE failures=" + failures.length)
        quit()
    }
    // The PreviewPdf under a surface: the column Loader item itself, or PdfViewer's inner page.
    function innerPdf(item) {
        if (!item)
            return null
        if (item.opened !== undefined)
            return item
        var kids = item.children || []
        for (var i = 0; i < kids.length; i++) {
            var found = shell.innerPdf(kids[i])
            if (found)
                return found
        }
        return null
    }
    function colPdf() { return columnLoader.item }
    function colPage() { return columnLoader.item ? columnLoader.item.pageItem : null }

    FloatingWindow {
        implicitWidth: 800
        implicitHeight: 560
        color: "#303030"

        Loader {
            id: columnLoader
            x: 20; y: 20; width: 360; height: 470
            source: "file://" + shell.uiDir + "/PreviewPdf.qml"
            onLoaded: { item.active = true }
            onStatusChanged: if (status === Loader.Error) { shell.check("the column surface loads", false); shell.done() }
        }

        Loader {
            id: quickLoader
            x: 400; y: 20; width: 360; height: 470
            source: "file://" + shell.uiDir + "/PdfViewer.qml"
            onLoaded: { item.active = true }
            onStatusChanged: if (status === Loader.Error) { shell.check("the Quick Look surface loads", false); shell.done() }
        }
    }

    Timer {
        id: tick
        interval: 5
        running: true
        repeat: true
        onTriggered: shell.step()
    }

    function step() {
        var now = Date.now()
        if (shell.stage === 0) {
            if (!columnLoader.item)
                return
            columnLoader.item.path = shell.pdfA
            shell.pressedAt = now
            shell.stage = 1
        } else if (shell.stage === 1) {
            if (columnLoader.item.opened !== shell.pdfA) {
                if (now - shell.pressedAt > 5000)
                    shell.check("the isolated document opens at all", false), shell.done()
                return
            }
            // Before the 120 ms settle the timer cannot have fired; after it the open is instant.
            shell.check("an isolated press opens before the settle", now - shell.pressedAt < 60)
            shell.mark = now
            shell.stage = 2
        } else if (shell.stage === 2) {
            // A second press inside the settle window: the walk keeps waiting for it.
            if (now - shell.mark < 50)
                return
            columnLoader.item.path = shell.pdfB
            shell.pressedAt = now
            shell.stage = 3
        } else if (shell.stage === 3) {
            if (now - shell.pressedAt < 40)
                return
            shell.check("a walk press waits for the settle", columnLoader.item.opened !== shell.pdfB)
            shell.stage = 4
        } else if (shell.stage === 4) {
            if (columnLoader.item.opened !== shell.pdfB) {
                if (now - shell.pressedAt > 5000)
                    shell.check("the walk lands on the second document", false), shell.done()
                return
            }
            shell.check("the walk lands on the second document", true)
            shell.mark = now
            shell.stage = 5
        } else if (shell.stage === 5) {
            // Idle again before the heavy document, so only the render can still hold it.
            if (now - shell.mark < 300)
                return
            columnLoader.item.path = shell.pdfHeavy
            shell.pressedAt = now
            shell.stage = 6
        } else if (shell.stage === 6) {
            if (columnLoader.item.opened !== shell.pdfHeavy) {
                if (now - shell.pressedAt > 10000)
                    shell.check("the heavy document opens at all", false), shell.done()
                return
            }
            shell.log("heavy opened after " + Math.round(now - shell.pressedAt) + " ms")
            shell.pressedAt = now
            shell.stage = 7
        } else if (shell.stage === 7) {
            var page = shell.colPage()
            if (!page || page.status !== Image.Loading) {
                if (now - shell.pressedAt > 15000)
                    shell.check("the heavy render is seen loading", false), shell.done()
                return
            }
            // A switch while the first render is in flight takes the settle, never the fast path.
            columnLoader.item.path = shell.pdfB
            shell.pressedAt = now
            shell.stage = 8
        } else if (shell.stage === 8) {
            if (now - shell.pressedAt < 40)
                return
            shell.check("a switch with a live render does not open at once", columnLoader.item.opened !== shell.pdfB)
            shell.stage = 9
        } else if (shell.stage === 9) {
            if (columnLoader.item.opened !== shell.pdfB) {
                if (now - shell.pressedAt > 5000)
                    shell.check("the held switch lands at the settle", false), shell.done()
                return
            }
            var live = shell.colPage()
            shell.log("switched with render still loading: " + (live !== null && live.status === Image.Loading))
            shell.check("the held switch lands at the settle", true)
            var quick = shell.innerPdf(quickLoader.item)
            if (quick) {
                quick.path = shell.pdfA
                shell.pressedAt = now
                shell.stage = 10
            } else {
                shell.check("Quick Look reaches the shared rule", false)
                shell.done()
            }
        } else if (shell.stage === 10) {
            var target = shell.innerPdf(quickLoader.item)
            if (!target || target.opened !== shell.pdfA) {
                if (now - shell.pressedAt > 5000)
                    shell.check("Quick Look opens an isolated press before the settle", false), shell.done()
                return
            }
            shell.check("Quick Look opens an isolated press before the settle", now - shell.pressedAt < 60)
            shell.done()
        }
    }
}
