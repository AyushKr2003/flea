import QtQuick
import "js/PathBar.js" as PathBar
import "js/Picker.js" as Picker

// What a committed line means in the picker. The backend's peek says what the line names before anything lists:
// a folder opens, a file lists its folder once and answers through the listing row's own accept, so the dialog's
// filter judges it, and a line that names nothing changes nothing.
Item {
    id: root

    required property var picker
    required property var listing
    required property var backend
    required property var entry

    // Recent is a location and not a path, so a relative line resolves
    // against home there instead of joining onto the location token.
    readonly property string basePath: root.picker.recent ? root.picker.home : root.picker.path

    // The path peeked and waiting for its answer.
    property string asked: ""
    // A file's leaf, looked for in the rows of its parent once that folder shows.
    property string leaf: ""
    property string leafParent: ""

    function commitTyped(text) {
        var target = PathBar.resolve(text, root.basePath, root.picker.home)
        if (target === "") {
            // A URI on another host says its sentence; an empty line only closes, as the chrome's commit does.
            if (PathBar.refused(text)) {
                root.picker.say(PathBar.REFUSED_SENTENCE, false)
                return
            }
            root.entry.closeEdit()
            return
        }
        root.ask(target)
    }

    // A peek of count zero is the stat and nothing else; Tab's own peek asks for rows, so the two replies never mix.
    function ask(target) {
        root.asked = target
        root.leaf = ""
        root.listing.peek(target, 0, root.picker.showHidden)
    }

    function answered(path, readFailed, mode) {
        if (path !== root.asked) return
        root.asked = ""
        var kind = PathBar.kindOfPeek(readFailed, mode)
        if (kind === "missing") {
            root.picker.say(PathBar.fill(PathBar.MISSING_SENTENCE, path), true)
        } else if (kind === "folder") {
            root.picker.open(path)
            root.entry.closeEdit()
        } else {
            root.openFile(path)
        }
    }

    function openFile(path) {
        // A file where a folder answers is the backend's own refusal, never a
        // sentence written here: the mark names the folder type and fails it.
        if (root.picker.saving || root.picker.folderMode) {
            root.picker.acceptMarks = false
            root.picker.pathProbe = root.picker.check({op: "mark", path: path, directory: true, multiple: false})
            return
        }
        var cut = path.lastIndexOf("/")
        root.leaf = path.substring(cut + 1)
        root.leafParent = Picker.parentOf(path)
        if (root.leafParent === root.picker.path) {
            root.findLeaf(root.picker.held, root.picker.rows)
        } else {
            root.picker.open(root.leafParent)
        }
    }

    // Rows arrive windowed, so the leaf is searched as each window lands; past the last row without it, the
    // listing's own filter or the hidden files setting left it out, and the field stays open with that said.
    function findLeaf(start, items) {
        for (var i = 0; i < items.length; i++) {
            if (items[i].n === root.leaf) {
                root.picker.cursorIndex = start + i
                root.leaf = ""
                root.picker.activate(start + i)
                return
            }
        }
        if (start + items.length < root.picker.total) {
            root.listing.window(start + items.length, root.picker.windowSize)
            return
        }
        root.picker.say(PathBar.fill(PathBar.FILTERED_SENTENCE, root.leaf), true)
        root.leaf = ""
    }

    // The field closing, or the picker moving on, drops whatever was still being looked for.
    function editClosed() {
        root.asked = ""
        root.leaf = ""
        root.picker.focusView()
    }

    // The leaf is searched as each rows window lands, never at the listed line,
    // which answers before any row of the new listing arrived.
    Connections {
        target: root.backend
        function onListed(total) {
            if (root.leaf !== "" && total === 0 && root.picker.path === root.leafParent) root.findLeaf(0, [])
        }
        function onRows(start, items) {
            if (root.leaf === "") return
            if (root.picker.path !== root.leafParent) { root.leaf = ""; return }
            root.findLeaf(start, items)
        }
        function onJumped(id, favourites, zoxide, recent, frecency) {
            if (root.entry.jump !== null) root.entry.jump.take(id, favourites, zoxide, recent, frecency)
        }
        function onPeeked(path, hidden, total, rows, readFailed, mode, hiddenLast, first) {
            if (first === 0) root.answered(path, readFailed, mode)
            else root.entry.completeWith(path, hidden, rows)
        }
    }
}
