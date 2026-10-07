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
    readonly property string pdfC: Quickshell.env("PDF_IDLE_C")

    property var failures: []
    property int stage: 0
    property double mark: 0
    property double pressedAt: 0
    property double secondPressedAt: 0
    property string armedFor: ""
    // Presented frames, counted on the window's own frameSwapped: the shell connects at startup
    // while an item connects only when it arms, so the count already holds the frame runFast opens on.
    property int frameCount: 0
    property int pressFrame: -1
    property int openFrame: -1
    property var openedLog: []
    property int hiddenFrames: -1
    property bool pulse: false

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
        id: win
        implicitWidth: 800
        implicitHeight: 560
        color: "#303030"

        // Counts presented frames, so the open can be ordered against them. The probe reads
        // the same attached window production connects to; it connects at startup while an item
        // connects only when it arms, so the count already holds the frame runFast opens on.
        Item {
            id: frameProbe
            Connections {
                target: frameProbe.Window.window
                function onFrameSwapped() { shell.frameCount += 1 }
            }
        }

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

    // Every opened value the column takes, so a cancelled open is seen even if it never settles.
    Connections {
        target: columnLoader.item
        function onOpenedChanged() {
            if (shell.pressFrame >= 0 && shell.openFrame < 0 && columnLoader.item.opened === shell.armedFor)
                shell.openFrame = shell.frameCount
            shell.openedLog.push(columnLoader.item.opened)
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
            shell.armedFor = shell.pdfA
            shell.pressFrame = shell.frameCount
            shell.openFrame = -1
            shell.openedLog = []
            // A pulse schedules a frame after the press, so the open has a frame to wait for.
            shell.pulse = !shell.pulse
            win.color = shell.pulse ? "#313131" : "#303030"
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
            shell.check("the open waits for the first frame after the press", shell.openFrame > shell.pressFrame)
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
                // A pulse schedules a frame after the press, so the open has a frame to wait for.
                shell.pulse = !shell.pulse
                win.color = shell.pulse ? "#313131" : "#303030"
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
            // A second request in the same turn cancels the first open: both sets run before any frame.
            shell.armedFor = shell.pdfA
            shell.pressFrame = shell.frameCount
            shell.openFrame = -1
            shell.openedLog = []
            columnLoader.item.path = shell.pdfC
            columnLoader.item.path = shell.pdfA
            // A frame presents while disarmed, so the cancel holds against a real frame.
            shell.pulse = !shell.pulse
            win.color = shell.pulse ? "#313131" : "#303030"
            shell.secondPressedAt = now
            shell.stage = 11
        } else if (shell.stage === 11) {
            if (columnLoader.item.opened !== shell.pdfA) {
                if (now - shell.secondPressedAt > 5000)
                    shell.check("the second request opens at the settle", false), shell.done()
                return
            }
            shell.check("the second request opens at the settle", true)
            var sawC = false
            for (var i = 0; i < shell.openedLog.length; i++)
                if (shell.openedLog[i] === shell.pdfC)
                    sawC = true
            shell.check("the cancelled first open never lands", !sawC)
            shell.check("the cancelled open waits for the settle, never the fast path",
                now - shell.secondPressedAt > 60)
            // A window that never swaps still opens at the settle: hidden, no frame presents.
            shell.armedFor = shell.pdfC
            shell.pressFrame = shell.frameCount
            shell.openFrame = -1
            shell.openedLog = []
            win.visible = false
            shell.hiddenFrames = shell.frameCount
            columnLoader.item.path = shell.pdfC
            shell.pressedAt = now
            shell.stage = 12
        } else if (shell.stage === 12) {
            if (columnLoader.item.opened !== shell.pdfC) {
                if (now - shell.pressedAt > 5000)
                    shell.check("a hidden window still opens at the settle", false), shell.done()
                return
            }
            shell.check("a hidden window still opens at the settle", true)
            shell.check("that open waits for the settle, never a frame", now - shell.pressedAt > 60)
            shell.check("no frame presents before that open", shell.openFrame === shell.pressFrame)
            shell.done()
        }
    }
}
