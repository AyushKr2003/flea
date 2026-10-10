.import "../../ui/js/Unlock.js" as Unlock
.import "../../ui/js/Devices.js" as Devices
.import "../../ui/js/Mounts.js" as Mounts
.import "../../ui/js/Eject.js" as Eject
.import "sourcefixture.js" as Source

// Unlock (U039): locked LUKS rows, the dialog's own sentences, and the udisks output the dialog parses.
function run(check) {
    check("the dialog titles itself for the drive", Unlock.title("Backup"), "Unlock Backup")
    check("unlocking names the drive with an ellipsis", Unlock.unlockingNote("Backup"), "Unlocking Backup…")
    check("a wrong passphrase names the drive", Unlock.wrongNote("Backup"), "That passphrase did not unlock Backup.")
    check("success names the drive", Unlock.unlockedNote("Backup"), "Unlocked and mounted Backup.")
    check("a lock that fails names the drive", Unlock.lockNote("Backup"), "Backup was unmounted but could not be locked; close what is using it.")
    check("the mapped device is read off the unlock line",
        Unlock.parseUnlocked("Unlocked /dev/sda1 as /dev/dm-0."), "/dev/dm-0")
    check("the mountpoint is read off the mount line",
        Unlock.parseMounted("Mounted /dev/dm-0 at /run/media/gm/Backup."), "/run/media/gm/Backup")
    check("an unlock without a mount names the drive", Unlock.mountNote("Backup"), "Backup was unlocked but could not be mounted.")
    check("a refused unlock names the drive", Unlock.unlockFailedNote("Backup"), "Backup could not be unlocked.")
    check("the name row joins all three parts", Unlock.subtitle("Backup", "500.0 GB", "LUKS2"), "Backup · 500.0 GB · LUKS2")
    check("the name row without a size joins two", Unlock.subtitle("Backup", "", "LUKS2"), "Backup · LUKS2")
    check("the name row alone is the label", Unlock.subtitle("Backup", "", ""), "Backup")
    check("the D-Bus error name is read off the daemon line",
        Unlock.parseDbusError("Error unlocking /dev/sdb1: GDBus.Error:org.freedesktop.UDisks2.Error.Failed: x"), "org.freedesktop.UDisks2.Error.Failed")
    check("translated prose around the name changes nothing",
        Unlock.parseDbusError("Fehler beim Entsperren: GDBus.Error:org.freedesktop.UDisks2.Error.Failed: y"), "org.freedesktop.UDisks2.Error.Failed")
    check("another error name is answered as itself",
        Unlock.parseDbusError("GDBus.Error:org.freedesktop.UDisks2.Error.NotAuthorized: z"), "org.freedesktop.UDisks2.Error.NotAuthorized")
    check("output without a name answers empty", Unlock.parseDbusError("boom"), "")
    check("the key reaches udisksctl through /dev/stdin, since it opens --key-file as a path",
        Unlock.unlockArgv("/dev/sdb1").join(" "), "udisksctl unlock --block-device /dev/sdb1 --key-file /dev/stdin")
    check("only the daemon's Failed reads as a wrong passphrase",
        Unlock.refusalNote("Error unlocking /dev/sda1: GDBus.Error:org.freedesktop.UDisks2.Error.Failed: Incorrect passphrase.", "Backup"),
        "That passphrase did not unlock Backup.")
    check("a local failure with no daemon error is never called a wrong passphrase",
        Unlock.refusalNote("Error unlocking /dev/sda1: Failed to open file \u201c-\u201d: No such file or directory", "Backup"),
        "Backup could not be unlocked.")
    check("a refused authorization could not unlock",
        Unlock.refusalNote("GDBus.Error:org.freedesktop.UDisks2.Error.NotAuthorized: z", "Backup"), "Backup could not be unlocked.")

    // Sample lsblk body: one internal disk plus a locked LUKS stick beside it.
    var locked = '{"blockdevices":['
        + '{"name":"nvme0n1","path":"/dev/nvme0n1","label":null,"mountpoints":[null],"rm":false,"size":256060514304,"type":"disk","model":"KBG40ZNS256G",'
        + '"children":[{"name":"nvme0n1p1","path":"/dev/nvme0n1p1","label":null,"mountpoints":["/"],"rm":false,"size":256060514304,"type":"part","model":null}]},'
        + '{"name":"sdb","path":"/dev/sdb","label":null,"mountpoints":[null],"rm":true,"size":500000000000,"type":"disk","model":"Vault Drive",'
        + '"children":[{"name":"sdb1","path":"/dev/sdb1","label":"Backup","mountpoints":[null],"rm":true,"size":500000000000,"type":"part","fstype":"crypto_LUKS","model":null}]}'
        + ']}'
    var rows = Devices.parseDevices(locked)
    check("a locked container on a stick is a rail row", rows.length, 2)
    check("the locked row carries its label", rows[1].label, "Backup")
    check("the locked row carries its device node", rows[1].device, "/dev/sdb1")
    check("the locked row reads as locked", rows[1].locked, true)
    check("the locked row is not mounted", rows[1].mounted, false)

    // tests/ui-captures-unlock.sh's lsblk shim: the lane's loop container as cap-loop0 with rm set, since any loop* name is skipped.
    var loopLocked = '{"blockdevices":[{"name":"%N","path":"/dev/loop0","label":null,"mountpoints":[null],"rm":%R,'
        + '"tran":null,"size":33554432,"type":"loop","model":null,"fstype":"crypto_LUKS"}]}'
    rows = Devices.parseDevices(loopLocked.replace("%N", "cap-loop0").replace("%R", "true"))
    check("the shimmed loop container is one locked row", rows.length === 1 && rows[0].locked, true)
    check("the shimmed loop row keeps the real device node", rows[0].device, "/dev/loop0")
    check("the shimmed loop row is labelled by its shimmed name", rows[0].label, "cap-loop0")
    check("a loop name stays no row even when removable", Devices.parseDevices(loopLocked.replace("%N", "loop0").replace("%R", "true")).length, 0)

    // Unlock critic F1: the board's container keeps its name once unlocked, so the row and the footer say one name.
    var named = '{"blockdevices":[{"name":"sdb","path":"/dev/sdb","label":null,"mountpoints":[null],"rm":true,"size":500000000000,"type":"disk","model":"Vault Drive",'
        + '"children":[{"name":"sdb1","path":"/dev/sdb1","label":"Backup","mountpoints":[null],"rm":true,"size":500000000000,"type":"part","fstype":"crypto_LUKS",'
        + '"children":[{"name":"luks-1","path":"/dev/mapper/luks-1","label":"S1LUKS","mountpoints":[%M],"rm":false,"size":499983810560,"type":"crypt","fstype":"ext4"}]}]}]}'
    var unlocked = Devices.parseDevices(named.replace("%M", '"/run/media/gm/S1LUKS"'))
    check("an unlocked named container keeps the locked row's name and opens its own folder",
        unlocked.map(function (r) { return r.label + "|" + r.path + "|" + r.locked }).join(","), "Backup|/run/media/gm/S1LUKS|false")
    check("mid-unlock, before the mount, the row already reads the container's name",
        Devices.parseDevices(named.replace("%M", "null"), true).map(function (r) { return r.label }).join(","), "Backup")
    check("an unnamed container's unlocked volume reads its own label, as it did",
        Devices.parseDevices(named.replace('"label":"Backup"', '"label":null').replace("%M", '"/run/media/gm/S1LUKS"'))[0].label, "S1LUKS")

    // Unlock critic F3: flea --unlock names the card from the rail's locked row for that device, once the rail lists it.
    var rail = [{ label: "Backup", device: "/dev/sdb1", locked: false, size: 1 }, { label: "Backup", device: "/dev/loop0", locked: true, size: 33554432, fstype: "crypto_LUKS" }]
    check("the CLI device finds its locked row", Unlock.lockedRow(rail, "/dev/loop0").size, 33554432)
    check("an unlocked row of the same device is never the card's name", Unlock.lockedRow([rail[0]], "/dev/sdb1"), null)
    check("a rail that has not listed the device yet names nothing", Unlock.lockedRow([], "/dev/loop0"), null)
    var host = Source.source("ui/UnlockHost.qml")
    check("the host names the CLI card on each rail rebuild",
        Source.slice(host, "        function onEntriesChanged()", "    }").indexOf("root.nameDevice()") >= 0, true)

    // Unlock critic F5, F6 and F8 (ui:cap_unlock proves each natively): dots through Unlocking and Wrong, Tab field to Unlock.
    var dialog = Source.source("ui/UnlockDialog.qml")
    var submit = Source.slice(dialog, "    function submit()", "    function _startQueued()")
    check("submit keeps the typed text in the field", submit.indexOf('field.text = ""'), -1)
    var refusal = Source.slice(dialog, "    function showRefusal(", "    // A dialog that ends")
    check("a refusal keeps the dots and remembers them for the retry",
        (refusal.indexOf("root._refused = field.text") >= 0) + "|" + refusal.indexOf('field.text = ""'), "true|-1")
    check("keys typed after the refused dots are the whole retry", Unlock.retryText("wrongpw", "wrongpwhunter2"), "hunter2")
    check("a Backspace into the refused dots empties the field", Unlock.retryText("wrongpw", "wrongp"), "")
    check("a select-all and paste over them stands", Unlock.retryText("wrongpw", "hunter2"), "hunter2")
    check("an edit with nothing refused is left alone", Unlock.retryText("", "abc"), "abc")
    check("a card the user has typed in keeps its name", Source.slice(host, "    function nameDevice()", "    // After an unlock").indexOf("dlg.masked") >= 0, true)
    check("the field's Tab steps the card's own order", /onTabbed: function \(from, back\) \{ root\.stepTab\(back\) \}/.test(dialog), true)
    check("the order is field, Cancel, Unlock", dialog.indexOf("[field.input, cancelButton, unlockButton]") >= 0, true)
    check("Unlock drops out with the field while unlocking", Source.slice(dialog, "                        id: unlockButton", "                    }").indexOf('enabled: root.phase !== "unlocking"') >= 0, true)
    var loopOpen = '{"blockdevices":[{"name":"cap-loop0","path":"/dev/loop0","mountpoints":[null],"rm":true,"type":"loop","fstype":"crypto_LUKS",'
        + '"children":[{"name":"luks-6f1c","path":"/dev/mapper/luks-6f1c","label":"S1LUKS","mountpoints":["/run/media/gm/S1LUKS"],'
        + '"rm":true,"type":"crypt","fstype":"vfat"}]}]}'
    rows = Devices.parseDevices(loopOpen)
    check("the shimmed unlocked leaf is the one row", rows.length === 1 && rows[0].path, "/run/media/gm/S1LUKS")
    check("the shimmed unlocked leaf locks its loop container", Unlock.backingFor(loopOpen, "/dev/mapper/luks-6f1c"), "/dev/loop0")
    check("an eject of the shimmed leaf judges its loop disk", Eject.diskOf(loopOpen, "/dev/mapper/luks-6f1c").path, "/dev/loop0")

    // An internal locked container gets a row too, behind the same switch.
    var internal = '{"blockdevices":['
        + '{"name":"nvme0n1","path":"/dev/nvme0n1","label":null,"mountpoints":[null],"rm":false,"size":256060514304,"type":"disk","model":"KBG40ZNS256G",'
        + '"children":[{"name":"nvme0n1p1","path":"/dev/nvme0n1p1","label":null,"mountpoints":["/"],"rm":false,"size":256060514304,"type":"part","model":null},'
        + '{"name":"nvme0n1p2","path":"/dev/nvme0n1p2","label":"Backup","mountpoints":[null],"rm":false,"size":500000000000,"type":"part","fstype":"crypto_LUKS","model":null}]}'
        + ']}'
    var inner = Devices.parseDevices(internal)
    check("an internal locked container is a rail row too", inner.length, 2)
    check("the internal locked row reads as locked", inner[1].locked, true)

    // The rail menu offers Unlock on a locked row and nothing else.
    var menu = Mounts.railMenu({ label: "Backup", group: "device", kind: "volume", device: "/dev/sdb1", mounted: false, removable: true, locked: true })
    check("a locked row offers one row", menu.length, 1)
    check("and that row is Unlock", menu[0].label, "Unlock")
    check("the Unlock row carries the unlock action", menu[0].action, "unlockVolume")
    check("the Unlock row draws the lock mark", menu[0].glyph, "lock")

    // S0: an unlocked crypt row offers Open, Unmount and Eject, and never Unlock.
    var cryptMenu = Mounts.railMenu({ label: "Backup", group: "device", kind: "volume", device: "/dev/dm-0", path: "/run/media/gm/Backup", mounted: true, removable: true, volumeMenu: true, locked: false })
    check("an unlocked row offers open, unmount and eject",
        cryptMenu.filter(function (r) { return r.separator !== true }).map(function (r) { return r.label + ":" + r.action }).join(","), "Open:open,Unmount:unmountVolume,Eject:eject")

    // Sample lsblk body: an unlocked crypt on a stick, and a plain stick beside it.
    var open = '{"blockdevices":['
        + '{"name":"sdb","path":"/dev/sdb","type":"disk","rm":true,"mountpoints":[null],'
        + '"children":[{"name":"sdb1","path":"/dev/sdb1","type":"part","fstype":"crypto_LUKS","mountpoints":[null],'
        + '"children":[{"name":"luks-vault","path":"/dev/mapper/luks-vault","type":"crypt","mountpoints":["/run/media/gm/vault"]}]}]},'
        + '{"name":"sdc","path":"/dev/sdc","type":"disk","rm":true,"mountpoints":[null],'
        + '"children":[{"name":"sdc1","path":"/dev/sdc1","type":"part","fstype":"vfat","mountpoints":["/run/media/gm/STICK"]}]}'
        + ']}'
    check("the container behind an unlocked crypt is what lock takes", Unlock.backingFor(open, "/dev/mapper/luks-vault"), "/dev/sdb1")
    check("a plain partition has no container to lock", Unlock.backingFor(open, "/dev/sdc1"), "")
    check("the locked container itself has none either", Unlock.backingFor(open, "/dev/sdb1"), "")
    check("an empty device locks nothing", Unlock.backingFor(open, ""), "")
    check("a body that does not parse locks nothing", Unlock.backingFor("not json", "/dev/mapper/luks-vault"), "")

    // The eject verdict reads the device before the chain state clears it, or the lock never fires.
    var verdictBody = Source.slice(Source.source("ui/DeviceMounts.qml"), "    function reportEject(", "    Timer {")
    check("the eject lock runs before the device is cleared",
        verdictBody.indexOf("root.lockCrypt(root._ejectDevice") >= 0
            && verdictBody.indexOf("root.lockCrypt(root._ejectDevice") < verdictBody.indexOf('root._ejectDevice = ""'), true)
    runEjectLock(check, open)
}

