// A copy onto a drive that cannot hold some items lands every other item and names each one it could not hold.
use crate::backend::copyfile::{move_cross_device, test_set_precheck, Progress};
use crate::backend::opsreq::{run_transfer, OpMsg};
use crate::backend::testdir::TestDir;
use crate::backend::undo::{Entry, Journal, Step};
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::sync::mpsc::channel;
use std::sync::Arc;

const EPERM: i32 = 1;
const EEXIST: i32 = 17;
const EINVAL: i32 = 22;
const EOPNOTSUPP: i32 = 95;

// The FAT model every case here shares: symlink(2) answers EPERM and the destination reads as vfat.
fn fat(on: bool) {
    super::test_force_linkless(on);
}

// Sample tree: a.txt, link-file -> a.txt, sub/b.txt, sub/link-dir -> ../deep, deep/c.txt, broken -> missing, z.txt.
fn tree_with_links(d: &TestDir) -> PathBuf {
    let tree = d.dir("tree");
    std::fs::write(tree.join("a.txt"), "a").unwrap();
    std::fs::create_dir(tree.join("sub")).unwrap();
    std::fs::write(tree.join("sub/b.txt"), "b").unwrap();
    std::fs::create_dir(tree.join("deep")).unwrap();
    std::fs::write(tree.join("deep/c.txt"), "c").unwrap();
    std::fs::write(tree.join("z.txt"), "z").unwrap();
    std::os::unix::fs::symlink("a.txt", tree.join("link-file")).unwrap();
    std::os::unix::fs::symlink("../deep", tree.join("sub/link-dir")).unwrap();
    std::os::unix::fs::symlink("missing", tree.join("broken")).unwrap();
    tree
}

// Every plain file the tree holds, so a walk that stopped early leaves one of these missing.
fn assert_every_file_landed(out: &Path) {
    for (rel, body) in [("a.txt", "a"), ("sub/b.txt", "b"), ("deep/c.txt", "c"), ("z.txt", "z")] {
        assert_eq!(std::fs::read_to_string(out.join(rel)).ok().as_deref(), Some(body), "{rel} must land past every refused item");
    }
}

fn assert_no_link_landed(out: &Path) {
    for rel in ["link-file", "sub/link-dir", "broken"] {
        assert!(out.join(rel).symlink_metadata().is_err(), "{rel} cannot exist on a drive that holds no links");
    }
}

// The item lines and the done line one transfer sends, read off the channel the loop reads.
fn transferred(src: &Path, dest: &Path) -> (Vec<(String, bool, String)>, usize, usize, Entry) {
    let (tx, rx) = channel();
    run_transfer(1, false, vec![src.to_string_lossy().to_string()], dest.to_path_buf(), Arc::new(AtomicBool::new(false)), tx);
    let (mut items, mut done) = (Vec::new(), None);
    for msg in rx.iter() {
        match msg {
            OpMsg::Item { name, ok, err, .. } => items.push((name, ok, err)),
            OpMsg::TransferDone { ok, failed, entry, .. } => done = Some((ok, failed, entry)),
            _ => {}
        }
    }
    let (ok, failed, entry) = done.expect("a done line");
    (items, ok, failed, entry)
}

#[test]
fn a_copy_onto_a_drive_without_links_lands_every_other_item_and_names_the_links() {
    let d = TestDir::new("unheldlinks");
    let src = tree_with_links(&d);
    let dest = d.dir("out");
    fat(true);
    let (items, ok, failed, entry) = transferred(&src, &dest);
    fat(false);
    let out = dest.join("tree");
    assert_every_file_landed(&out);
    assert_no_link_landed(&out);
    assert_eq!((ok, failed), (0, 1), "a folder that could not land whole is a failed item, never a silent success");
    let (name, item_ok, err) = &items[0];
    assert!(name == "tree" && !item_ok, "the folder's own line fails: {items:?}");
    assert!(err.starts_with("3 items inside could not be copied; the first is ") && err.ends_with(": this drive cannot hold links"),
        "the item names how many it could not hold and the first of them: {err}");
    assert!(["link-file", "sub/link-dir", "broken"].iter().any(|rel| err.contains(&format!(" {rel}: "))), "the first one is named by its path: {err}");
    assert!(matches!(&entry.steps[..], [Step::Copied { to, manifest: Some(_), .. }] if to == &out),
        "what landed is journaled as a partial with its manifest: {:?}", entry.steps);
    let mut j = Journal::new();
    j.push(entry);
    assert_eq!(j.undo().expect("undo"), "copy");
    assert!(!out.exists(), "undo removes every path the partial copy created");
    assert!(src.join("link-file").symlink_metadata().unwrap().file_type().is_symlink(), "and leaves the source whole");
}

