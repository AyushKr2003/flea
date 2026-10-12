// Properties on a folder counts its contents with the folder size walker, on the menu worker and under the request's own cancel.
use super::dirsize::{walk_counted, Progress, Tally};
use super::menu_actions::{response, Selected};
use super::opsreq::{OpMsg, PROGRESS_EVERY};
use super::trashmanifest::Cancellation;
use crate::json::field_usize;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

// Sample input: {"c":"menuaction","op":"contents","id":4} answers a progress line every PROGRESS_EVERY, then one final line.
// False once the receiver is gone, so the worker ends with it.
pub(super) fn serve(line: &str, id: usize, items: &[Selected], replies: &Sender<OpMsg>, cancel: &Cancellation) -> bool {
    serve_with_deadline(line, id, items, replies, cancel, super::iomount::BULK_DEADLINE)
}

// The bulk deadline bounds only a remote folder; a local one walks inline exactly as before.
fn serve_with_deadline(line: &str, id: usize, items: &[Selected], replies: &Sender<OpMsg>, cancel: &Cancellation, deadline: Duration) -> bool {
    if id == 0 || field_usize(line, "id") != Some(id) || items.len() != 1 {
        return send(replies, line, Err("Menu selection expired; reopen the menu.".into()));
    }
    let body = super::iomount::mount_body();
    if super::iomount::is_remote(&items[0].path, &body) {
        serve_remote(line, &items[0], replies, cancel, deadline)
    } else {
        serve_local(line, id, items, replies, cancel)
    }
}

fn send(replies: &Sender<OpMsg>, line: &str, fields: Result<String, String>) -> bool {
    replies.send(OpMsg::Meta { line: response(line, fields) }).is_ok()
}

