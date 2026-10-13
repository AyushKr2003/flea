use std::path::Path;
use super::sandbox::{BWRAP, BWRAP_FLAGS, CPU_SECONDS, PRLIMIT};

// Chromium reserves large virtual ranges, so this still-image helper keeps the CPU cap without an address-space cap.
pub fn wrap_html(inner: &[String], folder: &Path, writable: &Path) -> Vec<String> {
    let mut argv = vec![PRLIMIT.to_string(), format!("--cpu={CPU_SECONDS}"), BWRAP.to_string()];
    argv.extend(BWRAP_FLAGS.iter().map(|flag| flag.to_string()));
    for (flag, from, to) in [("--ro-bind", folder, "/page"), ("--bind", writable, "/output")] {
        argv.extend([flag.to_string(), from.to_string_lossy().into_owned(), to.to_string()]);
    }
    for (name, value) in [("QT_QPA_PLATFORM", "offscreen"),
        ("QT_QPA_PLATFORMTHEME", "generic"), ("HOME", "/tmp"), ("QT_FORCE_STDERR_LOGGING", "1")] {
        argv.extend(["--setenv".to_string(), name.to_string(), value.to_string()]);
    }
    argv.extend_from_slice(inner);
    argv
}
