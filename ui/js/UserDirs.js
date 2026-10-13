.pragma library

// Sample input: XDG_DOWNLOAD_DIR="$HOME/Photo\"Inbox" # local inbox
function parseLine(line, home) {
    var kv = String(line || "").match(/^[ \t]*XDG_([A-Z]+)_DIR[ \t]*=([\s\S]*)$/)
    if (!kv)
        return null
    var value = kv[2].match(/^[ \t]*"(\$HOME(?=\/|"))?((?:\\[\s\S]|[^"\\])*)"/)
    var path = null
    if (value && (value[1] || value[2].charAt(0) === "/")) {
        path = (value[1] ? home : "") + value[2].replace(/\\([\s\S])/g, "$1")
        path = path.replace(/\/+$/, "")
        if (path.charAt(0) !== "/")
            path = null
    }
    return { role: kv[1], path: path }
}

// Sample input: XDG_DOWNLOAD_DIR="$HOME/Downloads".
function userDirs(body, home) {
    var out = []
    var lines = String(body || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
        var entry = parseLine(lines[i], home)
        // A disabled role points at Home, which is not a separate place or a default-sort folder.
        if (!entry || !entry.path || entry.path === home)
            continue
        out.push({ path: entry.path, label: leaf(entry.path) })
    }
    return out
}

function leaf(path) {
    var cut = path.lastIndexOf("/")
    return cut < 0 ? path : path.substring(cut + 1)
}