// Sample input: the listing before the eject (the crypt unlocked) and the one gio's exit was judged on (the drive gone).
function ejectLockFrom(stale, judged, unmount) {
    var mounts = Source.source("ui/DeviceMounts.qml")
    var body = Source.slice(mounts, "    function lockCrypt(", "    // Eject goes through")
        + Source.slice(mounts, "    function judgeEject(", "    Timer {")
    var handed = []
    var attempts = 0
    var root = { _listing: stale, _ejectDevice: "/dev/mapper/luks-vault", _ejectLabel: "vault", _verdictFromListing: 1, _listingsStarted: 1,
        _lastVerdict: "", forgetMessage: function () {}, message: function () {},
        deviceLock: { lockCryptAfter: function (listing, device) { attempts += 1; handed.push(Unlock.backingFor(listing, device)); return true } } }
    var stop = { stop: function () {} }
    new Function("root", "Eject", "powerOffTimeout", "ejectVerdictTimeout", "judged", "deviceLock",
        body + "; root.lockCrypt = lockCrypt; root.reportEject = reportEject; root.judgeEject = judgeEject; " + (unmount ? "root.lockCrypt(root._ejectDevice, root._ejectLabel);" : "root.judgeEject(judged);"))(root, Eject, stop, stop, judged, root.deviceLock)
    // One attempt refused by backingFor reads "1:", never reaching lockCrypt reads "0:".
    return attempts + ":" + handed.join("|")
}

