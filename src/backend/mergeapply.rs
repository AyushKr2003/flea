// Folder merge, second half: landing entries, the manifests they record, and the
// journal, redo and wire arms for the folders a move emptied. The walk, the cards
// and the transfer dispatch stay in merge.rs.
use super::merge::{count_tree, real_dir};
pub(crate) use super::merge::Counts;
use crate::backend::collide::{Place, Policy};
use crate::backend::copyfile::{copy_any, move_any, Progress};
use crate::backend::copymanifest::Writer;
use crate::backend::durable::Durability;
use crate::backend::undo::{self, ItemIdentity, Step};
use crate::error::{from_io, FleaError};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::time::{Duration, Instant};
// Copies or moves one entry, recording what landed; move_any already touches what its rename leg
// needs, so no source folder is flushed from here.
// The six context arguments one entry lands with, so land_one takes three.
pub(crate) struct LandCtx<'a> {
    pub moving: bool,
    pub cancel: &'a AtomicBool,
    pub sink: &'a mut dyn FnMut(u64, u64),
    pub carried: &'a mut u64,
    pub manifest: &'a mut Option<Writer>,
    pub ctx: &'a mut Durability,
    pub steps: &'a mut Vec<Step>,
}

fn land_one(src: &Path, to: &Path, land: &mut LandCtx) -> Result<(), FleaError> {
    let mut p = Progress { cancel: land.cancel, on_bytes: &mut *land.sink, partial: None, tree: Some(*land.carried),
        manifest: land.manifest.take(), durability: Some(&mut *land.ctx), for_move: land.moving };
    let r = if land.moving { move_any(src, to, &mut p) } else { copy_any(src, to, &mut p) };
    *land.carried = p.tree.unwrap_or(*land.carried);
    *land.manifest = p.manifest.take();
    if r.is_ok() && land.moving {
        if let Ok(meta) = to.symlink_metadata() {
            if let Ok(step) = undo::moved(src, to, ItemIdentity::record(&meta)) {
                land.steps.push(step);
            }
        }
    }
    r
}

// Merges one top-level folder into the destination; inner failures collect and the top answers once.
#[allow(clippy::too_many_arguments)]
pub(crate) fn merge_folder(
    id: usize,
    src: &Path,
    dst_top: &Path,
    dest: &Path,
    moving: bool,
    inner: &Policy,
    steps: &mut Vec<Step>,
    cancel: &AtomicBool,
    tx: &Sender<crate::backend::opsreq::OpMsg>,
    index: usize,
    name: &str,
    settled: &std::sync::atomic::AtomicU64,
    ctx: &mut Durability,
    counts: &mut Counts,
) -> Result<(), FleaError> {
    const EVERY: Duration = Duration::from_millis(150);
    let mut last = Instant::now() - EVERY;
    let mut sink = |done: u64, total: u64| {
        if last.elapsed() < EVERY {
            return;
        }
        last = Instant::now();
        let _ = tx.send(crate::backend::opsreq::OpMsg::Progress { id, index, name: name.to_string(),
            bytes: done, total, scanned: settled.load(Ordering::Relaxed) });
    };
    let mut carried: u64 = 0;
    // Moves journal per-file steps, so no manifest; copies keep one manifest for the whole folder.
    let mut manifest = if moving { None } else { crate::backend::copymanifest::writer_for(src, dst_top) };
    // The top folder already exists, so only its children are recorded; recording it would risk it on undo.
    let r = merge_into(src, dst_top, dest, moving, inner, steps, cancel, &mut sink, &mut carried, &mut manifest, ctx, counts);
    if moving && r.is_ok() {
        // The mode is read before the remove, and the step is pushed only when the remove landed.
        let removed = removed_empty_dir(src).ok();
        if std::fs::remove_dir(src).is_ok() {
            steps.extend(removed);
        }
    }
    if moving {
        return r;
    }
    finish_manifest(src, dst_top, manifest, steps, &r, counts.merged)
}

