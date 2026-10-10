import QtQuick

// ui/TagState.qml driven through a stub pane and backend: answers in send order, refusals, the removal line and the off-window read.
Item {
    id: probe
    signal failure(string message)
    function check(ok, message) { if (!ok) probe.failure(message) }

    // A pane and backend just wide enough for ui/TagState.qml: two held rows, a selection, and every line it sends or says.
    QtObject {
        id: stubBackend
        signal tagAnswer(var message)
        signal failed(string where, string input, string message, int mode)
        property real heldListing: 4
        property var sent: []
        property int windowAsks: 0
        function send(object) { stubBackend.sent.push(object) }
        function window(start, count) { stubBackend.windowAsks += 1 }
    }
    QtObject {
        id: stubPane
        property var backend: stubBackend
        property var rows: [{ n: "a", tg: ["Red"] }, { n: "b" }]
        property var picked: [0, 1]
        property var said: []
        property int held: 0
        property int windowSize: 2
        property int selectionVersion: 0
        property int cursorIndex: 0
        property int menuRefreshes: 0
        property var menu: QtObject { function refreshProviderRows() { stubPane.menuRefreshes += 1 } }
        function rowFor(index) { return index >= 0 && index < stubPane.rows.length ? stubPane.rows[index] : null }
        function selectedIndices() { return stubPane.picked }
        function selectionCount() { return stubPane.picked.length }
        function message(text, error) { stubPane.said.push(text) }
        function contextMenu() { return stubPane.menu }
    }

    function stateOf(entries, name) { return entries.filter(function (e) { return e.id === name })[0].tagRow.state }

    // Each settagged answer reports its own change in send order, a refusal takes its own change, and nothing changed says nothing.
    function measureAnswers() {
        var state = Qt.createComponent("flea/TagState.qml").createObject(probe, { pane: stubPane })
        probe.check(state !== null, "answers: TagState did not build")
        if (state === null) return
        probe.check(probe.stateOf(state.flyout(), "Red") === "mixed", "answers: one of two rows carrying Red is not mixed")
        state.choose("Red")
        state.choose("Blue")
        state.choose("Green")
        var ops = stubBackend.sent.map(function (o) { return o.c + ":" + o.op + ":" + o.tag }).join(",")
        probe.check(ops === "settags:toggle:Red,settags:toggle:Blue,settags:toggle:Green", "answers: the flyout sent " + ops)
        stubBackend.tagAnswer({ t: "settagged", ok: 2, op: "add" })
        probe.check(stubPane.said[0] === "Tagged 2 items Red \u00b7 z undoes", "answers: the first answer says " + stubPane.said[0])
        stubBackend.tagAnswer({ t: "settagged", ok: 1, op: "remove" })
        probe.check(stubPane.said[1] === "Removed Blue from 1 item \u00b7 z undoes", "answers: the second answer says " + stubPane.said[1])
        probe.check(stubBackend.windowAsks === 2, "answers: " + stubBackend.windowAsks + " window asks for two answers")
        stubBackend.failed("settags", "/x/a", "a refusal", 0)
        state.choose("Purple")
        stubBackend.tagAnswer({ t: "settagged", ok: 0, op: "add" })
        probe.check(stubPane.said.length === 2, "answers: a write that changed nothing said " + stubPane.said[stubPane.said.length - 1])
        probe.check(stubBackend.windowAsks === 3 && (state.pending || [null]).length === 0, "answers: the refused Green was not taken, or the no-op asked no window")
        state.choose("Gray")
        stubBackend.failed("stale", "settags", "the listing changed", 0)
        probe.check((state.pending || [null]).length === 0, "answers: a stale settags refusal left its change pending")
        probe.answersState = state
    }

    // A selection reaching past the held window reads its states from the backend, in the numbering it asked in, and redraws the flyout.
    function measureRead() {
        var state = probe.answersState
        probe.check(state !== null && typeof state.ask === "function", "read: TagState has no backend read to ask")
        if (state === null || typeof state.ask !== "function") return
        stubPane.picked = [0, 5000]
        stubPane.selectionVersion += 1
        probe.check(probe.stateOf(state.flyout(), "Red") === "absent", "read: an off-window selection claims a state before the backend answered")
        stubBackend.sent = []
        state.ask()
        var asked = stubBackend.sent[0]
        probe.check(asked !== undefined && asked.c === "tagstates" && asked.rows.join(",") === "0,5000", "read: no tagstates request for the off-window selection")
        if (asked === undefined) return
        stubBackend.tagAnswer({ t: "tagstates", id: asked.id, applied: ["Red"], mixed: [], listing: 3 })
        probe.check(probe.stateOf(state.flyout(), "Red") === "absent" && stubPane.menuRefreshes === 0, "read: an answer from another numbering was taken")
        state.ask()
        asked = stubBackend.sent[1]
        stubBackend.tagAnswer({ t: "tagstates", id: asked.id, applied: ["Red"], mixed: ["Blue"], listing: 4 })
        var entries = state.flyout()
        probe.check(probe.stateOf(entries, "Red") === "applied" && probe.stateOf(entries, "Blue") === "mixed", "read: the flyout does not draw the backend's states")
        probe.check(stubPane.menuRefreshes === 1, "read: the open flyout was redrawn " + stubPane.menuRefreshes + " times")
        state.ask()
        probe.check(stubBackend.sent.length === 2, "read: an answered selection was asked again")
        stubPane.selectionVersion += 1
        state.ask()
        var early = stubBackend.sent[2]
        state.choose("Red")
        stubBackend.tagAnswer({ t: "settagged", ok: 2, op: "add" })
        stubBackend.tagAnswer({ t: "tagstates", id: early.id, applied: [], mixed: ["Red"], listing: 4 })
        probe.check(probe.stateOf(state.flyout(), "Red") === "absent" && stubPane.menuRefreshes === 1, "read: a read made before a change landed drew the flyout")
        state.ask()
        probe.check(stubBackend.sent.length === 5, "read: after a change the selection was not asked again")
    }

    property var answersState: null
}
