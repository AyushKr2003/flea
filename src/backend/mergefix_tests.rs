// Advloop round 1 fixes for merge folders, and the pins that guard them.
use super::*;
use crate::backend::undo::Step;

#[test]
fn a_failure_in_one_subfolder_leaves_the_next_sibling_to_finish_and_be_journalled() {
    let d = TestDir::new("merge-sibling");
    let to = d.dir("to");
    let trip = d.dir("from/trip");
    for sub in ["sub1", "sub2"] {
        d.dir(&format!("from/trip/{sub}"));
        d.file(&format!("from/trip/{sub}/new.txt"), sub);
        d.dir(&format!("to/trip/{sub}"));
    }
    // The listing order decides which sibling is walked first, so the shut one is whichever comes first.
    let order: Vec<String> = std::fs::read_dir(&trip).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().to_string()).collect();
    let (bad, fine) = (order[0].clone(), order[1].clone());
    let shut = d.join(&format!("to/trip/{bad}"));
    std::fs::set_permissions(&shut, std::fs::Permissions::from_mode(0o500)).unwrap();
    let (ok, failed, _, _, entry, _, _, _) = transfer(true, &[&trip], &to, merged_policy(7, &[&trip], &to, "keep"));
    std::fs::set_permissions(&shut, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!((ok, failed), (0, 1), "the fold reports its one failure");
    assert!(trip.join(&bad).join("new.txt").exists(), "the entry that failed stays in its source folder");
    assert!(!trip.join(&fine).exists(), "the sibling that landed completely is removed from the source");
    let removed = |step: &Step| matches!(step, Step::RemovedEmptyDir { path, .. } if *path == trip.join(&fine));
    assert!(entry.steps.iter().any(removed), "and its removal is journalled so undo recreates it");
}

#[test]
fn walk_names_inner_files_for_the_one_folder_that_merges() {
    let d = TestDir::new("merge-walk-single");
    let to = d.dir("to");
    let trip = d.dir("from/trip");
    d.file("from/trip/a.txt", "x");
    let loose = d.file("from/x.txt", "y");
    d.dir("to/trip");
    d.file("to/trip/a.txt", "there");
    d.file("to/x.txt", "z");
    let rels: Vec<String> = walk(&owned(&[&trip, &loose]), &to).iter().map(|f| f.rel.clone()).collect();
    assert_eq!(rels, vec!["a.txt".to_string(), "x.txt".to_string()], "one merging folder names its own inners: {:?}", rels);
}

#[test]
fn copy_and_move_merge_count_the_same_entries() {
    for moving in [false, true] {
        let _force = crate::backend::movebatch::ForceCopyGuard::hold();
        let d = TestDir::new(if moving { "merge-counts-move" } else { "merge-counts-copy" });
        let to = d.dir("to");
        let trip = d.dir("from/trip");
        d.file("from/trip/x.txt", "x");
        let photo = d.file("from/photo.png", "new");
        d.dir("to/trip");
        let (ok, failed, _, _, _, merged, kept, _) = transfer(moving, &[&trip, &photo], &to,
            merged_policy(7, &[&trip, &photo], &to, "keep"));
        assert_eq!((ok, failed), (2, 0), "moving={}", moving);
        assert_eq!((merged, kept), (2, 0), "copy and move count alike, moving={}", moving);
    }
}

#[test]
fn top_level_keep_counts_on_copy_and_on_move() {
    for moving in [false, true] {
        let _force = crate::backend::movebatch::ForceCopyGuard::hold();
        let d = TestDir::new(if moving { "merge-keep-move" } else { "merge-keep-copy" });
        let to = d.dir("to");
        let trip = d.dir("from/trip");
        d.file("from/trip/x.txt", "x");
        let photo = d.file("from/photo.png", "yours");
        d.dir("to/trip");
        d.file("to/photo.png", "there");
        let (ok, failed, _, _, _, merged, kept, _) = transfer(moving, &[&trip, &photo], &to,
            merged_policy(7, &[&trip, &photo], &to, "keep"));
        assert_eq!((ok, failed), (2, 0), "moving={}", moving);
        assert_eq!((merged, kept), (2, 1), "a top-level keep counts, moving={}", moving);
    }
}

