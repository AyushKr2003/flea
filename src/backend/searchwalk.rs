// The session walk: bounded parallel threads over a shared queue locally, one bounded worker per directory remotely.
use super::searchindex::{index_bytes, read_entries, Index, WALK_THREADS};
use super::searchreq::Cancelled;
use super::searchsession::Session;
#[cfg(test)]
use super::searchsession::Counters;
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

// How long an idle walk thread waits before it rechecks the cancel flag; every queue change notifies sooner.
const CANCEL_RECHECK: Duration = Duration::from_millis(50);

// How many directories the walk has opened; tests read it beside the cancel flag.
pub(crate) struct WalkProbes {
    pub opened: AtomicUsize,
    pub cancel: AtomicBool,
    // Test seam: parks this walk alone once it has opened `at` directories, until released.
    #[cfg(test)]
    hold: Mutex<Option<WalkHold>>,
}

impl WalkProbes {
    pub(crate) fn new() -> WalkProbes {
        WalkProbes {
            opened: AtomicUsize::new(0),
            cancel: AtomicBool::new(false),
            #[cfg(test)]
            hold: Mutex::new(None),
        }
    }

    // Arms the hold on this walk's own probes; the walk sends `parked` once blocked.
    #[cfg(test)]
    pub(crate) fn test_hold_walk_at(
        &self,
        at: usize,
    ) -> (std::sync::mpsc::Receiver<()>, std::sync::mpsc::Sender<()>) {
        let (parked_tx, parked_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        *self.hold.lock().unwrap() = Some(WalkHold { at, parked: parked_tx, release: release_rx });
        (parked_rx, release_tx)
    }
}

#[cfg(test)]
impl WalkProbes {
    // Parks this walk once it has opened `at` directories; other walks never see the hold.
    fn hold_if_due(&self, opened: usize) {
        let due = self.hold.lock().unwrap().as_ref().is_some_and(|hold| opened >= hold.at);
        if due {
            let hold = self.hold.lock().unwrap().take();
            if let Some(hold) = hold {
                let _ = hold.parked.send(());
                let _ = hold.release.recv();
            }
        }
    }
}

// Test seam: holds the walk once it has opened `at` directories until released, so close lands mid-walk.
#[cfg(test)]
struct WalkHold {
    at: usize,
    parked: std::sync::mpsc::Sender<()>,
    release: std::sync::mpsc::Receiver<()>,
}

// The whole walk: one mountinfo read, then the local or the remote walk.
#[cfg(test)]
pub(crate) fn walk(
    root: &Path,
    hidden: bool,
    remote: bool,
    body: &str,
    probes: &WalkProbes,
) -> (Index, usize) {
    let out = Mutex::new(Index::new());
    let dirs = fill(&out, root, hidden, remote, body, probes);
    (out.into_inner().unwrap_or_else(|poisoned| poisoned.into_inner()), dirs)
}

// Fills a shared index, so a background walk publishes while queries score the partial one.
pub(crate) fn fill(
    out: &Mutex<Index>,
    root: &Path,
    hidden: bool,
    remote: bool,
    body: &str,
    probes: &WalkProbes,
) -> usize {
    if remote {
        walk_remote(out, root, hidden, body, probes)
    } else {
        walk_local(out, root, hidden, probes)
    }
}

// Local scopes walk with bounded worker threads over a shared directory queue.
fn walk_local(out: &Mutex<Index>, root: &Path, hidden: bool, probes: &WalkProbes) -> usize {
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1).clamp(1, WALK_THREADS);
    // The queue beside how many threads hold a popped directory; a thread ends only when both are empty.
    let work: Mutex<(VecDeque<PathBuf>, usize)> = Mutex::new((VecDeque::from([root.to_path_buf()]), 0));
    let ready = Condvar::new();
    let dirs = AtomicUsize::new(0);
    std::thread::scope(|scope| {
        for _ in 0..threads {
            scope.spawn(|| {
                while let Some(dir) = next_dir(&work, &ready, &probes.cancel) {
                    let subdirs = open_local(out, root, &dir, hidden, probes);
                    if subdirs.is_some() {
                        dirs.fetch_add(1, Ordering::Relaxed);
                    }
                    let mut state = work.lock().unwrap();
                    state.0.extend(subdirs.unwrap_or_default());
                    state.1 -= 1;
                    drop(state);
                    ready.notify_all();
                }
            });
        }
    });
    // No reorder after the walk: a query may already hold row ids, and ranking is total on its own.
    dirs.load(Ordering::Relaxed)
}

