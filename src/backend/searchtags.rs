// Tag terms inside a live search session: which scored hits carry every tag the query names.
use crate::backend::searchindex::Index;
use std::path::{Path, PathBuf};

// One bounded call reads the tags of this many entries, so a slow share costs its deadline per chunk and never per directory.
pub(crate) const TAG_CHUNK: usize = 128;

// True when the tags read for one file hold every wanted name; an unreadable file reads empty and matches nothing.
fn holds_all(have: &[String], wanted: &[String]) -> bool {
    wanted.iter().all(|want| have.iter().any(|got| super::tags::name_matches(got, want)))
}

// Keeps the hits carrying every wanted tag: a local scope reads in place, a remote one reads each hit under the mount bound.
pub(crate) fn retain_tagged(hits: &mut Vec<(i32, usize)>, scope: &Path, body: &str, index: &Index, wanted: &[String]) {
    let remote = super::iomount::is_remote(scope, body);
    hits.retain(|&(_, row)| {
        let path = scope.join(index.path(row));
        if !remote {
            return holds_all(&super::tags::read(&path).unwrap_or_default(), wanted);
        }
        let owned = path.clone();
        let have = super::iomount::call(&path, body, "search", move || super::tags::read(&owned).unwrap_or_default());
        holds_all(&have.unwrap_or_default(), wanted)
    });
}

// The tags of one directory's entries, one bounded call per chunk, parallel to `entries`.
pub(crate) fn read_tags(dir: &Path, body: &str, entries: &[(String, bool)], hidden: bool) -> Vec<Vec<String>> {
    tags_in_chunks(entries, hidden, |names| {
        let paths: Vec<PathBuf> = names.iter().map(|name| dir.join(name)).collect();
        let read = move || paths.iter().map(|path| super::tags::read(path).unwrap_or_default()).collect();
        super::iomount::call(dir, body, "search", read).ok()
    })
}

// Chunks the names the walk can match through `read`; a chunk that answers None ends the reads and leaves the rest untagged.
pub(crate) fn tags_in_chunks(entries: &[(String, bool)], hidden: bool, mut read: impl FnMut(&[&str]) -> Option<Vec<Vec<String>>>) -> Vec<Vec<String>> {
    let mut out = vec![Vec::new(); entries.len()];
    // A dot name the hidden rule drops is never read, so it costs no call.
    let wanted: Vec<usize> = (0..entries.len()).filter(|&i| hidden || !entries[i].0.starts_with('.')).collect();
    for chunk in wanted.chunks(TAG_CHUNK) {
        let names: Vec<&str> = chunk.iter().map(|&i| entries[i].0.as_str()).collect();
        let Some(read_tags) = read(&names) else { break };
        for (&i, tags) in chunk.iter().zip(read_tags) {
            out[i] = tags;
        }
    }
    out
}

#[cfg(test)]
#[path = "searchtags_tests.rs"]
mod tests;
