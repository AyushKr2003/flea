// The TUI's gvfs head start: the GUI's prepare and helper spawn, with "-" for the qs shell's page-cache list this process never maps.
pub(crate) fn start(path: &str) -> Option<crate::gvfsprefetch::Prefetch> {
    // Sample path: "/run/user/1000/gvfs/smb-share:server=x,share=y/dir".
    let (dest, start_ms) = crate::gvfsprefetch::prepare(path)?;
    if !crate::gui::warm_all(None, Some((path, dest.as_path()))) {
        return None;
    }
    Some(crate::gvfsprefetch::Prefetch { dest, path: path.to_string(), start_ms })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::testdir::TestDir;

    // One test's borrowed environment, restored on drop, because sibling tests share the process.
    static TEST_GUARD: std::sync::Mutex<()> = std::sync::Mutex::new(());
    struct EnvGuard {
        key: &'static str,
        was: Option<std::ffi::OsString>,
    }
    impl EnvGuard {
        fn set(key: &'static str, value: &std::ffi::OsStr) -> EnvGuard {
            let was = std::env::var_os(key);
            std::env::set_var(key, value);
            EnvGuard { key, was }
        }
    }
    impl Drop for EnvGuard {
        fn drop(&mut self) {
            match self.was.take() {
                Some(value) => std::env::set_var(self.key, value),
                None => std::env::remove_var(self.key),
            }
        }
    }

    #[test]
    fn a_local_start_prepares_nothing_and_spawns_nothing() {
        let _guard = TEST_GUARD.lock().unwrap();
        let d = TestDir::new("tui-warm-local");
        let _xdg = EnvGuard::set("XDG_RUNTIME_DIR", d.path().as_os_str());
        assert!(start(d.path().to_str().unwrap()).is_none(), "prepare answers None off gvfs, so no helper ever spawns");
    }

    #[test]
    fn a_gvfs_start_prepares_and_spawns_one_helper() {
        let _guard = TEST_GUARD.lock().unwrap();
        let d = TestDir::new("tui-warm-gvfs");
        let _xdg = EnvGuard::set("XDG_RUNTIME_DIR", d.path().as_os_str());
        // Sample path: "/run/user/1000/gvfs/smb-share:server=x,share=y/dir".
        let path = "/run/user/1000/gvfs/smb-share:server=x,share=y/dir";
        // In-harness current_exe is the test binary, so this proves prepare plus a successful spawn; the gio half is gui.rs's tested job.
        let found = start(path).expect("a gvfs start prepares");
        assert_eq!(found.path, path);
        assert!(found.dest.starts_with(d.path().join("flea")), "the dest is this launch's file in the runtime dir: {}", found.dest.display());
    }
}