#[test]
fn a_link_refused_as_unsupported_on_any_drive_never_ends_the_copy() {
    let d = TestDir::new("unheldnotsup");
    let src = tree_with_links(&d);
    let dest = d.dir("out");
    super::test_refuse(&[("link-file", EOPNOTSUPP), ("link-dir", EOPNOTSUPP), ("broken", EOPNOTSUPP)]);
    let (items, ok, failed, _) = transferred(&src, &dest);
    super::test_refuse(&[]);
    let out = dest.join("tree");
    assert_every_file_landed(&out);
    assert_no_link_landed(&out);
    assert_eq!((ok, failed), (0, 1));
    assert!(items[0].2.ends_with(": this drive cannot hold links"), "EOPNOTSUPP says the drive cannot hold links: {:?}", items[0]);
}

#[test]
fn a_move_onto_a_drive_without_links_copies_the_rest_keeps_its_source_and_names_the_link() {
    let d = TestDir::new("unheldmove");
    let src = d.dir("tree");
    std::fs::write(src.join("a.txt"), "a").unwrap();
    std::fs::write(src.join("b.txt"), "b").unwrap();
    std::fs::write(src.join("c.txt"), "c").unwrap();
    std::os::unix::fs::symlink("a.txt", src.join("link")).unwrap();
    let moved = d.join("moved");
    let flag = AtomicBool::new(false);
    let mut sink = |_: u64, _: u64| {};
    fat(true);
    let mut p = Progress { cancel: &flag, on_bytes: &mut sink, partial: None, tree: None, manifest: None, durability: None, for_move: true };
    let outcome = move_cross_device(&src, &moved, &mut p);
    fat(false);
    let error = outcome.expect_err("a move never drops a link to succeed");
    assert_eq!(error.msg, "link could not be moved: this drive cannot hold links");
    assert_eq!(p.partial.as_deref(), Some(moved.as_path()), "what landed is the partial the journal records");
    for leaf in ["a.txt", "b.txt", "c.txt"] {
        assert!(moved.join(leaf).is_file(), "{leaf} lands past the link");
        assert!(src.join(leaf).is_file(), "and its source stays");
    }
    assert!(src.join("link").symlink_metadata().unwrap().file_type().is_symlink(), "the refused link stays in the source");
}

// One of each other item FAT cannot hold: a refused name, a special file, a 4 GiB file and a name folded onto a sibling.
#[test]
fn every_item_fat_cannot_hold_is_skipped_and_counted_while_the_rest_lands() {
    let d = TestDir::new("unheldclass");
    let src = d.dir("tree");
    std::fs::write(src.join("a:b.txt"), "colon").unwrap();
    std::fs::write(src.join("CASE.txt"), "upper").unwrap();
    std::fs::write(src.join("case.txt"), "lower").unwrap();
    std::fs::File::create(src.join("big.iso")).unwrap().set_len(4 * 1024 * 1024 * 1024).unwrap();
    crate::backend::fifotest::mkfifo(&src.join("pipe"));
    for (rel, body) in [("a.txt", "a"), ("z.txt", "z")] {
        std::fs::write(src.join(rel), body).unwrap();
    }
    std::fs::create_dir(src.join("deep")).unwrap();
    std::fs::write(src.join("deep/c.txt"), "c").unwrap();
    let dest = d.dir("out");
    fat(true);
    super::test_refuse(&[("a:b.txt", EINVAL), ("pipe", EPERM), ("case.txt", EEXIST)]);
    test_set_precheck(Some(u64::MAX), Some(1), Some(0x4D44));
    let (items, ok, failed, _) = transferred(&src, &dest);
    test_set_precheck(None, None, None);
    super::test_refuse(&[]);
    fat(false);
    let out = dest.join("tree");
    for (rel, body) in [("a.txt", "a"), ("z.txt", "z"), ("deep/c.txt", "c"), ("CASE.txt", "upper")] {
        assert_eq!(std::fs::read_to_string(out.join(rel)).ok().as_deref(), Some(body), "{rel} must land past every refused item");
    }
    for rel in ["a:b.txt", "case.txt", "big.iso", "pipe"] {
        assert!(out.join(rel).symlink_metadata().is_err(), "{rel} is refused, not half-written");
    }
    assert_eq!((ok, failed), (0, 1));
    assert!(items[0].2.starts_with("4 items inside could not be copied; the first is "), "{:?}", items[0]);
}

