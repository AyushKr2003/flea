// Issue 144: a list scans on its own thread and answers as an event, and requests that arrive meanwhile wait in `Gate` and replay in order.
use crate::backend::events::Event;
use crate::backend::iomount::{internal_failure, ListErr, ListOut};
use crate::backend::proto::{error_line, error_line_with_mode};
use crate::backend::run::{adopt_listed, forget_rows};
use crate::backend::searchreq::finish_search;
use crate::backend::state::{State, Tables};
use crate::backend::thumbs::Pool;
use crate::backend::watch::Watch;
use std::collections::VecDeque;
use std::io::Write;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::sync::mpsc::Sender;
use std::sync::Arc;
use std::thread;

// One scan the loop has started and not yet adopted, with the request it answers.
pub struct Job {
    pub path: String,
    pub first: usize,
    // The request line, because ordering and the picker filter read it on the scan's own thread.
    pub line: String,
    pub hidden: bool,
    // The reload count rides the landed listing, so it travels with the job rather than the line.
    pub want_changed: bool,
}

// The scan's own answer, carried back on the loop's one channel like a thumbnail's or a size's.
pub struct Done {
    // A failure carries the mode the worker read, because that stat can hang on the same stalled mount.
    pub result: Result<ListOut, ListErr>,
}

// A job and the answer that closes it, so the loop hands the pair over in one argument.
pub struct Landed {
    pub job: Job,
    pub done: Done,
}

// What waits for a scan: the job, the requests behind it, and the watch bursts seen before the new descriptor is known.
pub struct Gate {
    job: Option<Job>,
    deferred: VecDeque<String>,
    changes: Vec<i32>,
    closed: bool,
}

impl Gate {
    pub fn new() -> Gate {
        Gate { job: None, deferred: VecDeque::new(), changes: Vec::new(), closed: false }
    }

    // True while a scan is out, which is when a request cannot be answered against the listing it will replace.
    pub fn holds(&self) -> bool {
        self.job.is_some()
    }

    pub fn begin(&mut self, job: Job) {
        self.job = Some(job);
    }

    pub fn take(&mut self) -> Option<Job> {
        self.job.take()
    }

    pub fn defer(&mut self, line: String) {
        self.deferred.push_back(line);
    }

    pub fn next(&mut self) -> Option<String> {
        self.deferred.pop_front()
    }

    pub fn note_change(&mut self, wd: i32) {
        self.changes.push(wd);
    }

    pub fn take_changes(&mut self) -> Vec<i32> {
        std::mem::take(&mut self.changes)
    }

    pub fn close(&mut self) {
        self.closed = true;
    }

    pub fn closed(&self) -> bool {
        self.closed
    }

    // Nothing outstanding and nothing queued: the point at which a closed stdin can leave.
    pub fn idle(&self) -> bool {
        self.job.is_none() && self.deferred.is_empty()
    }
}

// Ends the walk on the loop, then runs list_dir on its own thread, so a slow readdir or stat never holds the loop.
pub fn start(out: &mut impl Write, st: &mut State, pool: &Pool, watch: &mut Watch, tx: &Sender<Event>,
             job: Job, mime: Arc<super::mime::Db>) -> Job {
    // A new listing replaces whatever the walk was filling, so the walk ends before the scan starts.
    if finish_search(out, st, true) {
        forget_rows(st, pool);
    }
    // Read here, because the watch lives on the loop and the worker only carries the number.
    let fd = watch.raw_fd();
    let path = job.path.clone();
    let line = job.line.clone();
    let answer_tx = tx.clone();
    let worker_tx = tx.clone();
    spawn_list(answer_tx, job.path.clone(), move || Done {
        result: super::iomount::list_dir(path, job.hidden, job.first, line, mime, fd, worker_tx),
    });
    job
}

// A landed scan becomes the listing and a failed one leaves it alone; true when it became the listing.
pub fn finish<W: Write>(out: &mut W, st: &mut State, tb: &Tables, pool: &Pool, watch: &mut Watch, landed: Landed) -> bool {
    let Landed { job, done } = landed;
    let Job { path, first: _, line: _, hidden: _, want_changed } = job;
    let landed = match done.result {
        Ok(listed) => {
            watch.set_incoming(listed.watch_wd);
            watch.commit();
            // Said once per listing, because a folder nobody can watch goes stale in silence.
            if watch.refused() {
                eprintln!("flea: {} will not follow outside changes, inotify refused a watch on it", path);
            }
            adopt_listed(out, st, pool, tb, &path, listed, want_changed);
            out.flush().ok();
            true
        }
        Err(failed) => {
            // The listing did not move, so the loop removes the watch the failed scan armed.
            watch.abandon_wd(failed.watch_wd);
            // The denial's mode rides the answer from the worker, because a stat here would hang the loop on a stalled mount.
            if failed.mode == 0 {
                writeln!(out, "{}", error_line(&failed.error)).ok();
            } else {
                writeln!(out, "{}", error_line_with_mode(&failed.error, failed.mode)).ok();
            }
            false
        }
    };
    out.flush().ok();
    crate::prefetch::first_rows_sent();
    landed
}

// The scan answers exactly once, a panic included, or the gate would hold for good; see iomount's dead worker.
fn spawn_list(tx: Sender<Event>, path: String, work: impl FnOnce() -> Done + Send + 'static) {
    thread::spawn(move || {
        let done = catch_unwind(AssertUnwindSafe(work)).unwrap_or_else(|_| Done {
            result: Err(ListErr { error: internal_failure("scan", Path::new(&path)), mode: 0, watch_wd: -1 }),
        });
        let _ = tx.send(Event::List(done));
    });
}

#[cfg(test)]
#[path = "listwork_tests.rs"]
mod tests;
