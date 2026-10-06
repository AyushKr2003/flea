.import "../../ui/js/Unlock.js" as Unlock
.import "../../ui/js/Devices.js" as Devices
.import "../../ui/js/Mounts.js" as Mounts
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
    var verdictBody = Source.slice(Source.source("ui/DeviceMounts.qml"), "    function reportEject(verdict, others) {", "    Timer {")
    check("the eject lock runs before the device is cleared",
        verdictBody.indexOf("root.lockCrypt(root._ejectDevice") >= 0
            && verdictBody.indexOf("root.lockCrypt(root._ejectDevice") < verdictBody.indexOf('root._ejectDevice = ""'), true)
}
