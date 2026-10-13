use super::*;
use crate::backend::testdir::TestDir;
use crate::jsondoc::{parse, Json};
use std::sync::mpsc::channel;

// Twenty lines; the board's hunk is lines 9 to 20, and lines 12 to 17 are the ones that differ.
fn notes(changed: bool) -> String {
    let head = (1..=8).map(|n| format!("Line {n} of the notes.\n")).collect::<String>();
    let kept = "## Previews\n\nEach kind asks for what it shows.\n";
    let tail = "Only the visible lines are asked for.\nA newer request cancels an older one.\nThe frame runs to the column bottom.\n";
    let old = "Thumbnails never load on phones.\nThe map holds every row.\nA taller preview costs nothing.\nPorts keep their slots.\nMarks ship one size.\nFacts fold into two lines.\n";
    let new = "Thumbnails stay cache-only on phones.\nThe map holds the visible rows.\nA taller preview costs what a shorter one did.\nPorts keep their slots while scrolling.\nMarks share one optical size.\nFacts fold into one line.\n";
    format!("{head}{kept}{}{tail}", if changed { new } else { old })
}

fn pair(d: &TestDir, a: &str, b: &str) -> (String, String) {
    let first = d.file("notes-a.md", a).to_string_lossy().into_owned();
    let second = d.file("notes-b.md", b).to_string_lossy().into_owned();
    (first, second)
}

fn text_of(len: usize) -> String {
    (0..len).map(|i| if i % 100 == 99 { '\n' } else { 'a' }).collect()
}

#[test]
fn two_equal_files_are_identical() {
    if crate::backend::sandboxprobe::skipped() {
        return;
    }
    let d = TestDir::new("compareequal");
    let (a, b) = pair(&d, &notes(false), &notes(false));
    assert_eq!(compare(&a, &b), Outcome::Identical);
}

#[test]
fn the_boards_hunk_is_what_diff_prints_with_the_real_paths_as_labels() {
    if crate::backend::sandboxprobe::skipped() {
        return;
    }
    let d = TestDir::new("comparehunk");
    let (a, b) = pair(&d, &notes(false), &notes(true));
    let Outcome::Patch(bytes) = compare(&a, &b) else { panic!("two different files answer a patch") };
    let patch = String::from_utf8(bytes).expect("a text patch");
    let want = format!(
        "--- {a}\n+++ {b}\n@@ -9,12 +9,12 @@\n ## Previews\n \n Each kind asks for what it shows.\n\
-Thumbnails never load on phones.\n-The map holds every row.\n-A taller preview costs nothing.\n-Ports keep their slots.\n-Marks ship one size.\n-Facts fold into two lines.\n\
+Thumbnails stay cache-only on phones.\n+The map holds the visible rows.\n+A taller preview costs what a shorter one did.\n+Ports keep their slots while scrolling.\n+Marks share one optical size.\n+Facts fold into one line.\n\
\x20Only the visible lines are asked for.\n A newer request cancels an older one.\n The frame runs to the column bottom.\n"
    );
    assert_eq!(patch, want);
}

#[test]
fn a_file_is_over_above_one_mebibyte_and_not_at_it() {
    let d = TestDir::new("compareover");
    let (over, at) = (text_of(1_048_577), text_of(1_048_576));
    let (a, b) = pair(&d, &over, "small\n");
    assert_eq!(compare(&a, &b), Outcome::Over, "the first file is over");
    assert_eq!(compare(&b, &a), Outcome::Over, "the second file is over");
    let (a, b) = pair(&d, &at, &at);
    assert_eq!(screen(&a, &b), Ok(()), "at the mark the files are compared");
    if !crate::backend::sandboxprobe::skipped() {
        assert_eq!(compare(&a, &b), Outcome::Identical, "and diff finds them equal");
    }
}

