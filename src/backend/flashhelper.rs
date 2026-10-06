// The flea-udisks helper client: one process per flash, the descriptor back over a socket pair.
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::raw::c_int;
use std::time::{Duration, Instant};

// The packaged helper beside flea-gio-auth; FLEA_UDISKS overrides it, which is also the test seam.
const HELPER_PATH: &str = "/usr/lib/flea/flea-udisks";
// A drives or eject answer waits this long; the open leg waits on the user's own prompt instead.
const HELPER_TIMEOUT: Duration = Duration::from_secs(30);
// poll(2) POLLIN, one fd, EINTR retries; the only waiter this file needs.
const POLLIN: i16 = 1;
const EINTR: i32 = 4;
#[repr(C)]
struct PollFd {
    fd: c_int,
    events: i16,
    revents: i16,
}
extern "C" {
    fn poll(fds: *mut PollFd, nfds: usize, timeout: c_int) -> c_int;
}

// What an open can end in before any byte moves; flashop maps each to its flashdone err.
pub enum OpenFail {
    Denied,
    Busy,
    Changed,
    Helper(String),
}

// The one-byte answers the helper sends over the socket, with a descriptor only on ok.
const STATUS_OK: u8 = b'O';
const STATUS_DENIED: u8 = b'D';
const STATUS_BUSY: u8 = b'B';
const STATUS_CHANGED: u8 = b'C';

pub fn helper_path() -> String {
    let over = std::env::var("FLEA_UDISKS").unwrap_or_default();
    if over.is_empty() {
        return HELPER_PATH.to_string();
    }
    over
}

// The drives that survive the daemon's own system-disk judgement; a helper that fails leaves all.
pub fn surviving(devs: &[String]) -> Vec<String> {
    let path = helper_path();
    let mut cmd = std::process::Command::new(&path);
    cmd.arg("drives");
    for dev in devs {
        cmd.arg(dev);
    }
    cmd.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::null());
    let Ok(mut child) = cmd.spawn() else { return devs.to_vec() };
    let out = wait_output(&mut child, HELPER_TIMEOUT);
    match out {
        Some(text) => apply_drives(devs, &text),
        None => devs.to_vec(),
    }
}

// Sample input: {"drives":[{"dev":"sda","system":false},{"dev":"nvme0n1","system":true}]} keeps sda.
fn apply_drives(devs: &[String], text: &str) -> Vec<String> {
    let mut system = std::collections::HashSet::new();
    for dev in devs {
        let needle = format!("\"dev\":\"{}\"", dev.replace('"', ""));
        if let Some(at) = text.find(&needle) {
            let tail = &text[at..];
            let end = tail.find('}').map(|i| &tail[..i]).unwrap_or(tail);
            if end.contains("\"system\":true") {
                system.insert(dev.clone());
            }
        }
    }
    devs.iter().filter(|d| !system.contains(*d)).cloned().collect()
}

// Asks polkit first, unmounts, locks, opens, and hands back the exclusive descriptor.
pub fn open_device(dev: &str, serial: &str, bytes: u64) -> Result<OwnedFd, OpenFail> {
    let path = helper_path();
    if !std::path::Path::new(&path).is_file() {
        return Err(OpenFail::Helper(format!("{path} is not installed")));
    }
    let (ours, theirs) = crate::backend::fdpass::pair().map_err(|e| OpenFail::Helper(e.to_string()))?;
    let mut cmd = std::process::Command::new(&path);
    cmd.arg("open").arg(dev).arg(serial).arg(bytes.to_string());
    cmd.stdin(std::process::Stdio::from(theirs)).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| OpenFail::Helper(e.to_string()))?;
    let mut stderr = child.stderr.take();
    let answer = wait_fd(&ours);
    let _ = child.wait();
    let logged = drain(stderr.as_mut());
    match answer {
        Some((STATUS_OK, mut fds)) if !fds.is_empty() => Ok(fds.remove(0)),
        Some((STATUS_DENIED, _)) => {
            eprintln!("flea: the password prompt for /dev/{dev} was dismissed ({logged})");
            Err(OpenFail::Denied)
        }
        Some((STATUS_BUSY, _)) => {
            eprintln!("flea: /dev/{dev} would not unmount ({logged})");
            Err(OpenFail::Busy)
        }
        Some((STATUS_CHANGED, _)) => Err(OpenFail::Changed),
        _ => {
            eprintln!("flea: the udisks helper failed to open /dev/{dev} ({logged})");
            Err(OpenFail::Helper(elide(&logged)))
        }
    }
}

// Unmounts the drive's new volumes, then powers it off; the rail's own verdict still decides.
pub fn eject(dev: &str) -> Result<(), String> {
    let path = helper_path();
    let mut cmd = std::process::Command::new(&path);
    cmd.arg("eject").arg(dev);
    cmd.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::null());
    let mut child = cmd.spawn().map_err(|e| e.to_string())?;
    match wait_output(&mut child, HELPER_TIMEOUT) {
        Some(text) if text.contains("\"ok\":true") => Ok(()),
        Some(text) => Err(parse_eject_err(&text)),
        None => Err("the eject helper did not answer".to_string()),
    }
}

// Sample input: {"ok":false,"err":"busy"} answers busy; anything else is error.
fn parse_eject_err(text: &str) -> String {
    for err in ["busy", "gone", "changed"] {
        if text.contains(&format!("\"err\":\"{err}\"")) {
            return err.to_string();
        }
    }
    "error".to_string()
}