#[test]
fn merge_undo_from_another_window_refuses_rather_than_removing_the_destination() {
    let d = TestDir::new("merge-undo-foreign");
    let to = d.dir("to");
    let album = d.dir("from/trip");
    d.file("from/trip/new.txt", "yours");
    d.dir("to/trip");
    let there = d.file("to/trip/old.txt", "stays");
    let (_, _, _, _, entry, _, _, _) = transfer(false, &[&album], &to, merged_policy(7, &[&album], &to, "keep"));
    // A restart leaves only the nonce in the shared doc; no in-memory manifest survives it.
    let mut foreign = entry.clone();
    for step in &mut foreign.steps {
        if let Step::Copied { manifest, .. } = step {
            *manifest = None;
        }
    }
    let mut journal = Journal::new();
    journal.push(foreign);
    let err = journal.undo().expect_err("undo without the manifest must refuse a merge");
    assert!(err.msg.contains("only in the window that made it"), "{}", err.msg);
    assert_eq!(text(&there), "stays", "the pre-existing destination folder survives");
    assert!(to.join("trip/new.txt").exists(), "what the merge created stays too");
}

#[test]
fn a_merge_step_keeps_its_flag_through_the_shared_doc_and_a_plain_copy_carries_none() {
    let d = TestDir::new("merge-codec");
    let id = ItemIdentity::inspect(d.path()).unwrap();
    let step = |merge| Step::Copied { from: d.join("a"), to: d.join("b"), source: id.clone(), created: id.clone(), manifest: None, manifest_nonce: Some(7), merge };
    let doc = crate::backend::undoshare::Doc { undo: vec![Entry { op: "copy".into(), steps: vec![step(true), step(false)] }], redo: Vec::new(), push_gen: 0 };
    let text = crate::jsondoc::render(&crate::backend::undocodec::encode(&doc));
    assert_eq!(text.matches("\"merge\"").count(), 1, "only the merge top carries the flag: {text}");
    let back = crate::backend::undocodec::decode(&text).expect("the doc decodes");
    let flags: Vec<bool> = back.undo[0].steps.iter().map(|s| matches!(s, Step::Copied { merge: true, .. })).collect();
    assert_eq!(flags, [true, false], "an older journal without the key decodes as a plain copy");
}

#[test]
fn redo_of_a_copy_merge_refuses_and_leaves_the_destination_folder() {
    let d = TestDir::new("merge-redo");
    let to = d.dir("to");
    let album = d.dir("from/trip");
    d.file("from/trip/new.txt", "yours");
    d.dir("to/trip");
    let there = d.file("to/trip/old.txt", "stays");
    let (_, _, _, _, entry, _, _, _) = transfer(false, &[&album], &to, merged_policy(7, &[&album], &to, "keep"));
    let mut journal = Journal::new();
    journal.push(entry);
    journal.undo().expect("undo takes away what the merge made");
    let (tx, _rx) = channel();
    let err = journal.redo(1, &AtomicBool::new(false), &tx).expect_err("redo never replays a merge over its folder");
    assert!(err.msg.contains("already exists"), "{}", err.msg);
    assert_eq!(text(&there), "stays", "the pre-existing destination file survives the refusal");
}

#[test]
fn merge_replace_lists_the_trash_once_per_merge_not_per_file() {
    let d = TestDir::new("merge-replace-lists");
    let to = d.dir("to");
    let album = d.dir("from/trip");
    d.dir("to/trip");
    for i in 0..3 {
        d.file(&format!("from/trip/f{}.txt", i), "yours");
        d.file(&format!("to/trip/f{}.txt", i), "there");
    }
    let _trash = working_trash(&d);
    trash::test_reset_list_calls();
    let (ok, failed, _, _, _, merged, _, _) = transfer(false, &[&album], &to, merged_policy(7, &[&album], &to, "replace"));
    assert_eq!((ok, failed), (1, 0));
    assert_eq!(merged, 3);
    assert!(trash::test_list_calls() <= 2, "N replaces cost one before/after pair, not 2N: {}", trash::test_list_calls());
}

#[test]
fn merge_replace_puts_the_old_file_back_when_its_copy_fails() {
    let d = TestDir::new("merge-replace-putback");
    let to = d.dir("to");
    let album = d.dir("from/trip");
    d.dir("to/trip");
    let bad = d.file("from/trip/bad.txt", "yours");
    d.file("to/trip/bad.txt", "there");
    d.file("from/trip/good.txt", "yours-g");
    d.file("to/trip/good.txt", "there-g");
    std::fs::set_permissions(&bad, std::fs::Permissions::from_mode(0o000)).unwrap();
    let _trash = working_trash(&d);
    let (ok, failed, _, _, entry, _, _, _) = transfer(false, &[&album], &to, merged_policy(7, &[&album], &to, "replace"));
    assert_eq!((ok, failed), (0, 1));
    assert_eq!(text(&to.join("trip/bad.txt")), "there", "the failed replace goes straight back");
    assert_eq!(text(&to.join("trip/good.txt")), "yours-g");
    let kept: Vec<_> = entry.steps.iter().filter_map(|s| match s {
        crate::backend::undo::Step::Trashed(e) if e.original == to.join("trip/bad.txt") => Some(e.original.clone()),
        _ => None,
    }).collect();
    assert!(kept.is_empty(), "a restored put-back leaves no trash step: {:?}", kept);
}