#[test]
fn a_nul_in_the_first_eight_kibibytes_of_either_file_is_binary() {
    let d = TestDir::new("comparebinary");
    let nul_at = |at: usize| {
        let mut data = vec![b'a'; 9000];
        data[at] = 0;
        String::from_utf8(data).expect("ascii and nul")
    };
    let (a, b) = pair(&d, &nul_at(8191), "text\n");
    assert_eq!(compare(&a, &b), Outcome::Binary, "a NUL in the first file");
    assert_eq!(compare(&b, &a), Outcome::Binary, "a NUL in the second file");
    let (a, b) = pair(&d, &nul_at(8192), "text\n");
    assert_eq!(screen(&a, &b), Ok(()), "a NUL past the window is text");
}

#[test]
fn a_missing_file_a_folder_and_a_relative_path_fail() {
    let d = TestDir::new("comparefail");
    let (a, _) = pair(&d, "x\n", "y\n");
    let missing = d.join("none.md").to_string_lossy().into_owned();
    let folder = d.dir("sub").to_string_lossy().into_owned();
    assert_eq!(compare(&a, &missing), Outcome::Failed);
    assert_eq!(compare(&missing, &a), Outcome::Failed);
    assert_eq!(compare(&a, &folder), Outcome::Failed);
    assert_eq!(compare("notes-a.md", &a), Outcome::Failed);
}

#[test]
fn only_exit_zero_and_a_patch_with_output_are_answers() {
    assert_eq!(by_exit(Some(0), Vec::new()), Outcome::Identical);
    assert_eq!(by_exit(Some(1), b"--- /a\n".to_vec()), Outcome::Patch(b"--- /a\n".to_vec()));
    assert_eq!(by_exit(Some(1), Vec::new()), Outcome::Failed, "a jail that could not start diff also exits 1");
    assert_eq!(by_exit(Some(2), b"diff: trouble\n".to_vec()), Outcome::Failed);
    assert_eq!(by_exit(None, Vec::new()), Outcome::Failed, "ended by a signal");
}

#[test]
fn the_argv_names_both_paths_as_labels_and_as_files() {
    assert_eq!(
        diff_argv("/x/a.md", "/x/b.md"),
        ["/usr/bin/diff", "-u", "--label", "/x/a.md", "--label", "/x/b.md", "--", "/x/a.md", "/x/b.md"]
    );
}

#[test]
fn the_reply_is_one_wire_line_per_outcome() {
    let doc = |outcome: &Outcome| parse(&reply(3, outcome)).expect("a reply is one JSON object");
    let state = |outcome: &Outcome| doc(outcome).get("state").and_then(Json::as_str).expect("a state").to_string();
    assert_eq!(state(&Outcome::Identical), "identical");
    assert_eq!(state(&Outcome::Binary), "binary");
    assert_eq!(state(&Outcome::Over), "over");
    assert_eq!(state(&Outcome::Failed), "failed");
    let patch = doc(&Outcome::Patch(b"--- /a\n+++ /b\n@@ -1 +1 @@\n-x\n+y\n".to_vec()));
    assert_eq!(patch.get("state").and_then(Json::as_str), Some("diff"));
    assert_eq!(patch.get("patch").and_then(Json::as_str), Some("--- /a\n+++ /b\n@@ -1 +1 @@\n-x\n+y\n"));
    assert_eq!(patch.get("token").and_then(Json::as_f64), Some(3.0));
}

#[test]
fn a_request_is_answered_on_the_channel() {
    let d = TestDir::new("comparespawn");
    let (a, b) = pair(&d, "x\n", "x\n");
    let (tx, rx) = channel();
    let line = format!(r#"{{"c":"compare","token":9,"a":"{}","b":"{}"}}"#, escape(&a), escape(&b));
    spawn(Ask::parse(&line), tx);
    let OpMsg::Meta { line } = rx.recv_timeout(std::time::Duration::from_secs(20)).expect("one reply") else { panic!("a meta line") };
    assert!(line.starts_with(r#"{"t":"compare","token":9,"state":""#), "{line}");
}
