use super::*;
use crate::backend::scanhold::{self, Stage};
use crate::backend::testdir::TestDir;
use crate::json::field_str;

// Bounds a wait for an event the test caused, so a missing one fails instead of hanging.
const EVENT_DEADLINE: Duration = Duration::from_secs(10);

// Everything run() owns, built the way it builds them, with the loop's channel read by the test instead.
struct Loop {
    dir: TestDir,
    out: Vec<u8>,
    st: State,
    tb: Tables,
    pool: Pool,
    cache: Cache,
    ops: Ops,
    watch: Watch,
    peeks: PeekWatch,
    fsinfo: FsInfo,
    poller: super::super::watchpoll::Poller,
    gate: Gate,
    tx: Sender<Event>,
    rx: Receiver<Event>,
    _thumbs: Receiver<Done>,
    _ops: Receiver<OpMsg>,
}

impl Loop {
    fn new(tag: &str) -> Loop {
        let dir = TestDir::new(tag);
        let tb = Tables::load();
        let (tx, rx) = channel::<Event>();
        let st = State::new(super::super::dirsizeworker::Worker::new(tx.clone()));
        let (thumbs_tx, _thumbs) = channel();
        let pool = Pool::new(1, thumbs_tx, dir.join("thumbs"), Arc::clone(&tb.aliases), Arc::clone(&tb.thumbs));
        let cache = Cache::at(dir.join("thumbs"));
        let (ops_tx, _ops) = channel();
        let (watch, peeks) = (Watch::start(tx.clone()), PeekWatch::start(tx.clone()));
        let (fsinfo, poller) = (FsInfo::new(tx.clone()), super::super::watchpoll::Poller::new(tx.clone()));
        let gate = Gate::new(tx.clone());
        Loop { dir, out: Vec::new(), st, tb, pool, cache, ops: Ops::new(ops_tx), watch, peeks, fsinfo, poller, gate, tx, rx, _thumbs, _ops }
    }

    // One event through the loop's own dispatch, exactly as run() hands it over.
    fn feed(&mut self, event: Event) -> Control {
        dispatch(event, &mut self.out, &mut self.st, &self.tb, &self.pool, &self.cache, &mut self.ops, &mut self.watch,
                 &mut self.peeks, &mut self.fsinfo, &self.poller, &self.tx, &mut self.gate)
    }

    fn request(&mut self, line: &str) -> Control {
        self.feed(Event::Request(line.to_string()))
    }

    // Reads the loop's channel up to the awaited event; a remote folder's figures and polls also arrive there, and no check reads them.
    fn wait(&self, wanted: fn(&Event) -> bool) -> Event {
        loop {
            let event = self.rx.recv_timeout(EVENT_DEADLINE).expect("the awaited event reaches the loop's channel");
            if wanted(&event) {
                return event;
            }
        }
    }

    fn said(&mut self) -> String {
        String::from_utf8(std::mem::take(&mut self.out)).expect("the wire is UTF-8")
    }
}

fn is_list(event: &Event) -> bool {
    matches!(event, Event::List(_))
}

fn is_changed(event: &Event) -> bool {
    matches!(event, Event::Changed(_))
}

// The sandbox mapped onto an nfs mount, so every folder in it takes the scan thread and holds the gate.
fn remote_body(dir: &Path) -> String {
    format!("1 0 8:1 / / rw - ext4 /dev/a rw\n30 1 0:45 / {} rw - nfs n:/s rw\n", dir.to_string_lossy())
}

