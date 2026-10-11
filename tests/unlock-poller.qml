//@ pragma ShellId flea-unlock-poller-test

import QtQuick
import Quickshell
import "flea" as Flea
import "unlock-stdin-find.js" as Find

// tests/unlock-poller.sh's harness: the real UnlockHost against a held lsblk, proving the one-shot
// poller ends with its first listing, never starts on a touched card, builds DeviceMounts with entries,
// and reads the LUKS version off the remembered rail for a null call rail.
ShellRoot {
    id: shell

    property var failures: []
    property int ticks: 0
    property int phase: 0
    property int waits: 0
    property var rail: ({ deviceEntries: [{ device: "/dev/sdb1", label: "Backup", locked: true,
        size: 1, fstype: "crypto_LUKS", fsver: "2" }], placesEntries: [], networkEntries: [], cursorIndex: -1 })

    function log(line) { console.log("UNLOCKPOLLER " + line) }
    function quit() { Quickshell.execDetached(["kill", String(Quickshell.processId)]) }
    function check(name, cond, detail) {
        if (cond) shell.log("PASS " + name)
        else shell.failures.push(name + " got " + detail)
    }
    function step(next) { shell.phase = next; shell.waits = 0 }
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
    function testRoot() { return Quickshell.env("UNLOCK_TEST_ROOT") }
    function releaseLsblk() { Quickshell.execDetached(["sh", "-c", ": > \"$1/stub/go\"", "sh", shell.testRoot()]) }
    function armLsblk(body) {
        Quickshell.execDetached(["sh", "-c", "rm -f \"$1/stub/go\" && cp \"$1/stub/body-" + body + ".json\" \"$1/stub/body.json\"", "sh", shell.testRoot()])
    }

    FloatingWindow {
        implicitWidth: 640
        implicitHeight: 480
        color: "#303030"

        Flea.UnlockHost {
            id: host
            anchors.fill: parent
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
            // F4: a null call rail still reads the remembered rail's LUKS version.
            host.sidebar = shell.rail
            host.openFor("/dev/sdb1", "leaf", 0, "crypto_LUKS", null)
            shell.check("null-rail-reads-the-remembered-version", host.dialog.crypto === "LUKS2", host.dialog.crypto)
            shell.check("remembered-version-keeps-the-passed-label", host.dialog.driveLabel === "leaf", host.dialog.driveLabel)
            shell.check("no-pending-name-runs-no-poller", host.namePolling === false, "polling=" + host.namePolling)
            shell.step(1)
        } else if (shell.phase === 1) {
            if (shell.waits === 0) shell.armLsblk("row")
            if (shell.hold(4)) return
            host.openForDevice("/dev/loop9", null)
            shell.check("pending-card-shows-the-leaf", host.dialog.driveLabel === "loop9", host.dialog.driveLabel)
            shell.check("pending-card-waits-on-its-name", host.unnamedDevice === "/dev/loop9", host.unnamedDevice)
            shell.check("pending-name-starts-the-poller", host.namePolling === true, "polling=" + host.namePolling)
            shell.check("built-poller-carries-entries", host.fallbackEntries() instanceof Array, typeof host.fallbackEntries())
            shell.step(2)
        } else if (shell.phase === 2) {
            // F2: the first listing ends the poller, named or not; F3: the built poller lists.
            if (shell.waits === 0) shell.releaseLsblk()
            if (shell.until(host._namePollDone === true, 100)) return
            shell.check("first-listing-names-the-card", host.dialog.driveLabel === "cap-loop9", host.dialog.driveLabel)
            shell.check("named-card-ends-the-wait", host.unnamedDevice === "", host.unnamedDevice)
            shell.check("first-listing-stops-the-poller", host.namePolling === false, "polling=" + host.namePolling)
            shell.check("built-poller-reported-the-row", host.fallbackEntries().length === 1, host.fallbackEntries().length)
            shell.step(3)
        } else if (shell.phase === 3) {
            if (shell.waits === 0) shell.armLsblk("empty")
            if (shell.hold(4)) return
            host.openForDevice("/dev/ghost", null)
            shell.check("unnamed-card-shows-the-leaf", host.dialog.driveLabel === "ghost", host.dialog.driveLabel)
            shell.step(4)
        } else if (shell.phase === 4) {
            // F2: a first listing without the row still ends the one-shot wait.
            if (shell.waits === 0) shell.releaseLsblk()
            if (shell.until(host._namePollDone === true, 100)) return
            shell.check("rowless-listing-keeps-the-leaf", host.dialog.driveLabel === "ghost", host.dialog.driveLabel)
            shell.check("rowless-listing-ends-the-wait", host.unnamedDevice === "", host.unnamedDevice)
            shell.check("rowless-listing-stops-the-poller", host.namePolling === false, "polling=" + host.namePolling)
            shell.step(5)
        } else if (shell.phase === 5) {
            // F2: a card touched before the first listing never starts its poller and takes no later name.
            if (shell.waits === 0) shell.armLsblk("row")
            if (shell.hold(4)) return
            host.openForDevice("/dev/loop9", null)
            var field = Find.findField(host.dialog)
            if (field) field.text = "typed"
            shell.check("touched-card-starts-no-poller", host.namePolling === false, "polling=" + host.namePolling)
            host.nameDevice()
            shell.check("late-listing-names-no-touched-card", host.dialog.driveLabel === "loop9", host.dialog.driveLabel)
            shell.check("late-listing-ends-the-touched-wait", host.unnamedDevice === "", host.unnamedDevice)
            shell.step(6)
        } else if (shell.phase === 6) {
            if (shell.hold(4)) return
            shell.releaseLsblk()
            shell.finish()
        }
    }
}
