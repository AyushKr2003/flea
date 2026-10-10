// gio trash is the freedesktop trash this box already shares with every GTK app; nothing about the spec is written here, only an argv and a result.
use crate::error::FleaError;
use std::path::{Path, PathBuf};
use std::process::Command;

// gio trash --list prints one entry per line as "<uri>\t<original path>".
const LIST_SEP: char = '\t';
// A hung mount must not hold the single operation slot; trashbrowse.rs bounds gio the same way.
const TRASH_TIMEOUT: &str = "10s";
const TRASH_KILL_AFTER: &str = "1s";

// What a successful trash recorded, which is the only thing that can reverse it.
#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    pub original: PathBuf,
    pub uri: String,
    // URIs the settle list already held, so a step trashed while the settle list was unreadable resolves at undo.
    pub before: Vec<String>,
    // When the settle list was unreadable, in .trashinfo DeletionDate form, else empty.
    pub trashed_at: String,
}

impl Entry {
    // A settle the list never answered keeps the path and the time, so undo resolves it then.
    pub fn unresolved(original: PathBuf, before: Vec<String>, trashed_at: String) -> Entry {
        Entry { original, uri: String::new(), before, trashed_at }
    }
}

// A test stands in for gio on its own thread, because a build container has no trash:// to list or restore.
#[cfg(test)]
thread_local! {
    pub(crate) static STAND_IN: std::cell::RefCell<Option<std::rc::Rc<dyn Fn(&[&str]) -> Option<std::process::Output>>>> =
        const { std::cell::RefCell::new(None) };
}

// corner: gio on an unresponsive network mount can hang, which stalls this operation's own thread and nothing else.
pub(crate) fn gio(args: &[&str]) -> Option<std::process::Output> {
    #[cfg(test)]
    if let Some(stand_in) = STAND_IN.with(|slot| slot.borrow().clone()) {
        return stand_in(args);
    }
    let argv = gio_argv(args);
    Command::new(&argv[0]).args(&argv[1..]).output().ok()
}

// The argv gio runs under, so the suite pins the bound without spawning a subprocess.
fn gio_argv(args: &[&str]) -> Vec<String> {
    let mut out = vec!["timeout".to_string(), format!("--kill-after={TRASH_KILL_AFTER}"), TRASH_TIMEOUT.to_string(), "gio".to_string()];
    out.extend(args.iter().map(|s| s.to_string()));
    out
}

// One chunk's worth of paths per gio call, so the 10 s bound measures a stall and not the batch size.
const TRASH_CHUNK: usize = 64;

// The batch's own reason, so a hung mount or a denial reads as what happened rather than silence.
pub(crate) fn failure_reason(output: &Option<std::process::Output>) -> String {
    match output {
        None => "gio could not be run to move items to Trash".to_string(),
        Some(o) if matches!(o.status.code(), Some(124 | 137)) => "Trash took too long to answer".to_string(),
        Some(o) => {
            let line = String::from_utf8_lossy(&o.stderr).lines().last().unwrap_or("").trim().to_string();
            if line.is_empty() { "gio trash failed".to_string() } else { line }
        }
    }
}

// Sample line: trash:///a.txt\t/home/gm/a.txt
fn parse_list(stdout: &str) -> Vec<Entry> {
    let mut out = Vec::new();
    for line in stdout.lines() {
        let mut parts = line.splitn(2, LIST_SEP);
        let uri = match parts.next() {
            Some(u) if !u.is_empty() => u,
            _ => continue,
        };
        if let Some(original) = parts.next() {
            if !original.is_empty() {
                out.push(Entry { original: PathBuf::from(original), uri: uri.to_string(), before: Vec::new(), trashed_at: String::new() });
            }
        }
    }
    out
}

// A test counts the expensive call per item, never wall time: every list() here is one gio spawn.
#[cfg(test)]
thread_local! {
    static LIST_CALLS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}
