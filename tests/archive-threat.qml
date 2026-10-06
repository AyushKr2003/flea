//@ pragma ShellId flea-archive-threat-test

import QtQuick
import Quickshell
import "flea" as Flea

// tests/archive-threat.sh's offscreen walk for GM ruling 13: the canary S3cr3t-canary-1006 is
// held in each password card, every secret-holding property is dumped, then submit, close and
// failure paths must leave nothing behind. Property-only, no grabs.
ShellRoot {
    id: shell

    readonly property string canary: "S3cr3t-canary-1006"
    readonly property string outerTimeoutS: Quickshell.env("ARCHIVETHREAT_TIMEOUT_S") || "60"

    property int checks: 0
    property var failures: []
    property int step: 0
    property var script: []
    property var holder: ({ backend: { archiveFormats: ["7z", "zip"] }, listArea: stubArea })
    property string acceptedSecret: ""
    property bool acceptedFired: false

    Item {
        id: stubArea
        width: 64
        height: 64
    }

    Flea.ArchiveCompressDialog {
        id: compressCard
        width: 800
        height: 600
    }

    Flea.ArchivePasswordDialog {
        id: extractCard
        width: 800
        height: 600
    }

    Connections {
        target: compressCard
        function onAccepted(source, format, name, password, encryptNames) {
            shell.acceptedFired = true
            shell.acceptedSecret = password
        }
    }

    Connections {
        target: extractCard
        function onAccepted(password) {
            shell.acceptedFired = true
            shell.acceptedSecret = password
        }
    }

    function log(line) { console.log("ARCHIVETHREAT " + line) }
    function check(name, actual, expected) {
        shell.checks += 1
        if (JSON.stringify(actual) === JSON.stringify(expected)) {
            shell.log("ok " + name)
            return
        }
        shell.failures.push(name)
        shell.log("FAIL " + name + ": got " + JSON.stringify(actual) + ", expected " + JSON.stringify(expected))
    }

    // Every string-valued `text` under root, depth first: the only places a held secret can sit
    // in these cards are the masked fields, so the scan names them while open and must find none
    // after every terminal path.
    function heldTexts(root) {
        var out = []
        var stack = [root]
        while (stack.length > 0) {
            var o = stack.pop()
            if (o && typeof o.text === "string" && o.text.indexOf(shell.canary) >= 0)
                out.push(String(o))
            var kids = (o && o.children !== undefined) ? o.children : []
            for (var i = 0; i < kids.length; i++) stack.push(kids[i])
        }
        return out.length
    }

    function finish() {
        shell.log("DONE checks=" + shell.checks + " failed=" + shell.failures.length)
        Quickshell.execDetached(["kill", String(Quickshell.processId)])
    }

    Timer {
        id: stepper
        interval: 50
        repeat: true
        running: true
        onTriggered: {
            if (shell.step >= shell.script.length) {
                stepper.stop()
                shell.finish()
                return
            }
            var fn = shell.script[shell.step]
            shell.step += 1
            fn()
        }
    }

    Component.onCompleted: {
        shell.script = [
            // The compress card holds the canary in its pair and nowhere else.
            function () {
                compressCard.open(["/s/a", "/s/b"], "s", shell.holder)
                compressCard.takeSecretForTest(shell.canary)
                shell.check("compress holds the typed secret", compressCard.password, shell.canary)
                shell.check("the scan sees the held fields", shell.heldTexts(compressCard) > 0, true)
                shell.check("nothing else on the card holds it",
                    compressCard.name.indexOf(shell.canary) < 0
                    && compressCard.stem.indexOf(shell.canary) < 0
                    && compressCard.parentLeaf.indexOf(shell.canary) < 0
                    && compressCard.errorText.indexOf(shell.canary) < 0, true)
            },
            // Submit hands the child its secret, then the card holds nothing.
            function () {
                shell.acceptedFired = false
                shell.acceptedSecret = ""
                compressCard.commit()
                shell.check("submit answers the password prompt", shell.acceptedSecret, shell.canary)
                shell.check("submit clears the pair", compressCard.password, "")
                shell.check("and the scan finds nothing after submit",
                    shell.heldTexts(compressCard), 0)
            },
            // Close clears a held secret without submitting.
            function () {
                shell.acceptedFired = false
                shell.acceptedSecret = ""
                compressCard.open(["/s/a"], "s", shell.holder)
                compressCard.takeSecretForTest(shell.canary)
                compressCard.close()
                shell.check("close clears without submitting",
                    shell.acceptedFired === false
                    && compressCard.password === ""
                    && shell.heldTexts(compressCard) === 0, true)
            },
            // The extract card asks again with the board sentence and an empty field.
            function () {
                extractCard.open("backup.7z", shell.holder, "wrong-password")
                shell.check("a wrong answer reopens with its sentence",
                    extractCard.errorText, "That password did not open backup.7z.")
                shell.check("and the reopened field starts empty", extractCard.password, "")
                extractCard.takeSecretForTest(shell.canary)
                shell.check("the retry holds the secret", extractCard.password, shell.canary)
            },
            // The retry's submit clears; the leaf and the sentence never held it.
            function () {
                shell.acceptedFired = false
                shell.acceptedSecret = ""
                extractCard.commit()
                shell.check("retry answers the prompt", shell.acceptedSecret, shell.canary)
                shell.check("retry clears the field", extractCard.password, "")
                shell.check("the scan finds nothing after the retry",
                    shell.heldTexts(extractCard), 0)
                shell.check("leaf and sentence never held it",
                    extractCard.leaf.indexOf(shell.canary) < 0, true)
            }
        ]
    }
}
