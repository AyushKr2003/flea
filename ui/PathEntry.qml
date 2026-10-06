import QtQuick
import qs.Commons
import "js/PathBar.js" as PathBar

// The path bar's typed half for the main chrome and the picker: field, frame, Jump dropdown and Tab; hosts answer its commits.
Item {
    id: root

    property string path: ""
    property string home: ""
    // Read by the path bar alone, so a Tab on a dotted leaf peeks the way the listing is set to look.
    property bool showHidden: false

    // The commit and the jump's choice, which each host answers for itself.
    signal commitLine(string text)
    signal jumpChosen(string path)
    signal editClosed()
    signal completeRequested(string dir, bool hidden)
    signal said(string text)
    // The folder jump's one read per open, carried to the pane's backend like Tab's peek; see ui/PathJump.qml.
    signal jumpRequested(int id, int ranking, var favourites, var recent)

    // Built by the first edit and kept for the window's life, so a bar never opened compiles none of it.
    property bool jumpBuilt: false
    readonly property var jump: jumpLoader.item
    readonly property bool jumpShown: jumpLoader.item !== null && jumpLoader.item.shown
    // What the seam reads: the line as it stands.
    readonly property alias editText: field.text
    // The open field and its frame, so a test measures where they lie in the strip.
    readonly property alias pathFrame: editFrame
    readonly property alias pathField: field

    // The Tab request in flight and the one that came back, keyed by the hidden flag as well as the path, or a Tab
    // on ".conf" would answer off rows peeked without dotfiles: the key is what the request asked for, never the line.
    property string pendingKey: ""
    property string cachedKey: ""
    property var cachedNames: []

    // The path bar: the same strip, typed instead of drawn. ":" and Ctrl+L open it, so does a double
    // click on the path, and it is where the whole of keys.toml's pathBar action lands.
    property bool editing: false

    function startEdit() {
        if (root.editing) {
            return
        }
        // The Loader below is synchronous, so the jump stands before this returns.
        root.jumpBuilt = true
        root.editing = true
        // The trailing slash is what makes typing a child the natural next keystroke, and the line
        // opens selected, so a name typed straight away replaces it instead of joining onto it.
        field.text = root.path === "/" ? "/" : root.path + "/"
        field.forceActiveFocus()
        field.selectAll()
    }

    function closeEdit() {
        if (!root.editing) {
            return
        }
        root.editing = false
        root.pendingKey = ""
        root.cachedKey = ""
        root.cachedNames = []
        // The field is inside no focus scope of its own, so the keyboard goes nowhere until the pane
        // is told to take it back; the host answers editClosed for that.
        root.editClosed()
    }

    // Tab. The rows come from the backend's peek, which is the read the columns view already makes of
    // a directory that is not the pane's, so completing costs no new request type.
    function completeEdit() {
        var dir = PathBar.completionDir(field.text, root.path, root.home)
        var hidden = PathBar.wantsHidden(field.text, root.showHidden)
        var key = PathBar.requestKey(dir, hidden)
        if (key === root.cachedKey) {
            root.applyCompletion(dir, root.cachedNames)
            return
        }
        root.pendingKey = key
        root.completeRequested(dir, hidden)
    }

    // Column peeks and a Tab's dotfile retry share the wire, so a reply is matched on the (dir, hidden) pair the
    // backend echoes, never the path alone; only directories complete, since the bar goes to a directory.
    function completeWith(dir, hidden, rows) {
        if (PathBar.requestKey(dir, hidden) !== root.pendingKey) {
            return
        }
        var names = []
        for (var i = 0; i < rows.length; i++) {
            if (rows[i].d) {
                names.push(rows[i].n)
            }
        }
        root.cachedKey = root.pendingKey
        root.cachedNames = names
        root.pendingKey = ""
        if (root.editing && PathBar.completionDir(field.text, root.path, root.home) === dir) {
            root.applyCompletion(dir, names)
        }
    }

    function applyCompletion(dir, names) {
        var before = field.text
        var after = PathBar.complete(before, names)
        field.text = after.text
        field.cursorPosition = field.text.length
        var say = PathBar.completionMessage(before, after, dir)
        if (say.length > 0) {
            root.said(say)
        }
    }

    // The rename editor's own frame, at chrome scale: the accent marks the strip with the keyboard, and its fill covers the two Texts beneath.
    Rectangle {
        id: editFrame
        visible: root.editing
        anchors.fill: parent
        anchors.topMargin: Theme.spacing.hairline * 2
        // One below against two above centres the field in the strip, which is the flush dropdown the Jump board draws.
        anchors.bottomMargin: Theme.spacing.hairline
        color: Theme.color.background
        radius: Style.cornerRadius
        border.width: Theme.spacing.hairline
        border.color: Theme.color.accent
    }

    // corner: a typed path is arbitrary text, so it is drawn at the same size the path it
    // replaces is, and the caret sits on the line rather than on a row of its own.
    TextInput {
        id: field
        visible: root.editing
        enabled: root.editing
        anchors.fill: parent
        anchors.leftMargin: Theme.spacing.gap
        anchors.rightMargin: Theme.spacing.gap
        verticalAlignment: TextInput.AlignVCenter
        color: Theme.color.foreground
        selectionColor: Theme.color.accent
        selectedTextColor: Theme.color.background
        font.family: Theme.font.family
        font.pixelSize: Theme.font.caption
        clip: true
        // The jump's dropdown takes the arrows and Enter first, and only while it is showing rows.
        Keys.forwardTo: root.jump !== null ? [root.jump] : []

        // Every one of these is handled and accepted here, for the reason ui/RenameField.qml
        // gives: an unaccepted key goes on to the pane's own handler, which would read Return as
        // "open the row under the cursor" and Tab as "move to the rail" while the bar is up.
        Keys.onPressed: function (event) {
            if (event.key === Qt.Key_Escape) {
                root.closeEdit()
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.commitLine(field.text)
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                root.completeEdit()
                event.accepted = true
            }
        }

        // Losing the keyboard closes the bar, the rule the rename editor already follows: a bar
        // left standing over a window that has moved on would commit against the wrong directory.
        onActiveFocusChanged: if (!activeFocus && root.editing) root.closeEdit()
    }

    // The Jump board's dropdown, flush under this field at its width from the path slot its Loader fills.
    Loader {
        id: jumpLoader
        anchors.fill: parent
        active: root.jumpBuilt
        asynchronous: false
        source: "PathJump.qml"
    }
    // Live bindings onto the lazy item, applied once it stands and kept after the bar closes.
    Binding {
        target: jumpLoader.item
        property: "editing"
        value: root.editing
        when: jumpLoader.item !== null
    }
    Binding {
        target: jumpLoader.item
        property: "query"
        value: field.text
        when: jumpLoader.item !== null
    }
    Binding {
        target: jumpLoader.item
        property: "home"
        value: root.home
        when: jumpLoader.item !== null
    }
    Connections {
        target: jumpLoader.item
        function onRequested(id, ranking, favourites, recent) { root.jumpRequested(id, ranking, favourites, recent) }
        function onDeclined() { root.commitLine(field.text) }
        function onDismissed() { root.closeEdit() }
        function onChosen(path) { root.jumpChosen(path) }
    }
}
