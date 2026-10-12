// The GVFS FUSE root /run/user/<uid>/gvfs and the share folder under it; a folder named gvfs anywhere else is no mount.
use std::path::{Path, PathBuf};

// The directory whose children are the per-user run folders; a test points it at a sandbox, since /run/user is not writable.
#[cfg(test)]
thread_local! {
    static RUN_USER: std::cell::RefCell<Option<String>> = const { std::cell::RefCell::new(None) };
}

// Names the sandbox that stands for /run/user on this thread, or clears it with None.
#[cfg(test)]
pub(crate) fn set_test_run_user(root: Option<&Path>) {
    RUN_USER.with(|slot| *slot.borrow_mut() = root.map(|r| format!("{}/", r.to_string_lossy().trim_end_matches('/'))));
}

fn run_user_root() -> String {
    #[cfg(test)]
    if let Some(root) = RUN_USER.with(|slot| slot.borrow().clone()) {
        return root;
    }
    "/run/user/".to_string()
}

// Splits "<run>/<uid>/gvfs/<share...>" into the root through "gvfs/" and the rest; None for any path off the gvfs mount root.
fn gvfs_split(text: &str) -> Option<(String, &str)> {
    let run = run_user_root();
    let rest = text.strip_prefix(run.as_str())?;
    let uid = rest.find('/').filter(|&at| at > 0)?;
    let share = rest[uid + 1..].strip_prefix("gvfs/")?;
    Some((format!("{run}{}gvfs/", &rest[..=uid]), share))
}

// Sample input: "/run/user/1000/gvfs/mtp:host=X/" answers Some("phone"); "/home/gm/gvfs/mtp:host=X" answers None, since only the mount root counts.
pub fn gvfs_class(path: &Path) -> Option<&'static str> {
    let text = path.to_string_lossy();
    let (_, share) = gvfs_split(&text)?;
    let share = share.to_ascii_lowercase();
    if share.starts_with("mtp:") || share.starts_with("gphoto2:") || share.starts_with("afc:") {
        Some("phone")
    } else {
        Some("network")
    }
}

// Sample input: "/run/user/1000/gvfs/smb-share:server=n,share=x/dir" answers "/run/user/1000/gvfs/smb-share:server=n,share=x".
pub fn gvfs_root(path: &Path) -> Option<PathBuf> {
    let text = path.to_string_lossy();
    let (root, share) = gvfs_split(&text)?;
    let name = share.split('/').next().filter(|name| !name.is_empty())?;
    Some(PathBuf::from(root + name))
}
