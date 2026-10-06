use super::*;
use crate::backend::testdir::TestDir;

// One session, ten queries typed character by character on nested directories.
fn fixture() -> TestDir {
    let d = TestDir::new("sessionten");
    d.dir("docs/work");
    d.dir("downloads");
    d.file("docs/work/bench-notes.txt", "");
    d.file("docs/bench.txt", "");
    d.file("downloads/helper.txt", "");
    d.file("bench.txt", "");
    d
}

#[test]
fn ten_queries_cost_one_walk_and_one_mountinfo_read() {
    crate::backend::mountinfo::test_reset();
    let d = fixture();
    let root = d.path().to_str().expect("utf-8").to_string();
    let mut s = Session::open_sync(&root, &root, false);
    assert_eq!(s.counters.walks_started, 1, "1 walk over the session's directories");
    assert_eq!(s.walk_dirs(), 4, "the scope, docs, docs/work and downloads over 4 directories walked");
    assert!(!s.capped(), "the fixture never reaches the cap");
    assert_eq!(crate::backend::mountinfo::test_reads(), 1, "1 mountinfo read over the session's directories");
    let mut previous = usize::MAX;
    for (i, len) in (1..=10).enumerate() {
        let query: String = "bench-notes".chars().take(len).collect();
        let answer = s.query(i + 1, &query, 100).expect("each newer generation answers");
        assert_eq!(s.counters.walks_started, 1, "still 1 walk after query {}", i + 1);
        assert_eq!(crate::backend::mountinfo::test_reads(), 1, "still 1 mountinfo read after query {}", i + 1);
        if i > 0 {
            assert_eq!(s.counters.rows_scored, previous, "query {} scores the {} previous matches", i + 1, previous);
        }
        previous = answer.total;
    }
}

#[test]
fn backspace_to_a_shorter_query_scores_the_index_with_no_walk() {
    crate::backend::mountinfo::test_reset();
    let d = fixture();
    let root = d.path().to_str().expect("utf-8").to_string();
    let mut s = Session::open_sync(&root, &root, false);
    let indexed = s.indexed();
    assert!(indexed > 0, "the walk indexed {} rows", indexed);
    let _ = s.query(1, "bench-notes", 100).expect("the long query answers");
    s.query(2, "bench", 100).expect("the shorter query answers");
    assert_eq!(s.counters.walks_started, 1, "1 walk over both queries");
    assert_eq!(s.counters.rows_scored, indexed, "the shorter query scores the {} index rows", indexed);
}

#[test]
fn a_stale_generation_is_never_answered_after_a_newer_one() {
    let d = fixture();
    let root = d.path().to_str().expect("utf-8").to_string();
    let mut s = Session::open_sync(&root, &root, false);
    let _ = s.query(3, "bench", 100).expect("gen 3 answers");
    assert!(s.query(2, "benc", 100).is_none(), "gen 2 is stale after gen 3 and answers nothing");
    assert!(s.query(3, "bench", 100).is_none(), "gen 3 itself answers only once");
    assert!(s.query(4, "b", 100).is_some(), "gen 4 still answers");
}

#[test]
fn the_index_path_ranks_like_todays_walk_path() {
    let d = fixture();
    let root = d.path().to_str().expect("utf-8").to_string();
    let mut s = Session::open_sync(&root, &root, false);
    let answer = s.query(1, "bench", 100).expect("the index path answers");
    let session_names: Vec<String> = {
        let index = s.index.lock().unwrap();
        answer.ranked.iter().map(|&row| index.rows[row].path.clone()).collect()
    };
    let mut walk = crate::backend::search::Search::new(&root, "bench", false);
    let mut listing = crate::backend::listing::Listing::new();
    while !walk.step(&mut listing) {}
    walk.rank(&mut listing);
    let walk_names: Vec<String> = (0..listing.len()).map(|i| listing.name(i).to_string()).collect();
    assert_eq!(session_names, walk_names, "one tree answers in one order over {} rows", walk_names.len());
}

#[test]
fn an_own_write_two_levels_down_shows_in_the_next_query_with_no_walk() {
    let d = fixture();
    let root = d.path().to_str().expect("utf-8").to_string();
    let mut s = Session::open_sync(&root, &root, false);
    let before = s.query(1, "bench", 100).expect("the first query answers");
    assert!(!before.ranked.is_empty(), "the first query matches over {} rows", before.indexed);
    let added = d.file("docs/work/bench-new.txt", "");
    assert!(s.patch_after_write(&added), "the own write under the scope patches the index");
    let after = s.query(2, "bench-new", 100).expect("the next query answers");
    let names: Vec<String> = {
        let index = s.index.lock().unwrap();
        after.ranked.iter().map(|&row| index.rows[row].path.clone()).collect()
    };
    assert!(names.iter().any(|name| name == "docs/work/bench-new.txt"), "the own write shows over {} matches", names.len());
    assert_eq!(s.counters.walks_started, 1, "still 1 walk after the own write");
}