// The manifest names only what the merge created, so undo removes those and never a file already there.
fn finish_manifest(src: &Path, dst_top: &Path, manifest: Option<Writer>, steps: &mut Vec<Step>, r: &Result<(), FleaError>, merged: usize) -> Result<(), FleaError> {
    let Some(writer) = manifest else {
        if merged > 0 {
            eprintln!("flea: merge of {} left {} items without a manifest; undo restores replaced files only", dst_top.display(), merged);
        }
        return r.as_ref().map(|_| ()).map_err(clone_err);
    };
    let (handle, loud) = crate::backend::copymanifest::finish_loud(Some(writer));
    if let Some(e) = loud {
        let mut err = r.as_ref().err().map(clone_err).unwrap_or_else(|| FleaError { where_: "transfer".into(), path: dst_top.to_string_lossy().to_string(), msg: String::new() });
        err.msg.push_str(&format!("; copy manifest failed: {e}"));
        return Err(err);
    }
    if let Some(handle) = handle {
        if let Ok(meta) = src.symlink_metadata() {
            let source = ItemIdentity::record(&meta);
            if let Ok(step) = undo::copied_partial(src, dst_top, source, Some(handle)) {
                steps.push(step);
            }
        }
    }
    r.as_ref().map(|_| ()).map_err(clone_err)
}

fn clone_err(e: &FleaError) -> FleaError {
    FleaError { where_: e.where_.clone(), path: e.path.clone(), msg: e.msg.clone() }
}

// Folds one source directory into its destination twin, all the way down.
#[allow(clippy::too_many_arguments)]
fn merge_into(
    src_dir: &Path,
    dst_dir: &Path,
    dest: &Path,
    moving: bool,
    inner: &Policy,
    steps: &mut Vec<Step>,
    cancel: &AtomicBool,
    sink: &mut dyn FnMut(u64, u64),
    carried: &mut u64,
    manifest: &mut Option<Writer>,
    ctx: &mut Durability,
    counts: &mut Counts,
) -> Result<(), FleaError> {
    let entries = std::fs::read_dir(src_dir).map_err(|e| from_io("transfer", &src_dir.to_string_lossy(), &e))?;
    for entry in entries {
        if cancel.load(Ordering::Relaxed) {
            return Err(FleaError { where_: "copy".into(), path: dst_dir.to_string_lossy().to_string(), msg: "cancelled".into() });
        }
        let entry = entry.map_err(|e| from_io("transfer", &src_dir.to_string_lossy(), &e))?;
        let name = entry.file_name();
        let (src_inner, dst_inner) = (src_dir.join(&name), dst_dir.join(&name));
        let rel = dst_inner.strip_prefix(dest).unwrap_or(&dst_inner).to_string_lossy().to_string();
        let Ok(meta) = src_inner.symlink_metadata() else {
            counts.failed.push(format!("{rel}: gone before it could be merged"));
            continue;
        };
        if dst_inner.symlink_metadata().is_err() {
            // Everything missing is copied or moved in.
            let n = count_tree(&src_inner);
            let mut land = LandCtx { moving, cancel, sink: &mut *sink, carried: &mut *carried, manifest: &mut *manifest, ctx: &mut *ctx, steps: &mut *steps };
            match land_one(&src_inner, &dst_inner, &mut land) {
                Ok(()) => counts.merged += n,
                Err(e) => counts.failed.push(format!("{rel}: {}", e.msg)),
            }
            continue;
        }
        if meta.is_dir() && !meta.file_type().is_symlink() && real_dir(&dst_inner) {
            // Folders inside merge the same way all the way down.
            if merge_into(&src_inner, &dst_inner, dest, moving, inner, steps, cancel, sink, carried, manifest, ctx, counts).is_err() {
                continue;
            }
            if moving {
                // Newest first on undo recreates this folder before its entries go back.
                let removed = removed_empty_dir(&src_inner).ok();
                if std::fs::remove_dir(&src_inner).is_ok() {
                    steps.extend(removed);
                }
            }
            continue;
        }
        // Files that exist in both take the second card's answer, asked once before anything was written.
        match inner.place(&src_inner, dst_inner.clone(), false, moving) {
            Place::Skip => counts.skipped += 1,
            Place::Refuse(err) => counts.failed.push(format!("{rel}: {err}")),
            Place::Land { to, replace } => {
                let n = count_tree(&src_inner);
                let kept = to != dst_inner;
                // Replace trashes then creates exclusively, exactly as today's Replace.
                let r = if replace {
                    crate::backend::collide::replacing(&dst_inner, steps, |steps| {
                        let mut land = LandCtx { moving, cancel, sink: &mut *sink, carried: &mut *carried, manifest: &mut *manifest, ctx: &mut *ctx, steps: &mut *steps };
                        land_one(&src_inner, &to, &mut land)
                    })
                } else {
                    let mut land = LandCtx { moving, cancel, sink: &mut *sink, carried: &mut *carried, manifest: &mut *manifest, ctx: &mut *ctx, steps: &mut *steps };
                    land_one(&src_inner, &to, &mut land)
                };
                match r {
                    Ok(()) => {
                        counts.merged += n;
                        if kept {
                            counts.kept_both += 1;
                        }
                    }
                    Err(e) => counts.failed.push(format!("{rel}: {}", e.msg)),
                }
            }
        }
    }
    if counts.failed.is_empty() {
        Ok(())
    } else {
        let mut msg = counts.failed.iter().take(3).cloned().collect::<Vec<_>>().join("; ");
        if counts.failed.len() > 3 {
            msg.push_str(&format!("; and {} more", counts.failed.len() - 3));
        }
        Err(FleaError { where_: "transfer".into(), path: dst_dir.to_string_lossy().to_string(), msg })
    }
}

