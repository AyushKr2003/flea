import Quickshell
import Quickshell.Io
import QtQuick

// The one component that runs Flea's own opening modes, so the huge page corner has one owner; see AGENTS.md "Opening a file".
Item {
    id: root

    signal failed(string path)
    signal isDirectory(string path)
    signal terminalFailed(string path)
    // Raised where the two single-flight guards below drop a request, so a swallowed press says so.
    signal busy(string path)
    signal terminalBusy(string path)
    // flea --open answers 4 with the run card's own ask line, and 5 where no
    // application claims the file; the ask line rides stdout beside the status.
    signal askRunRaw(string path, string text)
    signal askOpenWith(string path)

    // The status src/open.rs returns for a directory, which the caller navigates to instead.
    readonly property int isDirectoryStatus: 3
    // The two statuses src/runfile.rs added beside it: ask the card, or ask Open with.
    readonly property int askRunStatus: 4
    readonly property int askOpenWithStatus: 5

    property string current: ""
    // The terminal launch's own path: open() and openTerminal() run on separate
    // Processes guarded only against themselves, so sharing current let whichever
    // started second rewrite the path the first one's onExited still reports.
    property string terminalCurrent: ""
    // One open at a time, and each half carries its request id: the stream text
    // and the exit belong together only when both name the pending request.
    property int askSeq: 0
    property int askPending: 0
    property int askCode: -1
    property int askCodeId: 0
    property string askText: ""
    property int askTextId: 0
    property bool askStreamBusy: false

    // flea --open waits for gio open and not for the application it starts, and that wait is 11 to 15 ms
    // for an Exec= handler but 0.32 to 0.75 s for a DBusActivatable one, which is what this box's
    // twenty-five archive types default to, so this guard drops a second Enter for that long and says so.
    function open(path) {
        // The previous launch never answered: its program never started, so that
        // refusal is said now and the new open proceeds instead of wedging busy.
        if (root.askPending !== 0 && !child.running && root.askCode < 0) {
            var stale = root.current
            root.askPending = 0
            root.askStreamBusy = false
            root.failed(stale)
        }
        if (child.running || root.askPending !== 0 || root.askStreamBusy) {
            root.busy(path)
            return
        }
        root.current = path
        root.askSeq++
        root.askPending = root.askSeq
        root.askCode = -1
        root.askCodeId = 0
        root.askText = ""
        root.askTextId = 0
        root.askStreamBusy = true
        child.command = [Quickshell.env("FLEA_BIN") || "flea", "--open", path]
        child.running = true
    }

    // An ask status without its line is a launch that died mid-answer, so it says
    // the plain failure rather than opening a card for a file it never described.
    function tryAsk() {
        if (root.askPending === 0 || root.askCodeId !== root.askPending || root.askTextId !== root.askPending)
            return
        var code = root.askCode
        var text = root.askText
        var path = root.current
        root.askPending = 0
        root.askCode = -1
        root.askCodeId = 0
        root.askText = ""
        root.askTextId = 0
        if (code === root.askRunStatus) {
            root.askRunRaw(path, text)
            return
        }
        if (code === root.askOpenWithStatus) {
            root.askOpenWith(path)
            return
        }
        root.failed(path)
    }

    Process {
        id: child
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.askText = this.text
                root.askTextId = root.askPending
                root.askStreamBusy = false
                root.tryAsk()
            }
        }

        onExited: function (exitCode, exitStatus) {
            if (exitCode === 0) {
                root.askPending = 0
                return
            }
            if (exitCode === root.isDirectoryStatus) {
                root.askPending = 0
                root.isDirectory(root.current)
                return
            }
            if (exitCode === root.askRunStatus || exitCode === root.askOpenWithStatus) {
                root.askCode = exitCode
                root.askCodeId = root.askPending
                root.tryAsk()
                return
            }
            root.askPending = 0
            root.failed(root.current)
        }
    }

    // A terminal in the current directory, through flea --terminal so the huge page,
    // process-group and stdio guards in src/terminal.rs apply. Its own Process, so a terminal
    // launch and a file open in flight cannot take each other's exit status.
    function openTerminal(path) {
        if (terminalChild.running) {
            root.terminalBusy(path)
            return
        }
        root.terminalCurrent = path
        terminalChild.command = [Quickshell.env("FLEA_BIN") || "flea", "--terminal", path]
        terminalChild.running = true
    }

    Process {
        id: terminalChild

        onExited: function (exitCode, exitStatus) {
            if (exitCode === 0) {
                return
            }
            root.terminalFailed(root.terminalCurrent)
        }
    }

    // The system clipboard, for the listing menu's Copy Path row. wl-copy reads the text on stdin,
    // so the one-liner hands it over; flea's own copy clipboard (Ops.clip) is a different thing
    // and must stay a different thing.
    function copyText(text) {
        if (copier.running) {
            return
        }
        copier.command = ["sh", "-c", "printf '%s' \"$1\" | wl-copy", "_", text]
        copier.running = true
    }

    Process {
        id: copier
    }

    // A library cannot name a singleton, so the menu's Update Flea row comes through here, and the pane's footer says what it did.
    function updateFlea(pane) {
        UpdateCheck.launch(pane)
    }

}
