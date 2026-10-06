// The bench seam, compiled only with the flash-test-seam feature: a loop device or file inside a marked root.
use std::path::{Path, PathBuf};

// The marker this tree's own sandbox guard owns; a root without it is not a bench root.
const MARKER: &str = ".flea-test-sandbox";
// The one variable that names the marked root the seam may touch.
const ROOT_ENV: &str = "FLEA_FLASH_ALLOW_LOOP";

// The marked root the bench named, when it is absolute and carries the marker.
pub(crate) fn root() -> Option<PathBuf> {
    let text = std::env::var(ROOT_ENV).ok()?;
    let root = Path::new(&text);
    (!text.is_empty() && root.is_absolute() && root.join(MARKER).is_file()).then(|| root.to_path_buf())
}

// Strictly inside: the root itself is a directory, never the file.
pub(crate) fn inside(root: &Path, path: &Path) -> bool {
    let canonical_root = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
    let canonical = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    canonical.starts_with(&canonical_root) && canonical != canonical_root
}

// Sample backing file: /sys/block/loop0/loop/backing_file answers the file the loop was set up on.
pub(crate) fn loop_backing_inside(dev: &str, sys: &Path) -> bool {
    let Some(root) = root() else { return false };
    let text = std::fs::read_to_string(sys.join("block").join(dev).join("loop/backing_file")).unwrap_or_default();
    let backing = text.trim();
    if backing.is_empty() {
        return false;
    }
    match std::fs::symlink_metadata(backing) {
        Ok(meta) if meta.is_file() => inside(&root, Path::new(backing)),
        _ => false,
    }
}
