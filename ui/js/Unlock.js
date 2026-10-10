.pragma library
.import "Devices.js" as Devices

// Unlock (U039): the dialog's sentences and the udisks answers it parses; a passphrase goes only to the child's stdin.

// Sample input: the label of the locked rail row the dialog opened over.
function title(label) {
    return "Unlock " + String(label || "")
}

// Sample input: "Unlocked /dev/sda1 as /dev/dm-0.", the line udisksctl unlock prints.
function parseUnlocked(output) {
    var m = String(output || "").match(/as\s+(\/dev\/\S+)/)
    return m ? m[1].replace(/[.,;:\s]+$/, "") : ""
}

// Sample input: "Backup", the locked rail row's own label.
function unlockingNote(label) {
    return "Unlocking " + String(label || "") + "…"
}

// Sample input: "Backup", the drive the passphrase did not open.
function wrongNote(label) {
    return "That passphrase did not unlock " + String(label || "") + "."
}

// Sample input: "Backup", the drive just unlocked and mounted.
function unlockedNote(label) {
    return "Unlocked and mounted " + String(label || "") + "."
}

// Sample input: "Backup", the drive unmounted but still unlocked.
function lockNote(label) {
    return String(label || "") + " was unmounted but could not be locked; close what is using it."
}

// Sample input: "Mounted /dev/dm-0 at /run/media/gm/Backup.", the line udisksctl mount prints.
function parseMounted(output) {
    var m = String(output || "").match(/\bat\s+(\/\S+)/)
    return m ? m[1].replace(/[.,;:\s]+$/, "") : ""
}

// Sample input: "Backup", the drive unlocked but never mounted.
function mountNote(label) {
    return String(label || "") + " was unlocked but could not be mounted."
}

// Sample input: "Backup", the drive whose unlock failed for a reason other than the passphrase.
function unlockFailedNote(label) {
    return String(label || "") + " could not be unlocked."
}

// Sample input: "Error unlocking /dev/sdb1: GDBus.Error:org.freedesktop.UDisks2.Error.Failed: x", answered with the error name.
function parseDbusError(output) {
    var m = String(output || "").match(/GDBus\.Error:([A-Za-z0-9._-]+)/)
    return m ? m[1] : ""
}

// Sample input: "/dev/sdb1"; udisksctl opens --key-file as a path, so "-" names a file and stdin is /dev/stdin.
function unlockArgv(device) {
    return ["udisksctl", "unlock", "--block-device", String(device || ""), "--key-file", "/dev/stdin"]
}

// Sample input: udisksctl's stderr after a refused unlock; only the daemon's Failed is a wrong passphrase.
function refusalNote(stderr, label) {
    return parseDbusError(stderr) === "org.freedesktop.UDisks2.Error.Failed" ? wrongNote(label) : unlockFailedNote(label)
}

// Sample input: the rail's device rows and "/dev/loop0"; the locked row for that device, or null before the rail lists it.
function lockedRow(entries, device) {
    var rows = entries || []
    for (var i = 0; i < rows.length; i++) {
        if (rows[i] && rows[i].locked === true && String(rows[i].device || "") === String(device || ""))
            return rows[i]
    }
    return null
}

// Sample input: "wrongpw", "wrongpwh", a retry's first edit: keys after the refused text are the retry, a deletion empties it, a paste stands.
function retryText(refused, edited) {
    var before = String(refused || "")
    var after = String(edited || "")
    if (before.length === 0)
        return after
    if (after.indexOf(before) === 0)
        return after.slice(before.length)
    return before.indexOf(after) === 0 ? "" : after
}

// Sample input: "crypto_LUKS", the fstype lsblk reports for a locked container.
function cryptoName(fstype) {
    var name = String(fstype || "").replace(/^crypto_/i, "").toUpperCase()
    return name.length > 0 ? name : "LUKS"
}

// Sample input: "Backup", "500.0 GB", "LUKS2", the name row under the title, one template per shape.
function subtitle(label, sizeText, crypto) {
    var name = String(label || "")
    var size = String(sizeText || "")
    var kind = String(crypto || "")
    if (size.length > 0 && kind.length > 0)
        return "%1 · %2 · %3".arg(name).arg(size).arg(kind)
    if (size.length > 0)
        return "%1 · %2".arg(name).arg(size)
    if (kind.length > 0)
        return "%1 · %2".arg(name).arg(kind)
    return name
}

// Sample input: the lsblk body and "/dev/mapper/luks-vault", answered with its container "/dev/sdb1", or "" when gone.
function backingFor(body, cryptDevice) {
    var tree
    try {
        tree = JSON.parse(String(body || ""))
    } catch (e) {
        return ""
    }
    var want = String(cryptDevice || "")
    var nodes = (tree && tree.blockdevices) || []
    for (var i = 0; i < nodes.length; i++) {
        var found = backingIn(nodes[i], want)
        if (found.length > 0)
            return found
    }
    return ""
}

// A crypt leaf's parent is the container udisksctl lock takes, whatever depth it sits at; no other type has one.
function backingIn(node, want) {
    var kids = node.children || []
    for (var i = 0; i < kids.length; i++) {
        if (String(kids[i].type || "") === "crypt" && Devices.devicePath(kids[i]) === want)
            return Devices.devicePath(node)
        var deeper = backingIn(kids[i], want)
        if (deeper.length > 0)
            return deeper
    }
    return ""
}
