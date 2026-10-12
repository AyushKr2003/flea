// An AppImage row's own icon: 7z lists the image in the archive jail, the .DirIcon chain is resolved here, one member is extracted and published as the row's thumbnail.
use crate::backend::archivework::{run_boxed_cancellable_capped, Work};
use crate::backend::child::{run_with_timeout, Ran};
use crate::backend::sandbox;
use crate::backend::thumbargv::argv;
use crate::backend::thumbcache::uri_for;
use crate::backend::thumbspec::{is_runnable, Spec};
use crate::backend::thumbs::{discard, publish, record_failure, records_marker, wrote_something, Job, Outcome, Tables, JOB_TIMEOUT, THUMB_SIZE};
use crate::backend::thumbwrite::exclusive_temp;
use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

// The 7zip optdepend; the jail binds /usr read-only, so this path resolves inside it.
pub(crate) const TOOL: &str = "/usr/bin/7z";
// exec[0] of the internal spec: never run, only read by is_route.
const ROUTE: &str = "appimage-icon";
pub(crate) const MIMES: [&str; 2] = ["application/vnd.appimage", "application/x-iso9660-appimage"];
// The first path component the icon is named by, at the image root.
const DIR_ICON: &str = ".DirIcon";
// A .DirIcon may link on to the real file; a fifth link, or a loop, is refused.
const LINK_LIMIT: usize = 4;
const MAX_ICON_BYTES: u64 = 4 << 20;
const MAX_LIST_BYTES: u64 = 16 << 20;
const WATCH_STEP: Duration = Duration::from_millis(50);
const PNG_SIGNATURE: [u8; 8] = [0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a];
const SVG_SCAN_BYTES: usize = 4096;

pub(crate) fn available() -> bool {
    is_runnable(TOOL)
}

pub(crate) fn route_spec() -> Spec {
    Spec { exec: vec![ROUTE.to_string()] }
}

pub(crate) fn is_route(spec: &Spec) -> bool {
    spec.exec.first().is_some_and(|program| program == ROUTE)
}

// Why no icon was made: the image said no, or the clock did.
#[derive(Debug, PartialEq)]
pub(crate) enum Stop {
    Refused,
    TimedOut,
}

pub(crate) fn run(tables: &Tables, job: &Job) -> Outcome {
    run_with(&[TOOL.to_string()], within, tables, job)
}

// Runs one tool argv with the image readable and the work folder writable, under the deadline.
type Runner = fn(Vec<String>, &Path, &mut Work, Duration) -> Result<(), Stop>;

// The tool is a prefix argv and the runner a parameter so a test can stand a script in for 7z and for the jail.
pub(crate) fn run_with(tool: &[String], runner: Runner, tables: &Tables, job: &Job) -> Outcome {
    // corner: a missing package or an input that will not canonicalise is the machine's, so nothing is recorded; see AGENTS.md "Thumbnail sandbox".
    if !sandbox::available() || !tool.first().is_some_and(|program| is_runnable(program)) {
        return Outcome::Failed;
    }
    let image = match std::fs::canonicalize(&job.path) {
        Ok(p) => p,
        Err(_) => return Outcome::Failed,
    };
    let key_uri = uri_for(&job.path);
    let final_path = tables.cache.large_path(&key_uri);
    let dir = tables.cache.large_dir();
    if std::fs::create_dir_all(&dir).is_err() {
        return Outcome::Failed;
    }
    let (mut work, temp) = match (Work::new(&dir, "appicon"), exclusive_temp(&dir)) {
        (Ok(w), Some(t)) => (w, t),
        _ => return Outcome::Failed,
    };
    let ran = match icon(tool, runner, &image, &mut work, JOB_TIMEOUT) {
        Ok(member) => make(tables, &member, &temp),
        Err(Stop::TimedOut) => Ran::TimedOut,
        Err(Stop::Refused) => Ran::Failed,
    };
    if matches!(ran, Ran::Succeeded) && wrote_something(&temp) {
        return publish(&temp, &key_uri, job.mtime, final_path);
    }
    if records_marker(&ran, super::extclass::classify(&job.path)) {
        record_failure(&tables.cache, &key_uri, job.mtime);
    }
    discard(&temp)
}

// Writes the thumbnail into temp: a PNG member as it is, an SVG through the existing image/svg+xml spec in the same jail.
fn make(tables: &Tables, member: &Path, temp: &Path) -> Ran {
    let bytes = match std::fs::read(member) {
        Ok(b) => b,
        Err(_) => return Ran::Failed,
    };
    if is_png(&bytes) {
        return if std::fs::write(temp, &bytes).is_ok() { Ran::Succeeded } else { Ran::NotStarted };
    }
    if !is_svg(&bytes) {
        return Ran::Failed;
    }
    let Some(spec) = tables.specs.for_mime("image/svg+xml", &tables.aliases) else { return Ran::Failed };
    let Some((abs, inner)) = argv(spec, member, temp, THUMB_SIZE) else { return Ran::NotStarted };
    let mut full = sandbox::wrap(&inner, &abs, temp);
    sandbox::add_status(&mut full, inner.len());
    run_with_timeout(&full, JOB_TIMEOUT)
}

// The stamp needs an IHDR right after the signature, so a PNG without one is refused here and recorded.
fn is_png(bytes: &[u8]) -> bool {
    bytes.starts_with(&PNG_SIGNATURE) && bytes.get(12..16) == Some(b"IHDR")
}

fn is_svg(bytes: &[u8]) -> bool {
    String::from_utf8_lossy(&bytes[..bytes.len().min(SVG_SCAN_BYTES)]).contains("<svg")
}

