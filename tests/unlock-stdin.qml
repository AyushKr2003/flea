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

    function log(line) { console.log("UNLOCKSTDIN " + line) }
    function quit() { Quickshell.execDetached(["kill", String(Quickshell.processId)]) }
    function check(name, cond, detail) {
        if (cond) shell.log("PASS " + name)
        else shell.failures.push(name + " got " + detail)
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

    UnlockKit {
        id: kit
        dlg: dlg
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
            shell.check("wrong-holds-no-secret", kit.sweepSecret() === "", "a property holds it")
            var retry = Find.findField(dlg)
            if (retry) retry.text = "S3cr3t-canary-1006"
            dlg.submit()
            shell.phase = 2
            shell.waits = 0
        } else if (shell.phase === 2) {
            if (dlg.phase !== "wrong" && shell.waits++ < 100) return
            shell.check("other-refusal-names-no-passphrase", dlg.noteText === Unlock.unlockFailedNote("Backup"), dlg.noteText)
            shell.check("failed-holds-no-secret", kit.sweepSecret() === "", "a property holds it")
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
            shell.check("success-holds-no-secret", kit.sweepSecret() === "", "a property holds it")
            kit.arm("dead")
            shell.goto(4)
        } else if (shell.phase === 4) {
            // UL2: a command that cannot start still ends the attempt, and the passphrase goes with it.
            if (shell.hold(4)) return
            dlg.unlockTimeoutMs = 1500
            kit.openAndSubmit()
            shell.goto(5)
        } else if (shell.phase === 5) {
            if (shell.until(dlg.phase !== "unlocking", 100)) return
            var dead = Find.findField(dlg)
            shell.check("never-started-says-what-happened", dlg.phase === "wrong" && dlg.noteText === Unlock.unlockFailedNote("Backup"),
                dlg.phase + "|" + dlg.noteText)
            shell.check("never-started-holds-no-secret", dlg._secret === "" && (!dead || dead.text === "") && kit.sweepSecret() === "",
                "a property holds it")
            shell.check("never-started-leaves-the-dialog-actionable", dead !== null && dead.enabled === true, "field disabled")
            kit.arm("hang")
            shell.goto(6)
        } else if (shell.phase === 6) {
            // UL1 and UL8: no timer ends a started child; Cancel is the way out.
            if (shell.hold(4)) return
            kit.openAndSubmit()
            shell.goto(7)
        } else if (shell.phase === 7) {
            if (shell.until(dlg._started, 100)) return
            shell.goto(8)
        } else if (shell.phase === 8) {
            if (shell.hold(25)) return
            kit.probe("hangpid")
            shell.goto(9)
        } else if (shell.phase === 9) {
            if (shell.until(kit.probed !== "", 100)) return
            shell.check("timer-leaves-a-started-child-running", kit.probed === "alive" && dlg.phase === "unlocking", kit.probed + "|" + dlg.phase)
            dlg.close()
            shell.goto(10)
        } else if (shell.phase === 10) {
            if (shell.hold(10)) return
            kit.probe("hangpid")
            shell.goto(11)
        } else if (shell.phase === 11) {
            if (shell.until(kit.probed !== "", 100)) return
            shell.check("cancel-leaves-the-client-running", kit.probed === "alive", kit.probed)
            shell.check("cancel-closes-and-holds-no-secret", dlg.opened === false && dlg._secret === "" && kit.sweepSecret() === "", "opened=" + dlg.opened)
            kit.killStub("hangpid")
            kit.probe("hangpid")
            shell.goto(12)
        } else if (shell.phase === 12) {
            // The harness reaps its own stub; Cancel itself never kills.
            if (shell.until(kit.probed !== "", 100)) return
            kit.arm("mounthang")
            shell.goto(13)
        } else if (shell.phase === 13) {
            // UL7: a mount killed by close exits late, and that exit does nothing visible and takes no focus.
            if (shell.hold(4)) return
            kit.openAndSubmit()
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
            shell.check("close-during-mount-holds-no-secret", kit.sweepSecret() === "", "a property holds it")
            kit.arm("mountfail")
            shell.goto(16)
        } else if (shell.phase === 16) {
            // UL9: a mount that fails puts the container back, so the retry starts from a locked one.
            if (shell.hold(4)) return
            kit.openAndSubmit()
            shell.goto(17)
        } else if (shell.phase === 17) {
            if (shell.until(dlg.phase !== "unlocking", 100)) return
            shell.check("failed-mount-says-so-and-holds-no-secret", dlg.phase === "wrong" && dlg.noteText === Unlock.mountNote("Backup")
                && kit.sweepSecret() === "", dlg.phase + "|" + dlg.noteText)
            kit.setMode("ok", false)
            shell.goto(18)
        } else if (shell.phase === 18) {
            if (shell.hold(4)) return
            shell.unlockedPath = ""
            kit.typeSecret()
            dlg.submit()
            shell.goto(19)
        } else if (shell.phase === 19) {
            if (shell.until(shell.unlockedPath !== "", 100)) return
            shell.check("retry-after-a-failed-mount-unlocks", shell.unlockedPath === "/run/media/gm/Backup", shell.unlockedPath)
            shell.check("retry-after-a-failed-mount-closes-clean", dlg.opened === false && kit.sweepSecret() === "", "opened=" + dlg.opened)
            kit.arm("mounthang,lockfail")
            shell.goto(20)
        } else if (shell.phase === 20) {
            if (shell.hold(4)) return
            shell.lockFailedNote = ""
            kit.openAndSubmit()
            shell.goto(21)
        } else if (shell.phase === 21) {
            if (shell.until(dlg._stage === "mount", 100)) return
            dlg.close()
            shell.goto(22)
        } else if (shell.phase === 22) {
            if (shell.hold(25)) return
            shell.check("close-during-mount-lock-refusal-is-posted", shell.lockFailedNote === Unlock.lockNote("Backup"), shell.lockFailedNote)
            kit.arm("mountfail,lockfail")
            shell.goto(23)
        } else if (shell.phase === 23) {
            if (shell.hold(4)) return
            shell.lockFailedNote = ""
            kit.openAndSubmit()
            shell.goto(24)
        } else if (shell.phase === 24) {
            if (shell.until(dlg.phase !== "unlocking", 100)) return
            shell.check("failed-mount-with-a-refused-lock-tells-both", dlg.phase === "wrong" && dlg.noteText === Unlock.mountNote("Backup")
                && shell.lockFailedNote === Unlock.lockNote("Backup"), dlg.phase + "|" + dlg.noteText + "|" + shell.lockFailedNote)
            kit.arm("latesuccess")
            shell.goto(25)
        } else if (shell.phase === 25) {
            // Cancel during unlock leaves the client running; its late success locks back with no focus.
            if (shell.hold(4)) return
            shell.lockFailedNote = ""
            shell.unlockedPath = ""
            kit.openAndSubmit()
            shell.goto(26)
        } else if (shell.phase === 26) {
            if (shell.until(dlg._started, 100)) return
            kit.probe("hangpid")
            shell.goto(27)
        } else if (shell.phase === 27) {
            if (shell.until(kit.probed !== "", 100)) return
            shell.check("cancel-during-unlock-leaves-the-client-running", kit.probed === "alive", kit.probed)
            dlg.close()
            shell.goto(28)
        } else if (shell.phase === 28) {
            if (shell.hold(4)) return
            kit.touchGo()
            shell.goto(29)
        } else if (shell.phase === 29) {
            if (shell.waits === 0)
                kit.probed = ""
            kit.stubCount("lockcalls")
            if (kit.probed !== "5" && shell.waits++ < 150) return
            shell.waits = 0
            shell.check("cancelled-unlock-locks-after-success", kit.probed === "5", kit.probed)
            shell.check("cancelled-unlock-stays-closed", dlg.opened === false, "opened=" + dlg.opened)
            shell.check("cancelled-unlock-takes-no-focus", sink.activeFocus === true, "sink=" + sink.activeFocus)
            shell.check("successful-late-lock-posts-nothing", shell.lockFailedNote === "", shell.lockFailedNote)
            shell.goto(30)
        } else if (shell.phase === 30) {
            if (shell.hold(4)) return
            kit.arm("latesuccess,lockfail")
            shell.goto(31)
        } else if (shell.phase === 31) {
            if (shell.hold(4)) return
            shell.lockFailedNote = ""
            kit.openAndSubmit()
            shell.goto(32)
        } else if (shell.phase === 32) {
            if (shell.until(dlg._started, 100)) return
            kit.probe("hangpid")
            shell.goto(33)
        } else if (shell.phase === 33) {
            if (shell.until(kit.probed !== "", 100)) return
            dlg.close()
            shell.goto(34)
        } else if (shell.phase === 34) {
            if (shell.hold(4)) return
            kit.touchGo()
            shell.goto(35)
        } else if (shell.phase === 35) {
            if (shell.waits === 0)
                kit.probed = ""
            kit.stubCount("lockcalls")
            if (kit.probed !== "6" && shell.waits++ < 150) return
            shell.waits = 0
            shell.check("refused-late-lock-names-the-drive", shell.lockFailedNote === Unlock.lockNote("Backup"), shell.lockFailedNote)
            shell.check("refused-late-lock-stays-closed", dlg.opened === false, "opened=" + dlg.opened)
            shell.goto(36)
        } else if (shell.phase === 36) {
            if (shell.hold(4)) return
            kit.arm("latefail")
            shell.goto(37)
        } else if (shell.phase === 37) {
            if (shell.hold(4)) return
            shell.lockFailedNote = ""
            kit.openAndSubmit()
            shell.goto(38)
        } else if (shell.phase === 38) {
            if (shell.until(dlg._started, 100)) return
            dlg.close()
            shell.goto(39)
        } else if (shell.phase === 39) {
            if (shell.hold(4)) return
            kit.touchGo()
            shell.goto(40)
        } else if (shell.phase === 40) {
            if (shell.hold(15)) return
            kit.probe("hangpid")
            shell.goto(41)
        } else if (shell.phase === 41) {
            if (shell.until(kit.probed !== "", 100)) return
            shell.check("failed-late-unlock-exits", kit.probed === "dead", kit.probed)
            kit.stubCount("lockcalls")
            shell.goto(42)
        } else if (shell.phase === 42) {
            if (shell.waits === 0)
                kit.probed = ""
            kit.stubCount("lockcalls")
            if (kit.probed === "" && shell.waits++ < 100) return
            shell.waits = 0
            shell.check("failed-late-unlock-issues-no-lock", kit.probed === "6", kit.probed)
            shell.check("failed-late-unlock-stays-closed", dlg.opened === false, "opened=" + dlg.opened)
            shell.check("failed-late-unlock-posts-nothing", shell.lockFailedNote === "", shell.lockFailedNote)
            kit.arm("latesuccess")
            shell.goto(43)
        } else if (shell.phase === 43) {
            // A submit behind a Cancelled client queues, and that client's late lock goes to the drive it was opened on.
            if (shell.hold(4)) return
            kit.openAndSubmit()
            shell.goto(44)
        } else if (shell.phase === 44) {
            if (shell.until(dlg._started, 100)) return
            dlg.close()
            kit.openAndSubmit("/dev/sdc1", "Stick")
            var queued = Find.findField(dlg)
            shell.check("resubmit-behind-a-running-client-queues", dlg._queued && dlg.phase === "unlocking" && queued
                && queued.text === "" && dlg.noteText === Unlock.unlockingNote("Stick"), "queued=" + dlg._queued + " phase=" + dlg.phase)
            kit.touchGo()
            shell.goto(45)
        } else if (shell.phase === 45) {
            if (shell.waits === 0)
                kit.probed = ""
            kit.stubCount("lockcalls", "^lock --block-device /dev/sdb1$")
            if (kit.probed !== "7" && shell.waits++ < 150) return
            shell.waits = 0
            shell.check("late-lock-locks-the-cancelled-drive", kit.probed === "7" && dlg._lockLabel === "Backup"
                && shell.lockFailedNote === "", kit.probed + " " + dlg._lockLabel)
            shell.goto(46)
        } else if (shell.phase === 46) {
            if (shell.until(shell.unlockedLabel === "Stick", 100)) return
            shell.check("queued-unlock-runs-after-the-late-lock", shell.unlockedLabel === "Stick" && !dlg.opened, shell.unlockedLabel)
            kit.arm("hang")
            shell.goto(47)
        } else if (shell.phase === 47) {
            // A queued submit dies with Cancel, and one left waiting is refused at the bound with nothing started after.
            if (shell.hold(4)) return
            kit.openAndSubmit()
            shell.goto(48)
        } else if (shell.phase === 48) {
            if (shell.until(dlg._started, 100)) return
            dlg.close()
            kit.openAndSubmit("/dev/sdc1", "Stick")
            dlg.close()
            shell.check("close-drops-the-queued-submit", !dlg._queued && dlg._secret === "", "queued=" + dlg._queued)
            kit.openAndSubmit("/dev/sdc1", "Stick")
            shell.goto(49)
        } else if (shell.phase === 49) {
            if (shell.until(dlg.phase === "wrong", 100)) return
            shell.check("queued-submit-is-bounded", dlg.noteText === Unlock.unlockFailedNote("Stick") && dlg._secret === ""
                && !dlg._queued, dlg.noteText)
            kit.killStub("hangpid")
            shell.goto(50)
        } else if (shell.phase === 50) {
            if (shell.hold(10)) return
            shell.check("bounded-queue-starts-nothing-later", dlg.phase === "wrong" && dlg._stage === "idle", dlg.phase + " " + dlg._stage)
            shell.finish()
        }
    }
}
