// The run card's own classifier and launchers: a regular file with an execute bit or a script with a shebang asks once, anything else opens the way it always did.
use std::ffi::OsString;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};

#[path = "runharden.rs"]
mod runharden;

// The two answers flea --open gives beyond its 0/2/3 contract, read by ui/Opener.qml.
pub const ASK_RUN: i32 = 4;
pub const ASK_OPEN_WITH: i32 = 5;

// Magic, shebang and the AppImage marker all sit at the head, so this is all that is read.
const HEAD_LEN: usize = 4096;
const ELF_MAGIC: &[u8] = b"\x7fELF";
const SHEBANG: &[u8] = b"#!";
// The payload marker an AppImage carries near its head, past the ELF header.
const APPIMAGE_MARKER: &[u8] = b"AppImage";

#[derive(Debug, PartialEq, Clone, Copy)]
pub enum Kind {
    Script,
    Elf,
    AppImage,
}

// The wire spelling ui/js/RunFile.js reads off the ask line.
pub fn kind_name(kind: Kind) -> &'static str {
    match kind {
        Kind::Script => "script",
        Kind::Elf => "elf",
        Kind::AppImage => "appimage",
    }
}

// Sample head: b"#!/bin/sh\n" answers Script, b"\x7fELF..." answers Elf.
pub fn classify_header(head: &[u8], name: &str) -> Option<Kind> {
    if head.starts_with(SHEBANG) {
        return Some(Kind::Script);
    }
    if head.starts_with(ELF_MAGIC) {
        if is_appimage_name(name) || contains(head, APPIMAGE_MARKER) {
            return Some(Kind::AppImage);
        }
        return Some(Kind::Elf);
    }
    None
}

// Sample name: "Obsidian-1.9.AppImage" is one, "appimage.txt" is not.
fn is_appimage_name(name: &str) -> bool {
    name.len() > ".appimage".len()
        && name[name.len() - ".appimage".len()..].eq_ignore_ascii_case(".appimage")
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty() && haystack.len() >= needle.len() && haystack.windows(needle.len()).any(|w| w == needle)
}

#[derive(Debug, PartialEq)]
pub enum Decision {
    Ask(Kind),
    // Program-shaped but missing its execute bit: the chmod path, never a silent run.
    MakeExecutable(Kind),
    OpenNormally,
    RefuseNoExec,
}

// A header the classifier cannot name opens the way it always did, whatever its mode.
pub fn decide(path: &Path) -> Decision {
    let body = std::fs::read("/proc/self/mountinfo").unwrap_or_default();
    let text = String::from_utf8_lossy(&body).into_owned();
    decide_with(path, &text)
}

// Sample body: "1 0 8:1 / /tmp rw,noexec - tmpfs tmpfs rw" refuses; "1 0 8:1 / / rw - ext4 /dev/a rw" allows.
pub fn decide_with(path: &Path, mounts: &str) -> Decision {
    let meta = match std::fs::metadata(path) {
        Ok(m) => m,
        Err(_) => return Decision::OpenNormally,
    };
    if !meta.is_file() {
        return Decision::OpenNormally;
    }
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let kind = match classify_header(&read_head(path), &name) {
        Some(k) => k,
        None => return Decision::OpenNormally,
    };
    if noexec_in(path, mounts) {
        return Decision::RefuseNoExec;
    }
    if meta.permissions().mode() & 0o111 != 0 {
        Decision::Ask(kind)
    } else {
        Decision::MakeExecutable(kind)
    }
}

// The first HEAD_LEN bytes, or nothing when the file cannot be read: an unreadable head is not a program, so it opens the way it always did rather than refusing.
fn read_head(path: &Path) -> Vec<u8> {
    use std::io::Read;
    let mut head = Vec::new();
    if let Ok(file) = std::fs::File::open(path) {
        let _ = file.take(HEAD_LEN as u64).read_to_end(&mut head);
    }
    head
}

// Sample options: "rw,noexec" refuses, "rw" allows; an unreadable mount table allows.
fn noexec_in(path: &Path, mounts: &str) -> bool {
    match crate::backend::mountinfo::raw_mount_options_in(path, mounts) {
        Some(options) => options.split(',').any(|o| o == "noexec"),
        None => false,
    }
}

