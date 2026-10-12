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

// Sample input: "/run/user/1000//gvfs/../gvfs/smb-share:x/a" answers "/run/user/1000/gvfs/smb-share:x/a"; the text of a clean path is kept as is.
fn folded(path: &Path) -> std::borrow::Cow<'_, str> {
    let text = path.to_string_lossy();
    if !text.contains("//") && !text.contains("/./") && !text.ends_with("/.") && !text.contains("/../") && !text.ends_with("/..") {
        return text;
    }
    let mut out = PathBuf::new();
    for part in path.components() {
        // A ".." pops one named segment and never climbs above the root.
        match part {
            std::path::Component::ParentDir => {
                if matches!(out.components().next_back(), Some(std::path::Component::Normal(_))) {
                    out.pop();
                }
            }
            other => out.push(other),
        }
    }
    std::borrow::Cow::Owned(out.to_string_lossy().into_owned())
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
    let text = folded(path);
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
    let text = folded(path);
    let (root, share) = gvfs_split(&text)?;
    let name = share.split('/').next().filter(|name| !name.is_empty())?;
    Some(PathBuf::from(root + name))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Doubled slashes, dot and dot-dot segments fold away before the gvfs root is matched, so no spelling of a mount path escapes the guard.
    #[test]
    fn an_unnormalized_gvfs_path_is_still_a_gvfs_path() {
        for spelled in ["/run/user/1000//gvfs/smb-share:server=n,share=x/a", "/run/user/1000/./gvfs/smb-share:server=n,share=x/a",
            "/run/user/1000/gvfs//smb-share:server=n,share=x/a", "//run/user/1000/gvfs/smb-share:server=n,share=x/a", "/run/user/1000/gvfs/smb-share:server=n,share=x/.",
            "/run/user/1000/gvfs/../gvfs/smb-share:server=n,share=x/a", "/run/user/1000/x/../gvfs/smb-share:server=n,share=x/a",
            "/../run/user/1000/gvfs/smb-share:server=n,share=x/a", "/run/user/1000/gvfs/smb-share:server=n,share=x/a/b/.."] {
            assert_eq!(gvfs_class(Path::new(spelled)), Some("network"), "{spelled} is a gvfs path");
            assert_eq!(gvfs_root(Path::new(spelled)).as_deref(), Some(Path::new("/run/user/1000/gvfs/smb-share:server=n,share=x")), "{spelled} roots at its share");
        }
        assert_eq!(gvfs_class(Path::new("/home/u//gvfs/smb-share:server=n,share=x/a")), None, "a doubled slash does not turn a plain folder into a mount");
    }
}
