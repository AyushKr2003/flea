// The TUI's gvfs head start: the GUI's prepare and helper spawn, with "-" for the qs shell's page-cache list this process never maps.
pub(crate) fn start(path: &str) -> Option<crate::gvfsprefetch::Prefetch> {
    start_with(path, crate::gui::warm_all)
}

// The spawn rides in as an argument so a test counts the helpers a start launches.
fn start_with(path: &str, mut spawn: impl FnMut(Option<&std::path::Path>, Option<(&str, &std::path::Path)>) -> bool) -> Option<crate::gvfsprefetch::Prefetch> {
    // Sample path: "/run/user/1000/gvfs/smb-share:server=x,share=y/dir".
    let (dest, start_ms) = crate::gvfsprefetch::prepare(path)?;
    if !spawn(None, Some((path, dest.as_path()))) {
        return None;
    }
    Some(crate::gvfsprefetch::Prefetch { dest, path: path.to_string(), start_ms })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::testdir::TestDir;

    #[test]
    fn a_local_start_prepares_nothing_and_spawns_nothing() {
        let (_lock, _env) = crate::gvfsprefetch::hold_env();
        let d = TestDir::new("tui-warm-local");
        std::env::set_var("XDG_RUNTIME_DIR", d.path());
        assert!(start(d.path().to_str().unwrap()).is_none(), "prepare answers None off gvfs, so no helper ever spawns");
    }

    #[test]
    fn a_gvfs_start_prepares_and_spawns_one_helper() {
        let (_lock, _env) = crate::gvfsprefetch::hold_env();
        let d = TestDir::new("tui-warm-gvfs");
        std::env::set_var("XDG_RUNTIME_DIR", d.path());
        // Sample path: "/run/user/1000/gvfs/smb-share:server=x,share=y/dir".
        let path = "/run/user/1000/gvfs/smb-share:server=x,share=y/dir";
        // In-harness current_exe is the test binary, so this proves prepare plus a successful spawn; the gio half is gui.rs's tested job.
        let found = start(path).expect("a gvfs start prepares");
        assert_eq!(found.path, path);
        let mut spawned = 0;
        let counted = start_with(path, |list, gvfs| {
            spawned += 1;
            assert!(list.is_none() && gvfs.is_some_and(|(at, _)| at == path), "the one helper warms the gvfs path alone");
            true
        });
        assert!(counted.is_some());
        assert_eq!(spawned, 1, "one start spawns exactly one helper");
        assert!(found.dest.starts_with(d.path().join("flea")), "the dest is this launch's file in the runtime dir: {}", found.dest.display());
    }
}
