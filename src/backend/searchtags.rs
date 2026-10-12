// The tag terms of a live search query: split off the query, read once per row on a worker thread, never on the loop.
use crate::backend::events::Event;
use crate::backend::search::{names_carry, split_query};
use crate::backend::searchindex::Index;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
#[cfg(test)]
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

// The row-keyed names the worker has read so far: None is not read yet, an empty list is an untagged entry.
struct Pass {
    names: Mutex<Vec<Option<Vec<String>>>>,
    done: AtomicBool,
    announced: AtomicBool,
    stop: AtomicBool,
    // Test seam: attribute reads this pass made, so a query with no tag term can pin zero.
    #[cfg(test)]
    reads: AtomicUsize,
}

// A session's tag state; dropping it stops the worker, so close and a patch end the pass with no call.
pub(crate) struct Tags {
    pass: Option<Arc<Pass>>,
    events: Sender<Event>,
    // False while the last answer ran on a pass still reading, so its matches cannot seed a narrowing.
    whole: bool,
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
        Tags { pass: None, events, whole: true }
    }

    // A patch moves every row id, so the names read for the old numbering go with the pass that read them.
    pub(crate) fn reset(&mut self) {
        *self = Tags::new(self.events.clone());
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
                let pass = Arc::new(Pass {
                    names: Mutex::new(vec![None; len]),
                    done: AtomicBool::new(false),
                    announced: AtomicBool::new(false),
                    stop: AtomicBool::new(false),
                    #[cfg(test)]
                    reads: AtomicUsize::new(0),
                });
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

    // Keeps the hits whose entry carries every named tag; a row the worker has not reached yet carries none.
    pub(crate) fn keep(&self, hits: &mut Vec<(i32, usize)>, terms: &Terms) {
        let Some(pass) = &self.pass else { return };
        if terms.tags.is_empty() {
            return;
        }
        let names = pass.names.lock().unwrap();
        hits.retain(|&(_, row)| matches!(names.get(row), Some(Some(have)) if names_carry(have, &terms.tags)));
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
    pass.done.store(true, Ordering::Relaxed);
    let _ = events.send(Event::SearchWalked);
}

#[cfg(test)]
#[path = "searchtags_tests.rs"]
mod tests;
