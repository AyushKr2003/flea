// The tag terms of a live search query: split off the query, read once per row on a worker thread, never on the loop.
use crate::backend::events::Event;
use crate::backend::search::{names_carry, split_query};
use crate::backend::searchindex::Index;
use std::collections::HashSet;
use crate::backend::searchsession::Session;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::atomic::AtomicUsize;
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};

// One lock and one batch of attribute reads per this many rows, so an answer never waits long on the cache.
const CHUNK: usize = 512;

// A query cut into its tag names (lowercased) and the text the fuzzy scorer sees; text is the query itself when no tag term stands.
pub(crate) struct Terms {
    pub tags: Vec<String>,
    pub text: String,
}

// Files whose tags Flea itself changed and one worker to re-read them: busy from the first read until the queue runs dry.
struct Rewrites {
    queue: Vec<String>,
    busy: bool,
}

// The row-keyed names the worker has read so far: None is not read yet, an empty list is an untagged entry.
struct Pass {
    names: Mutex<Vec<Option<Vec<String>>>>,
    // One lock decides who re-reads: the first worker takes the queue before it lands, a later write wakes a worker of its own.
    rewrites: Mutex<Rewrites>,
    done: AtomicBool,
    announced: AtomicBool,
    stop: AtomicBool,
    // Bumped when a patch renumbers the rows, so a re-read that located its rows before it locates them again.
    epoch: AtomicUsize,
    // Test seam: attribute reads this pass made, so a query with no tag term can pin zero.
    #[cfg(test)]
    reads: AtomicUsize,
}

impl Pass {
    fn new(len: usize) -> Arc<Pass> {
        Arc::new(Pass {
            names: Mutex::new(vec![None; len]),
            rewrites: Mutex::new(Rewrites { queue: Vec::new(), busy: true }),
            done: AtomicBool::new(false),
            announced: AtomicBool::new(false),
            stop: AtomicBool::new(false),
            epoch: AtomicUsize::new(0),
            #[cfg(test)]
            reads: AtomicUsize::new(0),
        })
    }
}

// A session's tag state; dropping it stops the worker, so close and a patch end the pass with no call.
pub(crate) struct Tags {
    pass: Option<Arc<Pass>>,
    events: Sender<Event>,
    // False while the last answer ran on a pass still reading, so its matches cannot seed a narrowing.
    whole: bool,
    // True from an own tag write until the standing tagged query is re-run on the names it queued.
    rewritten: bool,
}

impl Drop for Tags {
    fn drop(&mut self) {
        if let Some(pass) = &self.pass {
            pass.stop.store(true, Ordering::Relaxed);
        }
    }
}

impl Tags {
    pub(crate) fn new(events: Sender<Event>) -> Tags {
        Tags { pass: None, events, whole: true, rewritten: false }
    }

    // A patch moves row ids: a finished pass keeps every surviving row's names under its new id, with the added rows unread and answered
    // for the caller to queue; a pass still reading numbered its rows under the old ids, so it is dropped and the next tagged query starts one.
    pub(crate) fn carry(&mut self, index: &Index) -> Vec<String> {
        let Some(pass) = &self.pass else { return Vec::new() };
        if !pass.done.load(Ordering::Relaxed) {
            *self = Tags::new(self.events.clone());
            return Vec::new();
        }
        let (kept, survivors) = index.last_patch();
        let mut names = pass.names.lock().unwrap();
        let old = std::mem::take(&mut *names);
        let mut next: Vec<Option<Vec<String>>> = match kept {
            None => old,
            Some(kept) => {
                let mut keep = kept.iter().peekable();
                old.into_iter().enumerate().filter(|(at, _)| keep.next_if(|&&row| row == *at).is_some()).map(|(_, have)| have).collect()
            }
        };
        next.resize(index.len(), None);
        // A re-read that found its rows under the old ids sees this and finds them again.
        pass.epoch.fetch_add(1, Ordering::Relaxed);
        *names = next;
        (survivors..index.len()).map(|row| index.path(row).to_string()).collect()
    }

