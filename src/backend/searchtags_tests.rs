use super::*;
use crate::backend::events::Event;
use crate::backend::searchreq::Answer;
use crate::backend::searchsession::Session;
use crate::backend::testdir::TestDir;
use std::sync::mpsc::{channel, Receiver};
use std::time::{Duration, Instant};

const DEADLINE: Duration = Duration::from_secs(10);

// Two Red files (one also Blue), one Yellow, one untagged, and a Red file inside a folder.
fn fixture(tag: &str) -> TestDir {
    let d = TestDir::new(tag);
    d.dir("sub");
    for (name, names) in [
        ("red-holiday.txt", vec!["Red"]),
        ("red-notes.txt", vec!["Red", "Blue"]),
        ("yellow-holiday.txt", vec!["Yellow"]),
        ("plain-holiday.txt", vec![]),
        ("sub/red-deep.txt", vec!["Red"]),
    ] {
        let path = d.file(name, "");
        let names: Vec<String> = names.iter().map(|name| name.to_string()).collect();
        crate::backend::tags::write_names(&path, &names).expect("this filesystem keeps user.xdg.tags");
    }
    d
}

// A session with its walk landed and its landing event taken, the way the loop sees an idle one.
fn opened(d: &TestDir) -> (Session, Receiver<Event>) {
    let root = d.path().to_str().expect("utf-8").to_string();
    let (tx, rx) = channel();
    let mut s = Session::open_async(&root, &root, false, tx);
    s.join_walk();
    assert!(matches!(rx.recv_timeout(DEADLINE), Ok(Event::SearchWalked)), "the walk landing arrives");
    (s, rx)
}

// Asks a tagged query: the answer stands partial while the names are read, and the worker's landing re-runs it whole.
fn tagged(s: &mut Session, rx: &Receiver<Event>, gen: usize, query: &str) -> Answer {
    let partial = s.query(gen, query, 50).expect("a newer generation answers");
    assert!(partial.walking, "{query}: an answer on unread names says it is still walking");
    assert!(matches!(rx.recv_timeout(DEADLINE), Ok(Event::SearchWalked)), "the tag worker lands through the walk's event");
    assert!(s.poll_walked(), "the loop sees the tag landing");
    let whole = s.re_answer_standing().expect("the standing tagged query is re-run once");
    assert!(!whole.walking, "{query}: the re-run is whole");
    assert_eq!(whole.gen, gen, "the re-run keeps the query's gen");
    whole
}

fn names(answer: &Answer) -> Vec<String> {
    let mut rows: Vec<String> = answer.rows.iter().map(|(path, _)| path.clone()).collect();
    rows.sort();
    rows
}

#[test]
fn a_tag_term_keeps_the_entries_that_carry_it() {
    let d = fixture("tagsred");
    let (mut s, rx) = opened(&d);
    let answer = tagged(&mut s, &rx, 1, "tag:Red");
    assert_eq!(answer.total, 3, "red-holiday, red-notes and sub/red-deep carry Red");
    assert_eq!(names(&answer), ["red-holiday.txt", "red-notes.txt", "sub/red-deep.txt"]);
}

#[test]
fn a_tag_term_and_text_both_hold() {
    let d = fixture("tagsredtext");
    let (mut s, rx) = opened(&d);
    let answer = tagged(&mut s, &rx, 1, "tag:Red holiday");
    assert_eq!(names(&answer), ["red-holiday.txt"], "Red and the text holiday leave one entry");
}

#[test]
fn the_tag_name_matches_in_any_case_and_every_named_tag_must_be_present() {
    let d = fixture("tagscase");
    let (mut s, rx) = opened(&d);
    assert_eq!(tagged(&mut s, &rx, 1, "TAG:rEd").total, 3, "the tag name is case-insensitive");
    // The names are in from the first query, so this one answers whole at once.
    let both = s.query(2, "tag:red tag:blue", 50).expect("answers");
    assert!(!both.walking);
    assert_eq!(names(&both), ["red-notes.txt"], "only red-notes carries both");
}

#[test]
fn a_query_with_no_tag_term_reads_no_attribute_and_starts_no_worker() {
    let d = fixture("tagsnone");
    let (mut s, _rx) = opened(&d);
    let answer = s.query(1, "holiday", 50).expect("answers");
    assert!(!answer.walking && answer.total == 3, "a plain query answers whole: {}", answer.total);
    assert_eq!(s.tags.reads(), 0, "no tag term, no getxattr");
    let words = s.query(2, "tag: holiday", 50).expect("answers");
    assert_eq!(s.tags.reads(), 0, "a bare tag: is text, not a term");
    assert!(!words.walking);
}