#[test]
fn merge_replace_refuses_a_destination_that_vanished_before_its_trash() {
    let d = TestDir::new("merge-replace-gone");
    let can = d.dir("can");
    let gone = d.dir("to").join("trip/f.txt");
    let seen = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let (seen_in, at) = (std::rc::Rc::clone(&seen), can.clone());
    trash::STAND_IN.with(|slot| *slot.borrow_mut() = Some(std::rc::Rc::new(move |args: &[&str]| {
        seen_in.borrow_mut().push(args.join(" "));
        if let ["trash", "--", path] = args {
            if std::path::Path::new(path).symlink_metadata().is_err() {
                return Some(exited(1, String::new()));
            }
        }
        Some(gio_trash(&at, args))
    })));
    let landed = std::rc::Rc::new(std::cell::Cell::new(false));
    let landed_in = std::rc::Rc::clone(&landed);
    let mut deferred = crate::backend::mergeapply::Deferred::begin();
    let mut steps = Vec::new();
    let r = crate::backend::mergeapply::replacing_deferred(&gone, &mut steps, &mut deferred, move |_| { landed_in.set(true); Ok(()) });
    match r {
        Err(e) => assert_eq!(e.msg, crate::backend::collide::TRASH_REFUSED),
        Ok(()) => panic!("a gone destination must refuse, not trash-and-land"),
    }
    assert!(!landed.get(), "land must not run for a gone destination");
    assert!(steps.is_empty(), "a refused trash journals nothing: {:?}", steps);
    assert!(seen.borrow().iter().all(|a| !a.starts_with("trash -- ")), "no gio trash spawn for a gone path: {:?}", seen.borrow());
    trash::STAND_IN.with(|slot| *slot.borrow_mut() = None);
}

// Without the before list no settle can attribute, so the Replace is refused before anything moves.
#[test]
fn a_replace_refuses_up_front_when_the_before_list_cannot_be_read() {
    let d = TestDir::new("deferred-before-none");
    let to = d.dir("to");
    d.dir("from");
    let photo = d.file("from/p.png", "yours");
    let there = to.join("p.png");
    std::fs::write(&there, "there").unwrap();
    let can = d.dir("can");
    let at = can.clone();
    trash::STAND_IN.with(|slot| *slot.borrow_mut() = Some(std::rc::Rc::new(move |args: &[&str]| {
        if matches!(args, ["trash", "--list"]) {
            return None;
        }
        Some(gio_trash(&at, args))
    })));
    let _guard = StandIn;
    let mut deferred = crate::backend::mergeapply::Deferred::begin();
    let mut steps = Vec::new();
    let landed = std::rc::Rc::new(std::cell::Cell::new(false));
    let landed_in = std::rc::Rc::clone(&landed);
    let r = crate::backend::mergeapply::replacing_deferred(&there, &mut steps, &mut deferred, move |_| {
        landed_in.set(true);
        Ok(())
    });
    assert_eq!(r.expect_err("no before list means no Replace").msg, crate::backend::collide::TRASH_REFUSED);
    assert!(!landed.get(), "land never runs for a refused trash");
    assert!(steps.is_empty(), "a refused trash journals nothing: {steps:?}");
    assert_eq!(text(&there), "there", "nothing was trashed");
    let _ = photo;
}

