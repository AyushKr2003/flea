#!/usr/bin/python3
# The helper's pure decisions without a daemon: error names, the system-disk predicate and the
# status bytes. gi is stubbed because this box carries no python-gobject; the D-Bus calls behind
# cmd_open and cmd_eject run against scsi_debug in the controller's integration, never here.
import importlib.machinery
import importlib.util
import sys
import types

gi = types.ModuleType("gi")
gi.require_version = lambda *args: None
repository = types.ModuleType("gi.repository")
repository.Gio = types.ModuleType("Gio")
repository.GLib = types.ModuleType("GLib")
repository.UDisks = types.ModuleType("UDisks")
gi.repository = repository
sys.modules["gi"] = gi
sys.modules["gi.repository"] = repository
sys.modules["gi.repository.Gio"] = repository.Gio
sys.modules["gi.repository.GLib"] = repository.GLib
sys.modules["gi.repository.UDisks"] = repository.UDisks

loader = importlib.machinery.SourceFileLoader("flea_udisks", "tools/flea-udisks")
spec = importlib.util.spec_from_loader("flea_udisks", loader)
helper = importlib.util.module_from_spec(spec)
loader.exec_module(helper)

failures = []


def check(label, got, want):
    if got != want:
        failures.append(label)
        print("FAIL %s: got %r want %r" % (label, got, want))
    else:
        print("ok   %s" % label)


# The machine half of a D-Bus failure, never the prose past the second colon.
check("busy name", helper.error_name(Exception("GDBus.Error:org.freedesktop.UDisks2.Error.DeviceBusy: Device is busy")),
      "org.freedesktop.UDisks2.Error.DeviceBusy")
check("denied name", helper.error_name(Exception("GDBus.Error:org.freedesktop.PolicyKit1.Error.Failed: dismissed")),
      "org.freedesktop.PolicyKit1.Error.Failed")
check("no marker", helper.error_name(Exception("plain failure")), "")
check("busy predicate", (helper.busy_name("org.freedesktop.UDisks2.Error.DeviceBusy"),
                         helper.busy_name("org.freedesktop.UDisks2.Error.Failed")), (True, False))
check("denied predicate", (helper.denied_name("org.freedesktop.UDisks2.Error.NotAuthorized"),
                           helper.denied_name("org.freedesktop.UDisks2.Error.Failed")), (True, False))
# The daemon's own system-disk judgement, off machine fields alone.
check("no drive", helper.is_system_drive(None), True)
check("hint system", helper.is_system_drive({"HintSystem": True, "Removable": True}), True)
check("removable", helper.is_system_drive({"HintSystem": False, "Removable": True}), False)
check("usb bus", helper.is_system_drive({"HintSystem": False, "Removable": False, "ConnectionBus": "usb"}), False)
check("internal bus", helper.is_system_drive({"HintSystem": False, "Removable": False, "ConnectionBus": ""}), True)
# The disk itself or one of its partitions, /dev/sda beside /dev/sda1, never a prefix twin.
check("on drive", (helper.on_drive("sda", "/dev/sda"), helper.on_drive("sda", "/dev/sda1"),
                   helper.on_drive("sda", "/dev/sdaa"), helper.on_drive("sda", "/dev/nvme0n1")),
      (True, True, False, False))
# The portal's own ay rule, copied rather than reinvented for the Device bytestring.
check("bytestring", (helper.bytestring(b"/dev/sda\0"), helper.bytestring([47, 100, 101, 118]),
                    helper.bytestring("nope")), ("/dev/sda", "/dev", ""))
# The one-byte answers the backend reads off the socket.
check("status bytes", (helper.STATUS_OK, helper.STATUS_DENIED, helper.STATUS_BUSY,
                       helper.STATUS_CHANGED, helper.STATUS_ERROR), (b"O", b"D", b"B", b"C", b"E"))
# O_EXCL | O_DIRECT | O_CLOEXEC, TECH.md section 0; O_SYNC is what OpenForRestore paid.
check("open flags", helper.OPEN_FLAGS, 0o200000 | 0o40000 | 0o2000000)

if failures:
    print("%d failed: %s" % (len(failures), failures))
    sys.exit(1)
print("flash-udisks: all checks passed")
