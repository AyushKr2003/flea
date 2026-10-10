// The settags request's tests, beside it so tagsreq.rs stays under the file budget.
use super::*;
use crate::backend::dirsizeworker::Worker;
use crate::backend::testdir::TestDir;
use std::sync::mpsc::channel;

fn state_for(base: &Path) -> State {
    let (tx, _rx) = channel();
    let mut st = State::new(Worker::new(tx));
    st.base = base.to_path_buf();
    st
}

fn ops() -> crate::backend::opsdispatch::Ops {
    let (tx, _rx) = channel();
    crate::backend::opsdispatch::Ops::new(tx)
}

#[test]
fn a_write_changes_every_file_and_journals_each_previous_attribute() {
    let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let d = TestDir::new("tagsreqwrite");
    let _first = d.file("a.txt", "body");
    let _second = d.file("b.txt", "body");
    let mut st = state_for(d.path());
    st.listing.push("a.txt", false);
    st.listing.push("b.txt", false);
    let mut o = ops();
    let mut out = Vec::new();
    apply_tags(&mut out, &mut o, &st, vec![0, 1], "add", "Red");
    assert_eq!(String::from_utf8(out).unwrap(), settagged_line(2) + "\n");
    assert_eq!(crate::backend::tags::read(&d.join("a.txt")).unwrap(), vec!["Red"]);
    assert_eq!(o.journal.len(), 1);
    let mut out = Vec::new();
    crate::backend::opsdispatch::do_undo(&mut out, &mut o);
    assert_eq!(crate::backend::tags::read(&d.join("a.txt")).unwrap(), Vec::<String>::new());
    assert_eq!(crate::backend::tags::read(&d.join("b.txt")).unwrap(), Vec::<String>::new());
}

#[test]
fn a_redo_reapplies_what_undo_took_back() {
    let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let d = TestDir::new("tagsreqredo");
    let _file = d.file("a.txt", "body");
    let mut st = state_for(d.path());
    st.listing.push("a.txt", false);
    let mut o = ops();
    let mut out = Vec::new();
    apply_tags(&mut out, &mut o, &st, vec![0], "add", "Green");
    crate::backend::opsdispatch::do_undo(&mut out, &mut o);
    assert_eq!(crate::backend::tags::read(&d.join("a.txt")).unwrap(), Vec::<String>::new());
    let (tx, _rx) = channel();
    o.journal.redo(1, &std::sync::atomic::AtomicBool::new(false), &tx).expect("redo reapplies");
    assert_eq!(crate::backend::tags::read(&d.join("a.txt")).unwrap(), vec!["Green"]);
}

