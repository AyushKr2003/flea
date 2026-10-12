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
fn a_patch_keeps_the_finished_pass_and_reads_only_the_rows_it_added() {
    let d = fixture("tagspatch");
    let (mut s, rx) = opened(&d);
    let first = tagged(&mut s, &rx, 1, "tag:Red");
    let before = s.tags.reads();
    let added = d.file("red-new.txt", "");
    crate::backend::tags::write_names(&added, &["Red".to_string()]).expect("tagged");
    assert!(s.patch_after_write(&added), "the patch lands");
    // The standing answer stays whole across the patch: no row drops out and comes back.
    let between = s.query(2, "tag:Red", 50).expect("answers");
    assert!(!between.walking && between.total >= first.total, "whole at once: walking {} total {}", between.walking, between.total);
    let after = landed(&mut s, &rx);
    assert_eq!(after.total, 4, "the added entry is read under the new numbering");
    assert_eq!(s.tags.reads(), before + 1, "no row but the added one was read again");
}

#[test]
fn a_patch_that_drops_rows_moves_the_surviving_names_to_their_new_ids() {
    let d = fixture("tagspatchdrop");
    let (mut s, rx) = opened(&d);
    tagged(&mut s, &rx, 1, "tag:Red");
    let before = s.tags.reads();
    let gone = d.join("red-holiday.txt");
    std::fs::remove_file(&gone).expect("removed");
    assert!(s.patch_after_write(&gone));
    let red = s.query(2, "tag:Red", 50).expect("answers");
    assert!(!red.walking, "the finished pass answers whole after the patch");
    assert_eq!(names(&red), ["red-notes.txt", "sub/red-deep.txt"]);
    assert_eq!(names(&s.query(3, "tag:Yellow", 50).expect("answers")), ["yellow-holiday.txt"], "every later row kept its own names");
    assert_eq!(s.tags.reads(), before, "a removal reads nothing");
}

#[test]
fn a_tag_query_on_a_pass_not_started_keeps_no_row() {
    let (tx, _rx) = channel();
    let mut tags = Tags::new(tx);
    let terms = Tags::terms("tag:Red");
    let index = Arc::new(Mutex::new(Index::new()));
    assert!(tags.prepare(&terms, &index, Path::new("/scope"), true), "a walk still running leaves the answer partial");
    let mut hits = vec![(10, 0), (9, 1), (8, 2)];
    tags.keep(&mut hits, &terms);
    assert!(hits.is_empty(), "no pass has read a name, so no untagged row is kept");
    let mut plain = vec![(10, 0)];
    tags.keep(&mut plain, &Tags::terms("holiday"));
    assert_eq!(plain, [(10, 0)], "a query with no tag term is left alone");
}

// An own tag write through the real request: the files it changed, as the loop hands them to the session.
fn written(d: &TestDir, ops: &mut crate::backend::opsdispatch::Ops, rel: &str, op: &str, tag: &str) -> Vec<std::path::PathBuf> {
    let (tx, _rx) = channel();
    let mut st = crate::backend::state::State::new(crate::backend::dirsizeworker::Worker::new(tx));
    st.base = d.path().to_path_buf();
    st.listing.push(rel, false);
    crate::backend::tagsreq::apply_tags(&mut Vec::new(), ops, &st, vec![0], op, tag)
}

fn ops() -> crate::backend::opsdispatch::Ops {
    let (tx, _rx) = channel();
    crate::backend::opsdispatch::Ops::new(tx)
}

// The names swap in, the landing event arrives, and the standing query is re-run once.
fn landed(s: &mut Session, rx: &Receiver<Event>) -> Answer {
    assert!(matches!(rx.recv_timeout(DEADLINE), Ok(Event::SearchWalked)), "the rewrite lands through the walk's event");
    assert!(s.poll_walked(), "the loop sees the rewrite landing");
    let whole = s.re_answer_standing().expect("the standing tagged query is re-run once");
    assert!(!whole.walking, "the re-run is whole");
    assert!(!s.poll_walked() && s.re_answer_standing().is_none(), "one landing, one re-run");
    whole
}