// One absolute argument, so a name with spaces, quotes, a leading dash or a newline is never read as flags by the child it names.
pub fn run_argv(target: &Path) -> Vec<OsString> {
    vec![target.as_os_str().to_owned()]
}

// Sample dir: "/home/gm/Downloads" names xdg-terminal-exec --dir=/home/gm/Downloads -e <target>, the OEM route src/terminal.rs takes and the -e spelling omarchy-launch-tui runs.
pub fn terminal_argv(dir: &Path, target: &Path) -> Vec<OsString> {
    let mut flag = OsString::from("--dir=");
    flag.push(dir);
    vec![
        OsString::from("xdg-terminal-exec"),
        flag,
        OsString::from("-e"),
        target.as_os_str().to_owned(),
    ]
}

fn canonical(path: &str) -> Option<PathBuf> {
    std::fs::canonicalize(path).ok()
}

// The card's three modes beside main.rs's --open arms: Some(code) when argv names one, malformed shapes refused through the same usage errors, None for every other mode.
pub fn dispatch(args: &[String]) -> Option<i32> {
    if args.get(1).map(String::as_str) == Some("--run") {
        if args.len() == 8 {
            if let Some(id) = crate::runid::FileId::parse(&args[3], &args[4], &args[5], &args[6], &args[7]) {
                return Some(run(&args[2], &id));
            }
        }
        crate::usage("--run takes one path and its card identity");
    }
    if args.get(1).map(String::as_str) == Some("--run-terminal") {
        if args.len() == 8 {
            if let Some(id) = crate::runid::FileId::parse(&args[3], &args[4], &args[5], &args[6], &args[7]) {
                return Some(run_in_terminal(&args[2], &id));
            }
        }
        crate::usage("--run-terminal takes one path and its card identity");
    }
    if args.get(1).map(String::as_str) == Some("--open-text") {
        if args.len() == 3 {
            return Some(open_text(&args[2]));
        }
        crate::usage("--open-text takes one path");
    }
    None
}

fn parent_of(target: &Path) -> PathBuf {
    target.parent().map(Path::to_path_buf).unwrap_or_else(|| PathBuf::from("/"))
}

// Some(exit) when the target must not start at all, None when the card may ask for it.
fn refused(target: &Path) -> Option<i32> {
    match decide(target) {
        Decision::Ask(_) => None,
        Decision::MakeExecutable(_) => {
            eprintln!("flea: that file is not executable, so it was not run");
            Some(2)
        }
        Decision::RefuseNoExec => {
            eprintln!("flea: that program is on a volume that does not allow running files");
            Some(2)
        }
        Decision::OpenNormally => {
            eprintln!("flea: that file is not a program, so it was not run");
            Some(2)
        }
    }
}

// The R3 recheck: the file behind the path is still the one the card named, and a stat the swap itself broke refuses like a mismatch.
fn rechecked(target: &Path, expect: &crate::runid::FileId) -> Option<i32> {
    match crate::runid::capture(target) {
        Some(now) if now.matches(expect) => None,
        _ => {
            eprintln!("flea: that file changed since the card asked, so it was not run");
            Some(2)
        }
    }
}

// Run starts it detached in its own folder, the way the terminal launcher does: nothing runs without the card, so this mode answers only the card's own Run button.
pub fn run(path: &str, expect: &crate::runid::FileId) -> i32 {
    let target = match canonical(path) {
        Some(p) => p,
        None => {
            eprintln!("flea: that program could not be run, check that it still exists");
            return 2;
        }
    };
    if let Some(exit) = refused(&target) {
        return exit;
    }
    if let Some(exit) = rechecked(&target, expect) {
        return exit;
    }
    let argv = run_argv(&target);
    let mut child = std::process::Command::new(&argv[0]);
    child.args(&argv[1..]);
    child.current_dir(parent_of(&target));
    crate::terminal::detach(&mut child);
    runharden::harden(&mut child);
    match child.spawn() {
        Ok(_) => 0,
        Err(_) => {
            eprintln!("flea: nothing on this system could be asked to run that file");
            2
        }
    }
}

