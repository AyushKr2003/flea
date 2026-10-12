// The Tags journal step's codec and replay, so undo.rs, redo.rs and undocodec.rs each carry it with one call.
use super::undocodec::{arr, checked_path, get, n, obj, parse_u32, parse_u64, s};
use super::undo::Step;
use crate::error::FleaError;
use crate::jsondoc::Json;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

// Sample input: {"k":"tg","path":"/a","before":[82,101,100],"after":null,"dev":2049,"ino":77}.
pub(crate) fn encode(path: &Path, before: &Option<Vec<u8>>, after: &Option<Vec<u8>>, dev: u64, ino: u64) -> Json {
    obj(vec![
        ("k", s("tg")), ("path", s(&path.to_string_lossy())),
        ("before", raw_bytes(before)), ("after", raw_bytes(after)), ("dev", n(dev)), ("ino", n(ino)),
    ])
}

// A raw attribute value is bytes, so it rides as byte numbers under the cap read_raw reads to.
fn raw_bytes(raw: &Option<Vec<u8>>) -> Json {
    match raw {
        None => Json::Null,
        Some(bytes) => arr(bytes.iter().map(n).collect()),
    }
}

pub(crate) fn decode(pairs: &[(String, Json)]) -> Option<Step> {
    Some(Step::Tags {
        path: checked_path(get(pairs, "path")?)?,
        before: decode_raw(get(pairs, "before")?)?,
        after: decode_raw(get(pairs, "after")?)?,
        dev: get(pairs, "dev").and_then(parse_u64)?,
        ino: get(pairs, "ino").and_then(parse_u64)?,
    })
}

// Anything else is a foreign record; the cap is read_raw's own, so every value Flea journals decodes.
fn decode_raw(value: &Json) -> Option<Option<Vec<u8>>> {
    match value {
        Json::Null => Some(None),
        v => {
            let items = v.as_array()?;
            if items.len() > super::tags::MAX_VALUE {
                return None;
            }
            let mut bytes = Vec::with_capacity(items.len());
            for item in items {
                let byte = parse_u32(item)?;
                if byte > 255 {
                    return None;
                }
                bytes.push(byte as u8);
            }
            Some(Some(bytes))
        }
    }
}

// The file's own dev and inode, read without following a link, as the step recorded them.
pub(crate) fn identity(path: &Path) -> Result<(u64, u64), FleaError> {
    let meta = std::fs::symlink_metadata(path).map_err(|e| crate::error::from_io("settags", &path.to_string_lossy(), &e))?;
    Ok((meta.dev(), meta.ino()))
}

// The two whole sentences a pinned write refuses with, one pair for undo and one for redo: (file replaced, tags changed).
const UNDO_REFUSALS: (&str, &str) = ("the file was replaced, so undo left its tags in place",
    "the tags changed since then, so undo left them in place");
const REDO_REFUSALS: (&str, &str) = ("the file was replaced, so redo left its tags in place",
    "the tags changed since then, so redo left them in place");

// Writes `to` only onto the same file still holding `expect`, so a replaced file or a newer change is left alone.
fn pinned(where_: &str, path: &Path, dev: u64, ino: u64, expect: &Option<Vec<u8>>, to: &Option<Vec<u8>>, refusals: (&str, &str))
    -> Result<(), FleaError> {
    let refuse = |msg: String| FleaError { where_: where_.into(), path: path.to_string_lossy().into(), msg };
    if identity(path).ok() != Some((dev, ino)) {
        return Err(refuse(refusals.0.to_string()));
    }
    if super::tags::read_raw(path).ok().as_ref() != Some(expect) {
        return Err(refuse(refusals.1.to_string()));
    }
    super::tags::restore(path, to).map_err(|e| refuse(e.msg))
}

// Undo restores the exact attribute the file carried, absent included, only onto what the operation left.
pub(crate) fn reverse(path: &Path, before: &Option<Vec<u8>>, after: &Option<Vec<u8>>, dev: u64, ino: u64)
    -> Result<(), FleaError> {
    pinned("undo", path, dev, ino, after, before, UNDO_REFUSALS)
}

// Redo re-applies only onto what undo left, or it would overwrite a newer change.
pub(crate) fn replay(path: &Path, before: &Option<Vec<u8>>, after: &Option<Vec<u8>>, dev: u64, ino: u64,
    saved: &Step, steps: &mut Vec<Step>) -> Result<(), FleaError> {
    pinned("redo", path, dev, ino, before, after, REDO_REFUSALS)?;
    steps.push(saved.clone());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip(len: usize) -> Option<Step> {
        let raw = Some(vec![b'a'; len]);
        let Json::Obj(pairs) = encode(Path::new("/a"), &raw, &None, 1, 2) else { panic!("a step encodes as an object") };
        decode(&pairs)
    }

    #[test]
    fn a_value_at_the_read_cap_round_trips_and_one_past_it_refuses() {
        let cap = super::super::tags::MAX_VALUE;
        assert!(matches!(round_trip(0), Some(Step::Tags { dev: 1, ino: 2, .. })), "the identity rides with the step");
        assert!(matches!(round_trip(cap), Some(Step::Tags { before: Some(ref b), .. }) if b.len() == cap), "a value read_raw accepts decodes");
        assert!(round_trip(cap + 1).is_none(), "a value past the read cap is foreign");
    }

    #[test]
    fn undo_and_redo_each_refuse_in_their_own_whole_sentence() {
        let dir = crate::backend::testdir::TestDir::new("tagsundo-sentences");
        let file = dir.file("a.txt", "body");
        let (dev, ino) = identity(&file).unwrap();
        let held = Some(b"held".to_vec());
        let msg = |r: Result<(), FleaError>| r.expect_err("the write is refused").msg;
        // The file carries no attribute, so a recorded one has changed since; a wrong inode is a replaced file.
        assert_eq!(msg(reverse(&file, &None, &held, dev, ino)), "the tags changed since then, so undo left them in place");
        assert_eq!(msg(reverse(&file, &None, &held, dev, ino + 1)), "the file was replaced, so undo left its tags in place");
        let mut steps = Vec::new();
        let saved = Step::Tags { path: file.clone(), before: None, after: held.clone(), dev, ino };
        assert_eq!(msg(replay(&file, &held, &None, dev, ino, &saved, &mut steps)), "the tags changed since then, so redo left them in place");
        assert_eq!(msg(replay(&file, &held, &None, dev, ino + 1, &saved, &mut steps)), "the file was replaced, so redo left its tags in place");
    }
}
