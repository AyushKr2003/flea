import QtQuick
import "js/sourcefixture.js" as Source
import "js/collidefixture.js" as CollideFixture

Item {
    id: test
    property int checked: 0
    property int failed: 0

    function check(label, actual, expected) {
        test.checked++
        if (actual !== expected) {
            test.failed++
            console.log("FAIL " + label + ": got " + JSON.stringify(actual) + ", expected " + JSON.stringify(expected))
        }
    }

    // Sample input: "Flea.DropInto { dest: root.pane.dropPath }".
    function block(text, marker) {
        var start = text.indexOf(marker)
        if (start < 0) throw new Error("missing shipped block " + marker)
        var end = text.indexOf("{", start) + 1
        var depth = 1
        while (depth > 0 && end < text.length) {
            if (text[end] === "{") depth++
            else if (text[end] === "}") depth--
            end++
        }
        if (depth !== 0) throw new Error("unterminated shipped block " + marker)
        return text.slice(start, end)
    }

    // The shipped floor bindings and drop handler without Quickshell singletons; bare DropKeys becomes the real ui/DropKeys.qml minus its pragma.
    function floor(file, pane) {
        var wiring = block(Source.source(file), "Flea.DropInto {")
        var handler = block(Source.source("ui/DropInto.qml"), "onDropped: function (drop)")
            .replace("onDropped: function (drop)", "function performDrop(drop)")
            .replace(/\bDropKeys\./g, "dropKeys.")
        var exit = block(Source.source("ui/DropInto.qml"), "onExited: {").replace("onExited: {", "function performExit() {")
            .replace(/\bDropKeys\./g, "dropKeys.")
        var code = "import QtQuick\n"
        var imports = [["Drag.js", "DragOps"], ["DragOut.js", "DragOut"], ["Tabs.js", "Tabs"]]
        for (var i = 0; i < imports.length; i++)
            code += "import " + JSON.stringify(String(Qt.resolvedUrl("../ui/js/" + imports[i][0]))) + " as " + imports[i][1] + "\n"
        code += "Item { id: root; property var pane: null\nproperty var dropKeys\nproperty bool scrolls: false\nfunction leaveFeedback() {}\n"
        var defaults = { dest: '""', destDev: "0", refuseLoading: "false" }
        var types = { dest: "string", destDev: "int", refuseLoading: "bool" }
        for (var name in defaults) {
            var binding = wiring.match(new RegExp("^\\s*" + name + ": ([^\\n]+)$", "m"))
            code += "property " + types[name] + " " + name + ": " + (binding ? binding[1] : defaults[name]) + "\n"
        }
        var result = Qt.createQmlObject(code + handler + "\n" + exit + "\n}", test, "shipped-floor.qml")
        result.pane = pane
        result.dropKeys = CollideFixture.realDropKeys(result)
        return result
    }

    function sample(view, loading) {
        var requests = []
        var said = []
        var pane = { path: "/shown", dropPath: loading ? "/requested" : "/shown",
            listInFlight: loading, viewMode: view, backend: { dirDev: 32 },
            collide: { ask: function (request) { requests.push(request); return true } },
            message: function (line) { said.push(line) } }
        var floor = test.floor(view === "columns" ? "ui/ColumnPane.qml" : "ui/PaneWire.qml", pane)
        var accepted = 0
        var drop = { urls: ["file:///source/a.txt"], proposedAction: Qt.CopyAction,
            getDataAsString: function () { return "" }, accept: function () { accepted++ } }
        floor.performDrop(drop)
        if (loading) {
            test.check(view + " held floor sends no transfer", requests.length, 0)
            test.check(view + " held floor accepts no drop", accepted, 0)
            test.check(view + " held floor names loading refusal", said.join("|"), "A directory is already loading.")
            test.check(view + " held floor binds destination to dropPath", floor.dest, "/requested")
        } else {
            test.check(view + " settled floor sends one transfer", requests.length, 1)
            test.check(view + " settled floor names shown directory", requests.length ? requests[0].dest : "", "/shown")
            test.check(view + " settled floor accepts once", accepted, 1)
        }
        floor.destroy()
    }

    // #259: a plain lift from /source on device 32 would move; the shipped handler copies it for a held ctrl and clears the store on every way out.
    function keyed(view, loading) {
        var requests = []
        var pane = { path: "/shown", dropPath: "/shown", listInFlight: loading, viewMode: view, backend: { dirDev: 32 },
            collide: { ask: function (request) { requests.push(request); return true } }, message: function () {} }
        var floor = test.floor(view === "columns" ? "ui/ColumnPane.qml" : "ui/PaneWire.qml", pane)
        var marker = "foreign\n0\nmove\n%2Fsource\n32\n1\n0"
        floor.dropKeys.enter(marker)
        floor.dropKeys.track({ key: Qt.Key_Control }, true)
        floor.performDrop({ urls: ["file:///source/a.txt"], proposedAction: Qt.MoveAction, accept: function () {},
            getDataAsString: function (type) { return type === "application/x-flea-rows" ? marker : "" } })
        var tag = view + (loading ? " held" : " settled")
        if (!loading) test.check(tag + " floor copies a plain lift dropped holding ctrl", requests.length ? requests[0].op : "nothing", "copy")
        test.check(tag + " floor drop clears the store's drag", floor.dropKeys.marker + " " + floor.dropKeys.ctrl, " -1")
        floor.dropKeys.enter(marker)
        floor.performExit()
        floor.dropKeys.settle()
        test.check(tag + " floor leave no entrance follows ends the drag's keys", floor.dropKeys.marker, "")
        floor.destroy()
    }

    Component.onCompleted: {
        var views = ["list", "grid", "columns"]
        for (var i = 0; i < views.length; i++) {
            test.sample(views[i], true)
            test.sample(views[i], false)
            test.keyed(views[i], true)
            test.keyed(views[i], false)
        }
        console.log("floor drops: " + test.checked + " checks, " + test.failed + " failed")
        Qt.exit(test.failed === 0 ? 0 : 1)
    }
}
