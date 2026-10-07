//@ pragma ShellId flea-unlock-stdin-test

import QtQuick
import Quickshell
import Quickshell.Io
import "flea" as Flea
import "flea/js/Unlock.js" as Unlock
import "unlock-stdin-find.js" as Find

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
    property string unlockedNote: ""
    property string lockFailedNote: ""
    property string probed: ""

    function log(line) { console.log("UNLOCKSTDIN " + line) }
    function quit() { Quickshell.execDetached(["kill", String(Quickshell.processId)]) }
    function check(name, cond, detail) {
        if (cond) shell.log("PASS " + name)
        else shell.failures.push(name + " got " + detail)
    }
    // S6: no string the dialog holds may carry the canary once submitted.
    function sweepSecret() {
        var field = Find.findField(dlg)
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
            "cd \"$1/stub\" && " + (reset ? "rm -f unlocked go && " : "") + "printf %s \"$2\" > mode"
            + " && case \"$2\" in dead) t=udisksctl.dead ;; *) t=udisksctl.live ;; esac && ln -sfn \"$1/stub/$t\" \"$1/bin/udisksctl\"",
            "sh", root, mode])
    }
    function probe(pidFile) {
        shell.probed = ""
        probeProcess.command = ["sh", "-c", "kill -0 \"$(cat \"$1/stub/$2\")\" 2>/dev/null && echo alive || echo dead",
            "sh", Quickshell.env("UNLOCK_TEST_ROOT"), pidFile]
        probeProcess.running = true
    }
    // Reap a stub client the dialog deliberately left running, so the next submit starts clean.
    function killStub(pidFile) {
        Quickshell.execDetached(["sh", "-c", "kill \"$(cat \"$1/stub/$2\" 2>/dev/null)\" 2>/dev/null",
            "sh", Quickshell.env("UNLOCK_TEST_ROOT"), pidFile])
    }
    // Release a stub unlock waiting on its go flag, so Cancel happens while the client runs.
    function touchGo() {
        Quickshell.execDetached(["sh", "-c", ": > \"$1/stub/go\"", "sh", Quickshell.env("UNLOCK_TEST_ROOT")])
    }
    // Start a reader only when the last one finished; a completed value persists until the next wait erases it.
    function stubCount(name) {
        if (probeProcess.running)
            return
        probeProcess.command = ["sh", "-c", "grep -c . \"$1/stub/$2\" 2>/dev/null || echo 0",
            "sh", Quickshell.env("UNLOCK_TEST_ROOT"), name]
        probeProcess.running = true
    }
    function typeSecret() {
        var field = Find.findField(dlg)
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
            onUnlocked: function (path, label, note) {
                shell.unlockedPath = path
                shell.unlockedLabel = label
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
            var field = Find.findField(dlg)
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
            var retry = Find.findField(dlg)
            if (retry) retry.text = "S3cr3t-canary-1006"
            dlg.submit()
            shell.phase = 2
            shell.waits = 0
        } else if (shell.phase === 2) {
            if (dlg.phase !== "wrong" && shell.waits++ < 100) return
            shell.check("other-refusal-names-no-passphrase", dlg.noteText === Unlock.unlockFailedNote("Backup"), dlg.noteText)
            shell.check("failed-holds-no-secret", shell.sweepSecret() === "", "a property holds it")
            var again = Find.findField(dlg)
            if (again) again.text = "S3cr3t-canary-1006"
            dlg.submit()
            shell.phase = 3
            shell.waits = 0
        } else if (shell.phase === 3) {
            // A retry after a closed stdin needs stdinEnabled true again before the start.
            if (shell.unlockedPath === "" && shell.waits++ < 100) return
            shell.check("retry-unlocks-and-mounts", shell.unlockedPath === "/run/media/gm/Backup"
                && shell.unlockedLabel === "Backup" && shell.unlockedNote === Unlock.unlockedNote("Backup"),
                shell.unlockedPath + "|" + shell.unlockedLabel + "|" + shell.unlockedNote)
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
            var dead = Find.findField(dlg)
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
            shell.check("cancel-leaves-the-client-running", shell.probed === "alive", shell.probed)
            shell.check("cancel-closes-and-holds-no-secret", dlg.opened === false && dlg._secret === "" && shell.sweepSecret() === "", "opened=" + dlg.opened)
            shell.killStub("hangpid")
            shell.probe("hangpid")
            shell.goto(12)
        } else if (shell.phase === 12) {
            // The harness reaps its own stub; Cancel itself never kills.
            if (shell.until(shell.probed !== "", 100)) return
            shell.arm("mounthang")
            shell.goto(13)
        } else if (shell.phase === 13) {
            // UL7: a mount killed by close exits late, and that exit does nothing visible and takes no focus.
            if (shell.hold(4)) return
            shell.openAndSubmit()
            shell.goto(14)
        } else if (shell.phase === 14) {
            if (shell.until(dlg._stage === "mount", 100)) return
            dlg.close()
            shell.goto(15)
        } else if (shell.phase === 15) {
            if (shell.hold(20)) return
            var gone = Find.findField(dlg)
            shell.check("close-during-mount-stays-closed", dlg.opened === false && dlg.phase !== "wrong" && dlg.noteText !== Unlock.mountNote("Backup"),
                "opened=" + dlg.opened + " phase=" + dlg.phase)
            shell.check("close-during-mount-takes-no-focus", sink.activeFocus === true && (!gone || gone.focused === false),
                "sink=" + sink.activeFocus)
            shell.check("close-during-mount-holds-no-secret", shell.sweepSecret() === "", "a property holds it")
            shell.arm("mountfail")
            shell.goto(16)
        } else if (shell.phase === 16) {
            // UL9: a mount that fails puts the container back, so the retry starts from a locked one.
            if (shell.hold(4)) return
            shell.openAndSubmit()
            shell.goto(17)
        } else if (shell.phase === 17) {
            if (shell.until(dlg.phase !== "unlocking", 100)) return
            shell.check("failed-mount-says-so-and-holds-no-secret", dlg.phase === "wrong" && dlg.noteText === Unlock.mountNote("Backup")
                && shell.sweepSecret() === "", dlg.phase + "|" + dlg.noteText)
            shell.setMode("ok", false)
            shell.goto(18)
        } else if (shell.phase === 18) {
            if (shell.hold(4)) return
            shell.unlockedPath = ""
            shell.typeSecret()
            dlg.submit()
            shell.goto(19)
        } else if (shell.phase === 19) {
            if (shell.until(shell.unlockedPath !== "", 100)) return
            shell.check("retry-after-a-failed-mount-unlocks", shell.unlockedPath === "/run/media/gm/Backup", shell.unlockedPath)
            shell.check("retry-after-a-failed-mount-closes-clean", dlg.opened === false && shell.sweepSecret() === "", "opened=" + dlg.opened)
            shell.arm("mounthang,lockfail")
            shell.goto(20)
        } else if (shell.phase === 20) {
            if (shell.hold(4)) return
            shell.lockFailedNote = ""
            shell.openAndSubmit()
            shell.goto(21)
        } else if (shell.phase === 21) {
            if (shell.until(dlg._stage === "mount", 100)) return
            dlg.close()
            shell.goto(22)
        } else if (shell.phase === 22) {
            if (shell.hold(25)) return
            shell.check("close-during-mount-lock-refusal-is-posted", shell.lockFailedNote === Unlock.lockNote("Backup"), shell.lockFailedNote)
            shell.arm("mountfail,lockfail")
            shell.goto(23)
        } else if (shell.phase === 23) {
            if (shell.hold(4)) return
            shell.lockFailedNote = ""
            shell.openAndSubmit()
            shell.goto(24)
        } else if (shell.phase === 24) {
            if (shell.until(dlg.phase !== "unlocking", 100)) return
            shell.check("failed-mount-with-a-refused-lock-tells-both", dlg.phase === "wrong" && dlg.noteText === Unlock.mountNote("Backup")
                && shell.lockFailedNote === Unlock.lockNote("Backup"), dlg.phase + "|" + dlg.noteText + "|" + shell.lockFailedNote)
            shell.arm("latesuccess")
            shell.goto(25)
        } else if (shell.phase === 25) {
            // Cancel during unlock leaves the client running; its late success locks back with no focus.
            if (shell.hold(4)) return
            shell.lockFailedNote = ""
            shell.unlockedPath = ""
            shell.openAndSubmit()
            shell.goto(26)
        } else if (shell.phase === 26) {
            if (shell.until(dlg._started, 100)) return
            shell.probe("hangpid")
            shell.goto(27)
        } else if (shell.phase === 27) {
            if (shell.until(shell.probed !== "", 100)) return
            shell.check("cancel-during-unlock-leaves-the-client-running", shell.probed === "alive", shell.probed)
            dlg.close()
            shell.goto(28)
        } else if (shell.phase === 28) {
            if (shell.hold(4)) return
            shell.touchGo()
            shell.goto(29)
        } else if (shell.phase === 29) {
            if (shell.waits === 0)
                shell.probed = ""
            shell.stubCount("lockcalls")
            if (shell.probed !== "5" && shell.waits++ < 150) return
            shell.waits = 0
            shell.check("cancelled-unlock-locks-after-success", shell.probed === "5", shell.probed)
            shell.check("cancelled-unlock-stays-closed", dlg.opened === false, "opened=" + dlg.opened)
            shell.check("cancelled-unlock-takes-no-focus", sink.activeFocus === true, "sink=" + sink.activeFocus)
            shell.check("successful-late-lock-posts-nothing", shell.lockFailedNote === "", shell.lockFailedNote)
            shell.goto(30)
        } else if (shell.phase === 30) {
            if (shell.hold(4)) return
            shell.arm("latesuccess,lockfail")
            shell.goto(31)
        } else if (shell.phase === 31) {
            if (shell.hold(4)) return
            shell.lockFailedNote = ""
            shell.openAndSubmit()
            shell.goto(32)
        } else if (shell.phase === 32) {
            if (shell.until(dlg._started, 100)) return
            shell.probe("hangpid")
            shell.goto(33)
        } else if (shell.phase === 33) {
            if (shell.until(shell.probed !== "", 100)) return
            dlg.close()
            shell.goto(34)
        } else if (shell.phase === 34) {
            if (shell.hold(4)) return
            shell.touchGo()
            shell.goto(35)
        } else if (shell.phase === 35) {
            if (shell.waits === 0)
                shell.probed = ""
            shell.stubCount("lockcalls")
            if (shell.probed !== "6" && shell.waits++ < 150) return
            shell.waits = 0
            shell.check("refused-late-lock-names-the-drive", shell.lockFailedNote === Unlock.lockNote("Backup"), shell.lockFailedNote)
            shell.check("refused-late-lock-stays-closed", dlg.opened === false, "opened=" + dlg.opened)
            shell.goto(36)
        } else if (shell.phase === 36) {
            if (shell.hold(4)) return
            shell.arm("latefail")
            shell.goto(37)
        } else if (shell.phase === 37) {
            if (shell.hold(4)) return
            shell.lockFailedNote = ""
            shell.openAndSubmit()
            shell.goto(38)
        } else if (shell.phase === 38) {
            if (shell.until(dlg._started, 100)) return
            dlg.close()
            shell.goto(39)
        } else if (shell.phase === 39) {
            if (shell.hold(4)) return
            shell.touchGo()
            shell.goto(40)
        } else if (shell.phase === 40) {
            if (shell.hold(15)) return
            shell.probe("hangpid")
            shell.goto(41)
        } else if (shell.phase === 41) {
            if (shell.until(shell.probed !== "", 100)) return
            shell.check("failed-late-unlock-exits", shell.probed === "dead", shell.probed)
            shell.stubCount("lockcalls")
            shell.goto(42)
        } else if (shell.phase === 42) {
            if (shell.waits === 0)
                shell.probed = ""
            shell.stubCount("lockcalls")
            if (shell.probed === "" && shell.waits++ < 100) return
            shell.waits = 0
            shell.check("failed-late-unlock-issues-no-lock", shell.probed === "6", shell.probed)
            shell.check("failed-late-unlock-stays-closed", dlg.opened === false, "opened=" + dlg.opened)
            shell.check("failed-late-unlock-posts-nothing", shell.lockFailedNote === "", shell.lockFailedNote)
            shell.finish()
        }
    }
}