#[test]
fn an_outside_change_in_the_open_folder_shows_with_no_walk_but_two_levels_down_needs_a_reopen() {
    crate::backend::mountinfo::test_reset();
    let d = fixture();
    let root = d.path().to_str().expect("utf-8").to_string();
    let mut s = Session::open_sync(&root, &root, false);
    let added = d.file("bench-outside.txt", "");
    assert!(s.patch_open_dir(added.parent().unwrap()), "the open folder's change patches the index");
    let answer = s.query(1, "bench-outside", 100).expect("the next query answers");
    assert_eq!(answer.total, 1, "the open folder's change shows with {} match", answer.total);
    assert_eq!(s.counters.walks_started, 1, "still 1 walk after the open folder's change");
    let deep = d.file("docs/work/bench-deep.txt", "");
    let _ = std::fs::remove_file(&deep);
    let _ = s.query(2, "bench-deep", 100).expect("a query before the reopen answers");
    // Reopening is a fresh searchopen on the wire: the session closes and one new walk runs.
    let _ = s.close();
    assert_eq!(crate::backend::mountinfo::test_reads(), 1, "1 mountinfo read over the first session");
    let mut reopened = Session::open_sync(&root, &root, false);
    assert_eq!(crate::backend::mountinfo::test_reads(), 2, "the reopen costs its 1 mountinfo read");
    let after = reopened.query(1, "bench-deep", 100).expect("the query after the reopen answers");
    assert_eq!(after.total, 0, "the deep file is gone after the reopen over {} rows", after.indexed);
}

#[test]
fn close_frees_the_arena_to_zero_bytes() {
    let d = fixture();
    let root = d.path().to_str().expect("utf-8").to_string();
    let s = Session::open_sync(&root, &root, false);
    let bytes = s.index_bytes();
    let indexed = s.indexed();
    assert!(bytes > 0, "the arena holds {} bytes over {} rows", bytes, indexed);
    eprintln!("session index: {} bytes over {} rows, {} bytes per entry", bytes, indexed, bytes / indexed);
    let freed = s.close();
    assert_eq!(freed, bytes, "close frees the {} arena bytes it held", bytes);
}

#[test]
fn a_query_while_walking_re_runs_with_its_own_gen_at_landing() {
    let d = TestDir::new("landingwalk");
    for i in 0..10 {
        d.dir(&format!("d{}", i));
    }
    let root = d.path().to_str().expect("utf-8").to_string();
    let (walked_tx, walked_rx) = std::sync::mpsc::channel();
    // Park the walk at its first directory, so the query below answers from a partial index.
    let (_guard, parked, release) = crate::backend::searchindex::test_hold_walk_at(1);
    let mut s = Session::open_async(&root, &root, false, walked_tx);
    parked.recv().expect("the walk parks at its first directory");
    let partial = s.query(1, "zzz-nomatch", 100).expect("gen 1 answers while walking");
    assert!(partial.walking, "the answer says walking over {} indexed rows", partial.indexed);
    assert_eq!(partial.total, 0, "no match yet over the partial index");
    let _ = release.send(());
    walked_rx.recv_timeout(std::time::Duration::from_secs(30)).expect("the walk lands");
    assert!(s.poll_walked(), "the landing announces once");
    assert!(!s.poll_walked(), "the landing never announces twice");
    let landed = s.re_answer_standing().expect("the standing query re-runs at landing");
    assert_eq!(landed.gen, 1, "the landing carries the standing query's own gen");
    assert!(!landed.walking, "the landing says walking false");
    assert!(landed.ms > 0.0, "the landing carries the walk's ms");
    assert!(s.landing().is_none(), "no second landing re-run");
}

#[test]
fn close_mid_walk_opens_no_directory_after_close() {
    let d = TestDir::new("cancelwalk");
    for i in 0..20 {
        d.dir(&format!("d{}", i));
    }
    let root = d.path().to_str().expect("utf-8").to_string();
    // Single-threaded remote-shaped walk, so the hold lands deterministically mid-walk.
    let body = crate::backend::mountinfo::read_body();
    let probes = Arc::new(WalkProbes::new());
    let (_guard, parked, release) = crate::backend::searchindex::test_hold_walk_at(3);
    let scope = PathBuf::from(&root);
    let thread_probes = Arc::clone(&probes);
    let worker = std::thread::spawn(move || searchindex::walk(&scope, false, true, &body, &thread_probes));
    parked.recv().expect("the walk parks after 3 opens");
    // Close lands mid-walk: the flag goes up while the walker is parked.
    probes.cancel.store(true, Ordering::Relaxed);
    let opened_at_close = probes.opened.load(Ordering::Relaxed);
    let _ = release.send(());
    worker.join().expect("the walk ends after release");
    assert_eq!(
        probes.opened.load(Ordering::Relaxed),
        opened_at_close,
        "0 directories open after close over {} opened",
        opened_at_close
    );
}

#[test]
fn a_remote_shaped_scope_walks_through_the_bound() {
    crate::backend::iomount::test_reset();
    let d = fixture();
    let root = d.path().to_str().expect("utf-8").to_string();
    let body = crate::backend::mountinfo::read_body();
    let probes = Arc::new(WalkProbes::new());
    let scope = PathBuf::from(&root);
    let (index, dirs) = searchindex::walk(&scope, false, true, &body, &probes);
    assert_eq!(dirs, 4, "4 directories walked over the fixture");
    assert!(index.len() >= 6, "the remote walk indexes {} rows", index.len());
    assert!(crate::backend::iomount::test_calls() > 0, "the remote walk takes the bound");
}

#[test]
fn an_update_push_is_due_only_past_the_batch_window() {
    let d = fixture();
    let root = d.path().to_str().expect("utf-8").to_string();
    let mut s = Session::open_sync(&root, &root, false);
    let _ = s.query(1, "bench", 100).expect("the first query answers");
    assert!(!s.batch_due(), "no update push right after an answer");
    s.test_set_last_batch(Instant::now() - std::time::Duration::from_millis(BATCH_MS));
    assert!(s.batch_due(), "an update push is due past the batch window");
}
