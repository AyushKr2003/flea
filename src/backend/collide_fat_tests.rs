// A FAT answer on the policy remaps or skips each leaf before the collision rules see it, driven against real files in a sandbox.
use super::{text, transfer};
use crate::backend::collide::*;
use crate::backend::fatnames::Choice;
use crate::backend::testdir::TestDir;
use std::path::{Path, PathBuf};

fn fat_policy(choice: Choice, on_fat: bool) -> Policy {
    Policy { fat: Some(choice), on_fat, ..Policy::default() }
}

fn sources(d: &TestDir) -> Vec<PathBuf> {
    d.dir("from");
    ["clip: final.mp4", "notes?.md", "draft.", "final.mp4"].iter().map(|name| d.file(&format!("from/{}", name), "yours")).collect()
}

#[test]
fn rename_and_copy_lands_each_bad_name_under_its_new_one() {
    let d = TestDir::new("fat-rename");
    let to = d.dir("to");
    let from = sources(&d);
    let paths: Vec<&Path> = from.iter().map(|p| p.as_path()).collect();
    let (ok, failed, skipped, errors, _) = transfer(false, &paths, &to, fat_policy(Choice::Rename, true));
    assert_eq!((ok, failed, skipped, errors.len()), (4, 0, 0, 0));
    for landed in ["clip_ final.mp4", "notes_.md", "draft", "final.mp4"] {
        assert_eq!(text(&to.join(landed)), "yours", "{} landed", landed);
    }
    assert!(from.iter().all(|p| p.exists()), "a copy leaves every source in place");
}

#[test]
fn skip_them_copies_the_rest_and_writes_nothing_for_a_bad_name() {
    let d = TestDir::new("fat-skip");
    let to = d.dir("to");
    let from = sources(&d);
    let paths: Vec<&Path> = from.iter().map(|p| p.as_path()).collect();
    let (ok, failed, skipped, _, entry) = transfer(false, &paths, &to, fat_policy(Choice::Skip, true));
    assert_eq!((ok, failed, skipped), (1, 0, 3), "only the clean name is copied");
    assert_eq!(std::fs::read_dir(&to).unwrap().count(), 1);
    assert_eq!(entry.steps.len(), 1, "undo has exactly the one file to take back");
}

#[test]
fn a_destination_off_the_fat_family_keeps_every_name_as_asked() {
    let d = TestDir::new("fat-ext4");
    let to = d.dir("to");
    let from = sources(&d);
    let paths: Vec<&Path> = from.iter().map(|p| p.as_path()).collect();
    let (ok, _, skipped, _, _) = transfer(false, &paths, &to, fat_policy(Choice::Rename, false));
    assert_eq!((ok, skipped), (4, 0));
    assert!(to.join("clip: final.mp4").exists() && to.join("draft.").exists(), "nothing is renamed on a guess");
}
