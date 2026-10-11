// A cancel that lands on a probe ends extract at that probe's own answer, before any later listing or extraction starts.
use super::*;
use crate::backend::archivework::WORK_PREFIX;
use crate::backend::procwatch;
use crate::backend::testdir::TestDir;
use std::sync::Arc;

fn sh(script: &str) -> Vec<String> {
    vec!["/usr/bin/sh".to_string(), "-c".to_string(), script.to_string()]
}

// Extracts a stub .7z whose probe sleeps until the watcher cancels it; returns the error, the index listings asked for and the sandbox.
fn extract_cancelled_on_the_probe(tag: &str, extract_exit: i32, password: Option<&str>) -> (FleaError, usize, TestDir) {
    let d = TestDir::new(tag);
    let archive = d.file("stub.7z", "x");
    let dest = d.join("out");
    let nonce = format!("rt2-{}-{}", tag, std::process::id());
    // The trailing no-op keeps the shell from exec-ing the sleep away; only the cancel can end the probe early.
    let formats = Formats::test_stub(sh(&format!(": {}; sleep 20; :", nonce)), sh(&format!("exit {}", extract_exit)));
    let cancel = Arc::new(AtomicBool::new(false));
    let watcher = procwatch::cancel_when_sleeping(nonce, Arc::clone(&cancel));
    let err = extract(&formats, &archive, &dest, &cancel, password).expect_err("a cancelled extract is an error");
    assert!(watcher.join().expect("watcher").slept, "the probe never ran, so the cancel did not land on it");
    assert!(!dest.exists(), "a cancelled extract published a destination");
    let litter = std::fs::read_dir(d.path()).unwrap()
        .filter(|entry| entry.as_ref().map(|e| e.file_name().to_string_lossy().starts_with(WORK_PREFIX)).unwrap_or(false))
        .count();
    assert_eq!(litter, 0, "a cancelled extract left its staging directory behind");
    let indexed = formats.indexed();
    (err, indexed, d)
}

// The killed probe's None is no verdict: extract answers cancelled at once and never lists the index for the free-space check.
#[test]
fn a_cancel_during_the_encryption_probe_ends_extract_before_any_index_listing() {
    if crate::backend::sandboxprobe::skipped() { return; }
    let (err, indexed, _d) = extract_cancelled_on_the_probe("archopsprobe", 0, None);
    assert_eq!(err.msg, "cancelled");
    assert_eq!(indexed, 0, "extract went on to list the index after the cancel");
}

// The extract exits 2 and the guarded re-probe is cancelled: the job is cancelled, not the failed extract's own message.
#[test]
fn a_cancel_during_the_wrong_password_probe_answers_cancelled_not_the_extract_failure() {
    if crate::backend::sandboxprobe::skipped() { return; }
    let (err, _indexed, _d) = extract_cancelled_on_the_probe("archopsguard", 2, Some("secret"));
    assert_eq!(err.msg, "cancelled", "the failed extract's message won over the cancel");
}
