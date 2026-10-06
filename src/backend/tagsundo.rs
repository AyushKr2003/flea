// The Tags journal step's codec and replay, so undo.rs, redo.rs and undocodec.rs each carry it with one call.
use super::undocodec::{arr, checked_path, get, n, obj, parse_u32, s, MAX_TEXT};
use super::undo::Step;
use crate::error::FleaError;
use crate::jsondoc::Json;
use std::path::Path;

// Sample input: {"k":"tg","path":"/a","before":[82,101,100],"after":null}.
pub(crate) fn encode(path: &Path, before: &Option<Vec<u8>>, after: &Option<Vec<u8>>) -> Json {
    obj(vec![
        ("k", s("tg")), ("path", s(&path.to_string_lossy())),
        ("before", raw_bytes(before)), ("after", raw_bytes(after)),
    ])
}

// A raw attribute value is bytes, so it rides as byte numbers under the text cap.
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
    })
}

// Anything else is a foreign record, never trusted into a path the undo removes.
fn decode_raw(value: &Json) -> Option<Option<Vec<u8>>> {
    match value {
        Json::Null => Some(None),
        v => {
            let items = v.as_array()?;
            if items.len() > MAX_TEXT {
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

// Undo restores the exact attribute the file carried, absent included.
pub(crate) fn reverse(path: &Path, before: &Option<Vec<u8>>) -> Result<(), FleaError> {
    super::tags::restore(path, before)
}

// Redo re-applies only onto what undo left, or it would overwrite a newer change.
pub(crate) fn replay(path: &Path, before: &Option<Vec<u8>>, after: &Option<Vec<u8>>,
    saved: &Step, steps: &mut Vec<Step>) -> Result<(), FleaError> {
    if super::tags::read_raw(path).ok().as_ref() != Some(before) {
        return Err(FleaError { where_: "redo".into(), path: path.to_string_lossy().into(),
            msg: "the file tags changed since undo; redo left them in place".into() });
    }
    super::tags::restore(path, after).map_err(|e| FleaError { where_: "redo".into(),
        path: path.to_string_lossy().into(), msg: e.msg })?;
    steps.push(saved.clone());
    Ok(())
}