fn list(path: &Path) -> String {
    format!(r#"{{"c":"list","path":"{}","first":10}}"#, crate::json::escape(&path.to_string_lossy()))
}

fn text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

// Sample: protocol.sh's list A, list B, paths with listing 1, here with B's scan provably out when the requests and the close arrive.
#[test]
fn requests_a_close_and_a_burst_seen_during_a_scan_wait_for_it_and_replay_in_order() {
    let mut l = Loop::new("rungate-order");
    let (old, new) = (l.dir.dir("old"), l.dir.dir("new"));
    l.dir.file("old/a.txt", "a");
    let kept = l.dir.file("new/b.txt", "b");
    let _body = crate::backend::iomount::test_hold_body(remote_body(l.dir.path()));
    assert!(l.request(&list(&old)) == Control::Continue);
    assert!(l.gate.holds(), "the remote list is out on the scan thread");
    let landed = l.wait(is_list);
    assert!(l.feed(landed) == Control::Continue);
    let first = l.said();
    assert!(first.contains(r#""t":"listed""#), "the first folder lands before the second is asked for: {first}");
    let stale = l.st.generation;
    let hold = scanhold::hold(&text(&new), Stage::Read);
    assert!(l.request(&list(&new)) == Control::Continue);
    hold.entered.recv_timeout(EVENT_DEADLINE).expect("the second scan is out and held at its read");
    assert!(l.request(&format!(r#"{{"c":"paths","rows":[0],"listing":{stale}}}"#)) == Control::Continue);
    assert!(l.request(r#"{"c":"paths","rows":[0]}"#) == Control::Continue);
    // A burst in the folder being left, which is still the current watch until the scan lands.
    std::fs::create_dir(old.join("burst")).expect("the sandbox takes a folder");
    let burst = l.wait(is_changed);
    assert!(l.feed(burst) == Control::Continue);
    assert!(l.feed(Event::Closed) == Control::Continue, "a close while the scan is out waits for its answer");
    let early = l.said();
    assert!(early.is_empty(), "nothing is answered while the scan is out: {early}");
    hold.release();
    let landed = l.wait(is_list);
    assert!(l.feed(landed) == Control::Quit, "the closed loop leaves once the scan and every queued request are answered");
    let said = l.said();
    let lines: Vec<&str> = said.lines().collect();
    assert_eq!(lines.len(), 4, "listed, rows, then the two requests in order, and no changed line for the folder left: {said}");
    assert_eq!(field_str(lines[0], "t").as_deref(), Some("listed"), "{said}");
    assert_eq!(field_str(lines[0], "path"), Some(text(&new)), "the scan's own folder became the listing: {said}");
    assert_eq!(field_str(lines[1], "t").as_deref(), Some("rows"), "{said}");
    assert_eq!(field_str(lines[2], "where").as_deref(), Some("stale"), "the first request named the old numbering, so it is refused: {said}");
    assert_eq!(lines[3], paths_line(&[text(&kept)]), "the second request is answered against the new listing");
}

// A change inside the folder being scanned is answered once the scan lands, after its rows.
#[test]
fn a_burst_in_the_folder_being_scanned_is_answered_once_it_lands() {
    let mut l = Loop::new("rungate-burst");
    let new = l.dir.dir("new");
    l.dir.file("new/b.txt", "b");
    let _body = crate::backend::iomount::test_hold_body(remote_body(l.dir.path()));
    let hold = scanhold::hold(&text(&new), Stage::Read);
    assert!(l.request(&list(&new)) == Control::Continue);
    hold.entered.recv_timeout(EVENT_DEADLINE).expect("the scan is out and held at its read");
    // The worker armed the folder's watch before its read, so this burst carries the descriptor that becomes current.
    std::fs::create_dir(new.join("burst")).expect("the sandbox takes a folder");
    let burst = l.wait(is_changed);
    assert!(l.feed(burst) == Control::Continue);
    let early = l.said();
    assert!(early.is_empty(), "the burst waits for the scan: {early}");
    hold.release();
    let landed = l.wait(is_list);
    assert!(l.feed(landed) == Control::Continue);
    let said = l.said();
    let lines: Vec<&str> = said.lines().collect();
    assert_eq!(lines.len(), 3, "listed, rows, then one changed line: {said}");
    assert_eq!(field_str(lines[1], "t").as_deref(), Some("rows"), "{said}");
    assert_eq!(lines[2], changed_line(&new), "the burst names the folder that became current");
}