// One dropped settle list is retried, so a single stall still attributes every Replace in the batch.
#[test]
fn a_settle_list_that_fails_once_is_retried_and_still_attributes() {
    let d = TestDir::new("deferred-settle-retry");
    let to = d.dir("to");
    d.dir("from");
    let photo = d.file("from/p.png", "yours");
    let there = to.join("p.png");
    std::fs::write(&there, "there").unwrap();
    let can = d.dir("can");
    let at = can.clone();
    let lists = std::rc::Rc::new(std::cell::Cell::new(0));
    let lists_in = std::rc::Rc::clone(&lists);
    trash::STAND_IN.with(|slot| *slot.borrow_mut() = Some(std::rc::Rc::new(move |args: &[&str]| {
        if matches!(args, ["trash", "--list"]) {
            lists_in.set(lists_in.get() + 1);
            // The settle's first list drops; the retry answers.
            if lists_in.get() == 2 {
                return None;
            }
        }
        Some(gio_trash(&at, args))
    })));
    let _guard = StandIn;
    let mut deferred = crate::backend::mergeapply::Deferred::begin();
    let mut steps = Vec::new();
    let r = crate::backend::mergeapply::replacing_deferred(&there, &mut steps, &mut deferred, |_| {
        std::fs::rename(&photo, &there).map_err(|e| crate::error::from_io("copy", "p.png", &e))?;
        Ok(())
    });
    assert!(r.is_ok(), "the Replace lands: {r:?}");
    deferred.settle(&mut steps);
    assert_eq!(lists.get(), 3, "before, one dropped settle list, one retry");
    match &steps[..] {
        [Step::Trashed(entry)] => assert!(!entry.uri.is_empty(), "the retry attributed the entry"),
        other => panic!("one attributed Trashed step: {other:?}"),
    }
}

// A settle no list answers twice keeps the path and the time, and undo resolves the URI from a fresh list.
#[test]
fn a_settle_no_list_answers_keeps_path_and_time_for_undo_to_resolve() {
    let d = TestDir::new("deferred-settle-unresolved");
    let to = d.dir("to");
    d.dir("from");
    let photo = d.file("from/p.png", "yours");
    let there = to.join("p.png");
    std::fs::write(&there, "there").unwrap();
    let can = d.dir("can");
    let at = can.clone();
    let at_first = at.clone();
    // A prior trash entry, so the before list is non-empty and the undo resolution must skip it.
    std::fs::write(can.join("9"), "prior bytes").unwrap();
    std::fs::write(can.join("9.original"), "/prior/path").unwrap();
    let lists = std::rc::Rc::new(std::cell::Cell::new(0));
    let lists_in = std::rc::Rc::clone(&lists);
    trash::STAND_IN.with(|slot| *slot.borrow_mut() = Some(std::rc::Rc::new(move |args: &[&str]| {
        if matches!(args, ["trash", "--list"]) {
            lists_in.set(lists_in.get() + 1);
            // The before list answers; the settle's two lists never do.
            if lists_in.get() > 1 {
                return None;
            }
        }
        Some(gio_trash(&at_first, args))
    })));
    let _guard = StandIn;
    let mut deferred = crate::backend::mergeapply::Deferred::begin();
    let mut steps = Vec::new();
    let r = crate::backend::mergeapply::replacing_deferred(&there, &mut steps, &mut deferred, |_| {
        std::fs::rename(&photo, &there).map_err(|e| crate::error::from_io("copy", "p.png", &e))?;
        Ok(())
    });
    assert!(r.is_ok(), "the Replace lands: {r:?}");
    deferred.settle(&mut steps);
    let entry = match &steps[..] {
        [Step::Trashed(entry)] => entry.clone(),
        other => panic!("one Trashed step: {other:?}"),
    };
    assert!(entry.uri.is_empty(), "no list answered, so no URI was recorded");
    assert_eq!(entry.original, there);
    assert!(!entry.trashed_at.is_empty(), "the time stays for the undo error");
    assert_eq!(entry.before, ["trash:///9"], "the before list stays for the undo resolution");
    // The lists answer again, so undo resolves the URI from a fresh one and restores.
    trash::STAND_IN.with(|slot| *slot.borrow_mut() = Some(std::rc::Rc::new(move |args: &[&str]| Some(gio_trash(&at, args)))));
    // The replacement is already undone ahead of its trash step, as the journal orders them.
    std::fs::remove_file(&there).unwrap();
    crate::backend::trash::restore(&entry).expect("a fresh list resolves the entry");
    assert_eq!(text(&there), "there", "undo brings the old item back to its path");
}

// A merge that replaces nothing lists the trash never: the first list waits for the first trash.
#[test]
fn a_merge_with_no_replace_lists_the_trash_never() {
    let d = TestDir::new("merge-no-replace-lists");
    let to = d.dir("to");
    let album = d.dir("from/trip");
    d.file("from/trip/new.txt", "yours");
    d.dir("to/trip");
    d.file("to/trip/old.txt", "stays");
    let _trash = working_trash(&d);
    trash::test_reset_list_calls();
    let (ok, failed, _, _, _, merged, _, _) = transfer(false, &[&album], &to, merged_policy(7, &[&album], &to, "keep"));
    assert_eq!((ok, failed), (1, 0));
    assert_eq!(merged, 1);
    assert_eq!(trash::test_list_calls(), 0, "no Replace means no list");
}
