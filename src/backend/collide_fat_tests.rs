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

// Stands vfat's refusal on the sandbox: the create of each raw name answers EINVAL, which is what a FAT mount does and a tmpfs does not.
// No FAT mount is available to this user (a mount needs root), so every case here runs against that fake.
struct RefusesFatNames;
impl RefusesFatNames {
    fn arm(raw: &[&str]) -> RefusesFatNames {
        let faults: Vec<(&str, i32)> = raw.iter().map(|name| (*name, 22)).collect();
        crate::backend::unheld::test_refuse(&faults);
        RefusesFatNames
    }
}
impl Drop for RefusesFatNames {
    fn drop(&mut self) {
        crate::backend::unheld::test_refuse(&[]);
        crate::backend::unheld::test_force_linkless(false);
    }
}

// Sample tree: from/trip holds ok.txt, "clip: x.mp4" and a folder "sub: a" holding "b?.txt".
fn trip_with_bad_names(d: &TestDir) -> PathBuf {
    let trip = d.dir("from/trip");
    d.file("from/trip/ok.txt", "plain");
    d.file("from/trip/clip: x.mp4", "inside");
    d.dir("from/trip/sub: a");
    d.file("from/trip/sub: a/b?.txt", "deeper");
    trip
}

#[test]
fn rename_and_copy_renames_the_names_inside_a_folder_too() {
    let d = TestDir::new("fat-rename-inside");
    let to = d.dir("to");
    let trip = trip_with_bad_names(&d);
    let _fat = RefusesFatNames::arm(&["clip: x.mp4", "sub: a", "b?.txt"]);
    let (ok, failed, skipped, errors, _) = transfer(false, &[&trip], &to, fat_policy(Choice::Rename, true));
    assert_eq!((ok, failed, skipped, errors.len()), (1, 0, 0, 0), "{errors:?}");
    assert_eq!(text(&to.join("trip/clip_ x.mp4")), "inside", "the file inside lands under the name Rename gives a top-level file");
    assert_eq!(text(&to.join("trip/sub_ a/b_.txt")), "deeper", "a folder and the file in it are renamed alike");
    assert_eq!(text(&to.join("trip/ok.txt")), "plain");
    assert!(to.join("trip/clip: x.mp4").symlink_metadata().is_err() && to.join("trip/sub: a").symlink_metadata().is_err(), "no raw name landed");
    assert!(trip.join("clip: x.mp4").exists(), "a copy leaves the source names as they were");
}

#[test]
fn skip_them_leaves_the_names_inside_a_folder_as_they_are() {
    let d = TestDir::new("fat-skip-inside");
    let to = d.dir("to");
    let trip = trip_with_bad_names(&d);
    let _fat = RefusesFatNames::arm(&["clip: x.mp4", "sub: a"]);
    let (ok, failed, _, errors, _) = transfer(false, &[&trip], &to, fat_policy(Choice::Skip, true));
    assert_eq!((ok, failed), (0, 1), "Skip skips the listed top-level items only, so the folder still lands and names what it could not hold");
    assert!(errors[0].contains("2 items inside could not be copied"), "{errors:?}");
    assert_eq!(text(&to.join("trip/ok.txt")), "plain");
    assert!(to.join("trip/clip_ x.mp4").symlink_metadata().is_err(), "Skip never renames");
}

#[test]
fn a_destination_off_the_fat_family_keeps_the_names_inside_a_folder() {
    let d = TestDir::new("fat-ext4-inside");
    let to = d.dir("to");
    let trip = trip_with_bad_names(&d);
    let (ok, failed, _, _, _) = transfer(false, &[&trip], &to, fat_policy(Choice::Rename, false));
    assert_eq!((ok, failed), (1, 0));
    assert_eq!(text(&to.join("trip/clip: x.mp4")), "inside");
    assert_eq!(text(&to.join("trip/sub: a/b?.txt")), "deeper", "nothing is renamed on a guess");
}

#[test]
fn two_names_inside_a_folder_that_sanitize_alike_land_one_and_name_the_other() {
    let d = TestDir::new("fat-collide-inside");
    let to = d.dir("to");
    let trip = d.dir("from/trip");
    d.file("from/trip/a:b.txt", "colon");
    d.file("from/trip/a_b.txt", "underscore");
    let _fat = RefusesFatNames::arm(&["a:b.txt"]);
    crate::backend::unheld::test_force_linkless(true);
    let (ok, failed, _, errors, _) = transfer(false, &[&trip], &to, fat_policy(Choice::Rename, true));
    assert_eq!((ok, failed), (0, 1), "{errors:?}");
    assert!(errors[0].contains("same as another"), "the drive's own taken-name sentence, not a bare already-exists: {errors:?}");
    assert!(matches!(text(&to.join("trip/a_b.txt")).as_str(), "colon" | "underscore"), "exactly one of the two landed under the shared name");
}
