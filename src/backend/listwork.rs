// Issue 144: `list` used to scan inline on the event loop, so a `read_dir` on an MTP or FUSE mount
// held the loop for as long as the device took. Transfer progress piled up unwritten and a
// `transfercancel` sat unread behind the scan, so the copy ran on and the window looked hung. The
// scan runs on its own thread here and answers as an event, and every request that arrived while it
// was out waits in `Gate` and replays in the order it arrived, so the wire's request ordering is
// exactly what it was when the scan was inline.
use crate::backend::events::Event;
use crate::backend::proto::{error_line, error_line_with_mode};
use crate::backend::run::{adopt_listed, forget_rows};
use crate::backend::searchreq::finish_search;
use crate::backend::state::{State, Tables};
use crate::backend::thumbs::Pool;
use crate::backend::watch::Watch;
use std::collections::VecDeque;
use std::io::Write;
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
    // The worker's answer with its watch descriptor; on failure it also carries the mode the
    // worker read, because that stat can hang on the same stalled mount the scan did.
    pub result: Result<super::iomount::ListOut, super::iomount::ListErr>,
}

// A job and the answer that closes it, so the loop hands the pair over in one argument.
pub struct Landed {
    pub job: Job,
    pub done: Done,
}

// Everything that waits for a scan: the job in flight, the requests that arrived behind it, and the
// watch bursts seen while the descriptor that will be current is not yet known.
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

// A list request starts the scan and returns at once: the walk ends here on the loop, and the
// mount's own list_dir runs on the scan's thread, so neither a slow readdir nor its window stat
// ever holds the loop.
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
    spawn_list(answer_tx, move || Done {
        result: super::iomount::list_dir(path, job.hidden, job.first, line, mime, fd, worker_tx),
    });
    job
}

// The scan landed: it becomes the listing and is answered, or it failed and the listing does not move.
// True when the scan became the listing, so the caller lays the fresh figures and the poll beside it.
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
            // A typed path reaches the denial with no parent row to remember the mode from,
            // so the stat that survives the refused read is the pane's only source for it.
            // The mode rode the answer from the worker, because on a stalled mount it hangs
            // exactly as the scan did and must never be read here on the loop.
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

// The scan runs off the loop and answers on the loop's own channel, the way a thumbnail or a size does.
fn spawn_list(tx: Sender<Event>, work: impl FnOnce() -> Done + Send + 'static) {
    thread::spawn(move || {
        let _ = tx.send(Event::List(work()));
    });
}

#[cfg(test)]
#[path = "listwork_tests.rs"]
mod tests;
