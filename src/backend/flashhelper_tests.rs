// The helper client against stub helpers: the real answer shapes, the refusals and the waits that must end.
use super::*;
use crate::backend::flashfake::{LOOP_ENV, LOOP_ENV_GUARD};
use crate::backend::testdir::TestDir;
use std::sync::mpsc::channel;

// A stub that waits longer than any test lets it, to prove the bound and the kill.
const LONG_WAIT: &str = "60";
// A bound short enough for a test and long enough for python to start.
const SHORT_LIMIT: Duration = Duration::from_millis(400);
// What a test allows an open that must end on its own.
const ENDS_BY: Duration = Duration::from_secs(8);

// Sample shape: python3's json.dumps prints ", " and ": " between its tokens, which is what the helper printed.
const SPACED: &str = r#"{"drives": [{"dev": "nvme0n1", "system": true}, {"dev": "sda", "system": false}]}"#;

fn devs() -> Vec<String> {
    vec!["sda".to_string(), "nvme0n1".to_string()]
}

fn printing(d: &TestDir, name: &str, text: &str) -> String {
    d.script(name, &format!("#!/bin/sh\nprintf '%s' '{text}'\n")).to_string_lossy().to_string()
}

#[test]
fn only_a_system_drive_leaves_the_list() {
    let compact = r#"{"drives":[{"dev":"sda","system":false},{"dev":"nvme0n1","system":true}]}"#;
    assert_eq!(apply_drives(&devs(), compact), vec!["sda".to_string()]);
    assert_eq!(apply_drives(&devs(), SPACED), vec!["sda".to_string()], "the shape python prints parses the same");
    assert_eq!(apply_drives(&devs(), "not json"), devs(), "an unreadable answer keeps every drive");
    assert_eq!(apply_drives(&devs(), r#"{"drives": []}"#), devs(), "the list keeps a drive the helper never named");
}

// C16: layer 2 fails closed at flash time, so only a positive answer for this exact drive passes.
#[test]
fn a_flash_needs_a_positive_answer_for_its_own_drive() {
    let d = TestDir::new("flashhelper-confirm");
    let named = printing(&d, "named", SPACED);
    assert!(confirm_at(&named, "sda", HELPER_TIMEOUT), "sda is present and not a system disk");
    assert!(!confirm_at(&named, "nvme0n1", HELPER_TIMEOUT), "the daemon calls nvme0n1 a system disk");
    assert!(!confirm_at(&named, "sdb", HELPER_TIMEOUT), "a drive the helper did not name is not confirmed");
    let empty = printing(&d, "empty", r#"{"drives": []}"#);
    assert!(!confirm_at(&empty, "sda", HELPER_TIMEOUT), "an empty answer is no confirmation");
    let silent = d.script("silent", &format!("#!/bin/sh\nexec sleep {LONG_WAIT}\n")).to_string_lossy().to_string();
    assert!(!confirm_at(&silent, "sda", SHORT_LIMIT), "a helper that times out is no confirmation");
    assert!(!confirm_at("/nonexistent-helper", "sda", HELPER_TIMEOUT), "a helper that is missing is no confirmation");
    let broken = printing(&d, "broken", "not json");
    assert!(!confirm_at(&broken, "sda", HELPER_TIMEOUT), "an unreadable answer is no confirmation");
}

// C5: the eject answer in the shape python prints, with ": " after each key.
#[test]
fn the_eject_answer_is_read_in_the_shape_the_helper_prints() {
    assert_eq!(parse_eject(r#"{"ok": true}"#), Ok(()));
    assert_eq!(parse_eject(r#"{"ok":true}"#), Ok(()));
    assert_eq!(parse_eject(r#"{"ok": false, "err": "busy"}"#), Err("busy".to_string()));
    assert_eq!(parse_eject(r#"{"ok": false, "err": "gone"}"#), Err("gone".to_string()));
    assert_eq!(parse_eject(r#"{"ok": false, "err": "changed"}"#), Err("changed".to_string()));
    assert_eq!(parse_eject(r#"{"ok": false, "err": "weird"}"#), Err("error".to_string()));
    assert_eq!(parse_eject("garbage"), Err("error".to_string()));
    let d = TestDir::new("flashhelper-eject");
    let stub = printing(&d, "eject", r#"{"ok": true}"#);
    assert_eq!(eject_at(&stub, "sda", HELPER_TIMEOUT), Ok(()), "the printed shape ejects");
}

// C15: a cut on a byte index inside a two-byte character panics, so the cut moves to a boundary.
#[test]
fn elision_keeps_the_last_line_short_and_whole() {
    assert_eq!(elide(""), "");
    assert_eq!(elide("first\nsecond"), "second");
    let long = "x".repeat(200);
    assert!(elide(&long).len() <= ELIDE_BYTES + 3);
    let straddle = format!("{}é{}", "x".repeat(ELIDE_BYTES - 1), "y".repeat(40));
    assert_eq!(straddle.len(), ELIDE_BYTES + 41, "the two-byte character spans byte {ELIDE_BYTES}");
    let cut = elide(&straddle);
    assert!(cut.ends_with("..."), "{cut}");
    assert_eq!(cut.trim_end_matches("..."), "x".repeat(ELIDE_BYTES - 1), "the cut stops before the character it would split");
}

// F7: no privilege beyond one descriptor, so no flash source may name an escalation tool.
#[test]
fn no_flash_source_names_a_privilege_escalation() {
    // Built at runtime, so the needles themselves never trip the scan they run.
    let forbidden = ["su".to_string() + "do", "pk".to_string() + "exec"];
    let sources = [
        "src/backend/flash.rs",
        "src/backend/flashdesc.rs",
        "src/backend/flasheject.rs",
        "src/backend/flasheligible.rs",
        "src/backend/flashhelper.rs",
        "src/backend/flashimage.rs",
        "src/backend/flashmeter.rs",
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
    let d = TestDir::new("flashhelper-locale");
    let stub = d.script("stub-udisks", "#!/bin/sh\necho 'el demonio dice que no' >&2\nexec python3 -c 'import socket;s=socket.fromfd(0,socket.AF_UNIX,socket.SOCK_SEQPACKET);s.sendmsg([b\"D\"],[])'\n");
    let out = open_device_at(&stub.to_string_lossy(), "sda", "", 0, &mut || {}, ENDS_BY);
    assert!(matches!(out, Err(OpenFail::Denied)), "the D byte refuses whatever language stderr speaks");
}

#[test]
fn the_open_hands_back_the_descriptor_the_helper_sends() {
    let d = TestDir::new("flashhelper-fd");
    let file = d.file("target.img", "hello");
    let body = format!("#!/bin/sh\nexec python3 -c 'import socket;s=socket.fromfd(0,socket.AF_UNIX,socket.SOCK_SEQPACKET);f=open(\"{}\",\"rb\");socket.send_fds(s,[b\"O\"],[f.fileno()])'\n", file.display());
    let stub = d.script("fd-udisks", &body);
    let mut spawned = 0;
    let out = open_device_at(&stub.to_string_lossy(), "sda", "", 0, &mut || spawned += 1, ENDS_BY);
    let fd = match out { Ok(fd) => fd, Err(_) => panic!("the helper sent a descriptor") };
    use std::io::Read;
    let mut text = String::new();
    std::fs::File::from(fd).read_to_string(&mut text).unwrap();
    assert_eq!(text, "hello");
    assert_eq!(spawned, 1, "the spawned hook runs once, after the helper is up");
}

// C8: a helper that dies without answering hangs the socket up, and one that never answers is cut at the bound.
#[test]
fn an_open_ends_when_the_helper_dies_or_never_answers() {
    let d = TestDir::new("flashhelper-dies");
    let dies = d.script("dies", "#!/bin/sh\nexit 3\n").to_string_lossy().to_string();
    let (tx, rx) = channel();
    std::thread::spawn(move || {
        let _ = tx.send(matches!(open_device_at(&dies, "sda", "", 0, &mut || {}, OPEN_TIMEOUT), Err(OpenFail::Helper(_))));
    });
    assert_eq!(rx.recv_timeout(ENDS_BY), Ok(true), "a helper that exits unanswered ends the wait at once, not at the prompt's bound");
    let sleeps = d.script("sleeps", &format!("#!/bin/sh\nexec sleep {LONG_WAIT}\n")).to_string_lossy().to_string();
    let started = Instant::now();
    let out = open_device_at(&sleeps, "sda", "", 0, &mut || {}, SHORT_LIMIT);
    assert!(matches!(out, Err(OpenFail::Helper(_))), "a helper that never answers is a helper failure");
    assert!(started.elapsed() < ENDS_BY, "the wait ended at its bound");
}

#[test]
fn a_missing_helper_never_runs_the_spawned_hook() {
    let mut spawned = 0;
    let out = open_device_at("/nonexistent-helper", "sda", "", 0, &mut || spawned += 1, SHORT_LIMIT);
    assert!(matches!(out, Err(OpenFail::Helper(_))));
    assert_eq!(spawned, 0);
}

// A stub that records its arguments, one per line, in a file beside it.
fn recording(d: &TestDir) -> (String, std::path::PathBuf) {
    let log = d.join("args.txt");
    let body = format!("#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\" >> '{}'; done\nprintf '%s' '{{\"drives\":[]}}'\n", log.display());
    (d.script("recorder", &body).to_string_lossy().to_string(), log)
}

#[test]
fn a_default_build_passes_the_helper_no_bench_root() {
    let _guard = LOOP_ENV_GUARD.lock().unwrap();
    let d = TestDir::new("flashhelper-noseam");
    let (stub, log) = recording(&d);
    std::env::set_var(LOOP_ENV, d.path());
    let _ = drives_text(&stub, &devs(), HELPER_TIMEOUT);
    std::env::remove_var(LOOP_ENV);
    let args = std::fs::read_to_string(&log).unwrap_or_default();
    assert_eq!(args.lines().collect::<Vec<_>>().contains(&"--loop-root"), cfg!(feature = "flash-test-seam"), "only the bench feature forwards its root: {args}");
}

// C10: the seam tells the helper its root, so a loop inside it is not called a system disk.
#[cfg(feature = "flash-test-seam")]
#[test]
fn the_seam_tells_the_helper_its_root() {
    let _guard = LOOP_ENV_GUARD.lock().unwrap();
    let d = TestDir::new("flashhelper-seam");
    let (stub, log) = recording(&d);
    std::env::set_var(LOOP_ENV, d.path());
    let _ = drives_text(&stub, &devs(), HELPER_TIMEOUT);
    std::env::remove_var(LOOP_ENV);
    let args: Vec<String> = std::fs::read_to_string(&log).unwrap().lines().map(str::to_string).collect();
    assert_eq!(args, ["drives", "--loop-root", &d.path().to_string_lossy(), "sda", "nvme0n1"]);
}
