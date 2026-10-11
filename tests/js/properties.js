.import "sourcefixture.js" as Source
.import "../../ui/js/Format.js" as Format

function run(check) {
    // Properties pairs come from the dialog's own Repeater model, so the Tags pair is proven where it is built.
    var dialogSource = Source.source("ui/MenuActionDialog.qml")
    var modelSlice = Source.slice(dialogSource, "model: root.action", "Column {")
    var pairsOf = eval("(function(root, Format) { return (" + modelSlice.replace(/^model:\s*/, "").replace(/\s+$/, "") + "); })")
    function propertiesFacts(tags) {
        return {action: "properties", facts: {ok: true, path: "/fixture/note.txt", kind: "File", bytes: 13,
            modified: 1758835200, mode: "0644", owner: "gm", uid: 1000, gid: 1000, tags: tags}}
    }
    function tagPairs(pairs) {
        return pairs.filter(function (pair) { return pair[0] === "Tags" })
    }
    var untagged = pairsOf(propertiesFacts([]), Format)
    check("an untagged item shows no Tags pair", tagPairs(untagged).length, 0)
    check("an untagged item shows no None label", JSON.stringify(untagged).indexOf("None"), -1)
    var tagged = pairsOf(propertiesFacts(["Red", "Blue"]), Format)
    check("a tagged item shows one Tags pair", tagPairs(tagged).length, 1)
    check("the Tags pair holds both tags", tagPairs(tagged)[0][1], "Red, Blue")
}