#[test]
fn each_entry_is_read_once_per_session_and_an_extension_never_reads_again() {
    let d = fixture("tagsonce");
    let (mut s, rx) = opened(&d);
    let first = tagged(&mut s, &rx, 1, "tag:Red");
    let rows = first.indexed;
    assert_eq!(s.tags.reads(), rows, "one read per indexed entry");
    let narrowed = s.query(2, "tag:Red holiday", 50).expect("answers");
    assert!(!narrowed.walking, "the names are in, so the extension answers whole at once");
    assert_eq!(narrowed.total, 1);
    assert_eq!(s.counters.rows_scored, first.total, "the extension scores only the Red matches");
    let other = s.query(3, "tag:Blue", 50).expect("answers");
    assert_eq!(other.total, 1, "another tag is answered from the same names");
    assert_eq!(s.tags.reads(), rows, "no second read for the extension or another tag");
}

#[test]
fn a_tag_extension_does_not_narrow_to_the_shorter_tag_name() {
    let d = fixture("tagsnarrow");
    let (s, _rx) = opened(&d);
    assert!(!s.tags.narrows("tag:R", "tag:Re"), "tag:Re is another term, not the same one grown");
    assert!(!s.tags.narrows("hol", "tag:Red hol"), "a tag term is a new filter");
    assert!(s.tags.narrows("hol", "holi"), "a plain extension narrows as before");
}

#[test]
fn an_empty_text_with_a_tag_matches_every_carrying_entry() {
    let d = fixture("tagsempty");
    let (mut s, rx) = opened(&d);
    let answer = tagged(&mut s, &rx, 1, "tag:yellow");
    assert_eq!(names(&answer), ["yellow-holiday.txt"]);
}

#[test]
fn a_patch_forgets_the_names_so_a_tag_walk_reads_the_new_numbering() {
    let d = fixture("tagspatch");
    let (mut s, rx) = opened(&d);
    tagged(&mut s, &rx, 1, "tag:Red");
    let added = d.file("red-new.txt", "");
    crate::backend::tags::write_names(&added, &["Red".to_string()]).expect("tagged");
    assert!(s.patch_after_write(&added), "the patch lands");
    let answer = tagged(&mut s, &rx, 2, "tag:Red");
    assert_eq!(answer.total, 4, "the added entry is read under the new numbering");
}

// Measured by hand, not by the suite: cargo test --release --bin flea -- --ignored --nocapture tag_pass_at_200k.
#[test]
#[ignore]
fn tag_pass_at_200k_entries_prints_its_ms() {
    let d = TestDir::new("tags200k");
    for dir in 0..200 {
        d.dir(&format!("d{dir:03}"));
        for file in 0..1000 {
            let path = d.file(&format!("d{dir:03}/f{file:04}.txt"), "");
            // One file in a hundred is tagged.
            if (dir * 1000 + file) % 100 == 0 {
                crate::backend::tags::write_names(&path, &["Red".to_string()]).expect("tagged");
            }
        }
    }
    let (mut s, rx) = opened(&d);
    let asked = Instant::now();
    let partial = s.query(1, "tag:Red", 50).expect("answers");
    let loop_ms = asked.elapsed().as_secs_f64() * 1000.0;
    assert!(partial.walking);
    assert!(matches!(rx.recv_timeout(DEADLINE), Ok(Event::SearchWalked)));
    let read_ms = asked.elapsed().as_secs_f64() * 1000.0;
    assert!(s.poll_walked());
    let whole = s.re_answer_standing().expect("re-run");
    println!("TAGS200K entries={} tagged={} partial_answer_ms={loop_ms:.1} names_read_ms={read_ms:.1} rerun_ms={:.1}", whole.indexed, whole.total, whole.ms);
    let narrowed = s.query(2, "tag:Red f0100", 50).expect("answers");
    println!("TAGS200K narrowed_total={} narrowed_ms={:.1}", narrowed.total, narrowed.ms);
    let plain = s.query(3, "f0001", 50).expect("answers");
    println!("TAGS200K untagged_total={} untagged_ms={:.1} reads={}", plain.total, plain.ms, s.tags.reads());
}
