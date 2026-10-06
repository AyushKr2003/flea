import QtQuick
import Quickshell.Io
import "js/Unlock.js" as Unlock

// Unlock (U039): the udisksctl lock after an unmount or eject of an unlocked crypt, so no Lock row is offered.
// DeviceMounts creates it on first use and owns it; a refusal names the drive it left unlocked.
Item {
    id: root
    // The DeviceMounts that posts the refusal and re-polls once the lock has settled.
    property var host: null
    property string _label: ""

    // Answers whether a lock started: only a crypt leaf has a backing container, so no caller checks the kind first.
    function lockCryptAfter(listing, cryptDevice, label) {
        var backing = Unlock.backingFor(String(listing || ""), String(cryptDevice || ""))
        if (backing.length === 0)
            return false
        root._label = label
        lockProcess.command = ["udisksctl", "lock", "--block-device", backing]
        lockProcess.running = true
        return true
    }

    Process {
        id: lockProcess
        onExited: function (exitCode) {
            if (exitCode !== 0)
                root.host.message(Unlock.lockNote(root._label), true)
            root._label = ""
            root.host.poll()
        }
    }
}
