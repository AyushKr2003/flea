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

// A window past the answered head returns the full ranked order: the head's own
// continuation, byte for byte what a full-window query of the same generation answers.
#[test]
fn a_window_past_the_head_returns_the_full_ranked_order() {
    let d = TestDir::new("sessionwindowpasthead");
    d.dir("docs");
    d.file("docs/bench-notes.txt", "");
    d.file("bench.txt", "");
    d.file("other.txt", "");
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
    // The walk lands on its own event; the queries below must score the whole scope.
    let landed = events_rx.recv_timeout(WIRE_DEADLINE).expect("the walk lands");
    assert!(matches!(landed, Event::SearchWalked), "the walk announces itself");
    out.clear();
    // Two bench matches over the fixture, asked with a window of one.
    ask(r#"{"c":"searchquery","query":"bench","gen":1,"count":1}"#, &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
    let lines: Vec<String> = String::from_utf8(std::mem::take(&mut out)).expect("utf-8").lines().map(str::to_string).collect();
    assert_eq!(lines.len(), 3, "listed, rows, searched: {lines:?}");
    assert_eq!(crate::json::field_usize(&lines[0], "n"), Some(2), "both matches counted");
    let head_rows = lines[1].clone();
    // A locate past the head completes the listing the same way a scroll does: one of
    // the two matches is adopted, the other is not, so exactly one locate extends.
    let mut found = Vec::new();
    for rel in ["docs/bench-notes.txt", "bench.txt"] {
        ask(&format!(r#"{{"c":"locate","path":"{}/{}"}}"#, root, rel), &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
        let lines: Vec<String> = String::from_utf8(std::mem::take(&mut out)).expect("utf-8").lines().map(str::to_string).collect();
        assert_eq!(lines.len(), 1, "one located line: {lines:?}");
        found.push(crate::json::field_usize(&lines[0], "index"));
    }
    found.sort();
    assert_eq!(found, vec![Some(0), Some(1)], "the two matches sit at rows 0 and 1");
    // A scroll past the head names the continuation in the ranked order.
    ask(r#"{"c":"window","start":1,"count":100}"#, &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
    let lines: Vec<String> = String::from_utf8(std::mem::take(&mut out)).expect("utf-8").lines().map(str::to_string).collect();
    assert_eq!(lines.len(), 1, "one rows line: {lines:?}");
    let past_rows = lines[0].clone();
    assert_ne!(past_rows, head_rows, "the continuation is not the head again");
    // The same generation asked whole answers head plus continuation in one order.
    ask(r#"{"c":"searchquery","query":"bench","gen":2,"count":100}"#, &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
    let lines: Vec<String> = String::from_utf8(std::mem::take(&mut out)).expect("utf-8").lines().map(str::to_string).collect();
    assert_eq!(lines.len(), 3, "listed, rows, searched: {lines:?}");
    let full_rows = lines[1].clone();
    assert!(full_rows.contains("bench-notes.txt") && full_rows.contains("bench.txt"), "the whole answer carries both: {full_rows:?}");
    let head_name = if head_rows.contains("bench-notes.txt") { "bench-notes.txt" } else { "bench.txt" };
    let past_name = if past_rows.contains("bench-notes.txt") { "bench-notes.txt" } else { "bench.txt" };
    assert_ne!(head_name, past_name, "head and continuation name different matches");
    let head_at = full_rows.find(head_name).expect("the head opens the whole answer");
    let past_at = full_rows.find(past_name).expect("the continuation follows in the whole answer");
    assert!(head_at < past_at, "the scrolled window keeps the ranked order");
}

// A select-all snapshot resolves every match the listed line counted: rows past the
// answered head join the listing before the arm runs, so the snapshot sees them all,
// and the window behind it stands in the full-ranked order.
#[test]
fn a_menu_select_all_resolves_every_match_in_ranked_order() {
    let d = TestDir::new("sessionmenuselectall");
    d.dir("docs");
    d.file("docs/bench-notes.txt", "");
    d.file("bench.txt", "");
    d.file("other.txt", "");
    let root = d.path().to_str().expect("the sandbox path is utf-8").to_string();
    let tb = Tables::load();
    let (events, events_rx) = channel::<Event>();
    let mut st = State::new(super::super::dirsizeworker::Worker::new(events.clone()));
    let (results, _done) = channel();
    let pool = Pool::new(1, results, d.join("cache"), Arc::clone(&tb.aliases), Arc::clone(&tb.thumbs));
    let cache = Cache::new();
    let (tx, rx) = channel();
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
    // The walk lands on its own event; the queries below must score the whole scope.
    let landed = events_rx.recv_timeout(WIRE_DEADLINE).expect("the walk lands");
    assert!(matches!(landed, Event::SearchWalked), "the walk announces itself");
    out.clear();
    // Two bench matches over the fixture, asked with a window of one.
    ask(r#"{"c":"searchquery","query":"bench","gen":1,"count":1}"#, &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
    let lines: Vec<String> = String::from_utf8(std::mem::take(&mut out)).expect("utf-8").lines().map(str::to_string).collect();
    assert_eq!(lines.len(), 3, "listed, rows, searched: {lines:?}");
    assert_eq!(crate::json::field_usize(&lines[0], "n"), Some(2), "both matches counted");
    // Select all: every row the listed line counted resolves into the snapshot.
    ask(r#"{"c":"menuaction","op":"snapshot","id":7,"rows":[0,1]}"#, &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
    let crate::backend::opsreq::OpMsg::Meta { line } = rx.recv_timeout(WIRE_DEADLINE).expect("the snapshot answers") else {
        panic!("a menuaction reply");
    };
    assert!(line.contains(r#""ok":true"#), "the snapshot takes: {line:?}");
    assert!(line.contains(r#""count":2"#), "both matches resolved, not just the head: {line:?}");
    // The snapshot's extension completed the listing, so a window over it stands in
    // the same order a whole fresh answer does.
    ask(r#"{"c":"window","start":0,"count":100}"#, &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
    let lines: Vec<String> = String::from_utf8(std::mem::take(&mut out)).expect("utf-8").lines().map(str::to_string).collect();
    assert_eq!(lines.len(), 1, "one rows line: {lines:?}");
    let window_rows = lines[0].clone();
    ask(r#"{"c":"searchquery","query":"bench","gen":2,"count":100}"#, &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
    let lines: Vec<String> = String::from_utf8(std::mem::take(&mut out)).expect("utf-8").lines().map(str::to_string).collect();
    assert_eq!(lines.len(), 3, "listed, rows, searched: {lines:?}");
    let full_rows = lines[1].clone();
    let order_of = |rows: &str| {
        let notes = rows.find("bench-notes.txt").expect("the notes match is drawn");
        let plain = rows.find("bench.txt").expect("the plain match is drawn");
        notes < plain
    };
    assert_eq!(order_of(&window_rows), order_of(&full_rows), "the snapshot-extended listing keeps the ranked order");
}

// A locate after a partial extension finds a row still held: the first scroll
// past the head adopts one window and leaves the tail unranked, and the locate
// completes it rather than missing.
#[test]
fn a_locate_after_a_partial_extension_finds_a_row_in_the_held_remainder() {
    let d = TestDir::new("sessionlocatepartial");
    for i in 0..400 {
        d.file(&format!("bench-{:04}.txt", i), "");
    }
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
    let held = |st: &State| st.search_session.as_ref().map(|s| s.pending_rest_len()).unwrap_or(usize::MAX);

    ask(&format!(r#"{{"c":"searchopen","path":"{}","folder":"{}"}}"#, root, root), &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
    // The walk lands on its own event; the queries below must score the whole scope.
    let landed = events_rx.recv_timeout(WIRE_DEADLINE).expect("the walk lands");
    assert!(matches!(landed, Event::SearchWalked), "the walk announces itself");
    out.clear();
    // Four hundred bench matches over the fixture, asked with a window of one.
    ask(r#"{"c":"searchquery","query":"bench","gen":1,"count":1}"#, &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
    let lines: Vec<String> = String::from_utf8(std::mem::take(&mut out)).expect("utf-8").lines().map(str::to_string).collect();
    assert_eq!(lines.len(), 3, "listed, rows, searched: {lines:?}");
    assert_eq!(crate::json::field_usize(&lines[0], "n"), Some(400), "all four hundred matches counted");
    assert_eq!(held(&st), 399, "the rest waits unranked for a scroll");
    // Past the head: one window of 350 joins, 49 stay held.
    ask(r#"{"c":"window","start":1,"count":1}"#, &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
    let lines: Vec<String> = String::from_utf8(std::mem::take(&mut out)).expect("utf-8").lines().map(str::to_string).collect();
    assert_eq!(lines.len(), 1, "one rows line: {lines:?}");
    assert_eq!(held(&st), 49, "the first scroll spends one chunk, not the hold");
    // The oracle is today's walk path over the same tree and query.
    let mut walk = crate::backend::search::Search::new(&root, "bench", false);
    let mut listing = crate::backend::listing::Listing::new();
    while !walk.step(&mut listing) {}
    walk.rank(&mut listing);
    let walk_names: Vec<String> = (0..listing.len()).map(|i| listing.name(i).to_string()).collect();
    assert_eq!(walk_names.len(), 400, "the oracle sees every match");
    assert!(lines[0].contains(&walk_names[1]), "the scrolled row is the ranked order's second");
    // The last match is still held; the locate completes the listing to find it.
    let last = walk_names.last().expect("the oracle names a last match");
    ask(&format!(r#"{{"c":"locate","path":"{}/{}"}}"#, root, last), &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
    let lines: Vec<String> = String::from_utf8(std::mem::take(&mut out)).expect("utf-8").lines().map(str::to_string).collect();
    assert_eq!(lines.len(), 1, "one located line: {lines:?}");
    assert!(lines[0].contains(r#""index":399"#), "the locate finds the held row at the end: {lines:?}");
    assert_eq!(held(&st), 0, "the locate spends the held remainder");
}

    // A query answered while walking re-runs with its own gen when the walk lands.
    #[test]
    fn a_walking_query_re_runs_at_landing_with_its_own_gen() {
        let d = TestDir::new("sessionlanding");
        d.dir("docs");
        for i in 0..10 {
            d.dir(&format!("pad{}", i));
        }
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
        // Park the walk at its last directory, so the query answers from a partial index.
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
        // Twelve opens over the padded fixture; the arm lands long before the walk gets there.
        let (parked, release) = st.search_session.as_ref().expect("a session stands").test_hold_walk_at(12);
        parked.recv_timeout(WIRE_DEADLINE).expect("the walk parks at its last directory");
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


    // A cancel stops the session's walk and keeps its partial index: the standing query is
    // re-answered once with its own gen, cancelled true, and a later query scores the kept rows.
    // A cancel with no standing query answers only its searched line; with no walk running it
    // stays silent. One function, because the walk hold is global to the test binary.
    #[test]
    fn a_cancel_stops_the_walk_and_keeps_the_session() {
        let d = TestDir::new("sessioncancel");
        for i in 0..12 {
            d.dir(&format!("d{}", i));
        }
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
        out.clear();
        // Thirteen opens over the fixture; the arm lands long before the walk gets there.
        let (parked, release) = st.search_session.as_ref().expect("a session stands").test_hold_walk_at(13);
        parked.recv_timeout(WIRE_DEADLINE).expect("the walk parks at its last directory");
        ask(r#"{"c":"searchquery","query":"bench","gen":1,"count":100}"#, &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
        let lines: Vec<String> = String::from_utf8(std::mem::take(&mut out)).expect("utf-8").lines().map(str::to_string).collect();
        assert_eq!(lines.len(), 3, "the walking query answers: {lines:?}");
        assert!(lines[2].contains(r#""walking":true"#), "the partial answer says walking");
        let opened = st.search_session.as_ref().expect("a session stands").probes_opened();
        ask(r#"{"c":"searchcancel"}"#, &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
        let lines: Vec<String> = String::from_utf8(std::mem::take(&mut out)).expect("utf-8").lines().map(str::to_string).collect();
        assert_eq!(lines.len(), 3, "the cancel re-answers listed, rows, searched: {lines:?}");
        assert_eq!(crate::json::field_usize(&lines[2], "gen"), Some(1), "the re-answer keeps the standing gen");
        assert!(lines[2].contains(r#""cancelled":true"#), "the terminal line names the stop");
        assert!(lines[2].contains(r#""walking":false"#), "the stopped walk says walking false");
        assert!(st.search_session.is_some(), "the session stands after a cancel");
        // The landing event still arrives; the cancel swallowed it, so no re-run follows it.
        let _ = release.send(());
        let landed = events_rx.recv_timeout(WIRE_DEADLINE).expect("the stopped walk still announces");
        assert!(matches!(landed, Event::SearchWalked), "the announcement arrives");
        on_search_walked(&mut out, &mut st, &tb, &pool);
        assert!(out.is_empty(), "no landing re-run after a cancel");
        std::thread::sleep(std::time::Duration::from_millis(300));
        assert_eq!(
            st.search_session.as_ref().expect("a session stands").probes_opened(),
            opened,
            "no directory opens after the cancel"
        );
        // A later query is still answered, from the kept partial index.
        ask(r#"{"c":"searchquery","query":"bench","gen":2,"count":100}"#, &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
        let lines: Vec<String> = String::from_utf8(std::mem::take(&mut out)).expect("utf-8").lines().map(str::to_string).collect();
        assert_eq!(lines.len(), 3, "the kept index answers: {lines:?}");
        assert_eq!(crate::json::field_usize(&lines[2], "gen"), Some(2));
        assert!(lines[2].contains(r#""cancelled":false"#), "an ordinary answer is not a cancel");
        let frozen = crate::json::field_usize(&lines[2], "scanned").expect("scanned");
        ask(r#"{"c":"searchquery","query":"benc","gen":3,"count":100}"#, &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
        let lines: Vec<String> = String::from_utf8(std::mem::take(&mut out)).expect("utf-8").lines().map(str::to_string).collect();
        assert_eq!(
            crate::json::field_usize(&lines[2], "scanned"),
            Some(frozen),
            "the index stays frozen across later queries"
        );

        // A cancel with no standing query answers only its searched line; with no walk running it stays silent.
        ask(r#"{"c":"searchclose"}"#, &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
        out.clear();
        ask(&format!(r#"{{"c":"searchopen","path":"{}","folder":"{}"}}"#, root, root), &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
        out.clear();
        let (parked2, release2) = st.search_session.as_ref().expect("a session stands").test_hold_walk_at(13);
        parked2.recv_timeout(WIRE_DEADLINE).expect("the second walk parks at its last directory");
        ask(r#"{"c":"searchcancel"}"#, &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
        let lines: Vec<String> = String::from_utf8(std::mem::take(&mut out)).expect("utf-8").lines().map(str::to_string).collect();
        assert_eq!(lines.len(), 1, "no standing query answers only searched: {lines:?}");
        assert_eq!(crate::json::field_str(&lines[0], "t").as_deref(), Some("searched"));
        assert!(lines[0].contains(r#""cancelled":true"#), "the line names the stop");
        assert!(st.search_session.is_some(), "the session stands after a bare cancel");
        let _ = release2.send(());
        ask(r#"{"c":"searchcancel"}"#, &mut out, &mut st, &mut ops, &mut watch, &mut peeks, &mut fsinfo, &poller);
        assert!(out.is_empty(), "no walk running stays silent");
    }