#[cfg(test)]
pub(crate) fn test_list_calls() -> usize {
    LIST_CALLS.with(|v| v.get())
}
#[cfg(test)]
pub(crate) fn test_reset_list_calls() {
    LIST_CALLS.with(|v| v.set(0));
}

pub fn list() -> Option<Vec<Entry>> {
    #[cfg(test)]
    LIST_CALLS.with(|v| v.set(v.get() + 1));
    // None unless gio exited 0, so a list cut short by the wait journals no URI at all.
    match gio(&["trash", "--list"]) {
        Some(o) if o.status.success() => Some(parse_list(&String::from_utf8_lossy(&o.stdout))),
        _ => None,
    }
}

// The URI is captured here rather than looked up later, because gio trash --restore refuses an original
// path outright and two files trashed from one path both list that same path, so a later lookup is ambiguous.
pub fn trash(paths: &[PathBuf]) -> (Vec<Entry>, usize, String) {
    match trash_checked(paths, None) {
        Ok(result) => result,
        Err(error) => { eprintln!("flea: {}", error); (Vec::new(), paths.len(), error) }
    }
}

pub(crate) fn trash_checked(paths: &[PathBuf], selection: Option<&[super::menu_actions::Selected]>) -> Result<(Vec<Entry>, usize, String), String> {
    // A leading empty path is a drag that left this window. The receiver may already have moved
    // the file and still accepted a move; a path that is gone is then nothing left to delete.
    let (quiet_gone, paths) = match paths.first() {
        Some(path) if path.as_os_str().is_empty() => (true, &paths[1..]),
        _ => (false, paths),
    };
    super::menu_actions::validate_sources(selection, paths)?;
    if paths.is_empty() {
        return Ok((Vec::new(), 0, String::new()));
    }
    // Issue 88, nixfred: a path already gone before the call read as trashed afterwards and was
    // journaled as a step with no trash entry, which is where undo stopped, so it is a failure here.
    let (present, missing): (Vec<&PathBuf>, Vec<&PathBuf>) =
        paths.iter().partition(|p| p.symlink_metadata().is_ok());
    if present.is_empty() {
        let reason = if quiet_gone || missing.is_empty() { String::new() } else { "those items are already gone".to_string() };
        return Ok((Vec::new(), if quiet_gone { 0 } else { missing.len() }, reason));
    }
    let before = list();
    super::menu_actions::validate_sources(selection, paths)?;
    // The exit status covers one chunk, so which paths actually went is read off the filesystem instead.
    let mut output: Option<std::process::Output> = None;
    for chunk in present.chunks(TRASH_CHUNK) {
        let mut argv: Vec<String> = vec!["trash".to_string(), "--".to_string()];
        for p in chunk {
            argv.push(p.to_string_lossy().to_string());
        }
        let refs: Vec<&str> = argv.iter().map(|s| s.as_str()).collect();
        let out = gio(&refs);
        let stop = !matches!(&out, Some(o) if o.status.success());
        output = out;
        if stop {
            break;
        }
    }
    let after = list();
    let mut ok = Vec::new();
    let mut failed = if quiet_gone { 0 } else { missing.len() };
    let mut still_here = 0;
    for p in present {
        if p.symlink_metadata().is_ok() {
            failed += 1;
            still_here += 1;
            continue;
        }
        match before.as_ref().zip(after.as_ref()).and_then(|(b, a)| newest_entry_for(b, a, p)) {
            Some(e) => ok.push(e),
            // corner: the file went but gio listed no entry for it, so it is gone and simply not reversible.
            None => ok.push(Entry::unresolved((*p).clone(), Vec::new(), String::new())),
        }
    }
    let gio_failed = !matches!(&output, Some(o) if o.status.success());
    let reason = if failed == 0 {
        String::new()
    } else if gio_failed {
        failure_reason(&output)
    } else if still_here > 0 {
        "those items are still there".to_string()
    } else {
        "those items are already gone".to_string()
    };
    Ok((ok, failed, reason))
}