fn serve_local(line: &str, id: usize, items: &[Selected], replies: &Sender<OpMsg>, cancel: &Cancellation) -> bool {
    let send = |fields: Result<String, String>| send(replies, line, fields);
    let folder = match folder_of(line, id, items) {
        Ok(folder) => folder,
        Err(error) => return send(Err(error)),
    };
    let open = std::cell::Cell::new(true);
    // A progress line nobody takes ends the walk at once instead of counting for nobody.
    let stopped = || {
        if let Some(pace) = test_pace() { std::thread::sleep(pace); }
        cancel.check().is_err() || !open.get()
    };
    let mut report = |tally: &Tally| {
        if !send(Ok(fields(tally, false))) { open.set(false); }
    };
    let progress = Progress { every: PROGRESS_EVERY, report: &mut report };
    let tally = walk_counted(&folder, &stopped, Some(progress));
    // A cancelled walk is a floor and never says done; close has already told the card to leave.
    let last = if stopped() { format!(r#"{},"cancelled":true"#, fields(&tally, false)) } else { fields(&tally, true) };
    open.get() && send(Ok(last))
}

// What the remote worker hands back: the walk's own tally, or the refusal before any walk started.
struct RemoteDone {
    tally: Tally,
    cancelled: bool,
}

// The worker's lines to the menu thread: throttled progress, then the one ending.
enum RemoteMsg {
    Report(Tally),
    Done(Result<RemoteDone, String>),
}

// The floor so far and the stop both sides share; the worker never touches the replies channel.
struct RemoteShared {
    stop: AtomicBool,
    floor: Mutex<Tally>,
}

// A remote walk runs beside the menu worker under the bulk deadline; past it the menu answers the floor so far.
fn serve_remote(line: &str, item: &Selected, replies: &Sender<OpMsg>, cancel: &Cancellation, deadline: Duration) -> bool {
    let shared = Arc::new(RemoteShared { stop: AtomicBool::new(false), floor: Mutex::new(Tally { bytes: 0, items: 0, partial: true }) });
    let (done_tx, done_rx) = std::sync::mpsc::channel();
    let worker_item = item.clone();
    let worker_cancel = cancel.clone();
    let worker_shared = Arc::clone(&shared);
    let pace = test_pace();
    std::thread::spawn(move || remote_walk(&worker_item, &worker_cancel, &worker_shared, pace, &done_tx));
    remote_wait(line, replies, cancel, &shared, &done_rx, deadline)
}

// The single syscall that decides the folder happens on the worker too, so a hung mount never holds the menu worker.
fn remote_walk(item: &Selected, cancel: &Cancellation, shared: &RemoteShared, pace: Option<Duration>, done: &std::sync::mpsc::Sender<RemoteMsg>) {
    let outcome = match item.current() {
        Ok(meta) if meta.is_dir() => {
            shared.floor.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).bytes = meta.len();
            let stop = || {
                if let Some(pace) = pace { std::thread::sleep(pace); }
                cancel.check().is_err() || shared.stop.load(Ordering::Relaxed)
            };
            let mut forwarded = Instant::now();
            let mut report = |tally: &Tally| {
                *shared.floor.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = *tally;
                if forwarded.elapsed() >= PROGRESS_EVERY {
                    forwarded = Instant::now();
                    let _ = done.send(RemoteMsg::Report(*tally));
                }
            };
            let tally = walk_counted(&item.path, &stop, Some(Progress { every: Duration::ZERO, report: &mut report }));
            Ok(RemoteDone { tally, cancelled: cancel.check().is_err() || shared.stop.load(Ordering::Relaxed) })
        }
        Ok(_) => Err("Only a folder has contents to count.".into()),
        Err(error) => Err(error),
    };
    let _ = done.send(RemoteMsg::Done(outcome));
}

// Every wire line leaves from the menu worker, so a progress line never lands past the final one.
fn remote_wait(line: &str, replies: &Sender<OpMsg>, cancel: &Cancellation, shared: &RemoteShared, done: &std::sync::mpsc::Receiver<RemoteMsg>, deadline: Duration) -> bool {
    let bound = Instant::now() + deadline;
    let mut progress_due = Instant::now();
    loop {
        match done.recv_timeout(Duration::from_millis(20)) {
            Ok(RemoteMsg::Report(tally)) => {
                if Instant::now() >= progress_due {
                    progress_due = Instant::now() + PROGRESS_EVERY;
                    if !send(replies, line, Ok(fields(&tally, false))) {
                        shared.stop.store(true, Ordering::Relaxed);
                        return false;
                    }
                }
            }
            Ok(RemoteMsg::Done(outcome)) => return land_remote(line, replies, outcome),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                // A walk blocked in a syscall never sees the cancel, so the menu thread answers it here.
                if cancel.check().is_err() {
                    shared.stop.store(true, Ordering::Relaxed);
                    return send(replies, line, Ok(format!(r#"{},"cancelled":true"#, fields(&timed_out_floor(shared), false))));
                }
                if Instant::now() >= bound {
                    shared.stop.store(true, Ordering::Relaxed);
                    return send(replies, line, Ok(fields(&timed_out_floor(shared), true)));
                }
            }
            // A dead worker leaves the floor already reported, marked partial rather than exact.
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                return send(replies, line, Ok(fields(&timed_out_floor(shared), true)));
            }
        }
    }
}

fn timed_out_floor(shared: &RemoteShared) -> Tally {
    let mut floor = *shared.floor.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    floor.partial = true;
    floor
}

fn land_remote(line: &str, replies: &Sender<OpMsg>, outcome: Result<RemoteDone, String>) -> bool {
    match outcome {
        Err(error) => send(replies, line, Err(error)),
        Ok(done) if done.cancelled => send(replies, line, Ok(format!(r#"{},"cancelled":true"#, fields(&done.tally, false)))),
        Ok(done) => send(replies, line, Ok(fields(&done.tally, true))),
    }
}

// Test-only stretch of each stop check; production passes None through test_pace, so the walk is unpaced.
#[cfg(test)]
thread_local! {
    static TEST_PACE: std::cell::Cell<Option<Duration>> = const { std::cell::Cell::new(None) };
}

// Read on the menu thread and moved onto the worker, so holding it never races the walk.
#[cfg(test)]
fn test_pace() -> Option<Duration> {
    TEST_PACE.with(|slot| slot.get())
}

// Holds the stretch until the guard drops, so one test's slow walk never leaks into the next.
#[cfg(test)]
pub(crate) struct PaceGuard;

// Starts the stretch; the worker takes the value, so the hold itself is race free.
#[cfg(test)]
pub(crate) fn test_hold_pace(pace: Duration) -> PaceGuard {
    TEST_PACE.with(|slot| slot.set(Some(pace)));
    PaceGuard
}

// Dropping the guard hands the walk back its unpaced stop, so no later test walks slowly.
#[cfg(test)]
impl Drop for PaceGuard {
    fn drop(&mut self) {
        TEST_PACE.with(|slot| slot.set(None));
    }
}

#[cfg(not(test))]
fn test_pace() -> Option<Duration> {
    None
}

// The one captured item, and only while it is still a folder: a link to one is described as the link.
fn folder_of(line: &str, id: usize, items: &[Selected]) -> Result<PathBuf, String> {
    if id == 0 || field_usize(line, "id") != Some(id) || items.len() != 1 {
        return Err("Menu selection expired; reopen the menu.".into());
    }
    if !items[0].current()?.is_dir() { return Err("Only a folder has contents to count.".into()); }
    Ok(items[0].path.clone())
}

fn fields(tally: &Tally, done: bool) -> String {
    format!(r#""bytes":{},"items":{},"partial":{},"done":{}"#, tally.bytes, tally.items, tally.partial, done)
}

#[cfg(test)]
#[path = "menucontents_tests.rs"]
mod tests;
