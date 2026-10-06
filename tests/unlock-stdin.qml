//@ pragma ShellId flea-unlock-stdin-test

import QtQuick
import Quickshell
import Quickshell.Io
import "flea" as Flea
import "flea/js/Unlock.js" as Unlock

// tests/unlock-stdin.sh's harness: the real UnlockDialog against a stub udisksctl, canary S3cr3t-canary-1006; attempts 1 and 2 refuse, 3 unlocks.
// Reaching a wrong phase proves stdin closed: the stub recorder is a cat that exits only on EOF.
// Phases 4 and up arm the stub by mode: a child that cannot start, a hung unlock, a hung or failed mount, a refused lock.
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
    property string lockFailedNote: ""
    property string probed: ""

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
    function goto(next) { shell.phase = next; shell.waits = 0 }
    function hold(ticks) {
        if (shell.waits++ < ticks) return true
        shell.waits = 0
        return false
    }
    function until(done, ticks) {
        if (!done && shell.waits++ < ticks) return true
        shell.waits = 0
        return false
    }
    // The stub's state lives in files: a mode word, an unlocked marker, and which script the PATH name points at.
    function arm(mode) {
        shell.setMode(mode, true)
    }
    function setMode(mode, reset) {
        var root = Quickshell.env("UNLOCK_TEST_ROOT")
        Quickshell.execDetached(["sh", "-c",
            "cd \"$1/stub\" && " + (reset ? "rm -f unlocked && " : "") + "printf %s \"$2\" > mode"
            + " && case \"$2\" in dead) t=udisksctl.dead ;; *) t=udisksctl.live ;; esac && ln -sfn \"$1/stub/$t\" \"$1/bin/udisksctl\"",
            "sh", root, mode])
    }
    function probe(pidFile) {
        shell.probed = ""
        probeProcess.command = ["sh", "-c", "kill -0 \"$(cat \"$1/stub/$2\")\" 2>/dev/null && echo alive || echo dead",
            "sh", Quickshell.env("UNLOCK_TEST_ROOT"), pidFile]
        probeProcess.running = true
    }
    function typeSecret() {
        var field = findField(dlg)
        if (field) field.text = "S3cr3t-canary-1006"
    }
    function openAndSubmit() {
        dlg.openFor("/dev/sdb1", "Backup", 500000000000, "LUKS2")
        shell.typeSecret()
        dlg.submit()
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

        // The pane the host hands focus back to when the dialog closes, so a late focus grab shows as a stolen owner.
        Item {
            id: sink
            anchors.fill: parent
            focus: true
        }

        Flea.UnlockDialog {
            id: dlg
            onClosed: sink.forceActiveFocus()
            onLockFailed: function (note) { shell.lockFailedNote = note }
            onUnlocked: function (path, label, mapped, note) {
                shell.unlockedPath = path
                shell.unlockedLabel = label
                shell.unlockedMapped = mapped
                shell.unlockedNote = note
            }
        }
    }

    Process {
        id: probeProcess
        stdout: StdioCollector { id: probeOut; waitForEnd: true }
        onExited: shell.probed = String(probeOut.text).trim()
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
            shell.arm("dead")
            shell.goto(4)
        } else if (shell.phase === 4) {
            // UL2: a command that cannot start still ends the attempt, and the passphrase goes with it.
            if (shell.hold(4)) return
            dlg.unlockTimeoutMs = 1500
            shell.openAndSubmit()
            shell.goto(5)
        } else if (shell.phase === 5) {
            if (shell.until(dlg.phase !== "unlocking", 100)) return
            var dead = findField(dlg)
            shell.check("never-started-says-what-happened", dlg.phase === "wrong" && dlg.noteText === Unlock.unlockFailedNote("Backup"),
                dlg.phase + "|" + dlg.noteText)
            shell.check("never-started-holds-no-secret", dlg._secret === "" && (!dead || dead.text === "") && shell.sweepSecret() === "",
                "a property holds it")
            shell.check("never-started-leaves-the-dialog-actionable", dead !== null && dead.enabled === true, "field disabled")
            shell.arm("hang")
            shell.goto(6)
        } else if (shell.phase === 6) {
            // UL1 and UL8: no timer ends a started child; Cancel is the way out.
            if (shell.hold(4)) return
            shell.openAndSubmit()
            shell.goto(7)
        } else if (shell.phase === 7) {
            if (shell.until(dlg._started, 100)) return
            shell.goto(8)
        } else if (shell.phase === 8) {
            if (shell.hold(25)) return
            shell.probe("hangpid")
            shell.goto(9)
        } else if (shell.phase === 9) {
            if (shell.until(shell.probed !== "", 100)) return
            shell.check("timer-leaves-a-started-child-running", shell.probed === "alive" && dlg.phase === "unlocking", shell.probed + "|" + dlg.phase)
            dlg.close()
            shell.goto(10)
        } else if (shell.phase === 10) {
            if (shell.hold(10)) return
            shell.probe("hangpid")
            shell.goto(11)
        } else if (shell.phase === 11) {
            if (shell.until(shell.probed !== "", 100)) return
            shell.check("cancel-kills-the-started-child", shell.probed === "dead", shell.probed)
            shell.check("cancel-closes-and-holds-no-secret", dlg.opened === false && dlg._secret === "" && shell.sweepSecret() === "", "opened=" + dlg.opened)
            shell.arm("mounthang")
            shell.goto(12)
        } else if (shell.phase === 12) {
            // UL7: a mount killed by close exits late, and that exit does nothing visible and takes no focus.
            if (shell.hold(4)) return
            shell.openAndSubmit()
            shell.goto(13)
        } else if (shell.phase === 13) {
            if (shell.until(dlg._stage === "mount", 100)) return
            dlg.close()
            shell.goto(14)
        } else if (shell.phase === 14) {
            if (shell.hold(20)) return
            var gone = findField(dlg)
            shell.check("close-during-mount-stays-closed", dlg.opened === false && dlg.phase !== "wrong" && dlg.noteText !== Unlock.mountNote("Backup"),
                "opened=" + dlg.opened + " phase=" + dlg.phase)
            shell.check("close-during-mount-takes-no-focus", sink.activeFocus === true && (!gone || gone.focused === false),
                "sink=" + sink.activeFocus)
            shell.check("close-during-mount-holds-no-secret", shell.sweepSecret() === "", "a property holds it")
            shell.arm("mountfail")
            shell.goto(15)
        } else if (shell.phase === 15) {
            // UL9: a mount that fails puts the container back, so the retry starts from a locked one.
            if (shell.hold(4)) return
            shell.openAndSubmit()
            shell.goto(16)
        } else if (shell.phase === 16) {
            if (shell.until(dlg.phase !== "unlocking", 100)) return
            shell.check("failed-mount-says-so-and-holds-no-secret", dlg.phase === "wrong" && dlg.noteText === Unlock.mountNote("Backup")
                && shell.sweepSecret() === "", dlg.phase + "|" + dlg.noteText)
            shell.setMode("ok", false)
            shell.goto(17)
        } else if (shell.phase === 17) {
            if (shell.hold(4)) return
            shell.unlockedPath = ""
            shell.typeSecret()
            dlg.submit()
            shell.goto(18)
        } else if (shell.phase === 18) {
            if (shell.until(shell.unlockedPath !== "", 100)) return
            shell.check("retry-after-a-failed-mount-unlocks", shell.unlockedPath === "/run/media/gm/Backup", shell.unlockedPath)
            shell.check("retry-after-a-failed-mount-closes-clean", dlg.opened === false && shell.sweepSecret() === "", "opened=" + dlg.opened)
            shell.arm("mounthang,lockfail")
            shell.goto(19)
        } else if (shell.phase === 19) {
            if (shell.hold(4)) return
            shell.lockFailedNote = ""
            shell.openAndSubmit()
            shell.goto(20)
        } else if (shell.phase === 20) {
            if (shell.until(dlg._stage === "mount", 100)) return
            dlg.close()
            shell.goto(21)
        } else if (shell.phase === 21) {
            if (shell.hold(25)) return
            shell.check("close-during-mount-lock-refusal-is-posted", shell.lockFailedNote === Unlock.lockNote("Backup"), shell.lockFailedNote)
            shell.arm("mountfail,lockfail")
            shell.goto(22)
        } else if (shell.phase === 22) {
            if (shell.hold(4)) return
            shell.lockFailedNote = ""
            shell.openAndSubmit()
            shell.goto(23)
        } else if (shell.phase === 23) {
            if (shell.until(dlg.phase !== "unlocking", 100)) return
            shell.check("failed-mount-with-a-refused-lock-keeps-the-mount-note", dlg.phase === "wrong" && dlg.noteText === Unlock.mountNote("Backup")
                && shell.lockFailedNote === "", dlg.phase + "|" + dlg.noteText + "|" + shell.lockFailedNote)
            shell.finish()
        }
    }
}
