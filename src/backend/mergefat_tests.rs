// A merge onto a FAT destination lands a new name inside the folder under the name Rename gives it.
use super::*;
use crate::backend::fatnames::Choice;

// Clears the stood FAT destination and the refused names on the way out, a failed assert included.
struct StoodFat;
impl Drop for StoodFat {
    fn drop(&mut self) {
        crate::backend::fatnames::test_stand_fat(false);
        crate::backend::unheld::test_refuse(&[]);
    }
}

// Sample input: from/trip holds ok.txt, "clip: x.mp4" and "sub: a/b?.txt"; to/trip holds only ok.txt, so the other two are new.
#[test]
fn a_merge_lands_a_new_name_inside_the_folder_under_its_renamed_form() {
    let d = TestDir::new("merge-fat-rename");
    let to = d.dir("to");
    let trip = d.dir("from/trip");
    d.file("from/trip/ok.txt", "yours");
    d.file("from/trip/clip: x.mp4", "inside");
    d.dir("from/trip/sub: a");
    d.file("from/trip/sub: a/b?.txt", "deeper");
    d.dir("to/trip");
    d.file("to/trip/ok.txt", "there");
    crate::backend::fatnames::test_stand_fat(true);
    crate::backend::unheld::test_refuse(&[("clip: x.mp4", 22), ("sub: a", 22), ("b?.txt", 22)]);
    let _stood = StoodFat;
    let ask = Ask { word: Some("merge".to_string()), id: 7, inner: Some("keep".to_string()), fat: Some(Choice::Rename) };
    let policy = ask.policy(Some(question_for(7, &[&trip], &to)), &to);
    let (ok, failed, _, errors, _, _, _, _) = transfer(false, &[&trip], &to, policy);
    assert_eq!((ok, failed), (1, 0), "{errors:?}");
    assert_eq!(text(&to.join("trip/clip_ x.mp4")), "inside");
    assert_eq!(text(&to.join("trip/sub_ a/b_.txt")), "deeper");
    assert_eq!(text(&to.join("trip/ok.txt")), "there", "the name both sides hold takes the second card's answer");
    assert!(to.join("trip/clip: x.mp4").symlink_metadata().is_err(), "no raw name landed");
}
