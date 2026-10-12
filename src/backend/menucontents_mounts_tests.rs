// A folder holding a remote mount walks under the bulk deadline and shares iomount's stuck table.
use super::tests::{lines, tree};
use super::*;
use crate::json::{field_bool, field_usize as number};
use std::fs;
use std::path::Path;
use std::time::{Duration, Instant};

// The sandbox is local and holds an nfs mount point at `mnt`, as /run/user/1000 holds the gvfs mount.
fn nested_remote_body(root: &Path) -> String {
    format!("1 0 8:1 / / rw - ext4 /dev/a rw\n30 1 0:45 / {}/mnt rw - nfs n:/s rw\n", root.display())
}

#[test]
fn a_local_folder_holding_a_remote_mount_takes_the_deadline_path_and_one_without_stays_inline() {
    let (_sandbox, root) = tree("contents-nested-remote");
    for n in 0..16 { fs::write(root.join(format!("f{}", n)), "x").unwrap(); }
    fs::create_dir(root.join("mnt")).unwrap();
    let _pace = test_hold_pace(Duration::from_millis(25));
    let run = |body: String| {
        let _body = crate::backend::iomount::test_hold_body(body);
        let cancel = Cancellation::default().next();
        let (tx, rx) = std::sync::mpsc::channel();
        let items = [Selected::inspect(&root.to_string_lossy()).unwrap()];
        let line = r#"{"c":"menuaction","op":"contents","id":4}"#.to_string();
        let started = Instant::now();
        assert!(serve_with_deadline(&line, 4, &items, &tx, &cancel, Duration::from_millis(50)));
        (lines(&rx), started.elapsed())
    };
    let (sent, took) = run(nested_remote_body(&root));
    assert!(took < Duration::from_millis(300), "the deadline bounds a walk that reads a remote mount point: {:?}", took);
    assert!(field_bool(&sent[0], "done") && field_bool(&sent[0], "partial"), "{}", sent[0]);
    let (sent, took) = run("1 0 8:1 / / rw - ext4 /dev/a rw\n".to_string());
    assert!(took >= Duration::from_millis(300), "a folder with no remote mount walks inline, unbounded: {:?}", took);
    let last = sent.last().unwrap();
    assert!(field_bool(last, "done") && !field_bool(last, "partial"), "{}", last);
}

#[test]
fn a_mount_in_the_stuck_table_answers_the_floor_at_once_without_a_walk() {
    let (_sandbox, root) = tree("contents-stuck-answers");
    for n in 0..16 { fs::write(root.join(format!("f{}", n)), "x").unwrap(); }
    fs::create_dir(root.join("mnt")).unwrap();
    let _body = crate::backend::iomount::test_hold_body(nested_remote_body(&root));
    let _stuck = crate::backend::iomount::test_hold_stuck(root.join("mnt"));
    let _pace = test_hold_pace(Duration::from_millis(500));
    let cancel = Cancellation::default().next();
    let (tx, rx) = std::sync::mpsc::channel();
    let items = [Selected::inspect(&root.to_string_lossy()).unwrap()];
    let line = r#"{"c":"menuaction","op":"contents","id":4}"#.to_string();
    let started = Instant::now();
    assert!(serve_with_deadline(&line, 4, &items, &tx, &cancel, Duration::from_secs(5)));
    assert!(started.elapsed() < Duration::from_millis(200), "no walk and no wait: {:?}", started.elapsed());
    let sent = lines(&rx);
    assert_eq!(sent.len(), 1, "{:?}", sent);
    assert!(field_bool(&sent[0], "ok") && field_bool(&sent[0], "done") && field_bool(&sent[0], "partial"), "{}", sent[0]);
    assert_eq!((number(&sent[0], "items"), number(&sent[0], "bytes")), (Some(0), Some(0)), "{}", sent[0]);
}

#[test]
fn a_walk_past_its_deadline_answers_partial_and_marks_no_mount_so_a_repeat_walks_again() {
    let (_sandbox, root) = tree("contents-deadline-marks-nothing");
    for n in 0..16 { fs::write(root.join(format!("f{}", n)), "x").unwrap(); }
    let mounts = [root.join("mnt")];
    let _body = crate::backend::iomount::test_hold_body(nested_remote_body(&root));
    let _pace = test_hold_pace(Duration::from_millis(25));
    let run = || {
        let cancel = Cancellation::default().next();
        let (tx, rx) = std::sync::mpsc::channel();
        let items = [Selected::inspect(&root.to_string_lossy()).unwrap()];
        let line = r#"{"c":"menuaction","op":"contents","id":4}"#.to_string();
        let started = Instant::now();
        assert!(serve_with_deadline(&line, 4, &items, &tx, &cancel, Duration::from_millis(50)));
        (lines(&rx), started.elapsed())
    };
    let (first, _) = run();
    assert!(field_bool(&first[0], "done") && field_bool(&first[0], "partial"), "{}", first[0]);
    assert!(crate::backend::walkmounts::stuck_among(&mounts).is_none(), "local walk time marks a healthy remote mount stuck");
    let (again, took) = run();
    assert!(took >= Duration::from_millis(50), "the repeat answers a cached zero instead of walking: {:?}", took);
    assert!(field_bool(&again[0], "done") && field_bool(&again[0], "partial"), "{}", again[0]);
}