    // Queues the rows a patch added, so their names are read off the loop and the standing query is re-run once they are in.
    pub(crate) fn read_added(&mut self, added: Vec<String>, index: &Arc<Mutex<Index>>, scope: &Path) {
        if !added.is_empty() {
            self.refresh(added, index, scope);
        }
    }

    // Sample input: "TAG:red holiday" answers tags ["red"], text "holiday"; "bench" answers no tags and text "bench".
    pub(crate) fn terms(query: &str) -> Terms {
        let (tags, text) = split_query(query);
        let text = if tags.is_empty() { query.to_string() } else { text };
        Terms { tags, text }
    }

    // An extension scores only the previous matches: same tags, text grown, and the previous answer saw every row.
    pub(crate) fn narrows(&self, last: &str, query: &str) -> bool {
        if last.is_empty() || !self.whole {
            return false;
        }
        let (before, now) = (Tags::terms(last), Tags::terms(query));
        before.tags == now.tags && now.text.starts_with(&before.text)
    }

    // Starts the worker on the first tagged query once the walk has landed; true while rows are unread, when the answer is partial.
    pub(crate) fn prepare(&mut self, terms: &Terms, index: &Arc<Mutex<Index>>, scope: &Path, walking: bool) -> bool {
        if terms.tags.is_empty() {
            self.whole = true;
            return false;
        }
        // The index is still growing, so a pass now would read a part of it; the landing re-run starts it.
        if walking {
            self.whole = false;
            return true;
        }
        let pass = match &self.pass {
            Some(pass) => Arc::clone(pass),
            None => {
                let len = index.lock().unwrap().len();
                let pass = Pass::new(len);
                let (worker, index, scope, events) =
                    (Arc::clone(&pass), Arc::clone(index), scope.to_path_buf(), self.events.clone());
                std::thread::spawn(move || read_all(&worker, &index, &scope, len, &events));
                self.pass = Some(Arc::clone(&pass));
                pass
            }
        };
        self.whole = pass.done.load(Ordering::Relaxed);
        !self.whole
    }

    // Keeps the hits whose entry carries every named tag; a row the worker has not reached yet carries none, so with no pass none is kept.
    pub(crate) fn keep(&self, hits: &mut Vec<(i32, usize)>, terms: &Terms) {
        if terms.tags.is_empty() {
            return;
        }
        let Some(pass) = &self.pass else {
            hits.clear();
            return;
        };
        let names = pass.names.lock().unwrap();
        hits.retain(|&(_, row)| matches!(names.get(row), Some(Some(have)) if names_carry(have, &terms.tags)));
    }

    // An own tag write: the named files' rows get their names re-read off the loop and swapped in whole. False with no pass open, which reads nothing.
    fn refresh(&mut self, rels: Vec<String>, index: &Arc<Mutex<Index>>, scope: &Path) {
        let Some(pass) = &self.pass else { return };
        self.rewritten = true;
        let mut rewrites = pass.rewrites.lock().unwrap();
        rewrites.queue.extend(rels);
        // A worker already running drains this too, before it lands, so a write during the first read is never lost.
        if !rewrites.busy {
            rewrites.busy = true;
            let (worker, index, scope, events) = (Arc::clone(pass), Arc::clone(index), scope.to_path_buf(), self.events.clone());
            std::thread::spawn(move || land(&worker, &index, &scope, &events, false));
        }
    }

    // True once after a landed rewrite when the standing query carries a tag term, so it is re-run whatever answered in between.
    pub(crate) fn rewrite_due(&mut self, standing: &str) -> bool {
        std::mem::take(&mut self.rewritten) && !Tags::terms(standing).tags.is_empty()
    }

    // True once after the worker finished, so the loop re-runs the standing query exactly once.
    pub(crate) fn poll_read(&self) -> bool {
        self.pass.as_ref().is_some_and(|pass| pass.done.load(Ordering::Relaxed) && !pass.announced.swap(true, Ordering::Relaxed))
    }

    #[cfg(test)]
    pub(crate) fn reads(&self) -> usize {
        self.pass.as_ref().map(|pass| pass.reads.load(Ordering::Relaxed)).unwrap_or(0)
    }
}