// Run in terminal shows the output: the same checks as Run, under the OEM terminal.
pub fn run_in_terminal(path: &str, expect: &crate::runid::FileId) -> i32 {
    let target = match canonical(path) {
        Some(p) => p,
        None => {
            eprintln!("flea: that program could not be run, check that it still exists");
            return 2;
        }
    };
    if let Some(exit) = refused(&target) {
        return exit;
    }
    if let Some(exit) = rechecked(&target, expect) {
        return exit;
    }
    let argv = terminal_argv(&parent_of(&target), &target);
    let mut child = std::process::Command::new(&argv[0]);
    child.args(&argv[1..]);
    crate::terminal::detach(&mut child);
    runharden::harden(&mut child);
    match child.spawn() {
        Ok(_) => 0,
        Err(_) => {
            eprintln!("flea: nothing on this system could be asked to run that file in a terminal");
            2
        }
    }
}

// The text editor the desktop names for text/plain, or "" when it names none.
fn text_editor() -> String {
    let out = std::process::Command::new("xdg-mime")
        .arg("query")
        .arg("default")
        .arg("text/plain")
        .env("LC_ALL", "C")
        .output();
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => String::new(),
    }
}

// Open as text sends it to that editor through gio launch, waited on the way gio open is.
pub fn open_text(path: &str) -> i32 {
    let target = match canonical(path) {
        Some(p) => p,
        None => {
            eprintln!("flea: that file could not be opened, check that it still exists");
            return 2;
        }
    };
    if target.is_dir() {
        return crate::open::IS_DIRECTORY;
    }
    let id = text_editor();
    if id.is_empty() {
        eprintln!("flea: no text editor is installed for that file");
        return 2;
    }
    crate::thp::enable();
    let mut launcher = std::process::Command::new("gio");
    crate::vulkan::drop_display_pin(&mut launcher);
    crate::gui::restore_platform_theme(&mut launcher);
    let finished = launcher
        .arg("launch")
        .arg(&id)
        .arg(&target)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .process_group(0)
        .status();
    match finished {
        Ok(status) if status.success() => 0,
        Ok(_) => {
            eprintln!("flea: no text editor on this system opened that file");
            2
        }
        Err(_) => {
            eprintln!("flea: nothing on this system could be asked to open that file as text");
            2
        }
    }
}

// The card's Make executable has no chmod of its own: it reuses the menu's permissions batch, so one undo restores the bit.

// Sample line: "Default application for 'text/plain': nvim.desktop" names one, "No default applications for 'text/plain'" names none, anything else is claimed.
pub fn handler_of(output: &str) -> String {
    let line = output.trim();
    match line.strip_prefix("Default application for ") {
        Some(rest) => rest.rsplit_once(':').map(|(_, id)| id.trim().to_string()).unwrap_or_default(),
        None => String::new(),
    }
}

// Sample output: "Default application for 'x': a.desktop" runs gio, "No default ..." asks, and a failed lookup is claimed so a refused launch keeps its sentence.
pub fn default_handler_gio(mime: &str) -> String {
    let out = std::process::Command::new("gio")
        .arg("mime")
        .arg(mime)
        .env("LC_ALL", "C")
        .output();
    match out {
        Ok(o) if o.status.success() => handler_of(&String::from_utf8_lossy(&o.stdout)),
        _ => String::from("claimed"),
    }
}

// True when no application claims the file, which opens the approved Open with dialog instead of an error; a lookup that cannot be had answers claimed, so a refused launch keeps the sentence it has always had.
pub fn unclaimed(path: &Path) -> bool {
    let db = crate::backend::mime::Db::load();
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let mime = db.lookup(&name).unwrap_or("application/octet-stream");
    default_handler_gio(mime).is_empty()
}

// True when the desktop names a handler for the file's own type, which offers the AppImage card its first button; anything else leaves the card the board draws.
pub fn has_handler(path: &Path) -> bool {
    let db = crate::backend::mime::Db::load();
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let mime = db.lookup(&name).unwrap_or("application/octet-stream");
    !default_handler_gio(mime).is_empty()
}

#[cfg(test)]
#[path = "runfile_tests.rs"]
mod tests;