// The extracted member's path: list once, resolve the chain, extract that one member.
fn icon(tool: &[String], runner: Runner, image: &Path, work: &mut Work, limit: Duration) -> Result<PathBuf, Stop> {
    let started = Instant::now();
    let list = work.dir.join("list.txt");
    // 7z lists on stdout and the jail discards it, so the shell redirects it into the work folder.
    let mut inner: Vec<String> = ["/usr/bin/sh", "-c", r#"out=$1; shift; exec "$@" >"$out""#, "sh"].map(String::from).to_vec();
    inner.push(list.to_string_lossy().to_string());
    inner.extend_from_slice(tool);
    inner.extend(["l", "-slt", "--"].map(String::from));
    inner.push(image.to_string_lossy().to_string());
    runner(inner, image, work, limit)?;
    let member = resolve(&read_capped(&list, MAX_LIST_BYTES)?).map_err(|_| Stop::Refused)?;
    let out = work.dir.join("icon");
    let mut inner: Vec<String> = tool.to_vec();
    inner.extend(["e", "-y", "-bd"].map(String::from));
    inner.push(format!("-o{}", out.to_string_lossy()));
    inner.push("--".to_string());
    inner.push(image.to_string_lossy().to_string());
    inner.push(member);
    runner(inner, image, work, limit.saturating_sub(started.elapsed()))?;
    only_file(&out)
}

// One job in the archive jail under a deadline; a cancel the clock set reads as a timeout.
fn within(inner: Vec<String>, image: &Path, work: &mut Work, limit: Duration) -> Result<(), Stop> {
    let cancel = AtomicBool::new(false);
    let done = AtomicBool::new(false);
    let result = std::thread::scope(|scope| {
        scope.spawn(|| {
            let end = Instant::now() + limit;
            while !done.load(Ordering::Relaxed) && Instant::now() < end {
                std::thread::sleep(WATCH_STEP);
            }
            if !done.load(Ordering::Relaxed) {
                cancel.store(true, Ordering::Relaxed);
            }
        });
        let result = run_boxed_cancellable_capped("appimage icon", inner, image, work, &cancel);
        done.store(true, Ordering::Relaxed);
        result
    });
    match result {
        Ok(()) => Ok(()),
        Err(_) if cancel.load(Ordering::Relaxed) => Err(Stop::TimedOut),
        Err(_) => Err(Stop::Refused),
    }
}

fn read_capped(path: &Path, cap: u64) -> Result<String, Stop> {
    let mut bytes = Vec::new();
    let file = std::fs::File::open(path).map_err(|_| Stop::Refused)?;
    file.take(cap + 1).read_to_end(&mut bytes).map_err(|_| Stop::Refused)?;
    if bytes.len() as u64 > cap {
        return Err(Stop::Refused);
    }
    Ok(String::from_utf8_lossy(&bytes).to_string())
}

// The extract must leave exactly one regular file, never a link, within the size cap.
fn only_file(out: &Path) -> Result<PathBuf, Stop> {
    let mut found = std::fs::read_dir(out).map_err(|_| Stop::Refused)?.flatten();
    let (Some(entry), None) = (found.next(), found.next()) else { return Err(Stop::Refused) };
    let meta = std::fs::symlink_metadata(entry.path()).map_err(|_| Stop::Refused)?;
    if !meta.is_file() || meta.len() == 0 || meta.len() > MAX_ICON_BYTES {
        return Err(Stop::Refused);
    }
    Ok(entry.path())
}

struct Entry {
    link: Option<String>,
    folder: bool,
    size: u64,
}

// Sample input, `7z l -slt` after the "----------" line: "Path = .DirIcon", "Symbolic Link = app.png", then a blank line per record.
fn entries(listing: &str) -> HashMap<String, Entry> {
    let mut found = HashMap::new();
    let Some((_, records)) = listing.split_once("\n----------\n") else { return found };
    for record in records.split("\n\n") {
        let (mut path, mut link, mut folder, mut size) = (None, None, false, 0);
        for line in record.lines() {
            match line.split_once(" = ") {
                Some(("Path", v)) => path = clean(v),
                Some(("Symbolic Link", v)) if !v.is_empty() => link = Some(v.to_string()),
                Some(("Folder", v)) => folder = v == "+",
                Some(("Size", v)) => size = v.parse().unwrap_or(0),
                _ => {}
            }
        }
        if let Some(path) = path {
            found.insert(path, Entry { link, folder, size });
        }
    }
    found
}

// A path inside the image with `.` and `..` folded away; None for an absolute path or one that climbs past the root.
fn clean(path: &str) -> Option<String> {
    if path.starts_with('/') {
        return None;
    }
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop()?;
            }
            _ => parts.push(part),
        }
    }
    (!parts.is_empty()).then(|| parts.join("/"))
}

// The member holding the icon: .DirIcon, or where its link chain ends, never outside the image.
pub(crate) fn resolve(listing: &str) -> Result<String, &'static str> {
    let all = entries(listing);
    let mut at = DIR_ICON.to_string();
    for _ in 0..=LINK_LIMIT {
        let entry = all.get(&at).ok_or("no icon at the end of the .DirIcon chain")?;
        let Some(target) = &entry.link else {
            if entry.folder || entry.size == 0 || entry.size > MAX_ICON_BYTES {
                return Err("the icon is not a file of a usable size");
            }
            return Ok(at);
        };
        if target.starts_with('/') {
            return Err("a link leaves the image");
        }
        let joined = match at.rsplit_once('/') {
            Some((dir, _)) => format!("{}/{}", dir, target),
            None => target.clone(),
        };
        at = clean(&joined).ok_or("a link leaves the image")?;
    }
    Err("too many links")
}

#[cfg(test)]
#[path = "appicon_tests.rs"]
mod tests;