// The journal steps a merge move records for the folders it emptied, kept beside the fold.

// The mode is read before the remove, so undo recreates the folder as it was, not as the umask would make it.
pub(crate) fn removed_empty_dir(path: &std::path::Path) -> Result<Step, FleaError> {
    let mode = path.symlink_metadata().map(|meta| meta.permissions().mode() & 0o7777)
        .map_err(|e| from_io("journal", &path.to_string_lossy(), &e))?;
    Ok(Step::RemovedEmptyDir { path: path.to_path_buf(), mode })
}

// Only ever a folder this operation emptied and removed. A parent that is itself gone (an unmounted
// share, a deleted mount point) is not recreated here, because the next mount would hide the file;
// and a name something else holds is never taken. Either refusal creates nothing.
pub(crate) fn recreate_emptied(path: &PathBuf, mode: u32) -> Result<(), FleaError> {
    if path.symlink_metadata().is_ok() {
        return Err(FleaError { where_: "undo".into(), path: path.to_string_lossy().into(),
            msg: "something now holds the emptied folder's name, so undo left the moved items in place".into() });
    }
    let parent = path.parent().filter(|p| !p.as_os_str().is_empty());
    let held = match parent {
        // Followed, so a folder reached through a symlinked name still counts as there.
        Some(dir) => dir.metadata().map(|meta| meta.is_dir()).unwrap_or(false),
        None => false,
    };
    if !held {
        return Err(FleaError { where_: "undo".into(), path: path.to_string_lossy().into(),
            msg: "the emptied folder's parent is gone, so undo left the moved items in place".into() });
    }
    std::fs::DirBuilder::new().mode(mode).create(path).map_err(|e| from_io("undo", &path.to_string_lossy(), &e))?;
    // The builder's mode passes through the umask, so the exact bits are set after the create.
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).map_err(|e| from_io("undo", &path.to_string_lossy(), &e))
}

// Redo takes an emptied folder away again, so the folder must still be the one undo left.
pub(crate) fn check_emptied(step: &Step) -> Result<(), FleaError> {
    let Step::RemovedEmptyDir { path, .. } = step else { return Ok(()) };
    match path.symlink_metadata() {
        Ok(meta) if meta.is_dir() && !meta.file_type().is_symlink() => Ok(()),
        Ok(_) => Err(FleaError { where_: "redo".into(), path: path.to_string_lossy().into(),
            msg: "the emptied folder was replaced; redo left it in place".into() }),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Err(FleaError { where_: "redo".into(), path: path.to_string_lossy().into(),
            msg: "the emptied folder is already gone; redo left it in place".into() }),
        Err(e) => Err(from_io("redo", &path.to_string_lossy(), &e)),
    }
}

// The Moved replays above emptied it again, so redo takes it away as the operation did.
pub(crate) fn redo_emptied(path: &Path, mode: u32, steps: &mut Vec<Step>) -> Result<(), FleaError> {
    std::fs::remove_dir(path).map_err(|e| from_io("redo", &path.to_string_lossy(), &e))?;
    steps.push(Step::RemovedEmptyDir { path: path.to_path_buf(), mode });
    Ok(())
}

// The shared journal's wire arm for the step above, beside the codec that owns the version.
pub(crate) fn encode_emptied(path: &Path, mode: u32) -> crate::jsondoc::Json {
    super::undocodec::obj(vec![("k", super::undocodec::s("re")), ("path", super::undocodec::s(&path.to_string_lossy())), ("mode", super::undocodec::n(mode))])
}

pub(crate) fn decode_emptied(pairs: &[(String, crate::jsondoc::Json)]) -> Option<Step> {
    let path = super::undocodec::checked_path(super::undocodec::get(pairs, "path")?)?;
    let mode = super::undocodec::parse_u32(super::undocodec::get(pairs, "mode")?)?;
    Some(Step::RemovedEmptyDir { path, mode })
}
