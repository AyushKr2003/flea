use super::*;
use crate::backend::opsreq::OpMsg;
use crate::backend::scanhold::{self, Stage};
use crate::backend::testdir::TestDir;
use crate::error::FleaError;
use std::os::unix::fs::MetadataExt;
use std::sync::mpsc::{channel, Receiver};
use std::sync::Arc;
use std::time::Duration;

// Everything `start` and `finish` take, built the way the loop builds them.
struct Rig {
    dir: TestDir,
    tb: Tables,
    st: State,
    pool: Pool,
    watch: Watch,
    tx: Sender<Event>,
    rx: Receiver<Event>,
    _thumbs_rx: Receiver<crate::backend::thumbs::Done>,
}

fn rig(tag: &str) -> Rig {
    let dir = TestDir::new(tag);
    let tb = Tables::load();
    let (tx, rx) = channel::<Event>();
    let st = State::new(crate::backend::dirsizeworker::Worker::new(tx.clone()));
    let (thumbs_tx, _thumbs_rx) = channel();
    let pool = Pool::new(1, thumbs_tx, dir.join("thumbs"), Arc::clone(&tb.aliases), Arc::clone(&tb.thumbs));
    let watch = Watch::start(tx.clone());
    Rig { dir, tb, st, pool, watch, tx, rx, _thumbs_rx }
}

impl Rig {
    // The loop's own call: it returns at once, whatever the scan on its thread is doing.
    fn start(&mut self, path: &str) {
        let job = Job { path: path.to_string(), first: 10, line: "{}".into(), hidden: false, want_changed: false };
        start(&mut Vec::new(), &mut self.st, &self.pool, &mut self.watch, &self.tx, job, Arc::clone(&self.tb.mime));
    }

    // The scan is in flight and blocked, so what the loop reads next it read freely.
    fn progress_lands_first(&self) {
        self.tx.send(Event::Op(OpMsg::Progress { id: 1, index: 0, name: "big.bin".into(), bytes: 1, total: 2, scanned: 0 }))
            .expect("the loop's channel is open");
        let first = self.rx.recv_timeout(Duration::from_secs(5)).expect("an event lands while the scan is held");
        assert!(matches!(first, Event::Op(_)), "the progress line is what the loop reads first");
    }

    fn the_scan_lands(&self) -> Done {
        loop {
            if let Event::List(done) = self.rx.recv_timeout(Duration::from_secs(10)).expect("the scan lands") {
                return done;
            }
        }
    }
}

// Issue 144: start must return before list_dir's read answers, so the loop keeps delivering transferprogress meanwhile.
#[test]
fn a_slow_scan_does_not_hold_the_loop_or_its_events() {
    let mut r = rig("listwork-slow-scan");
    r.dir.file("a.txt", "a");
    let path = r.dir.path().to_string_lossy().into_owned();
    let hold = scanhold::hold(&path, Stage::Read);
    r.start(&path);
    assert!(!hold.over(), "start waited out the held scan, so list_dir ran on the loop");
    hold.entered.recv_timeout(Duration::from_secs(5)).expect("the scan reached the read");
    r.progress_lands_first();
    hold.release();
    let listed = match r.the_scan_lands().result {
        Ok(listed) => listed,
        Err(failed) => panic!("the held directory lists once released: {}", failed.error.msg),
    };
    assert_eq!(listed.listing.len(), 1, "and it is list_dir's own answer");
}

// Issue 144, the failure half: the mode stat can hang on the same stalled mount, so it runs on the worker and rides the answer.
#[test]
fn a_slow_mode_stat_after_a_failed_scan_does_not_hold_the_loop() {
    let mut r = rig("listwork-slow-mode");
    let file = r.dir.file("plain.txt", "a");
    let path = file.to_string_lossy().into_owned();
    let hold = scanhold::hold(&path, Stage::Mode);
    r.start(&path);
    assert!(!hold.over(), "start waited out the held mode stat, so it ran on the loop");
    hold.entered.recv_timeout(Duration::from_secs(5)).expect("the mode stat started on the worker");
    r.progress_lands_first();
    hold.release();
    let failed = match r.the_scan_lands().result {
        Err(failed) => failed,
        Ok(_) => panic!("a file is not a listing"),
    };
    assert_eq!(failed.mode, std::fs::metadata(&file).expect("the file exists").mode(), "the mode the worker read rides the answer");
}

