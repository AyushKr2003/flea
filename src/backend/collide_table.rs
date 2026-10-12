// The mount table a collision question reads once, and the hop each name takes from it.
use crate::backend::undo::ItemIdentity;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

// One question's read of the mount table: a name that is itself a remote mountpoint takes the guarded hop its local folder alone would not.
pub(crate) struct Table {
    body: String,
    dest_remote: bool,
    points: HashMap<PathBuf, bool>,
}

impl Table {
    pub(crate) fn read(dest: &Path) -> Table {
        Table::of(std::fs::read_to_string("/proc/self/mountinfo").unwrap_or_default(), dest)
    }

    pub(crate) fn of(body: String, dest: &Path) -> Table {
        Table { dest_remote: crate::backend::iomount::is_remote(dest, &body), points: crate::backend::mountinfo::wedge_points_in(&body), body }
    }

    // A name one component under dest sits on dest's mount unless it is a mountpoint itself, so the table is asked about that name alone.
    pub(super) fn remote(&self, dst: &Path) -> bool {
        self.points.get(dst).copied().unwrap_or(self.dest_remote)
    }
}

// A name on a local mount is looked at inline, as iomount::call does; only a remote one pays its guarded hop for every name.
pub(crate) fn identity_in(dst: &Path, table: &Table) -> Result<ItemIdentity, crate::error::FleaError> {
    if table.remote(dst) {
        return ItemIdentity::inspect_in(dst, &table.body);
    }
    dst.symlink_metadata().map(|meta| ItemIdentity::record(&meta)).map_err(|e| crate::error::from_io("journal", &dst.to_string_lossy(), &e))
}