// UL4: gvfs ejecting a LUKS stick locks and powers it off itself, so only a crypt the judged listing still shows gets a lock.
function runEjectLock(check, open) {
    var gone = '{"blockdevices":[{"name":"sdc","path":"/dev/sdc","type":"disk","rm":true,"mountpoints":[null],'
        + '"children":[{"name":"sdc1","path":"/dev/sdc1","type":"part","fstype":"vfat","mountpoints":[null]}]}]}'
    var parked = '{"blockdevices":[{"name":"sdb","path":"/dev/sdb","type":"disk","rm":true,"mountpoints":[null],'
        + '"children":[{"name":"sdb1","path":"/dev/sdb1","type":"part","fstype":"crypto_LUKS","mountpoints":[null],'
        + '"children":[{"name":"luks-vault","path":"/dev/mapper/luks-vault","type":"crypt","mountpoints":[null]}]}]}]}'
    var relocked = '{"blockdevices":[{"name":"sdb","path":"/dev/sdb","type":"disk","rm":true,"mountpoints":[null],'
        + '"children":[{"name":"sdb1","path":"/dev/sdb1","type":"part","fstype":"crypto_LUKS","mountpoints":[null]}]}]}'
    check("a drive gvfs already powered off gets one refused attempt", ejectLockFrom(open, gone, false), "1:")
    check("a container gvfs already locked gets one refused attempt", ejectLockFrom(open, relocked, false), "1:")
    check("a crypt the judged listing still shows is locked", ejectLockFrom(open, parked, false), "1:/dev/sdb1")
    check("an unmount locks from the listing it already holds", ejectLockFrom(open, gone, true), "1:/dev/sdb1")
}