#[test]
fn adding_a_tag_reaches_the_open_tag_search_and_reads_only_the_written_row() {
    let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let d = fixture("tagswriteadd");
    let (mut s, rx) = opened(&d);
    let first = tagged(&mut s, &rx, 1, "tag:Red");
    assert_eq!(first.total, 3);
    let before = s.tags.reads();
    let mut o = ops();
    let files = written(&d, &mut o, "plain-holiday.txt", "add", "Red");
    assert_eq!(files, [d.join("plain-holiday.txt")], "the request answers the file it changed");
    s.note_tags_written(&files);
    // Between the write and the landing the old names stand: whole, and no row fewer.
    let between = s.query(2, "tag:Red", 50).expect("answers");
    assert!(!between.walking && between.total >= first.total, "an answer in between is whole: walking {} total {}", between.walking, between.total);
    let after = landed(&mut s, &rx);
    assert_eq!(names(&after), ["plain-holiday.txt", "red-holiday.txt", "red-notes.txt", "sub/red-deep.txt"]);
    assert_eq!(after.gen, 2, "the re-run keeps the newest query's gen");
    assert_eq!(s.tags.reads(), before + 1, "exactly the written row was read");
}

#[test]
fn removing_a_tag_drops_the_row_from_the_open_tag_search() {
    let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let d = fixture("tagswriteremove");
    let (mut s, rx) = opened(&d);
    tagged(&mut s, &rx, 1, "tag:Red");
    let before = s.tags.reads();
    let mut o = ops();
    s.note_tags_written(&written(&d, &mut o, "sub/red-deep.txt", "remove", "Red"));
    let after = landed(&mut s, &rx);
    assert_eq!(names(&after), ["red-holiday.txt", "red-notes.txt"]);
    assert_eq!(s.tags.reads(), before + 1);
}

#[test]
fn a_tag_write_with_no_tag_term_asked_reads_nothing_and_announces_nothing() {
    let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let d = fixture("tagswritenone");
    let (mut s, rx) = opened(&d);
    s.query(1, "holiday", 50).expect("answers");
    let mut o = ops();
    s.note_tags_written(&written(&d, &mut o, "plain-holiday.txt", "add", "Red"));
    assert_eq!(s.tags.reads(), 0, "no pass is open, so the write reads nothing");
    assert!(rx.recv_timeout(Duration::from_millis(200)).is_err(), "and no landing is announced");
    assert!(!s.poll_walked());
    assert_eq!(tagged(&mut s, &rx, 2, "tag:Red").total, 4, "the first tag term reads the names as they are now");
}

#[test]
fn a_write_outside_the_scope_or_the_index_reads_nothing() {
    let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let d = fixture("tagswriteout");
    let (mut s, rx) = opened(&d);
    tagged(&mut s, &rx, 1, "tag:Red");
    let before = s.tags.reads();
    let mut o = ops();
    let mut files = written(&d, &mut o, "red-holiday.txt", "add", "Blue");
    files.extend([std::path::PathBuf::from("/elsewhere/a.txt"), d.join("not-indexed.txt")]);
    s.note_tags_written(&files);
    let after = landed(&mut s, &rx);
    assert_eq!(after.total, 3);
    assert_eq!(s.tags.reads(), before + 1, "only the indexed, written row was read");
    assert_eq!(names(&s.query(3, "tag:Blue", 50).expect("answers")), ["red-holiday.txt", "red-notes.txt"]);
}