// Sample input: EPERM from symlink under vfat or exfat is the drive's limit; under ext4 it stays the copy's own error.
#[test]
fn eperm_means_cannot_hold_only_on_a_drive_with_no_operation_for_the_kind() {
    let d = TestDir::new("unheldreason");
    let named = d.join("l");
    let eperm = std::io::Error::from_raw_os_error(EPERM);
    assert_eq!(super::refused(super::Kind::Link, &eperm, &named, None).where_, "copy", "EPERM on a drive that holds links is not skipped");
    fat(true);
    let link = super::refused(super::Kind::Link, &eperm, &named, None);
    let node = super::refused(super::Kind::Node, &eperm, &named, None);
    fat(false);
    assert_eq!((link.where_.as_str(), link.msg.as_str()), (super::UNHELD, super::LINKS));
    assert_eq!((node.where_.as_str(), node.msg.as_str()), (super::UNHELD, super::NODES));
    let taken = std::io::Error::from_raw_os_error(EEXIST);
    let source = d.file("README", "u");
    assert_eq!(super::refused(super::Kind::Entry, &taken, &named, None).msg, "already exists", "a taken name at the top is the collide card's");
    assert_eq!(super::refused(super::Kind::Entry, &taken, &named, Some(&source)).where_, "copy", "with no folding sibling it is another writer's");
    d.file("readme.", "l");
    assert_eq!(super::refused(super::Kind::Entry, &taken, &named, Some(&source)).where_, super::UNHELD, "beside a sibling that folds onto it, it is the drive's");
}

// The done line names each refused entry under the folder it was copied into, and says nothing extra when none was.
#[test]
fn the_done_line_names_each_refused_entry_and_its_reason() {
    let d = TestDir::new("unheldline");
    let src = tree_with_links(&d);
    let dest = d.dir("out");
    let (tx, rx) = channel();
    fat(true);
    run_transfer(4, false, vec![src.to_string_lossy().to_string()], dest.clone(), Arc::new(AtomicBool::new(false)), tx);
    fat(false);
    let refused = rx.iter().find_map(|m| match m { OpMsg::TransferDone { refused, .. } => Some(refused), _ => None }).expect("a done line");
    let mut names: Vec<&str> = refused.iter().map(|(name, _)| name.as_str()).collect();
    names.sort_unstable();
    assert_eq!(names, ["tree/broken", "tree/link-file", "tree/sub/link-dir"]);
    assert!(refused.iter().all(|(_, why)| why == super::LINKS));
    let line = crate::backend::opsreq::transferdone_line(4, 0, 1, 0, false, &[], false, "", &refused[..1]);
    assert!(line.ends_with(&format!(r#","refused":[{{"name":"{}","err":"this drive cannot hold links"}}]}}"#, refused[0].0)), "{line}");
    let clean = crate::backend::opsreq::transferdone_line(4, 1, 0, 0, false, &[], false, "", &[]);
    assert!(!clean.contains("refused"), "a transfer nothing was refused in keeps its line byte for byte: {clean}");
}

// A link at the top of the selection is the item's own failure, said plainly, with no folder to name it inside.
#[test]
fn a_link_at_the_top_fails_its_own_item_with_the_drive_reason() {
    let d = TestDir::new("unheldtop");
    std::fs::write(d.join("a.txt"), "a").unwrap();
    let link = d.join("link");
    std::os::unix::fs::symlink("a.txt", &link).unwrap();
    let dest = d.dir("out");
    fat(true);
    let (items, ok, failed, entry) = transferred(&link, &dest);
    fat(false);
    assert_eq!((ok, failed), (0, 1));
    assert_eq!(items, vec![("link".to_string(), false, super::LINKS.to_string())]);
    assert!(entry.steps.is_empty(), "nothing was created, so nothing is journaled");
}

// What landed of a tree with refused entries is still confirmed on a durable drive before the done line.
#[test]
fn what_landed_beside_the_refused_entries_is_confirmed_before_done() {
    use crate::backend::durable::{test_mark_durable, test_reset};
    test_reset();
    let d = TestDir::new("unhelddurable");
    let src = tree_with_links(&d);
    let dest = d.dir("out");
    test_mark_durable(&dest);
    let (tx, rx) = channel();
    fat(true);
    run_transfer(6, false, vec![src.to_string_lossy().to_string()], dest.clone(), Arc::new(AtomicBool::new(false)), tx);
    fat(false);
    let mut writing = false;
    let mut done = None;
    for msg in rx.iter() {
        match msg {
            OpMsg::Meta { line } if line.contains(r#""phase":"writing""#) => writing = true,
            OpMsg::TransferDone { durable, ok, failed, .. } => done = Some((durable, ok, failed)),
            _ => {}
        }
    }
    test_reset();
    assert!(writing, "the landed files go through the final flush");
    assert_eq!(done, Some((true, 0, 1)), "the item failed, and what landed of it is on the drive");
}
