import QtQuick
import Quickshell
import "flea" as Flea
import "flea/js/Drag.js" as DragOps

// A peek column row lifts its own path, with the column's device and writability in the marker and no listing rows, and takes drops only on a folder row; a column with no peek source lifts nothing.
ShellRoot {
    id: root

    property int checks: 0
    property int failures: 0
    readonly property var names: ["a#b.txt", "50%.txt", "two words.txt", "-dash.txt", "new\nline.txt"]
    // The pane a peek column belongs to: joins paths, records each collide request, and can hold a listing in flight.
    readonly property QtObject paneStub: QtObject {
        property bool listInFlight: false
        property var asked: []
        property string said: ""
        readonly property var collide: ({ ask: function (req) { root.paneStub.asked = root.paneStub.asked.concat([req]); return true } })
        // Drag.js dropInto asks through pane.asks(), as a product pane builds its collide card on first use.
        function asks() { return root.paneStub.collide }
        function join(a, b) { return a + "/" + b }
        function message(line, ok) { root.paneStub.said = line }
    }

    function check(label, actual, expected) {
        root.checks += 1
        if (JSON.stringify(actual) === JSON.stringify(expected)) return
        root.failures += 1
        console.log("COLUMNSPEEKDRAG FAIL " + label + ": got " + JSON.stringify(actual) + ", expected " + JSON.stringify(expected))
    }

    function source(writable) { return { pane: root.paneStub, dir: "/fx/sub", v: 42, w: writable } }

    function rowsOf(column) {
        var out = []
        for (var i = 0; i < root.names.length; i++) {
            var cell = column.viewport.itemAtIndex(i)
            for (var c = 0; cell && c < cell.children.length; c++)
                if (cell.children[c].session !== undefined) out.push(cell.children[c])
        }
        return out
    }

    // Sample output: [true, ""] for a call that answered true and threw nothing.
    function attempt(call) {
        try { return [call(), ""] } catch (e) { return [null, String(e)] }
    }

    function dropAreaOf(rowDrag) {
        for (var c = 0; c < rowDrag.children.length; c++)
            if (rowDrag.children[c].keys !== undefined) return rowDrag.children[c]
        return null
    }

    Flea.FileDrag { id: lone; pane: null; peekSource: root.source(true) }
    Flea.FileDrag { id: locked; pane: null; peekSource: root.source(false) }

    FloatingWindow {
        implicitWidth: 1200
        implicitHeight: 400
        Flea.ColumnPane {
            id: peekColumn
            x: 0; width: 400; height: 400
            rows: root.names.map(function (n) { return { n: n, d: false, i: "text-x-generic" } })
            peekSource: root.source(true)
        }
        Flea.ColumnPane {
            id: bareColumn
            x: 400; width: 400; height: 400
            rows: root.names.map(function (n) { return { n: n, d: false, i: "text-x-generic" } })
        }
        Flea.ColumnPane {
            id: folderColumn
            x: 800; width: 400; height: 400
            rows: [{ n: "inbox", d: true, i: "folder" }]
            peekSource: root.source(true)
        }
    }

    Timer {
        interval: 600
        running: true
        onTriggered: {
            for (var i = 0; i < root.names.length; i++) {
                var name = root.names[i]
                var mime = lone.peekMime({ n: name, d: false }, false, false)
                var marker = mime[DragOps.ROWS_MIME]
                root.check(name + " plain path", mime["text/plain"], "/fx/sub/" + name)
                root.check(name + " uri", mime["text/uri-list"], "file:///fx/sub/" + encodeURIComponent(name) + "\r\n")
                root.check(name + " marker source, device, deletable", [DragOps.markerSource(marker), DragOps.markerDev(marker), DragOps.markerDeletable(marker)], ["/fx/sub", 42, true])
                root.check(name + " marker carries no rows", marker.split("\n")[1], "")
                root.check(name + " no index drop", DragOps.canDropByIndex(marker, "/fx/sub", [], 0), false)
            }
            root.check("a read-only column copies", DragOps.markerDeletable(locked.peekMime({ n: "x", d: false }, false, false)[DragOps.ROWS_MIME]), false)
            root.check("shift rides the marker", DragOps.markerShift(lone.peekMime({ n: "x", d: false }, false, true)[DragOps.ROWS_MIME]), true)
            var peekRows = root.rowsOf(peekColumn)
            root.check("every peek row realised", peekRows.length, root.names.length)
            for (var p = 0; p < peekRows.length; p++)
                root.check("peek row " + p + " lifts and takes no drop", [peekRows[p].enabled, root.dropAreaOf(peekRows[p]).enabled], [true, false])
            var folderRows = root.rowsOf(folderColumn)
            root.check("a peek folder row lifts and takes a drop", folderRows.length === 1
                ? [folderRows[0].enabled, root.dropAreaOf(folderRows[0]).enabled, folderRows[0].targetDir] : [], [true, true, "/fx/sub"])
            var folder = folderRows.length === 1 ? folderRows[0] : null
            var outside = ["file:///elsewhere/x.txt"]
            root.check("an outside uri-list enters the peek folder row", root.attempt(function () { return folder.enter("", outside, "", "", Qt.CopyAction, "") })
                .concat([folder ? folder.session.dropIndex : null]), [true, "", 0])
            root.check("its drop reaches the pane's collide with the folder as destination", root.attempt(function () { return folder.dropped("", outside, "", "", Qt.CopyAction) })
                .concat([root.paneStub.asked, root.paneStub.said]), [true, "", [{ c: "transfer", op: "copy", paths: ["/elsewhere/x.txt"], dest: "/fx/sub/inbox" }], ""])
            root.paneStub.listInFlight = true
            root.check("a listing in flight closes the peek folder row's drop", folder ? root.dropAreaOf(folder).enabled : null, false)
            root.paneStub.listInFlight = false
            root.check("the landed listing opens it again", folder ? root.dropAreaOf(folder).enabled : null, true)
            var bareRows = root.rowsOf(bareColumn)
            root.check("every bare row realised", bareRows.length, root.names.length)
            for (var b = 0; b < bareRows.length; b++)
                root.check("a column with no source lifts nothing " + b, bareRows[b].enabled, false)
            console.log("COLUMNSPEEKDRAG DONE checks=" + root.checks + " failed=" + root.failures)
            Quickshell.execDetached(["kill", String(Quickshell.processId)])
        }
    }
}
