use super::*;
use crate::backend::searchsession::Session;
use crate::backend::testdir::TestDir;

// holiday.jpg carries Red, notes.txt carries nothing.
fn fixture(tag: &str) -> TestDir {
    let d = TestDir::new(tag);
    d.file("holiday.jpg", "");
    d.file("notes.txt", "");
    crate::backend::tags::write_names(&d.join("holiday.jpg"), &["Red".to_string()]).unwrap();
    d
}

fn rows(s: &mut Session, gen: usize, query: &str) -> Vec<String> {
    let answer = s.query(gen, query, 100).expect("a newer generation answers");
    answer.rows.iter().map(|(path, _)| path.clone()).collect()
}

#[test]
fn a_tag_name_typed_one_key_at_a_time_still_finds_its_files() {
    let d = fixture("tagtyped");
    let root = d.path().to_str().expect("utf-8").to_string();
    let mut s = Session::open_sync(&root, &root, false);
    for (i, query) in ["tag:R", "tag:Re"].iter().enumerate() {
        assert!(rows(&mut s, i + 1, query).is_empty(), "{query} names no tag any file carries");
    }
    assert_eq!(rows(&mut s, 3, "tag:Red"), ["holiday.jpg"], "the whole name finds the file the prefixes missed");
}

#[test]
fn a_tag_prefix_typed_from_the_bare_word_still_finds_its_files() {
    let d = fixture("tagbare");
    let root = d.path().to_str().expect("utf-8").to_string();
    let mut s = Session::open_sync(&root, &root, false);
    let typed = ["t", "ta", "tag", "tag:", "tag:R", "tag:Re", "tag:Red"];
    let mut last = Vec::new();
    for (i, query) in typed.iter().enumerate() {
        last = rows(&mut s, i + 1, query);
    }
    assert_eq!(last, ["holiday.jpg"], "typing tag:Red from t finds the Red file");
}

#[test]
fn text_typed_after_a_tag_term_still_narrows_from_the_previous_matches() {
    let d = fixture("tagnarrow");
    let root = d.path().to_str().expect("utf-8").to_string();
    let mut s = Session::open_sync(&root, &root, false);
    assert_eq!(rows(&mut s, 1, "tag:Red"), ["holiday.jpg"]);
    assert_eq!(rows(&mut s, 2, "tag:Red hol"), ["holiday.jpg"]);
    assert_eq!(s.counters.rows_scored, 1, "the same tag set scores only the one previous match, not the index");
}

#[test]
fn a_local_scope_reads_its_tags_with_no_mount_hop() {
    let d = fixture("taglocal");
    let root = d.path().to_str().expect("utf-8").to_string();
    let mut s = Session::open_sync(&root, &root, false);
    crate::backend::iomount::test_reset();
    assert_eq!(rows(&mut s, 1, "tag:Red"), ["holiday.jpg"]);
    assert_eq!(crate::backend::iomount::test_calls(), 0, "a local scope pays no bounded call per hit");
}

// Sample body: "30 1 0:45 / <sandbox> rw - nfs n:/s rw\n", so every path under the sandbox is remote.
fn remote_body(d: &TestDir) -> String {
    format!("1 0 8:1 / / rw - ext4 /dev/a rw\n30 1 0:45 / {} rw - nfs n:/s rw\n", d.path().display())
}

fn two_rows() -> Index {
    let mut index = Index::new();
    index.push("holiday.jpg".to_string(), false);
    index.push("notes.txt".to_string(), false);
    index
}

#[test]
fn a_remote_scope_keeps_one_bounded_read_per_hit() {
    let d = fixture("tagremote");
    let body = remote_body(&d);
    let index = two_rows();
    let mut hits = vec![(0, 0), (0, 1)];
    crate::backend::iomount::test_reset();
    retain_tagged(&mut hits, d.path(), &body, &index, &["red".to_string()]);
    assert_eq!(hits, [(0, 0)], "only the Red file stays");
    assert_eq!(crate::backend::iomount::test_calls(), 2, "each hit rides the mount bound");
}

#[test]
fn a_stuck_remote_scope_matches_nothing() {
    let d = fixture("tagstuck");
    let body = remote_body(&d);
    let index = two_rows();
    let mut hits = vec![(0, 0), (0, 1)];
    let _stuck = crate::backend::iomount::test_hold_stuck(d.path().to_path_buf());
    retain_tagged(&mut hits, d.path(), &body, &index, &["red".to_string()]);
    assert!(hits.is_empty(), "an unreadable mount matches no tag");
}

fn entries_named(count: usize) -> Vec<(String, bool)> {
    (0..count).map(|n| (format!("f{n}.txt"), false)).collect()
}

#[test]
fn a_failed_tag_chunk_leaves_the_rest_of_the_directory_untagged() {
    let entries = entries_named(TAG_CHUNK * 2 + 44);
    let mut calls = 0;
    let tagged = tags_in_chunks(&entries, true, |names| {
        calls += 1;
        if calls == 2 { return None; }
        Some(names.iter().map(|_| vec!["Red".to_string()]).collect())
    });
    assert_eq!(calls, 2, "the failed chunk ends the reads, so a third chunk is never asked");
    assert_eq!(tagged.iter().filter(|tags| !tags.is_empty()).count(), TAG_CHUNK, "only the first chunk's entries carry tags");
    assert!(tagged[..TAG_CHUNK].iter().all(|tags| tags == &["Red"]) && tagged[TAG_CHUNK..].iter().all(Vec::is_empty));
}

#[test]
fn a_hidden_name_the_walk_drops_is_never_read_for_tags() {
    let entries = vec![(".git".to_string(), true), ("a.txt".to_string(), false), (".x".to_string(), false)];
    let mut seen = Vec::new();
    let _ = tags_in_chunks(&entries, false, |names| {
        seen.extend(names.iter().map(|name| name.to_string()));
        Some(names.iter().map(|_| Vec::new()).collect())
    });
    assert_eq!(seen, ["a.txt"], "a dot name costs no tag read while hidden names are off");
    let mut every = Vec::new();
    let _ = tags_in_chunks(&entries, true, |names| {
        every.extend(names.iter().map(|name| name.to_string()));
        Some(names.iter().map(|_| Vec::new()).collect())
    });
    assert_eq!(every, [".git", "a.txt", ".x"], "with hidden names on, every name is read");
}

#[test]
fn a_directory_past_one_chunk_reads_its_tags_in_two_bounded_calls() {
    let d = TestDir::new("tagchunks");
    let entries = entries_named(TAG_CHUNK + 2);
    for (name, _) in &entries {
        d.file(name, "");
    }
    crate::backend::tags::write_names(&d.join("f129.txt"), &["Red".to_string()]).unwrap();
    crate::backend::iomount::test_reset();
    let tagged = read_tags(d.path(), &remote_body(&d), &entries, false);
    assert_eq!(crate::backend::iomount::test_calls(), 2, "130 entries cost two chunks, never 130 calls");
    assert_eq!(tagged[TAG_CHUNK + 1], ["Red"], "the tag in the second chunk is read");
}
