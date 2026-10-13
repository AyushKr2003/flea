// Each value is the literal shell double-quoted text stored in user-dirs.dirs.
var cases = [
    ["escaped quote", '"$HOME/Photo\\"Inbox"', '/home/test/Photo"Inbox'],
    ["escaped backslash", '"$HOME/Photo\\\\Inbox"', '/home/test/Photo\\Inbox'],
    ["escaped dollar", '"$HOME/Photo\\$HOME"', '/home/test/Photo$HOME'],
    ["escaped leading dollar", '"/media/\\$HOME/Inbox"', '/media/$HOME/Inbox'],
    ["escaped backquote", '"$HOME/Photo\\`Inbox"', '/home/test/Photo`Inbox'],
    ["leading HOME token", '"$HOME/Inbox"', '/home/test/Inbox'],
    ["absolute path", '"/media/Inbox"', '/media/Inbox'],
    ["surrounding whitespace", '  "$HOME/Inbox"  ', '/home/test/Inbox'],
    ["trailing comment", '"$HOME/Inbox" # local inbox', '/home/test/Inbox'],
    ["trailing spaces then comment", '"$HOME/Inbox"   # local inbox', '/home/test/Inbox'],
    ["trailing quoted comment", '"$HOME/Inbox" # "local inbox"', '/home/test/Inbox'],
    ["literal dollar mid-path", '"$HOME/Inbox$local"', '/home/test/Inbox$local'],
    ["multiple trailing slashes", '"$HOME/Inbox///" # local inbox', '/home/test/Inbox'],
    ["unterminated value", '"$HOME/Inbox', null],
    ["dangling escape", '"$HOME/Inbox\\', null],
    ["concatenated quotes", '"$HOME/Photo"Inbox"', '/home/test/Photo'],
    ["trailing content", '"$HOME/Inbox"junk', '/home/test/Inbox'],
    ["backslash makes any next character literal", '"$HOME/Photo\\q"', '/home/test/Photoq'],
    ["unescaped dollar", '"$HOME/Photo$HOME"', '/home/test/Photo$HOME'],
    ["unescaped backquote", '"$HOME/Photo`Inbox"', '/home/test/Photo`Inbox'],
    ["HOME is literal after an absolute prefix", '"/media/$HOME/Inbox"', '/media/$HOME/Inbox'],
    ["HOME token has a suffix", '"$HOMEwork/Inbox"', null],
    ["relative path", '"Inbox"', null],
    ["escaped absolute prefix is relative", '"\\/media/Inbox"', null],
    ["escaped HOME prefix is relative", '"\\$HOME/Inbox"', null],
    ["single-quoted value", "'$HOME/Inbox'", null],
    ["unquoted value", '$HOME/Inbox', null]
]

function body(value) {
    return 'XDG_DOWNLOAD_DIR=' + value + '\nXDG_PICTURES_DIR="$HOME"\nXDG_VIDEOS_DIR="$HOME"'
}
