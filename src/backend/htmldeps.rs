use super::regfile;
use crate::jsondoc::{self, Json};
use crate::oflags::O_NOFOLLOW;
use std::fs::Metadata;
use std::io::Read;
use std::os::unix::{ffi::OsStringExt, fs::MetadataExt};
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, SystemTime};

pub const MAX_RESOURCES: usize = 256;
pub const MAX_RECORD_BYTES: usize = 64 * 1024;

fn local_path(folder: &Path, encoded: &str) -> Option<PathBuf> {
    let bytes = crate::paths::percent_decode_bytes(encoded);
    if bytes.is_empty() || bytes.contains(&0) { return None }
    let relative = PathBuf::from(std::ffi::OsString::from_vec(bytes));
    if relative.components().any(|c| !matches!(c, Component::Normal(_))) { return None }
    let path = folder.join(relative);
    let resolved = path.canonicalize().ok()?;
    resolved.starts_with(folder).then_some(path)
}

fn stamp(folder: &Path, encoded: &str) -> Option<Metadata> {
    let meta = local_path(folder, encoded)?.metadata().ok()?;
    meta.is_file().then_some(meta)
}

fn number(value: impl ToString) -> Json { Json::Num(value.to_string()) }

fn fields(meta: &Metadata) -> Vec<Json> {
    vec![number(meta.len()), number(meta.mtime()), number(meta.mtime_nsec()), number(meta.ino()), number(meta.dev())]
}

// Sample input: HTML_RESOURCES {"resources":["file:///page/sub/style.css"],"overflow":false}.
pub fn record(text: &str, folder: &Path, started: SystemTime) -> Option<Vec<u8>> {
    if text.len() > MAX_RECORD_BYTES { return None }
    let document = jsondoc::parse(text).ok()?;
    if document.get("overflow")?.as_bool()? { return None }
    let resources = document.get("resources")?.as_array()?;
    if resources.len() > MAX_RESOURCES { return None }
    let mut rows = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for resource in resources {
        let url = resource.as_str()?;
        let Some(path) = url.strip_prefix("file:///page/").or_else(|| url.strip_prefix("file://localhost/page/")) else { continue };
        let path = path.split(['?', '#']).next()?;
        if !seen.insert(path) { continue }
        let meta = stamp(folder, path)?;
        let changed = SystemTime::UNIX_EPOCH + Duration::new(meta.ctime().max(0) as u64, meta.ctime_nsec().max(0) as u32);
        if meta.modified().ok()? > started || changed > started { return None }
        let mut row = vec![Json::Str(path.to_string())];
        row.extend(fields(&meta));
        rows.push(Json::Arr(row));
    }
    let bytes = jsondoc::render(&Json::Obj(vec![("version".into(), number(1)), ("dependencies".into(), Json::Arr(rows))])).into_bytes();
    (bytes.len() <= MAX_RECORD_BYTES).then_some(bytes)
}

pub fn sidecar(png: &Path) -> PathBuf { png.with_extension("deps") }

pub fn unchanged(png: &Path, folder: &Path) -> bool {
    let Ok(file) = regfile::open_if_regular(&sidecar(png), O_NOFOLLOW) else { return false };
    let mut text = String::new();
    if file.take(MAX_RECORD_BYTES as u64 + 1).read_to_string(&mut text).is_err() || text.len() > MAX_RECORD_BYTES { return false }
    let Ok(document) = jsondoc::parse(&text) else { return false };
    if document.get("version") != Some(&number(1)) { return false }
    let Some(rows) = document.get("dependencies").and_then(Json::as_array) else { return false };
    if rows.len() > MAX_RESOURCES { return false }
    rows.iter().all(|row| {
        let Some(row) = row.as_array().filter(|r| r.len() == 6) else { return false };
        let Some(path) = row[0].as_str() else { return false };
        stamp(folder, path).is_some_and(|meta| row[1..] == fields(&meta))
    })
}

#[cfg(test)]
#[path = "htmldeps_tests.rs"]
mod tests;