#[test]
fn undo_and_redo_of_a_tag_write_reach_the_open_tag_search_with_no_directory_patch() {
    let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let d = fixture("tagswriteundo");
    let (mut s, rx) = opened(&d);
    tagged(&mut s, &rx, 1, "tag:Red");
    let mut o = ops();
    s.note_tags_written(&written(&d, &mut o, "plain-holiday.txt", "add", "Red"));
    assert_eq!(landed(&mut s, &rx).total, 4);
    let before = s.tags.reads();
    let undone = crate::backend::opsdispatch::do_undo(&mut Vec::new(), &mut o);
    assert!(undone.dirs.is_empty(), "a tag step changes no directory, so nothing patches the index");
    s.note_tags_written(&undone.tags);
    assert_eq!(landed(&mut s, &rx).total, 3, "the undo takes the row back out");
    assert_eq!(s.tags.reads(), before + 1);
    let (tx, _rx) = channel();
    o.journal.redo(1, &std::sync::atomic::AtomicBool::new(false), &tx).expect("redo reapplies");
    let redone = o.journal.take_last_touched();
    assert!(redone.dirs.is_empty());
    s.note_tags_written(&redone.tags);
    assert_eq!(landed(&mut s, &rx).total, 4, "the redo puts it back");
    assert_eq!(s.tags.reads(), before + 2);
}

#[test]
fn a_slow_mount_write_reaches_the_open_tag_search_through_its_late_message() {
    let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let d = fixture("tagswriteslow");
    let (mut s, rx) = opened(&d);
    tagged(&mut s, &rx, 1, "tag:Red");
    let path = d.join("plain-holiday.txt");
    crate::backend::tags::write_names(&path, &["Red".to_string()]).expect("tagged");
    let (dev, ino) = crate::backend::tagsundo::identity(&path).expect("identity");
    let step = crate::backend::undo::Step::Tags { path: path.clone(), before: None, after: Some(crate::backend::tags::join(&["Red".to_string()])), dev, ino };
    let late = crate::backend::opsreq::OpMsg::SetTagsDone { id: 1, result: Ok((1, vec![step], "add")) };
    assert!(crate::backend::searchreq::op_write_paths(&late).is_empty(), "no directory patch");
    s.note_tags_written(&crate::backend::searchreq::op_tag_paths(&late));
    assert_eq!(landed(&mut s, &rx).total, 4);
}

// Frozen mid-read: the first worker holds a stale read of the row when the write lands, and the queue makes it read the row again.
#[test]
fn a_write_during_the_first_read_is_not_lost() {
    let d = fixture("tagswritefirst");
    let (tx, rx) = channel();
    let mut index = Index::new();
    let rels = ["red-holiday.txt", "plain-holiday.txt"];
    for rel in rels {
        index.push(rel.to_string(), false);
    }
    let index = Arc::new(Mutex::new(index));
    let pass = Pass::new(rels.len());
    let mut tags = Tags::new(tx.clone());
    tags.pass = Some(Arc::clone(&pass));
    // The test holds the names, so the worker finishes its reads and waits to store them.
    let held = pass.names.lock().unwrap();
    let worker = {
        let (pass, index, scope, tx) = (Arc::clone(&pass), Arc::clone(&index), d.path().to_path_buf(), tx.clone());
        std::thread::spawn(move || read_all(&pass, &index, &scope, rels.len(), &tx))
    };
    let started = Instant::now();
    while pass.reads.load(Ordering::Relaxed) < rels.len() {
        assert!(started.elapsed() < DEADLINE, "the worker reads both rows");
        std::thread::yield_now();
    }
    // Its stale read of plain-holiday.txt (untagged) is in hand; now the file gains Red and the write is announced.
    crate::backend::tags::write_names(&d.join("plain-holiday.txt"), &["Red".to_string()]).expect("tagged");
    tags.refresh(vec!["plain-holiday.txt".to_string()], &index, d.path());
    drop(held);
    assert!(matches!(rx.recv_timeout(DEADLINE), Ok(Event::SearchWalked)));
    worker.join().unwrap();
    assert!(pass.done.load(Ordering::Relaxed));
    let names = pass.names.lock().unwrap();
    assert_eq!(names[1].as_deref(), Some(&["Red".to_string()][..]), "the stale first read did not win");
    assert_eq!(pass.reads.load(Ordering::Relaxed), 3, "two first reads and one re-read");
    assert!(rx.recv_timeout(Duration::from_millis(200)).is_err(), "one landing, not two");
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
