.import "../../ui/js/Menu.js" as Menu
.import "../../ui/js/MarkdownPrepared.js" as Prepared
.import "../../ui/js/Lists.js" as Lists
.import "sourcefixture.js" as Source

// The backend delivers parsed replies through a var signal and readers retain them in var properties.
function received(text) {
    var parent = Qt.createComponent("QtQuick", "Item").createObject(null)
    var relay = Qt.createQmlObject("import QtQuick\nQtObject {\n"
        + "signal delivered(var message)\nproperty var received\n"
        + "onDelivered: function(message) { received = message }\n}", parent)
    relay.delivered(JSON.parse(text))
    return { parent: parent, message: relay.received }
}

// Execute the shipped QML body with only its process and singleton dependencies replaced.
function body(file, marker, args) {
    return new Function(args, Source.block(Source.source(file), marker, file))
}

function run(plain) {
    function check(label, actual, expected) { plain(label, JSON.stringify(actual), JSON.stringify(expected)) }
    var fixture = received('{"kinds":[32768,32768],"paths":["/a","/b"],'
        + '"blocks":[{"type":"list","parts":[[{"type":"figure","kind":"math","source":"x"},{"type":"table"}]]}]}')
    var message = fixture.message
    console.log("sequence signal: Array.isArray=" + Array.isArray(message.kinds)
        + ", every=" + typeof message.kinds.every + ", concat=" + JSON.stringify([].concat(message.kinds)))
    check("var signal: two regular files offer Compare", Menu.canCompare(message.kinds), true)
    check("var signal: nested Markdown formulas remain visible", Prepared.formulasIn(message.blocks, 8), [{source: "x", display: true}])

    var lists = Lists
    var root = {}
    var holds = body("ui/QuickLookPrepare.qml", "function holdsTable(", "root,Lists,list")
    root.holdsTable = function (list) { return holds(root, lists, list) }
    check("var signal: nested Markdown tables remain visible", root.holdsTable(message.blocks), true)
    var kind = body("ui/IpcPreviewState.qml", "function kindOf(", "root,Lists,block")
    root.kindOf = function (block) { return kind(root, lists, block) }
    check("var signal: Markdown diagnostics flatten list items", root.kindOf(message.blocks[0]), "list[figure,table]")

    var shelver = {}
    body("ui/PaneMenuActions.qml", "function startAdd(", "shelver,Quickshell,Lists,paths")
        (shelver, {env: function () { return "flea" }}, lists, message.paths)
    check("var signal: shelf command has separate path arguments", shelver.command, ["flea","shelf","add","/a","/b"])
    var runner = {}
    root = {entries: [{id: "test", path: "/scripts/test"}], said: function () {}}
    body("ui/Scripts.qml", "function run(", "root,runner,Lists,id,paths")(root, runner, lists, "test", message.paths)
    check("var signal: script command has separate path arguments", runner.command, ["/scripts/test","/a","/b"])
    root = {pending: {request: 7, range: null}, picker: {markRequest: -1, marks: []}}
    root.picker.check = function (request) { root.sent = request; return 8 }
    body("ui/PickerSelection.qml", "function onPathsResolved(", "root,Picker,Lists,paths,request")
        (root, {paths: function () { return ["/old"] }}, lists, message.paths, 7)
    check("var signal: picker selection remains a flat path list", root.sent.paths, ["/old","/a","/b"])
    var receivedEmpty = received('{"items":[],"mixed":[32768,16384],"links":[32768,40960]}')
    check("list test: var signal sequences are lists", Lists.isList(message.kinds), true)
    check("list test: native Arrays stay lists", Lists.isList([1, 2]), true)
    check("list test: empty signal sequence stays a list", Lists.isList(receivedEmpty.message.items), true)
    check("list test: strings, null and invalid objects stay refused",
        [Lists.isList("ab"), Lists.isList(new String("ab")), Lists.isList(null), Lists.isList(undefined),
         Lists.isList({}), Lists.isList({length: "2"}), Lists.isList({length: 2}),
         Lists.isList({length: -1, every: function () {}}), Lists.isList({length: Infinity, every: function () {}}),
         Lists.isList({length: 1.5, every: function () {}})],
        [false, false, false, false, false, false, false, false, false, false])
    check("var signal: a folder still refuses Compare", Menu.canCompare(receivedEmpty.message.mixed), false)
    check("var signal: a symlink still refuses Compare", Menu.canCompare(receivedEmpty.message.links), false)
    check("var signal: an empty list still refuses Compare", Menu.canCompare(receivedEmpty.message.items), false)
    check("var signal: strings and object-shaped kinds refuse Compare",
        [Menu.canCompare("ab"), Menu.canCompare({0: 32768, 1: 32768, length: 2}), Menu.canCompare(null)], [false, false, false])
    var copied = [].concat(message.paths)
    copied.push("/c")
    check("concat: command construction does not mutate the received sequence", message.paths, ["/a", "/b"])
    receivedEmpty.parent.destroy()
    fixture.parent.destroy()
}
