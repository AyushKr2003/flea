use super::*;
use crate::backend::testdir::TestDir;

const WIRE_DEADLINE: Duration = Duration::from_secs(30);

// A live session over the wire: open, query, empty query, stale drop, close, and list closing it.
#[test]
fn a_session_answers_listed_rows_and_searched_with_its_generation() {
    let d = TestDir::new("sessionwire");
    d.dir("docs");
    d.file("docs/bench-notes.txt", "");
    d.file("bench.txt", "");
    d.file("other.txt", "");
    let root = d.path().to_str().expect("the sandbox path is utf-8").to_string();
    let tb = Tables::load();
    let (events, events_rx) = channel::<Event>();
    let mut st = State::new(super::super::dirsizeworker::Worker::new(events.clone()));
    let (results, _done) = channel();
    let cache_root = d.join("cache");
    let pool = Pool::new(1, results, cache_root, Arc::clone(&tb.aliases), Arc::clone(&tb.thumbs));
    let cache = Cache::new();
    let (tx, _rx) = channel();
    let mut ops = Ops::new(tx);
    let (mut watch, mut peeks) = (Watch::start(events.clone()), PeekWatch::start(events.clone()));
    let mut fsinfo = FsInfo::new(events.clone());
    let poller = super::super::watchpoll::Poller::new(events.clone());
    let mut out = Vec::new();
    let ask = |line: &str,
               out: &mut Vec<u8>,
               st: &mut State,
               ops: &mut Ops,
               watch: &mut Watch,
               peeks: &mut PeekWatch,
               fsinfo: &mut FsInfo,
               poller: &super::super::watchpoll::Poller| {
        assert!(
            handle_line(line, out, st, &tb, &pool, &cache, ops, watch, peeks, fsinfo, poller, &events)
                == Control::Continue
        );
    };

    ask(&format!(r#"{{"c":"searchopen","path":"{}","folder":"{}"}}"#, root, root), &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
    // The walk lands on its own event; the query below must score the whole scope.
    let landed = events_rx.recv_timeout(WIRE_DEADLINE).expect("the walk lands");
    assert!(matches!(landed, Event::SearchWalked), "the walk announces itself");
    let lines: Vec<String> = String::from_utf8(std::mem::take(&mut out)).expect("utf-8").lines().map(str::to_string).collect();
    assert_eq!(lines.len(), 1, "open answers one line, no rows change: {lines:?}");
    assert_eq!(crate::json::field_str(&lines[0], "t").as_deref(), Some("searchopened"));

    ask(r#"{"c":"searchquery","query":"bench","gen":1,"count":100}"#, &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
    let lines: Vec<String> = String::from_utf8(std::mem::take(&mut out)).expect("utf-8").lines().map(str::to_string).collect();
    assert_eq!(lines.len(), 3, "listed, rows, searched over the fixture: {lines:?}");
    assert_eq!(crate::json::field_str(&lines[0], "t").as_deref(), Some("listed"));
    assert_eq!(crate::json::field_usize(&lines[0], "n"), Some(2), "bench.txt and docs/bench-notes.txt");
    assert_eq!(crate::json::field_str(&lines[0], "path").as_deref(), Some(root.as_str()));
    assert_eq!(crate::json::field_str(&lines[1], "t").as_deref(), Some("rows"));
    assert!(lines[1].contains("bench-notes.txt") && lines[1].contains("bench.txt"), "the window carries both matches");
    assert_eq!(crate::json::field_str(&lines[2], "t").as_deref(), Some("searched"));
    assert_eq!(crate::json::field_usize(&lines[2], "gen"), Some(1));
    assert_eq!(crate::json::field_usize(&lines[2], "n"), Some(2));
    assert_eq!(crate::json::field_str(&lines[2], "walking"), None, "walking is a bool, not a string");
    assert!(lines[2].contains(r#""walking":false"#), "the landed walk says walking false");

    // An empty query keeps the session and answers the folder's own listing with the same gen order.
    ask(r#"{"c":"searchquery","query":"","gen":2}"#, &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
    let lines: Vec<String> = String::from_utf8(std::mem::take(&mut out)).expect("utf-8").lines().map(str::to_string).collect();
    assert_eq!(lines.len(), 3, "listed, rows, searched for the folder: {lines:?}");
    assert_eq!(crate::json::field_str(&lines[0], "path").as_deref(), Some(root.as_str()), "the folder answers under its own path");
    assert_eq!(crate::json::field_usize(&lines[0], "n"), Some(3), "bench.txt, docs and other.txt");
    assert_eq!(crate::json::field_usize(&lines[2], "gen"), Some(2));

    // A stale generation answers nothing at all.
    ask(r#"{"c":"searchquery","query":"bench","gen":1}"#, &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
    assert!(out.is_empty(), "gen 1 after gen 2 answers nothing");

    // Close drops the index; a later query answers nothing until a session opens again.
    ask(r#"{"c":"searchclose"}"#, &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
    let lines: Vec<String> = String::from_utf8(std::mem::take(&mut out)).expect("utf-8").lines().map(str::to_string).collect();
    assert_eq!(lines.len(), 1);
    assert_eq!(crate::json::field_str(&lines[0], "t").as_deref(), Some("searchclosed"));
    ask(r#"{"c":"searchquery","query":"bench","gen":3}"#, &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
    assert!(out.is_empty(), "no session open answers nothing");

    // A navigation closes the session: open again, list away, and the query finds no session.
    ask(&format!(r#"{{"c":"searchopen","path":"{}","folder":"{}"}}"#, root, root), &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
    out.clear();
    ask(&format!(r#"{{"c":"list","path":"{}","first":10}}"#, root), &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
    out.clear();
    ask(r#"{"c":"searchquery","query":"bench","gen":4}"#, &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
    assert!(out.is_empty(), "a list closes the session");
}

    // A query answered while walking re-runs with its own gen when the walk lands.
    #[test]
    fn a_walking_query_re_runs_at_landing_with_its_own_gen() {
        let d = TestDir::new("sessionlanding");
        d.dir("docs");
        d.file("docs/bench-notes.txt", "");
        d.file("bench.txt", "");
        let root = d.path().to_str().expect("the sandbox path is utf-8").to_string();
        let tb = Tables::load();
        let (events, events_rx) = channel::<Event>();
        let mut st = State::new(super::super::dirsizeworker::Worker::new(events.clone()));
        let (results, _done) = channel();
        let pool = Pool::new(1, results, d.join("cache"), Arc::clone(&tb.aliases), Arc::clone(&tb.thumbs));
        let cache = Cache::new();
        let (tx, _rx) = channel();
        let mut ops = Ops::new(tx);
        let (mut watch, mut peeks) = (Watch::start(events.clone()), PeekWatch::start(events.clone()));
        let mut fsinfo = FsInfo::new(events.clone());
        let poller = super::super::watchpoll::Poller::new(events.clone());
        let mut out = Vec::new();
        // Park the walk at its first directory, so the query answers from a partial index.
        let (_guard, parked, release) = crate::backend::searchwalk::test_hold_walk_at(1);
        assert!(
            handle_line(
                &format!(r#"{{"c":"searchopen","path":"{}","folder":"{}"}}"#, root, root),
                &mut out,
                &mut st,
                &tb,
                &pool,
                &cache,
                &mut ops,
                &mut watch,
                &mut peeks,
                &mut fsinfo,
                &poller,
                &events
            ) == Control::Continue
        );
        out.clear();
        parked.recv().expect("the walk parks at its first directory");
        assert!(
            handle_line(
                r#"{"c":"searchquery","query":"bench","gen":1,"count":100}"#,
                &mut out,
                &mut st,
                &tb,
                &pool,
                &cache,
                &mut ops,
                &mut watch,
                &mut peeks,
                &mut fsinfo,
                &poller,
                &events
            ) == Control::Continue
        );
        let lines: Vec<String> = String::from_utf8(std::mem::take(&mut out)).expect("utf-8").lines().map(str::to_string).collect();
        assert_eq!(lines.len(), 3, "the walking query answers: {lines:?}");
        assert!(lines[2].contains(r#""walking":true"#), "the partial answer says walking");
        let _ = release.send(());
        let landed = events_rx.recv_timeout(WIRE_DEADLINE).expect("the walk lands");
        assert!(matches!(landed, Event::SearchWalked), "the walk announces itself");
        on_search_walked(&mut out, &mut st, &tb, &pool);
        let lines: Vec<String> = String::from_utf8(std::mem::take(&mut out)).expect("utf-8").lines().map(str::to_string).collect();
        assert_eq!(lines.len(), 3, "the landing re-runs once: {lines:?}");
        assert_eq!(crate::json::field_usize(&lines[2], "gen"), Some(1), "the landing carries its own gen");
        assert!(lines[2].contains(r#""walking":false"#), "the landing says walking false");
        assert_eq!(crate::json::field_usize(&lines[0], "n"), Some(2), "both matches after landing");
        on_search_walked(&mut out, &mut st, &tb, &pool);
        assert!(out.is_empty(), "no second landing re-run");
    }

    // An undo is an own write: the reversal's paths patch the index with no walk.
    #[test]
    fn an_undo_of_a_rename_shows_the_old_name_with_no_walk() {
        use crate::backend::undo::{Entry, Step};
        let d = TestDir::new("sessionundo");
        d.file("new.txt", "x");
        let root = d.path().to_str().expect("the sandbox path is utf-8").to_string();
        crate::backend::mountinfo::test_reset();
        let mut s = Session::open_sync(&root, &root, false);
        let before = s.query(1, "new.txt", 100).expect("the first query answers");
        assert_eq!(before.total, 1, "new.txt matches before the undo over the fixture");
        // Journal the rename old.txt to new.txt the operator just made, then undo reverses it for real.
        let (tx, _rx) = channel();
        let mut ops = Ops::new(tx);
        let meta = std::fs::metadata(d.path().join("new.txt")).expect("new.txt stats");
        let identity = crate::backend::undo::ItemIdentity::record(&meta);
        ops.journal.push(Entry {
            op: "rename".to_string(),
            steps: vec![Step::Moved {
                from: d.path().join("old.txt"),
                to: d.path().join("new.txt"),
                before: identity.clone(),
                after: identity.clone(),
            }],
        });
        let mut buf = Vec::new();
        let touched = do_undo(&mut buf, &mut ops);
        assert!(d.path().join("old.txt").exists(), "the undo restores old.txt");
        assert!(!d.path().join("new.txt").exists(), "the undo removes new.txt");
        assert!(!touched.is_empty(), "the undo names the {} paths it touched", touched.len());
        // The run.rs Undo arm shape: every touched path patches the session.
        for path in touched {
            s.patch_after_write(&path);
        }
        let restored = s.query(2, "old.txt", 100).expect("the next query answers");
        assert_eq!(restored.total, 1, "old.txt shows after the undo");
        let gone = s.query(3, "new.txt", 100).expect("the shrink query answers");
        assert_eq!(gone.total, 0, "new.txt is gone after the undo");
        assert_eq!(crate::backend::mountinfo::test_reads(), 1, "still 1 mountinfo read after the undo");
    }