// One elided sentence for the log, never the daemon's whole paragraph.
fn elide(text: &str) -> String {
    const LIMIT: usize = 160;
    let line = text.lines().rfind(|l| !l.trim().is_empty()).unwrap_or_default().trim().to_string();
    if line.len() <= LIMIT {
        return line;
    }
    format!("{}...", &line[..LIMIT])
}

fn drain(pipe: Option<&mut std::process::ChildStderr>) -> String {
    use std::io::Read;
    let mut out = String::new();
    if let Some(pipe) = pipe {
        let mut buf = [0u8; 4096];
        loop {
            match pipe.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => out.push_str(&String::from_utf8_lossy(&buf[..n])),
                Err(_) => break,
            }
        }
    }
    out
}

// A full wait with a deadline for helpers that answer on stdout; None killed the child.
fn wait_output(child: &mut std::process::Child, limit: Duration) -> Option<String> {
    use std::io::Read;
    let mut out = String::new();
    let mut pipe = child.stdout.take();
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait().unwrap_or(None) {
            if let Some(pipe) = pipe.as_mut() {
                let mut rest = Vec::new();
                let _ = pipe.read_to_end(&mut rest);
                out.push_str(&String::from_utf8_lossy(&rest));
            }
            return status.success().then_some(out);
        }
        if started.elapsed() >= limit {
            let _ = child.kill();
            let _ = child.wait();
            return None;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

// The open leg waits on the user's own prompt, so this blocks until the helper answers or dies.
fn wait_fd(sock: &OwnedFd) -> Option<(u8, Vec<OwnedFd>)> {
    let raw = sock.as_raw_fd();
    loop {
        let mut slot = PollFd { fd: raw, events: POLLIN, revents: 0 };
        let ready = unsafe { poll(&mut slot, 1, -1) };
        if ready < 0 && std::io::Error::last_os_error().raw_os_error() == Some(EINTR) {
            continue;
        }
        if ready <= 0 {
            return None;
        }
        match crate::backend::fdpass::recv(raw) {
            Ok(Some(got)) if !got.payload.is_empty() => return Some((got.payload[0], got.fds)),
            Ok(_) => return None,
            Err(_) => return None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_system_drive_leaves_the_list() {
        let devs = vec!["sda".to_string(), "nvme0n1".to_string()];
        let text = r#"{"drives":[{"dev":"sda","system":false},{"dev":"nvme0n1","system":true}]}"#;
        assert_eq!(apply_drives(&devs, text), vec!["sda".to_string()]);
        assert_eq!(apply_drives(&devs, "not json"), devs, "an unreadable answer keeps every drive");
    }

    #[test]
    fn the_eject_error_names_only_the_wire_words() {
        assert_eq!(parse_eject_err(r#"{"ok":false,"err":"busy"}"#), "busy");
        assert_eq!(parse_eject_err(r#"{"ok":false,"err":"gone"}"#), "gone");
        assert_eq!(parse_eject_err(r#"{"ok":false,"err":"changed"}"#), "changed");
        assert_eq!(parse_eject_err(r#"{"ok":false,"err":"weird"}"#), "error");
    }

    #[test]
    fn elision_keeps_the_last_line_short() {
        assert_eq!(elide(""), "");
        assert_eq!(elide("first\nsecond"), "second");
        let long = "x".repeat(200);
        assert!(elide(&long).len() <= 163);
    }

    // F7: no privilege beyond one descriptor, so no flash source may name an escalation tool.
    #[test]
    fn no_flash_source_names_a_privilege_escalation() {
        // Built at runtime, so the needles themselves never trip the scan they run.
        let forbidden = ["su".to_string() + "do", "pk".to_string() + "exec"];
        let sources = [
            "src/backend/flash.rs",
            "src/backend/flasheligible.rs",
            "src/backend/flashhelper.rs",
            "src/backend/flashimage.rs",
            "src/backend/flashop.rs",
            "src/backend/flashpipe.rs",
            "src/backend/flashslot.rs",
            "src/backend/flashverify.rs",
            "src/backend/flashwrite.rs",
            "src/backend/xxh64.rs",
            "tools/flea-udisks",
        ];
        for source in sources {
            let text = std::fs::read_to_string(source).unwrap_or_else(|_| panic!("{source} is read from the tree root"));
            for needle in &forbidden {
                assert!(!text.contains(needle), "{source} names an escalation tool");
            }
        }
    }

    // F10: a localized stderr never changes the outcome; the status byte alone decides it.
    #[test]
    fn a_localized_refusal_still_refuses() {
        let d = crate::backend::testdir::TestDir::new("flashhelper-locale");
        let stub = d.script("stub-udisks", "#!/bin/sh\necho 'el demonio dice que no' >&2\npython3 -c 'import os,socket,sys;s=socket.fromfd(0,socket.AF_UNIX,socket.SOCK_SEQPACKET);s.sendmsg([b\"D\"],[])'\n");
        let before = std::env::var("FLEA_UDISKS").ok();
        std::env::set_var("FLEA_UDISKS", stub.to_string_lossy().to_string());
        let out = open_device("sda", "", 0);
        match before {
            Some(value) => std::env::set_var("FLEA_UDISKS", value),
            None => std::env::remove_var("FLEA_UDISKS"),
        }
        assert!(matches!(out, Err(OpenFail::Denied)), "the D byte refuses whatever language stderr speaks");
    }
}