// The loop's side: the error line carries the mode the answer brought, so finish never stats a path for one.
#[test]
fn a_failed_scan_answers_the_mode_the_worker_read_not_a_fresh_stat() {
    let mut r = rig("listwork-failed-mode");
    let missing = r.dir.join("gone").to_string_lossy().into_owned();
    let landed = Landed {
        job: Job { path: missing.clone(), first: 10, line: "{}".into(), hidden: false, want_changed: false },
        done: Done {
            result: Err(ListErr {
                error: FleaError { where_: "scan".into(), path: missing, msg: "refused".into() },
                mode: 0o40750, watch_wd: -1,
            }),
        },
    };
    let mut out = Vec::new();
    assert!(!finish(&mut out, &mut r.st, &r.tb, &r.pool, &mut r.watch, landed), "a failed scan lands false");
    let text = String::from_utf8(out).expect("the error line is UTF-8");
    assert!(text.contains(r#""t":"error""#), "the failure is still an error line: {text}");
    // A fresh stat of the missing path would answer 0 and drop the field.
    assert!(text.contains(&format!(r#""mode":{}"#, 0o40750)), "the line carries the mode the worker read: {text}");
}

// A scan thread that dies must still answer, or the gate holds forever and every later request waits.
#[test]
fn a_scan_that_panics_answers_an_error_and_leaves_the_gate_free() {
    let (tx, rx) = channel::<Event>();
    let hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    spawn_list(tx, "/dead".into(), || -> Done { panic!("a decoder died") });
    let event = rx.recv_timeout(Duration::from_secs(2));
    std::panic::set_hook(hook);
    let done = match event.expect("a dead scan still answers") {
        Event::List(done) => done,
        _ => panic!("the answer is a list event"),
    };
    let mut gate = Gate::new();
    gate.begin(Job { path: "/dead".into(), first: 0, line: "{}".into(), hidden: false, want_changed: false });
    let job = gate.take().expect("the answer closes the job");
    assert!(!gate.holds(), "the gate is free once the answer lands");
    let mut r = rig("listwork-dead-scan");
    let mut out = Vec::new();
    assert!(!finish(&mut out, &mut r.st, &r.tb, &r.pool, &mut r.watch, Landed { job, done }), "a dead scan lands false");
    let text = String::from_utf8(out).expect("the error line is UTF-8");
    let said = crate::backend::iomount::internal_failure("scan", Path::new("/dead")).msg;
    assert!(text.contains(&said), "the line is iomount's own dead-worker sentence: {text}");
    assert!(!text.contains(r#""mode""#), "no mode was read, so the line carries none: {text}");
}

// Requests that land while a scan is out wait for it and replay in arrival order, so list/list/paths sees both listings.
#[test]
fn requests_that_arrive_while_a_scan_is_out_replay_in_order() {
    let mut gate = Gate::new();
    assert!(!gate.holds(), "nothing is out before the first list");
    gate.begin(Job { path: "/a".into(), first: 0, line: "{}".into(), hidden: false, want_changed: false });
    assert!(gate.holds());
    gate.defer("first".into());
    gate.defer("second".into());
    assert_eq!(gate.take().map(|job| job.path), Some("/a".to_string()));
    assert_eq!(gate.next().as_deref(), Some("first"), "the first request replays first");
    assert_eq!(gate.next().as_deref(), Some("second"), "and the second after it");
    assert_eq!(gate.next(), None);
}

// A change seen while a scan is out is answered after it, against the descriptor that became current.
#[test]
fn a_change_seen_during_a_scan_is_decided_once_the_scan_lands() {
    let mut gate = Gate::new();
    gate.begin(Job { path: "/a".into(), first: 0, line: "{}".into(), hidden: false, want_changed: false });
    gate.note_change(7);
    gate.note_change(9);
    assert_eq!(gate.take_changes(), vec![7, 9], "every descriptor is kept for the decision");
    assert!(gate.take_changes().is_empty(), "and the next scan starts with none");
}
