import QtQuick
import "js/FlashCard.js" as FlashCard
import "js/FlashEndings.js" as FlashEndings
import "js/Ops.js" as Ops

// The flash run: owns what the backend answers, so a Back mid-flash keeps answering into the pane's transfer.
Item {
    id: root
    required property var pane
    // The running flash in Transfer.js's own shape, so the card after Back draws it unchanged.
    property var transfer: Ops.emptyTransfer()
    property var ending: null
    // A Flash press already sent and not yet started, so a second Enter cannot double it.
    property bool pressSent: false
    property real rate: 0
    property real rateAt: 0
    property real rateBytes: 0
    readonly property bool running: root.transfer.running === true

    function reset() {
        root.ending = null
        root.pressSent = false
        root.transfer = Ops.emptyTransfer()
        root.rate = 0
    }

    // Every line the flash draws is rendered beside the fields it names, so the card and the
    // status line draw finished text through the shipped setters and Transfer.js never names it.
    function rendered(base) {
        var drawn = FlashCard.render(base, root.rate)
        return Object.assign({}, base, { headText: drawn.headText, fileText: drawn.fileText,
            byteText: drawn.byteText, share: drawn.share, noCancel: drawn.noCancel })
    }

    function startTransfer(id, total, known, imageName, driveLabel, opened) {
        root.pressSent = false
        root.rate = 0
        root.rateAt = Date.now()
        root.rateBytes = 0
        root.transfer = root.rendered(Object.assign(Ops.emptyTransfer(),
            { id: id, flash: true, phase: "prepare", drive: driveLabel, name: imageName,
              bytes: 0, total: total, known: known, permille: 0, running: true }))
        root.ending = null
        if (!opened) {
            root.pane.transfer = root.transfer
            root.pane.sticky(Ops.progressLine(root.transfer))
        }
    }

    function noteRate(bytes) {
        var now = Date.now()
        var span = (now - root.rateAt) / 1000
        if (span >= 2 && bytes >= root.rateBytes) {
            root.rate = (bytes - root.rateBytes) / span
            root.rateAt = now
            root.rateBytes = bytes
        }
    }

    function progressTransfer(id, phase, bytes, total, permille, opened) {
        if (!root.running || id !== root.transfer.id)
            return
        root.noteRate(bytes)
        root.transfer = root.rendered(Object.assign({}, root.transfer,
            { phase: phase, bytes: bytes, total: total, permille: permille }))
        if (!opened) {
            root.pane.transfer = root.transfer
            root.pane.sticky(Ops.progressLine(root.transfer))
        }
    }

    function finishTransfer(message, imageName, driveLabel, driveBytes, opened) {
        if (!root.running || (message.id || 0) !== root.transfer.id)
            return false
        var ok = message.ok === true
        var err = ok ? "" : String(message.err || "error")
        var ctx = { image: imageName, drive: driveLabel, at: message.at || 0,
            total: root.transfer.total || 0, blank: message.blank === true,
            tool: message.tool || "", phase: String(message.phase || ""), driveBytes: driveBytes }
        root.transfer = Ops.emptyTransfer()
        root.rate = 0
        if (opened) {
            root.ending = FlashEndings.endingFor(err, ctx)
            return true
        }
        root.pane.transfer = Ops.emptyTransfer()
        root.pane.sticky("")
        var line = FlashEndings.statusFor(err, ctx)
        root.pane.message(line.text, line.isError)
        return false
    }

    function finishEject(message, driveLabel) {
        if (message.ok === true) {
            root.pane.message(FlashEndings.ejectDoneLine(driveLabel), false)
            return
        }
        if (String(message.err || "") === "busy")
            root.pane.message(FlashEndings.ejectBusyLine(driveLabel), true)
        else
            root.pane.message(FlashEndings.ejectFailedLine(driveLabel), true)
    }
}