// Pops the next directory, waiting while a thread that holds one may still queue more.
fn next_dir(work: &Mutex<(VecDeque<PathBuf>, usize)>, ready: &Condvar, cancel: &AtomicBool) -> Option<PathBuf> {
    let mut state = work.lock().unwrap();
    loop {
        if cancel.load(Ordering::Relaxed) {
            return None;
        }
        if let Some(dir) = state.0.pop_front() {
            state.1 += 1;
            return Some(dir);
        }
        if state.1 == 0 {
            return None;
        }
        state = ready.wait_timeout(state, CANCEL_RECHECK).unwrap().0;
    }
}

// Opens one directory, pushes its rows, and returns its subdirectories; None once the walk is cancelled.
fn open_local(out: &Mutex<Index>, root: &Path, dir: &Path, hidden: bool, probes: &WalkProbes) -> Option<Vec<PathBuf>> {
    // A close cancels the walk at once: no directory opens after close.
    if probes.cancel.load(Ordering::Relaxed) {
        return None;
    }
    probes.opened.fetch_add(1, Ordering::Relaxed);
    #[cfg(test)]
    probes.hold_if_due(probes.opened.load(Ordering::Relaxed));
    if probes.cancel.load(Ordering::Relaxed) {
        return None;
    }
    let rel = rel_of(root, dir);
    let mut rows: Vec<(String, bool)> = Vec::new();
    let mut subdirs = Vec::new();
    for (name, is_dir) in read_entries(dir) {
        // A dot-prefixed name is dropped before it is counted, matching scan.rs's own hidden rule.
        if !hidden && name.starts_with('.') {
            continue;
        }
        // A symlink reports its own type, so a link to a directory is never descended.
        if is_dir {
            subdirs.push(dir.join(&name));
        }
        rows.push((if rel.is_empty() { name } else { format!("{}/{}", rel, name) }, is_dir));
    }
    // Rows land before their subdirectories queue, so a directory's rows always precede its children's.
    let mut index = out.lock().unwrap();
    for (path, is_dir) in rows {
        index.push(path, is_dir);
    }
    Some(subdirs)
}

// A remote scope keeps today's single bounded worker, so one dead server costs one deadline, never the walk.
fn walk_remote(out: &Mutex<Index>, root: &Path, hidden: bool, body: &str, probes: &WalkProbes) -> usize {
    let mut pending: Vec<PathBuf> = vec![root.to_path_buf()];
    let mut dirs = 0;
    while let Some(dir) = pending.pop() {
        // A close cancels the walk at once: no directory opens after close.
        if probes.cancel.load(Ordering::Relaxed) {
            break;
        }
        probes.opened.fetch_add(1, Ordering::Relaxed);
        #[cfg(test)]
        probes.hold_if_due(probes.opened.load(Ordering::Relaxed));
        if probes.cancel.load(Ordering::Relaxed) {
            break;
        }
        // One bound for opendir, getdents and d_type together, so a dead server costs one deadline.
        let owned = dir.clone();
        let entries = match super::iomount::call(&dir, body, "search", move || read_entries(&owned)) {
            Ok(entries) => entries,
            _ => continue,
        };
        let rel = rel_of(root, &dir);
        {
            let mut index = out.lock().unwrap();
            for (name, is_dir) in entries {
                if !hidden && name.starts_with('.') {
                    continue;
                }
                let child = if rel.is_empty() { name.clone() } else { format!("{}/{}", rel, name) };
                index.push(child.clone(), is_dir);
                if is_dir {
                    pending.push(dir.join(&name));
                }
            }
        }
        dirs += 1;
    }
    dirs
}

// The path relative to the scope; the empty string is the scope itself.
fn rel_of(root: &Path, dir: &Path) -> String {
    if dir == root {
        return String::new();
    }
    dir.strip_prefix(root).map(|rel| rel.to_string_lossy().into_owned()).unwrap_or_default()
}

