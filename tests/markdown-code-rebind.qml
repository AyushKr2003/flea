//@ pragma ShellId flea-markdown-rebind-test

import QtQuick
import Quickshell
import "flea" as Flea
import "flea/js/CodeRuns.js" as CodeRuns

// A same-file pane handoff over two real backends, with A's reply held until its connection has moved to B.
ShellRoot {
    id: shell

    property int stage: 0
    property int ticks: 0
    property int failures: 0
    property bool done: false
    property var originalFence: null
    property string originalPath: ""
    property int originalToken: 0
    property int sourceToken: 0
    property int sourceAsks: 0

    function log(text) { console.log("MARKDOWN_REBIND " + text) }
    function check(ok, text) {
        if (!ok) shell.failures += 1
        shell.log((ok ? "PASS " : "FAIL ") + text)
    }
    function finish() {
        shell.done = true
        shell.log("DONE " + shell.failures + " failed")
        quitter.start()
    }
    function fences(item) {
        var stack = [item], out = []
        while (stack.length > 0) {
            var current = stack.pop()
            if (current.objectName === "fenceBox") out.push(current)
            var kids = current.children || []
            for (var i = 0; i < kids.length; i++) stack.push(kids[i])
        }
        return out
    }

    component DelayedBackend: Item {
        property bool hold: false
        property var replies: []
        property var asks: ({})
        signal codeResult(var message)
        Flea.Backend { id: inner }
        function askCode(slot, source, first, count) {
            asks[slot] = (asks[slot] || 0) + 1
            return inner.askCode(slot, source, first, count)
        }
        function release() {
            var ready = replies
            replies = []
            for (var i = 0; i < ready.length; i++) codeResult(ready[i])
        }
        Connections {
            target: inner
            function onCodeResult(message) {
                if (hold) replies = replies.concat([message])
                else codeResult(message)
            }
        }
    }
    DelayedBackend { id: backendA; hold: true }
    DelayedBackend { id: backendB }

    FloatingWindow {
        implicitWidth: 560
        implicitHeight: 600
        color: "#101315"
        Flea.PreviewMarkdown {
            id: pane
            width: parent.width
            height: 300
            active: true
            path: Quickshell.env("MDCODE_DIR") + "/rebind.md"
            size: 1
            backend: backendA
        }
        Flea.CodeLines {
            id: source
            y: 300
            width: parent.width
            height: 300
            backend: backendA
            slot: "rebind-source"
            path: "rebind.rs"
            fromText: true
            text: "fn source() {}\n"
            active: shell.stage >= 2
        }
    }

    Timer {
        interval: 100
        repeat: true
        running: !shell.done
        onTriggered: {
            shell.ticks += 1
            if (shell.ticks > 100) {
                shell.check(false, "handoff probe timed out in stage " + shell.stage)
                shell.finish()
                return
            }
            if (shell.stage === 0) {
                var found = shell.fences(pane)
                if (found.length !== 1 || found[0].token === 0 || backendA.replies.length === 0) return
                shell.originalFence = found[0]
                shell.originalPath = pane.path
                shell.originalToken = found[0].token
                shell.log("REPRO A token=" + found[0].token + " waits=" + pane.fenceWaits + " firstScreen=" + pane.firstScreen)
                pane.backend = backendB
                backendA.release()
                shell.stage = 1
                shell.ticks = 0
                return
            }
            if (shell.stage === 1) {
                var fence = shell.originalFence
                if (!pane.firstScreen && shell.ticks < 20) return
                var asked = backendB.asks[fence.slot] || 0
                shell.log("REPRO B asks=" + asked + " token=" + fence.token + " waits=" + pane.fenceWaits + " firstScreen=" + pane.firstScreen)
                shell.check(pane.path === shell.originalPath && shell.fences(pane)[0] === fence, "handoff keeps the same file and live fence")
                shell.check(asked > 0 && fence.token === 0 && pane.firstScreen && pane.fenceWaits === 0, "backend handoff asks again and releases its first-screen hold")
                var coloured = fence.held[1] && fence.held[1].some(function (run, at) { return at % 2 === 0 && run > 0 })
                shell.check(coloured && fence.children[0].text === fence.markup, "B's engine colours reach the live fence")
                shell.stage = 2
                shell.ticks = 0
                return
            }
            if (shell.stage === 2) {
                if (source.token === 0 || backendA.replies.length === 0) return
                shell.sourceToken = source.token
                shell.sourceAsks = backendB.asks[source.slot] || 0
                source.backend = backendB
                backendA.release()
                shell.stage = 3
                shell.ticks = 0
                return
            }
            if (shell.stage === 3 && shell.ticks >= 10) {
                shell.log("CODELINES_HOLE oldToken=" + shell.sourceToken + " token=" + source.token
                    + " B_asks=" + ((backendB.asks[source.slot] || 0) - shell.sourceAsks) + " firstScreen=" + source.firstScreen)
                shell.finish()
            }
        }
    }
    Timer {
        id: quitter
        interval: 200
        onTriggered: Quickshell.execDetached(["kill", String(Quickshell.processId)])
    }
}
