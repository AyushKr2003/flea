use super::*;

#[test]
fn a_metadata_file_that_will_not_go_is_named_after_the_item_was_deleted() {
    let d = TestDir::new("refusal-info-left");
    let (path, reviewed) = fixture(&d, &d.join("restored"));
    let seen = logged().len();
    let refused = reviewed.with_claimed(Op::Delete, d.path(), None, || {}, |quarantine| {
        guard(&d, &fd_path(quarantine, OsStr::new("payload")).canonicalize().unwrap());
        remove_tree(reviewed.tree.as_ref().unwrap(), quarantine,
            Refusal::new(Outcome::NothingDeleted, "Trash contents changed; no deletion attempted."))?;
        std::fs::set_permissions(fd_path(quarantine, OsStr::new(".")), std::fs::Permissions::from_mode(0o500)).unwrap();
        Ok(())
    }).unwrap_err();
    let shown = refused.shown();
    assert!(shown.starts_with("The item was deleted, but a Trash record at "), "{shown}");
    assert!(shown.ends_with(" could not be removed: permission denied."), "{shown}");
    assert_logged(seen, "Trash metadata cleanup after completion");
    assert!(!path.exists());
    assert!(!quarantine_in(&d.join("files")).join("payload").exists());
}

#[test]
fn a_temporary_folder_that_will_not_go_is_named_after_the_step_finished() {
    let d = TestDir::new("refusal-folder-left");
    let original = d.join("restored");
    let (trashed, reviewed) = fixture(&d, &original);
    let seen = logged().len();
    let restored = reviewed.with_claimed(Op::Restore, d.path(), Some(&original), || {}, |quarantine| {
        guard(&d, &original);
        guard(&d, &fd_path(quarantine, OsStr::new("payload")).canonicalize().unwrap());
        let destination = open_dir(original.parent().unwrap())?;
        rename(quarantine, OsStr::new("payload"), &destination, original.file_name().unwrap()).unwrap();
        std::fs::write(fd_path(quarantine, OsStr::new("stray")), "x").unwrap();
        Ok(())
    }).unwrap_err();
    assert_eq!(restored.shown(), "The item was restored, but Flea could not remove its temporary folder: it still holds items.");
    assert_logged(seen, "no cleanup was recorded");
    assert_eq!(std::fs::read_to_string(&original).unwrap(), "payload");
    assert!(!trashed.exists());
    assert!(!quarantine_in(&d.join("files")).join("payload").exists());
    let path = d.file("selected", "reviewed");
    let (review, _) = PathReview::prepare(path.clone(), &mut Manifest::new(d.path()).unwrap(), d.path(), &Cancellation::default()).unwrap();
    let deleted = review.delete_after(d.path(), || std::fs::write(quarantine_in(d.path()).join("stray"), "x").unwrap()).unwrap_err();
    assert_eq!(deleted.shown(), "The item was deleted, but Flea could not remove its temporary folder: it still holds items.");
    assert!(!path.exists());
}