#[test]
fn a_file_that_vanished_refuses_all_and_writes_nothing() {
    let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let d = TestDir::new("tagsreqgone");
    let _first = d.file("a.txt", "body");
    let gone = d.file("gone.txt", "body");
    std::fs::remove_file(&gone).unwrap();
    let mut st = state_for(d.path());
    st.listing.push("a.txt", false);
    st.listing.push("gone.txt", false);
    let mut o = ops();
    let mut out = Vec::new();
    apply_tags(&mut out, &mut o, &st, vec![0, 1], "add", "Red");
    let line = String::from_utf8(out).unwrap();
    assert!(line.contains(r#""where":"settags""#), "{}", line);
    assert_eq!(crate::backend::tags::read(&d.join("a.txt")).unwrap(), Vec::<String>::new());
    assert_eq!(o.journal.len(), 0);
}

#[test]
fn an_unsupported_filesystem_refuses_before_anything_is_written() {
    let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let d = TestDir::new("tagsreqrefuse");
    let _first = d.file("a.txt", "body");
    let mut st = state_for(d.path());
    st.listing.push("a.txt", false);
    crate::backend::tags::FORCE_UNSUPPORTED.with(|f| f.set(true));
    let mut o = ops();
    let mut out = Vec::new();
    apply_tags(&mut out, &mut o, &st, vec![0], "add", "Red");
    crate::backend::tags::FORCE_UNSUPPORTED.with(|f| f.set(false));
    let line = String::from_utf8(out).unwrap();
    assert!(line.contains(r#""where":"settags""#), "{}", line);
    assert!(line.contains("nothing was changed"), "{}", line);
    assert_eq!(crate::backend::tags::read(&d.join("a.txt")).unwrap(), Vec::<String>::new());
    assert_eq!(o.journal.len(), 0);
}

#[test]
fn a_noop_change_answers_success_and_records_nothing() {
    let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let d = TestDir::new("tagsreqnoop");
    let _file = d.file("a.txt", "body");
    let mut st = state_for(d.path());
    st.listing.push("a.txt", false);
    let mut o = ops();
    let mut out = Vec::new();
    apply_tags(&mut out, &mut o, &st, vec![0], "remove", "Red");
    assert_eq!(String::from_utf8(out).unwrap(), settagged_line(0) + "\n");
    assert_eq!(o.journal.len(), 0, "an operation that changed nothing records nothing");
}

#[test]
fn a_stale_numbering_is_refused_before_anything_resolves() {
    let line = r#"{"c":"settags","rows":[0],"op":"add","tag":"Red","listing":1}"#;
    let refused = crate::backend::rowguard::refusal(line, 2).expect("a stale settags is refused");
    assert!(refused.contains(r#""where":"stale""#), "{}", refused);
}

#[test]
fn a_failed_write_after_an_unchanged_file_puts_back_every_file_it_wrote() {
    let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let d = TestDir::new("tagsreqrollback");
    let already = d.file("a.txt", "body");
    let _plain = d.file("b.txt", "body");
    crate::backend::tags::write_names(&already, &["Red".to_string()]).unwrap();
    // A symlink reads as untagged but refuses a user attribute, even for root, so the third write fails.
    std::os::unix::fs::symlink(d.join("b.txt"), d.join("c.lnk")).unwrap();
    let mut st = state_for(d.path());
    for name in ["a.txt", "b.txt", "c.lnk"] {
        st.listing.push(name, false);
    }
    let mut o = ops();
    let mut out = Vec::new();
    apply_tags(&mut out, &mut o, &st, vec![0, 1, 2], "add", "Red");
    let line = String::from_utf8(out).unwrap();
    assert!(line.contains(r#""where":"settags""#), "{}", line);
    assert_eq!(crate::backend::tags::read(&d.join("b.txt")).unwrap(), Vec::<String>::new(), "the written file was put back");
    assert_eq!(crate::backend::tags::read(&already).unwrap(), vec!["Red"], "the unchanged file kept its own tag");
    assert_eq!(o.journal.len(), 0);
}

#[test]
fn undo_leaves_a_file_whose_tags_changed_since_and_restores_the_rest() {
    let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let d = TestDir::new("tagsundochanged");
    let first = d.file("a.txt", "body");
    let second = d.file("b.txt", "body");
    let mut st = state_for(d.path());
    st.listing.push("a.txt", false);
    st.listing.push("b.txt", false);
    let mut o = ops();
    let mut out = Vec::new();
    apply_tags(&mut out, &mut o, &st, vec![0, 1], "add", "Red");
    crate::backend::tags::write_names(&first, &["Blue".to_string()]).unwrap();
    let mut out = Vec::new();
    crate::backend::opsdispatch::do_undo(&mut out, &mut o);
    let line = String::from_utf8(out).unwrap();
    assert!(line.contains(r#""t":"error""#) && line.contains("left in place"), "{}", line);
    assert_eq!(crate::backend::tags::read(&first).unwrap(), vec!["Blue"], "a newer change survives undo");
    assert_eq!(crate::backend::tags::read(&second).unwrap(), Vec::<String>::new(), "the untouched file is restored");
}

#[test]
fn undo_leaves_a_file_replaced_by_another_carrying_the_same_tags() {
    let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let d = TestDir::new("tagsundoreplaced");
    let file = d.file("a.txt", "body");
    let mut st = state_for(d.path());
    st.listing.push("a.txt", false);
    let mut o = ops();
    let mut out = Vec::new();
    apply_tags(&mut out, &mut o, &st, vec![0], "add", "Red");
    // Both files exist at once, so the replacement cannot reuse the old inode on any filesystem.
    let other = d.file("a.new", "other");
    crate::backend::tags::write_names(&other, &["Red".to_string()]).unwrap();
    std::fs::rename(&other, &file).unwrap();
    let mut out = Vec::new();
    crate::backend::opsdispatch::do_undo(&mut out, &mut o);
    let line = String::from_utf8(out).unwrap();
    assert!(line.contains(r#""t":"error""#) && line.contains("left in place"), "{}", line);
    assert_eq!(crate::backend::tags::read(&file).unwrap(), vec!["Red"], "the replacement keeps its own tags");
}

#[test]
fn every_filesystem_the_targets_sit_on_is_probed_before_any_write() {
    let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let d = TestDir::new("tagsreqmixed");
    let _first = d.file("a.txt", "body");
    let mut st = state_for(d.path());
    st.listing.push("a.txt", false);
    // An absolute name joins as itself, as a search row under another mount does; procfs refuses user attributes.
    st.listing.push("/proc/self/status", false);
    let mut o = ops();
    let mut out = Vec::new();
    apply_tags(&mut out, &mut o, &st, vec![0, 1], "add", "Red");
    let line = String::from_utf8(out).unwrap();
    assert!(line.contains("does not support file tags"), "the second filesystem refuses by name: {}", line);
    assert_eq!(crate::backend::tags::read(&d.join("a.txt")).unwrap(), Vec::<String>::new());
    assert_eq!(o.journal.len(), 0);
}

// The fake table maps the sandbox onto an nfs mount, so the write decision reads it as remote.
fn remote_body(dir: &Path) -> String {
    format!("1 0 8:1 / / rw - ext4 /dev/a rw\n30 1 0:45 / {} rw - nfs n:/s rw\n", dir.to_string_lossy())
}

#[test]
fn a_remote_tag_change_goes_through_the_slow_write_bound() {
    let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    crate::backend::iomount::test_reset();
    let d = TestDir::new("tagsreqremote");
    let file = d.file("a.txt", "body");
    let _body = crate::backend::iomount::test_hold_body(remote_body(d.path()));
    let mut st = state_for(d.path());
    st.listing.push("a.txt", false);
    let mut o = ops();
    let mut out = Vec::new();
    apply_tags(&mut out, &mut o, &st, vec![0], "add", "Red");
    assert_eq!(String::from_utf8(out).unwrap(), settagged_line(1) + "\n");
    assert!(crate::backend::iomount::test_calls() >= 1, "a remote write takes the bound rename and mkdir take");
    assert_eq!(crate::backend::tags::read(&file).unwrap(), vec!["Red"]);
    assert_eq!(o.journal.len(), 1);
}

#[test]
fn a_held_remote_tag_change_answers_slow_then_journals_when_it_lands() {
    let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let d = TestDir::new("tagsreqslow");
    let file = d.file("a.txt", "body");
    let _body = crate::backend::iomount::test_hold_body(remote_body(d.path()));
    let (tx, rx) = channel();
    let mut o = crate::backend::opsdispatch::Ops::new(tx);
    let (release, wait) = channel::<()>();
    let paths = vec![file.clone()];
    let held = paths.clone();
    let mut out = Vec::new();
    // The worker writes only after the test releases it, so the loop answers at the deadline first.
    apply_tags_with(&mut out, &mut o, paths, std::time::Duration::from_millis(50), move || {
        let _ = wait.recv();
        write_all(&held, "add", "Red")
    });
    let line = String::from_utf8(std::mem::take(&mut out)).unwrap();
    assert!(line.contains(r#""t":"slow""#) && line.contains(r#""op":"settags""#), "{}", line);
    assert!(line.contains("The tag change continues"), "{}", line);
    crate::backend::opsdispatch::do_undo(&mut out, &mut o);
    assert!(String::from_utf8(std::mem::take(&mut out)).unwrap().contains("already running"), "undo waits for the late entry");
    assert_eq!(o.journal.len(), 0, "nothing is journalled until the held write lands");
    drop(release);
    let landed = rx.recv_timeout(std::time::Duration::from_secs(5)).expect("the released write reports through the op channel");
    crate::backend::opsdispatch::report_op(&mut out, &mut o, landed);
    assert_eq!(String::from_utf8(std::mem::take(&mut out)).unwrap(), settagged_line(1) + "\n");
    assert!(o.pending.is_empty(), "the late reply clears its own pending entry");
    assert_eq!(o.journal.len(), 1);
    crate::backend::opsdispatch::do_undo(&mut out, &mut o);
    assert!(String::from_utf8(out).unwrap().contains(r#"{"t":"undone","op":"settags","ok":true}"#));
    assert_eq!(crate::backend::tags::read(&file).unwrap(), Vec::<String>::new());
}

#[test]
fn redo_skips_a_file_retagged_since_undo_and_refuses_a_replaced_one() {
    let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let d = TestDir::new("tagsredochanged");
    let file = d.file("a.txt", "body");
    let mut st = state_for(d.path());
    st.listing.push("a.txt", false);
    let (tx, _rx) = channel();
    let stop = std::sync::atomic::AtomicBool::new(false);
    let mut o = ops();
    let mut out = Vec::new();
    apply_tags(&mut out, &mut o, &st, vec![0], "add", "Red");
    crate::backend::opsdispatch::do_undo(&mut out, &mut o);
    crate::backend::tags::write_names(&file, &["Blue".to_string()]).unwrap();
    let skipped = o.journal.redo(1, &stop, &tx).expect_err("a retagged file is not overwritten");
    assert!(skipped.msg.contains("left in place"), "{}", skipped.msg);
    assert_eq!(crate::backend::tags::read(&file).unwrap(), vec!["Blue"]);
    // A second file in the same entry pins the whole-redo refusal apart from a per-file skip.
    let second = d.file("b.txt", "second");
    st.listing.push("b.txt", false);
    let mut o = ops();
    apply_tags(&mut out, &mut o, &st, vec![0, 1], "add", "Red");
    crate::backend::opsdispatch::do_undo(&mut out, &mut o);
    let other = d.file("a.new", "other body");
    std::fs::rename(&other, &file).unwrap();
    let refused = o.journal.redo(1, &stop, &tx).expect_err("a replaced file refuses the redo");
    assert!(refused.msg.contains("replaced"), "{}", refused.msg);
    assert_eq!(crate::backend::tags::read(&file).unwrap(), Vec::<String>::new());
    assert_eq!(crate::backend::tags::read(&second).unwrap(), Vec::<String>::new(), "the refusal leaves every file of the entry as undo left it");
}
