.pragma library

.import "Cloud.js" as Cloud
.import "Mounts.js" as Mounts

// A drop target's device from the mount table the UI already polls: the source device when
// the target sits on the source volume, 0 when it sits across a mount boundary
// or cannot be known, which makes the plain drop copy. String prefixes only,
// so no stat runs on the UI thread and a hung network mount is never touched.

// Sample input: normalize("/run/media/gm/USB/") is "/run/media/gm/USB".
function normalize(path) {
    var p = String(path || "").replace(/\/+$/, "")
    return p.length > 0 ? p : (String(path || "").charAt(0) === "/" ? "/" : "")
}

// Sample input: isUnder("/a/b/c", "/a/b") is true, isUnder("/a/bc", "/a/b") is false.
function isUnder(path, mount) {
    var p = normalize(path), m = normalize(mount)
    if (p.length === 0 || m.length === 0) return false
    if (p === m) return true
    return m === "/" ? p.charAt(0) === "/" : p.indexOf(m + "/") === 0
}

// Sample input: longestMount("/run/media/gm/USB/x", ["/", "/run/media/gm/USB"]) is "/run/media/gm/USB".
function longestMount(path, mounts) {
    var best = ""
    var list = mounts || []
    for (var i = 0; i < list.length; i++) {
        var m = normalize(list[i])
        if (m.length > 0 && m.length > best.length && isUnder(path, m)) best = m
    }
    return best
}

// Sample input, /proc/self/mountinfo lines (field five is the mount point, a space written \040):
// 36 1 8:1 / / rw - ext4 /dev/sda1 rw
// 41 36 8:2 / /home rw - btrfs /dev/sda2 rw,subvol=/@home
// 52 36 8:17 / /run/media/gm/My\040USB rw - vfat /dev/sdb1 rw
// answers ["/", "/home", "/run/media/gm/My USB"]; a text with no mount line answers [].
function mountPoints(mountinfoText) {
    var out = []
    var lines = String(mountinfoText || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
        var parsed = Cloud.parseMountinfoLine(lines[i])
        var m = parsed ? normalize(parsed.path) : ""
        if (m.length > 0 && out.indexOf(m) < 0) out.push(m)
    }
    return out
}

// Sample input: resolveDestDev("/home/u", "/home/u/docs", 42, ["/"]) is 42, and 0 when mounts is null or empty (the table not loaded yet).
// A gvfs path never resolves by prefix: its mount is not in the table, so it copies.
function resolveDestDev(target, srcPath, srcDev, mounts) {
    if (!srcDev) return 0
    if (String(target || "").length === 0) return 0
    if (Mounts.underGvfs(target) || Mounts.underGvfs(srcPath)) return 0
    var at = longestMount(target, mounts)
    return at.length > 0 && at === longestMount(srcPath, mounts) ? srcDev : 0
}
