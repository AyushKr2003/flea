// Issue 133, the TUI's half of ui/js/Mounts.js "trashable": what a folder's path says about its Trash.
pub use crate::backend::hometrash::trashable;

// The status line's refusal: what failed, then the key that still removes the rows.
pub const NO_TRASH: &str = "This location has no Trash; Shift+Delete deletes permanently";