impl Session {
    // Own tag writes: an open tag pass re-reads exactly these files' names, then the standing tagged query is re-run once; no pass reads nothing.
    pub(crate) fn note_tags_written(&mut self, written: &[PathBuf]) {
        let rels: Vec<String> =
            written.iter().filter_map(|path| path.strip_prefix(&self.scope).ok()).map(|rel| rel.to_string_lossy().into_owned()).collect();
        if !rels.is_empty() {
            self.tags.refresh(rels, &self.index, &self.scope);
        }
    }
}

// The worker: each indexed row's tags once, in chunks, then the landing event the loop answers the standing query on.
fn read_all(pass: &Pass, index: &Mutex<Index>, scope: &Path, len: usize, events: &Sender<Event>) {
    let mut row = 0;
    while row < len {
        if pass.stop.load(Ordering::Relaxed) {
            return;
        }
        let end = (row + CHUNK).min(len);
        let paths: Vec<String> = {
            let index = index.lock().unwrap();
            // A patch may have shortened the index; its reset stops this pass, but the chunk in hand must not read past the end.
            (row..end.min(index.len())).map(|at| index.path(at).to_string()).collect()
        };
        if paths.is_empty() {
            return;
        }
        let read: Vec<Vec<String>> = paths
            .iter()
            .map(|rel| {
                #[cfg(test)]
                pass.reads.fetch_add(1, Ordering::Relaxed);
                crate::backend::tags::read(&scope.join(rel)).unwrap_or_default()
            })
            .collect();
        let mut names = pass.names.lock().unwrap();
        for (offset, have) in read.into_iter().enumerate() {
            names[row + offset] = Some(have);
        }
        row = end;
    }
    land(pass, index, scope, events, true);
}

// Re-reads each queued write until the queue is dry, then announces: the first worker also marks the pass done under the same lock.
fn land(pass: &Pass, index: &Mutex<Index>, scope: &Path, events: &Sender<Event>, first: bool) {
    loop {
        if pass.stop.load(Ordering::Relaxed) {
            return;
        }
        let rels = {
            let mut rewrites = pass.rewrites.lock().unwrap();
            if rewrites.queue.is_empty() {
                rewrites.busy = false;
                if first {
                    pass.done.store(true, Ordering::Relaxed);
                }
                break;
            }
            std::mem::take(&mut rewrites.queue)
        };
        reread(pass, index, scope, rels);
    }
    if !first {
        pass.announced.store(false, Ordering::Relaxed);
    }
    let _ = events.send(Event::SearchWalked);
}

// Finds the written files' rows in chunks, reads their names, and swaps them in under one lock: the old names stand until then.
fn reread(pass: &Pass, index: &Mutex<Index>, scope: &Path, rels: Vec<String>) {
    let want: HashSet<String> = rels.into_iter().collect();
    loop {
        let epoch = pass.epoch.load(Ordering::Relaxed);
        let mut found: Vec<(usize, String)> = Vec::new();
        let mut row = 0;
        loop {
            let index = index.lock().unwrap();
            let end = (row + CHUNK).min(index.len());
            found.extend((row..end).filter(|&at| want.contains(index.path(at))).map(|at| (at, index.path(at).to_string())));
            if end >= index.len() || found.len() == want.len() {
                break;
            }
            row = end;
        }
        let read: Vec<(usize, Vec<String>)> = found
            .iter()
            .map(|(at, rel)| {
                #[cfg(test)]
                pass.reads.fetch_add(1, Ordering::Relaxed);
                (*at, crate::backend::tags::read(&scope.join(rel)).unwrap_or_default())
            })
            .collect();
        let mut names = pass.names.lock().unwrap();
        // A patch renumbered the rows while they were read, so the ids in hand are stale: locate and read again.
        if pass.epoch.load(Ordering::Relaxed) != epoch {
            continue;
        }
        for (at, have) in read {
            if let Some(slot) = names.get_mut(at) {
                *slot = Some(have);
            }
        }
        return;
    }
}

#[cfg(test)]
#[path = "searchtags_tests.rs"]
mod tests;