// Only an entry that was not already in the trash before this call can be one this call put there.
pub(crate) fn newest_entry_for(before: &[Entry], after: &[Entry], path: &Path) -> Option<Entry> {
    after
        .iter()
        .find(|e| e.original == path && !before.iter().any(|b| b.uri == e.uri))
        .cloned()
}

pub fn restore(entry: &Entry) -> Result<(), FleaError> {
    if !entry.uri.is_empty() {
        // A home Trash entry whose own record names this path goes back in-process, so undo spawns no gio for it.
        if let Some(done) = super::homerestore::restore_from_home(entry) {
            return done.map_err(|msg| err(&msg));
        }
        return restore_uri(entry);
    }
    // Only a step whose settle read the before list carries a time; an old record or the gio-listed-nothing corner cannot be told from another item of the same path.
    if entry.trashed_at.is_empty() {
        return Err(err("this item was trashed without a trash entry, so it cannot be restored"));
    }
    // A list that fails says so, never that the item is gone from a Trash nobody could read.
    let Some(after) = list() else {
        return Err(err("the Trash could not be listed, so that item cannot be restored yet"));
    };
    let mut found = after.iter().filter(|e| e.original == entry.original && !entry.before.contains(&e.uri));
    // Two new entries for one path cannot be told apart, so undo refuses rather than guess.
    match (found.next(), found.next()) {
        (Some(one), None) => restore_uri(one),
        (None, _) => Err(err(&format!("that item was trashed at {} but is no longer listed, so it cannot be restored", entry.trashed_at))),
        (Some(_), Some(_)) => Err(err(&format!(
            "that item was trashed at {} but the Trash holds more than one new item from that place, so it cannot be restored",
            entry.trashed_at
        ))),
    }
}

fn restore_uri(entry: &Entry) -> Result<(), FleaError> {
    match gio(&["trash", "--restore", &entry.uri]) {
        Some(o) if o.status.success() => Ok(()),
        Some(o) => {
            let msg = String::from_utf8_lossy(&o.stderr);
            Err(err(msg.lines().last().unwrap_or("gio trash --restore failed")))
        }
        None => Err(err("gio is not available to restore from the trash")),
    }
}

fn err(msg: &str) -> FleaError {
    FleaError { where_: "undo".to_string(), path: String::new(), msg: msg.to_string() }
}

// The journal's "t" record: an ordinary entry encodes as before, an unattributed settle adds its resolution data.
pub(crate) fn encode_step(entry: &Entry) -> crate::jsondoc::Json {
    use super::undocodec::{arr, obj, s};
    let mut fields = vec![("k", s("t")), ("path", s(&entry.original.to_string_lossy())), ("uri", s(&entry.uri))];
    if !entry.before.is_empty() {
        fields.push(("before", arr(entry.before.iter().map(|uri| s(uri)).collect())));
    }
    if !entry.trashed_at.is_empty() {
        fields.push(("time", s(&entry.trashed_at)));
    }
    obj(fields)
}

// A record from before settle-time resolution data was kept has neither "before" nor "time", and decodes empty.
pub(crate) fn decode_step(pairs: &[(String, crate::jsondoc::Json)]) -> Option<super::undo::Step> {
    use super::undocodec::{checked_path, checked_text, checked_uri, get};
    let before = match get(pairs, "before") {
        Some(crate::jsondoc::Json::Arr(items)) => items.iter().filter_map(checked_text).collect(),
        _ => Vec::new(),
    };
    Some(super::undo::Step::Trashed(Entry {
        original: checked_path(get(pairs, "path")?)?,
        uri: checked_uri(get(pairs, "uri")?)?,
        before,
        trashed_at: get(pairs, "time").and_then(checked_text).unwrap_or_default(),
    }))
}

#[cfg(test)]
#[path = "trash_tests.rs"]
mod tests;