// The walk-thread lifecycle of a session: spawn, landing poll, stop and close; the query side is searchsession.rs.
impl Session {
    pub(crate) fn open_async_inner(
        scope: &str,
        folder: &str,
        hidden: bool,
        walked: std::sync::mpsc::Sender<crate::backend::events::Event>,
        probes: Arc<WalkProbes>,
    ) -> Session {
        let body = crate::backend::mountinfo::read_body();
        let scope_buf = PathBuf::from(scope);
        let remote = crate::backend::iomount::is_remote(&scope_buf, &body);
        let dev = crate::backend::fsinfo::dev_of(&scope_buf);
        let writable = crate::backend::ops::dir_writable(&scope_buf);
        let index = Arc::new(Mutex::new(Index::new()));
        let walk_done = Arc::new(AtomicBool::new(false));
        let thread_index = Arc::clone(&index);
        let thread_probes = Arc::clone(&probes);
        let thread_done = Arc::clone(&walk_done);
        let thread_scope = scope_buf.clone();
        let thread_body = body.clone();
        let opened_at = Instant::now();
        let handle = std::thread::spawn(move || {
            let dirs = fill(&thread_index, &thread_scope, hidden, remote, &thread_body, &thread_probes);
            thread_done.store(true, Ordering::Relaxed);
            let _ = walked.send(crate::backend::events::Event::SearchWalked);
            dirs
        });
        #[cfg(test)]
        let counters = Counters { walks_started: 1, rows_scored: 0, rank_compares: 0 };
        Session {
            scope: scope_buf,
            folder: PathBuf::from(folder),
            hidden,
            dev,
            writable,
            body,
            index,
            walk_done,
            opened_at,
            walk_dirs: 0,
            walk_ms: 0.0,
            probes,
            handle: Some(handle),
            last_query: String::new(),
            last_matches: Vec::new(),
            pending_rest: None,
            folder_n: 0,
            last_answered_gen: 0,
            standing: None,
            standing_while_walking: false,
            announced: false,
            last_batch: Instant::now(),
            sizes: crate::backend::answersizes::AnswerSizes::new(remote),
            #[cfg(test)]
            counters,
        }
    }

    // Joins a finished walk and stamps it landed; tests use this, the loop polls.
    #[cfg(test)]
    pub(crate) fn join_walk(&mut self) {
        if let Some(handle) = self.handle.take() {
            self.walk_dirs = handle.join().unwrap_or(0);
        }
        self.walk_done.store(true, Ordering::Relaxed);
        self.announced = true;
        self.walk_ms = self.opened_at.elapsed().as_secs_f64() * 1000.0;
    }

    // True once after the walk lands, so the loop re-runs the standing query exactly once.
    pub(crate) fn poll_walked(&mut self) -> bool {
        if self.announced || !self.walk_done.load(Ordering::Relaxed) {
            return false;
        }
        self.announced = true;
        if let Some(handle) = self.handle.take() {
            // The event arrived, so the walker already sent and joining ends at once.
            self.walk_dirs = handle.join().unwrap_or(0);
        }
        self.walk_ms = self.opened_at.elapsed().as_secs_f64() * 1000.0;
        true
    }

    // Stops a running walk and keeps the session with its partial index; None when no walk runs.
    pub(crate) fn cancel_walk(&mut self) -> Option<Cancelled> {
        // A cancelled walk is not a running one, so a second cancel stays silent too.
        if !self.walking() || self.probes.cancel.load(Ordering::Relaxed) {
            return None;
        }
        self.probes.cancel.store(true, Ordering::Relaxed);
        // The landing event still arrives; swallowing it here stops the re-run it would fire.
        self.announced = true;
        self.standing_while_walking = false;
        // A landed join is quick, a running walk detaches like close: the loop never waits on it.
        drop(self.handle.take());
        let gen = self.standing.as_ref().map(|standing| standing.0).unwrap_or(self.last_answered_gen);
        let indexed = self.index.lock().unwrap().len();
        let answer = match self.standing.clone() {
            Some((_, query, count)) if !query.is_empty() => {
                let mut answer = self.answer(&query, count);
                answer.gen = gen;
                answer.walking = false;
                self.last_query = query;
                self.last_matches = answer.all.clone();
                self.last_batch = Instant::now();
                Some(answer)
            }
            _ => None,
        };
        Some(Cancelled { answer, gen, indexed })
    }

    // Close cancels a running walk at once and frees the arena, answering the bytes freed.
    pub(crate) fn close(mut self) -> usize {
        self.probes.cancel.store(true, Ordering::Relaxed);
        // A landed walk's thread is already gone, so joining ends at once; a running one detaches behind cancel.
        if self.walk_done.load(Ordering::Relaxed) {
            if let Some(handle) = self.handle.take() {
                let _ = handle.join();
            }
        }
        index_bytes(&self.index.lock().unwrap())
    }
}

#[cfg(test)]
#[path = "searchwalk_tests.rs"]
mod tests;
