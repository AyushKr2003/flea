use super::*;
use crate::backend::testdir::TestDir;
use std::sync::atomic::Ordering;
use std::sync::mpsc::channel;
use std::sync::Arc;

// `7z l -slt` on a content-encrypted .7z, exit 0 (captured on minipc, 7-Zip 26.03).
const CONTENT_ENCRYPTED: &str = "Path = one.7z\nType = 7z\nPhysical Size = 200231\nMethod = LZMA2:18 7zAES\n\n----------\nPath = a.txt\nSize = 5\nPacked Size = 32\nCRC = 5F1E2D3C\nEncrypted = +\nMethod = LZMA2:18 7zAES:19\nBlock = 0\n\nPath = b.bin\nSize = 99\nEncrypted = +\nMethod = LZMA2:18 7zAES:19\n";
// The same listing for a plain archive, exit 0.
const PLAIN: &str = "Path = plain.7z\nType = 7z\nMethod = LZMA2:18\n\n----------\nPath = a.txt\nSize = 5\nEncrypted = -\nMethod = LZMA2:18\n";
// A header-encrypted .7z with stdin closed: exit 255 and no listing at all.
const HEADER_ENCRYPTED: &str = "\nBreak signaled\n\n\nEnter password:";

// The verdict over a whole listing text, the way the streaming scan reads it line by line.
fn listing_encrypted(code: Option<i32>, stdout: &str) -> bool {
    verdict(code, stdout.lines().any(encrypted_key))
}

#[test]
fn a_header_encrypted_archive_is_told_by_the_break_exit() {
    assert!(listing_encrypted(Some(255), HEADER_ENCRYPTED));
    assert!(listing_encrypted(Some(255), ""), "the words are never read, so an empty stdout answers the same");
}

#[test]
fn encrypted_entries_are_told_by_their_technical_key() {
    assert!(listing_encrypted(Some(0), CONTENT_ENCRYPTED));
    assert!(listing_encrypted(Some(0), "Path = a\r\nEncrypted = +\r\n"), "a CRLF listing reads the same");
}

#[test]
fn a_plain_archive_is_never_encrypted() {
    assert!(!listing_encrypted(Some(0), PLAIN));
    assert!(!listing_encrypted(Some(0), ""));
}

// A key past the piece bound is one long line, not a key line; scan() joins pieces first.
#[test]
fn a_key_split_past_the_piece_bound_is_not_a_key_line() {
    let mut name = "y".repeat(LINE_MAX as usize - "Path = ".len());
    name.push_str("Encrypted = +");
    assert!(!scan(std::io::Cursor::new(format!("Path = {}\n", name))));
    assert!(scan(std::io::Cursor::new("Path = a\r\nEncrypted = +\r\n")));
    assert!(scan(std::io::Cursor::new("Path = a\nEncrypted = +")), "a last line with no newline still counts");
}

// The tail of a line past LINE_LIMIT is drained, never read as a fresh line, and the next whole line still counts.
#[test]
fn the_tail_of_a_line_past_the_limit_is_never_a_key_line() {
    let long = format!("Path = {}Encrypted = +\n", "y".repeat(LINE_LIMIT as usize - "Path = ".len()));
    assert!(!scan(std::io::Cursor::new(long.clone())));
    assert!(scan(std::io::Cursor::new(format!("{long}Encrypted = +\n"))), "the whole line after the drained one is read");
}

// A member named like the key is a Path value, and a failed listing proves nothing.
#[test]
fn only_a_key_line_on_a_clean_listing_counts() {
    assert!(!listing_encrypted(Some(0), "Path = Encrypted = +\nEncrypted = -\n"));
    assert!(!listing_encrypted(Some(2), CONTENT_ENCRYPTED), "a corrupt archive is not an encrypted one");
    assert!(!listing_encrypted(None, CONTENT_ENCRYPTED), "a killed probe proves nothing");
}

// The pids whose argv carries the marker, host side: the jail's pid namespace still shows in /proc.
fn pids_with(marker: &str) -> Vec<(i32, Vec<u8>)> {
    let found = std::fs::read_dir("/proc").expect("/proc").flatten().filter_map(|entry| {
        let pid = entry.file_name().to_string_lossy().parse::<i32>().ok()?;
        let cmdline = std::fs::read(entry.path().join("cmdline")).ok()?;
        cmdline.windows(marker.len()).any(|w| w == marker.as_bytes()).then_some((pid, cmdline))
    });
    found.collect()
}

// A shell stub as the listing argv, through the production jail.
fn stub(script: &str) -> Vec<String> {
    vec!["/usr/bin/sh".to_string(), "-c".to_string(), script.to_string()]
}

// The probe still reads its verdict off a stub's exit code and keys while no cancel is set.
#[test]
fn a_probe_with_no_cancel_reads_the_stubs_verdict() {
    if crate::backend::sandboxprobe::skipped() { return; }
    let d = TestDir::new("archencverdict");
    let archive = d.file("stub.7z", "x");
    let cancel = AtomicBool::new(false);
    assert_eq!(probe(&stub("exit 255"), &archive, &cancel), Some(true), "the break exit asks for a password");
    assert_eq!(probe(&stub("echo 'Encrypted = +'"), &archive, &cancel), Some(true));
    assert_eq!(probe(&stub("echo 'Encrypted = -'"), &archive, &cancel), Some(false));
}

// A cancel during a slow listing returns within a poll or so, not at the read deadline, and kills and reaps the whole tree.
#[test]
fn a_cancel_during_the_probe_kills_and_reaps_the_child_within_one_poll() {
    if crate::backend::sandboxprobe::skipped() { return; }
    let d = TestDir::new("archenccancel");
    let archive = d.file("stub.7z", "x");
    let nonce = format!("rt2-stub-{}", std::process::id());
    // Sleeps past ARCHIVE_READ_MS, so only a cancel can end it early; the trailing no-op keeps the shell from exec-ing the sleep away.
    let inner = stub(&format!(": {}; sleep 20; :", nonce));
    let cancel = Arc::new(AtomicBool::new(false));
    let (flag, marker) = (Arc::clone(&cancel), nonce.clone());
    let (tx, rx) = channel();
    let observer = std::thread::spawn(move || {
        // The stub is up once its shell shows; a stub that never starts is cancelled after this bound anyway.
        let bound = Instant::now() + Duration::from_secs(10);
        let mut seen: Vec<i32> = Vec::new();
        loop {
            let now = pids_with(&marker);
            for (pid, _) in &now {
                if !seen.contains(pid) {
                    seen.push(*pid);
                }
            }
            if Instant::now() >= bound || now.iter().any(|(_, argv)| argv.starts_with(b"/usr/bin/sh\0")) {
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        flag.store(true, Ordering::Relaxed);
        tx.send((Instant::now(), seen)).ok();
    });
    let verdict = probe(&inner, &archive, &cancel);
    let returned = Instant::now();
    observer.join().expect("observer");
    let (cancelled_at, pids) = rx.recv().expect("the observer reported");
    assert_eq!(verdict, None, "a cancelled probe proves nothing");
    assert!(!pids.is_empty(), "the stub never started, so nothing was proved");
    let late = returned.saturating_duration_since(cancelled_at);
    assert!(late < POLL * 10, "the cancel was seen {:?} late, which is the read deadline and not a poll", late);
    for pid in &pids {
        assert!(!Path::new(&format!("/proc/{}", pid)).exists(), "pid {} was left running or unreaped", pid);
    }
    assert!(pids_with(&nonce).is_empty(), "a cancelled probe left its child running");
}
