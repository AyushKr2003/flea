//@ pragma ShellId flea-unlock-stdin-test

import QtQuick
import Quickshell
import "flea" as Flea
import "flea/js/Unlock.js" as Unlock

// tests/unlock-stdin.sh's harness: the real UnlockDialog against a stub udisksctl, canary S3cr3t-canary-1006; attempts 1 and 2 refuse, 3 unlocks.
// Reaching a wrong phase proves stdin closed: the stub recorder is a cat that exits only on EOF.
ShellRoot {
    id: shell

    property var failures: []
    property int ticks: 0
    property int phase: 0
    property int waits: 0
    property string unlockedPath: ""
    property string unlockedLabel: ""
    property string unlockedMapped: ""
    property string unlockedNote: ""

    function log(line) { console.log("UNLOCKSTDIN " + line) }
    function quit() { Quickshell.execDetached(["kill", String(Quickshell.processId)]) }
    function check(name, cond, detail) {
        if (cond) shell.log("PASS " + name)
        else shell.failures.push(name + " got " + detail)
    }
    function findField(item) {
        if (!item) return null
        if (typeof item.takeFocus === "function" && item.text !== undefined
                && String(item.label || "") === "Passphrase") return item
        var kids = item.children || []
        for (var i = 0; i < kids.length; i++) {
            var found = findField(kids[i])
            if (found) return found
        }
        return null
    }
    // S6: no string the dialog holds may carry the canary once submitted.
    function sweepSecret() {
        var field = findField(dlg)
        var held = [field ? field.text : "", dlg._secret, dlg.noteText].join("\n")
        return held.indexOf("S3cr3t-canary-1006") < 0 ? "" : held
    }
    function finish() {
        for (var i = 0; i < shell.failures.length; i++)
            shell.log("FAIL " + shell.failures[i])
        shell.log("DONE failures=" + shell.failures.length)
        shell.phase = 99
        shell.quit()
    }

    FloatingWindow {
        implicitWidth: 640
        implicitHeight: 480
        color: "#303030"

        Flea.UnlockDialog {
            id: dlg
            onUnlocked: function (path, label, mapped, note) {
                shell.unlockedPath = path
                shell.unlockedLabel = label
                shell.unlockedMapped = mapped
                shell.unlockedNote = note
            }
        }
    }

    Timer {
        interval: 100
        repeat: true
        running: true
        onTriggered: shell.advance()
    }

    function advance() {
        shell.ticks += 1
        if (shell.ticks < 2) return
        if (shell.phase === 0) {
            dlg.openFor("/dev/sdb1", "Backup", 500000000000, "LUKS2")
            var field = findField(dlg)
            shell.check("dialog-opens-typing", dlg.opened && dlg.phase === "typing"
                && dlg.noteText === "" && field !== null, "opened=" + dlg.opened + " phase=" + dlg.phase)
            if (field) field.text = "S3cr3t-canary-1006"
            shell.check("field-takes-text", field && field.text === "S3cr3t-canary-1006",
                field ? "<hidden>" : "no field")
            dlg.submit()
            shell.check("submit-clears-the-field", !field || field.text === "", "field kept text")
            shell.phase = 1
            shell.waits = 0
        } else if (shell.phase === 1) {
            // The stub's recorder only exits on EOF, so the wrong phase is the close proof.
            if (dlg.phase !== "wrong" && shell.waits++ < 100) return
            shell.check("refused-passphrase-is-wrong", dlg.phase === "wrong", dlg.phase)
            shell.check("localized-failed-keeps-wrong-note", dlg.noteText === Unlock.wrongNote("Backup"), dlg.noteText)
            shell.check("wrong-holds-no-secret", shell.sweepSecret() === "", "a property holds it")
            var retry = findField(dlg)
            if (retry) retry.text = "S3cr3t-canary-1006"
            dlg.submit()
            shell.phase = 2
            shell.waits = 0
        } else if (shell.phase === 2) {
            if (dlg.phase !== "wrong" && shell.waits++ < 100) return
            shell.check("other-refusal-names-no-passphrase", dlg.noteText === Unlock.unlockFailedNote("Backup"), dlg.noteText)
            shell.check("failed-holds-no-secret", shell.sweepSecret() === "", "a property holds it")
            var again = findField(dlg)
            if (again) again.text = "S3cr3t-canary-1006"
            dlg.submit()
            shell.phase = 3
            shell.waits = 0
        } else if (shell.phase === 3) {
            // A retry after a closed stdin needs stdinEnabled true again before the start.
            if (shell.unlockedPath === "" && shell.waits++ < 100) return
            shell.check("retry-unlocks-and-mounts", shell.unlockedPath === "/run/media/gm/Backup"
                && shell.unlockedLabel === "Backup" && shell.unlockedMapped === "/dev/dm-0"
                && shell.unlockedNote === Unlock.unlockedNote("Backup"),
                shell.unlockedPath + "|" + shell.unlockedLabel + "|" + shell.unlockedMapped)
            shell.check("success-clears-and-closes", dlg.opened === false, "opened=" + dlg.opened)
            shell.check("success-holds-no-secret", shell.sweepSecret() === "", "a property holds it")
            shell.finish()
        }
    }
}
