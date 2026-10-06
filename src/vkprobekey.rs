// The fingerprint a Vulkan probe answer is cached under: every input the loader's answer depends on.
use crate::icdexclude::manifests::{manifest_library_path, manifest_paths};
use crate::icdexclude::{PCI_CLASS_DISPLAY, PCI_CLASS_SHIFT, SETTINGS_FILE};
use crate::vulkan::{is_card, parse_hex_id, platform_surface};
use std::ffi::OsString;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
// Where the loader, the kernel and the launcher keep what the key covers.
const BOOT_ID_FILE: &str = "/proc/sys/kernel/random/boot_id";
const PCI_ROOT: &str = "/sys/bus/pci/devices";
const DRM_ROOT: &str = "/sys/class/drm";
const ICD_SUBDIR: &str = "vulkan/icd.d";
const LAYER_SUBDIR: &str = "vulkan/implicit_layer.d";
const LIBVULKAN: &str = "libvulkan.so.1";
const LIB_DIRS: [&str; 2] = ["/usr/lib", "/usr/lib64"];
// Every variable under these prefixes can change what the loader or its layers find, MESA_VK_DEVICE_SELECT among them.
const ENV_PREFIXES: [&str; 2] = ["VK_", "MESA_"];
// Every other variable that changes what the loader finds, and DRI_PRIME reorders devices as the Mesa layer does.
const EXTRA_ENV: [&str; 7] = [
    "LD_LIBRARY_PATH",
    "LD_PRELOAD",
    "XDG_DATA_HOME",
    "XDG_DATA_DIRS",
    "XDG_CONFIG_HOME",
    "XDG_CONFIG_DIRS",
    "DRI_PRIME",
];
// Everything the test drives through fake roots, so no test reads the real sysfs or environment.
pub(super) struct Roots<'a> {
    pub(super) boot: &'a Path,
    pub(super) pci: &'a Path,
    pub(super) drm: &'a Path,
    pub(super) icd_dirs: &'a [PathBuf],
    pub(super) layer_dirs: &'a [PathBuf],
    pub(super) lib_dirs: &'a [PathBuf],
    pub(super) settings_files: &'a [PathBuf],
    pub(super) exe: &'a Path,
    pub(super) env_vars: &'a [(String, String)],
    pub(super) surface: &'a str,
}
// The key production reads, after icdexclude ran so its filter is part of what the probe sees.
pub(super) fn real_key() -> Option<String> {
    let roots = crate::icdexclude::xdg_roots(|name| std::env::var_os(name));
    let icd: Vec<PathBuf> = roots.iter().map(|r| r.join(ICD_SUBDIR)).collect();
    let layers: Vec<PathBuf> = roots.iter().map(|r| r.join(LAYER_SUBDIR)).collect();
    let settings: Vec<PathBuf> = roots.iter().map(|r| r.join(SETTINGS_FILE)).collect();
    let system: Vec<PathBuf> = LIB_DIRS.iter().map(PathBuf::from).collect();
    let libs = lib_search_dirs(std::env::var_os("LD_LIBRARY_PATH"), &system);
    let env_vars = collect_env(std::env::vars_os());
    let exe = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("absent"));
    key_for(&Roots {
        boot: Path::new(BOOT_ID_FILE),
        pci: Path::new(PCI_ROOT),
        drm: Path::new(DRM_ROOT),
        icd_dirs: &icd,
        layer_dirs: &layers,
        lib_dirs: &libs,
        settings_files: &settings,
        exe: &exe,
        env_vars: &env_vars,
        surface: &platform_surface().to_string_lossy(),
    })
}
// LD_LIBRARY_PATH in order with empties dropped, then the system dirs: where the dynamic loader looks for a name.
fn lib_search_dirs(ld_library_path: Option<OsString>, system: &[PathBuf]) -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = Vec::new();
    if let Some(value) = ld_library_path {
        for dir in std::env::split_paths(&value) {
            if !dir.as_os_str().is_empty() {
                dirs.push(dir);
            }
        }
    }
    dirs.extend(system.iter().cloned());
    dirs
}
// Every prefixed variable plus the listed ones, sorted, with absent ones named so setting one changes the key.
pub(super) fn collect_env(vars: impl Iterator<Item = (OsString, OsString)>) -> Vec<(String, String)> {
    let mut seen: Vec<(String, String)> = Vec::new();
    for (k, v) in vars {
        let Ok(k) = k.into_string() else {
            continue;
        };
        seen.push((k, v.to_string_lossy().into_owned()));
    }
    let mut out: Vec<(String, String)> = Vec::new();
    for (k, v) in &seen {
        if ENV_PREFIXES.iter().any(|prefix| k.starts_with(prefix)) {
            out.push((k.clone(), v.clone()));
        }
    }
    for name in EXTRA_ENV {
        match seen.iter().find(|(k, v)| k == name && !v.is_empty()) {
            Some((_, v)) => out.push((name.to_string(), v.clone())),
            None => out.push((name.to_string(), String::from("absent"))),
        }
    }
    out.sort();
    out
}
// The digest over every input in a fixed order with a label per section, or None when a manifest listing is not whole.
pub(super) fn key_for(r: &Roots) -> Option<String> {
    let icd_paths = manifest_paths(r.icd_dirs)?;
    let layer_paths = manifest_paths(r.layer_dirs)?;
    let mut parts = vec![format!("boot {}", boot_line(r.boot))];
    for line in pci_lines(r.pci) {
        parts.push(format!("pci {line}"));
    }
    for line in drm_lines(r.drm) {
        parts.push(format!("drm {line}"));
    }
    for line in manifest_lines(&icd_paths) {
        parts.push(format!("icd {line}"));
    }
    for line in manifest_lines(&layer_paths) {
        parts.push(format!("layer {line}"));
    }
    for path in r.settings_files {
        parts.push(format!("settings {}", stat_line(path)));
    }
    for line in icd_lib_lines(&icd_paths, r.lib_dirs) {
        parts.push(format!("lib {line}"));
    }
    parts.push(format!("libvulkan {}", libvulkan_line(r.lib_dirs)));
    for (k, v) in r.env_vars {
        parts.push(format!("env {k}={v}"));
    }
    parts.push(format!("surface {}", r.surface));
    parts.push(format!("exe {}", stat_line(r.exe)));
    Some(crate::figurecache::digest(parts.join("\n").as_bytes()))
}
// The boot id, or unknown when the kernel does not answer.
fn boot_line(path: &Path) -> String {
    std::fs::read_to_string(path)
        .ok()
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| String::from("unknown"))
}
// One sysfs hex file, or None when it cannot be read.
fn hex_file(path: &Path) -> Option<u32> {
    std::fs::read_to_string(path).ok().and_then(|s| parse_hex_id(&s))
}
// Every PCI display controller as slot plus vendor and device, sorted.
fn pci_lines(root: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(root) else {
        return out;
    };
    for entry in entries.flatten() {
        let slot = entry.file_name().to_string_lossy().into_owned();
        let dir = entry.path();
        if hex_file(&dir.join("class")).map_or(true, |c| c >> PCI_CLASS_SHIFT != PCI_CLASS_DISPLAY) {
            continue;
        }
        let vendor = hex_file(&dir.join("vendor"));
        let device = hex_file(&dir.join("device"));
        if let (Some(v), Some(d)) = (vendor, device) {
            out.push(format!("{slot} {v:04x} {d:04x}"));
        }
    }
    out.sort();
    out
}
// Every DRM card as name plus vendor and device, sorted.
fn drm_lines(root: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(root) else {
        return out;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !is_card(&name) {
            continue;
        }
        let dev = entry.path().join("device");
        let vendor = hex_file(&dev.join("vendor"));
        let device = hex_file(&dev.join("device"));
        if let (Some(v), Some(d)) = (vendor, device) {
            out.push(format!("{name} {v:04x} {d:04x}"));
        }
    }
    out.sort();
    out
}
// One path as size, mtime in nanoseconds and inode, or absent when it cannot be stat'ed.
fn stat_line(path: &Path) -> String {
    let Ok(meta) = std::fs::metadata(path) else {
        return format!("absent {}", path.display());
    };
    let mtime = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{} {} {mtime} {}", path.display(), meta.len(), meta.ino())
}
// Every manifest as its stat line, sorted.
fn manifest_lines(paths: &[PathBuf]) -> Vec<String> {
    let mut out: Vec<String> = paths.iter().map(|p| stat_line(p)).collect();
    out.sort();
    out
}
// Every ICD manifest's library as a stat line: absolute as written, with a slash beside the manifest, else by search.
fn icd_lib_lines(paths: &[PathBuf], lib_dirs: &[PathBuf]) -> Vec<String> {
    let mut out = Vec::new();
    for path in paths {
        let Some(lib) = manifest_library_path(path) else {
            continue;
        };
        if Path::new(&lib).is_absolute() {
            out.push(stat_line(Path::new(&lib)));
            continue;
        }
        // The loader resolves a relative library_path with a slash against the manifest's directory, else by search.
        if lib.contains('/') {
            let dir = path.parent().unwrap_or_else(|| Path::new("."));
            out.push(stat_line(&dir.join(&lib)));
            continue;
        }
        let mut found = false;
        for dir in lib_dirs {
            let candidate = dir.join(&lib);
            if candidate.is_file() {
                out.push(stat_line(&candidate));
                found = true;
            }
        }
        if !found {
            out.push(format!("absent {lib}"));
        }
    }
    out.sort();
    out
}
// libvulkan.so.1 as the lib dirs resolve it, following symlinks, or absent when none does.
fn libvulkan_line(lib_dirs: &[PathBuf]) -> String {
    for dir in lib_dirs {
        if let Ok(real) = std::fs::canonicalize(dir.join(LIBVULKAN)) {
            return stat_line(&real);
        }
    }
    String::from("absent libvulkan.so.1")
}
#[cfg(test)]
#[path = "vkprobekey_tests.rs"]
mod tests;
