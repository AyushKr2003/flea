// Eligibility layers 1, 3 and 4: which drives may be flashed, from sysfs, mountinfo and swaps.
use crate::backend::flash::{Drive, REFUSED_HOLDSIMAGE, REFUSED_MEMBER, REFUSED_READONLY, REFUSED_SMALL};
use std::path::{Path, PathBuf};

// Never candidates, whatever their flags say.
const EXCLUDED_PREFIXES: [&str; 6] = ["loop", "zram", "dm-", "md", "nbd", "sr"];
// The system paths whose disk is never listed.
const SYSTEM_PATHS: [&str; 6] = ["/", "/home", "/boot", "/efi", "/usr", "/var"];
// 512 bytes, the sector size size files count in.
const SECTOR_BYTES: u64 = 512;

// Every reader takes its root, so tests run on fake trees; production passes /sys and /proc paths.
pub struct Roots<'a> {
    pub sys: &'a Path,
    pub dev: &'a Path,
    pub exe: &'a Path,
    pub ui: &'a Path,
}

// Sample sysfs: <sys>/block/sda with removable, ro, size, diskseq, dev, vendor, model and holders/.
pub fn list_drives(roots: &Roots, mountinfo: &str, swaps: &str, image: Option<&Path>, image_bytes: Option<u64>) -> Vec<Drive> {
    let mut excluded = excluded_disks(roots, mountinfo, swaps);
    let _ = excluded.insert(String::new());
    let mut out = Vec::new();
    for dev in block_names(roots.sys) {
        if let Some(drive) = drive_if_candidate(roots, mountinfo, &excluded, &dev, image, image_bytes) {
            out.push(drive);
        }
    }
    out
}

// Layer 4: true when the drive the Flash step showed is gone or differs, so nothing is touched.
pub fn identity_changed(roots: &Roots, mountinfo: &str, swaps: &str, dev: &str, seq: u64, serial: &str, bytes: u64) -> bool {
    let drives = list_drives(roots, mountinfo, swaps, None, None);
    match drives.iter().find(|d| d.dev == dev) {
        None => true,
        Some(d) => d.seq != seq || d.serial != serial || d.bytes != bytes || !d.refused.is_empty(),
    }
}

// Sorted, so the pane order is the kernel's and stable across runs.
fn block_names(sys: &Path) -> Vec<String> {
    let mut names = Vec::new();
    let Ok(entries) = std::fs::read_dir(sys.join("block")) else { return names; };
    for entry in entries.flatten() {
        if let Some(name) = entry.file_name().to_str() {
            names.push(name.to_string());
        }
    }
    names.sort();
    names
}

// None when any layer refuses to list the drive at all; refused names why it cannot take the image.
fn drive_if_candidate(roots: &Roots, mountinfo: &str, excluded: &std::collections::HashSet<String>, dev: &str, image: Option<&Path>, image_bytes: Option<u64>) -> Option<Drive> {
    // Loop devices are never candidates, unless the bench seam admits this one; every other
    // prefix is refused outright, before any flag is read.
    if EXCLUDED_PREFIXES.iter().any(|p| dev.starts_with(p)) && !(dev.starts_with("loop") && loop_permitted(dev, roots.sys)) {
        return None;
    }
    if excluded.contains(dev) {
        return None;
    }
    let base = roots.sys.join("block").join(dev);
    if !removable_or_bus(&base) {
        return None;
    }
    let bytes = read_num(&base.join("size")).unwrap_or(0).saturating_mul(SECTOR_BYTES);
    let seq = read_num(&base.join("diskseq")).unwrap_or(0);
    let serial = read_text(&base.join("serial")).or_else(|_| read_text(&base.join("device").join("serial"))).unwrap_or_default();
    let model = drive_model(&base);
    let volumes = volumes(roots, dev);
    let label = if volumes.len() == 1 { volumes[0].clone() } else { model.clone() };
    let mut refused = String::new();
    if read_num(&base.join("ro")).unwrap_or(0) == 1 {
        refused = REFUSED_READONLY.to_string();
    } else if !holders(&base).is_empty() {
        refused = REFUSED_MEMBER.to_string();
    } else if let Some(path) = image {
        if disk_under(path, mountinfo, roots.sys).as_deref() == Some(dev) {
            refused = REFUSED_HOLDSIMAGE.to_string();
        }
    }
    if refused.is_empty() {
        if let Some(want) = image_bytes {
            if bytes < want {
                refused = REFUSED_SMALL.to_string();
            }
        }
    }
    Some(Drive { dev: dev.to_string(), seq, serial, label, model, bytes, volumes, refused })
}

// Removable, or a device path through USB, an MMC host or FireWire, the way udisks derives Removable.
fn removable_or_bus(base: &Path) -> bool {
    if read_num(&base.join("removable")).unwrap_or(0) == 1 {
        return true;
    }
    let Ok(target) = std::fs::read_link(base.join("device")) else { return false; };
    let text = target.to_string_lossy().to_lowercase();
    text.contains("usb") || text.contains("mmc") || text.contains("sdhci") || text.contains("firewire") || text.contains("ieee1394")
}

// "if the model contains the vendor, the model alone", omarchy-drive-info's own rule.
fn drive_model(base: &Path) -> String {
    let vendor = read_text(&base.join("device").join("vendor")).or_else(|_| read_text(&base.join("vendor"))).unwrap_or_default();
    let model = read_text(&base.join("device").join("model")).or_else(|_| read_text(&base.join("model"))).unwrap_or_default();
    let (vendor, model) = (vendor.trim().to_string(), model.trim().to_string());
    if model.is_empty() {
        return vendor;
    }
    if !vendor.is_empty() && model.contains(&vendor) {
        return model;
    }
    if vendor.is_empty() {
        return model;
    }
    format!("{vendor} {model}")
}

// Partition entries are subdirectories carrying their own dev file.
fn partitions(base: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(base) else { return out; };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() && path.join("dev").is_file() && path.join("partition").is_file() {
            if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                out.push(name.to_string());
            }
        }
    }
    out.sort();
    out
}

// The volumes the pane lists: each partition's filesystem label when it has one, else its
// kernel name. Labels come from /dev/disk/by-label, which the kernel maintains itself, so no
// sentence in any language is ever parsed for them.
fn volumes(roots: &Roots, dev: &str) -> Vec<String> {
    let base = roots.sys.join("block").join(dev);
    let mut labels = std::collections::HashMap::new();
    if let Ok(entries) = std::fs::read_dir(roots.dev.join("disk/by-label")) {
        for entry in entries.flatten() {
            let label = entry.file_name().to_string_lossy().to_string();
            let target = std::fs::read_link(entry.path()).unwrap_or_default();
            let part = target.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_string();
            if !part.is_empty() && parent_disk(&part) == dev {
                labels.entry(part).or_insert(label);
            }
        }
    }
    partitions(&base).into_iter().map(|part| labels.remove(&part).unwrap_or(part)).collect()
}

// Non-empty holders make the drive a RAID or volume-group member.
fn holders(base: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(base.join("holders")) else { return out; };
    for entry in entries.flatten() {
        if let Some(name) = entry.file_name().to_str() {
            out.push(name.to_string());
        }
    }
    out
}

// Every disk that is never listed: under the six system paths, under an active swap, under Flea itself.
fn excluded_disks(roots: &Roots, mountinfo: &str, swaps: &str) -> std::collections::HashSet<String> {
    let mut out = std::collections::HashSet::new();
    for path in SYSTEM_PATHS {
        if let Some(disk) = disk_under(Path::new(path), mountinfo, roots.sys) {
            out.insert(disk);
        }
    }
    for disk in swap_disks(swaps, mountinfo, roots.sys) {
        out.insert(disk);
    }
    for path in [roots.exe, roots.ui] {
        if !path.as_os_str().is_empty() {
            if let Some(disk) = disk_under(path, mountinfo, roots.sys) {
                out.insert(disk);
            }
        }
    }
    out
}

// The disk under a path, from mountinfo's mount source through /sys/dev/block, never from st_dev.
fn disk_under(path: &Path, mountinfo: &str, sys: &Path) -> Option<String> {
    let entry = super::mountinfo::mount_entry_in(path, mountinfo)?;
    resolve_disk(&entry.majmin, sys)
}

// Sample swaps line: "/swapfile file 8388604 2594844 -2", or "/dev/sda3 partition ...".
fn swap_disks(swaps: &str, mountinfo: &str, sys: &Path) -> Vec<String> {
    let mut out = Vec::new();
    for (i, line) in swaps.lines().enumerate() {
        if i == 0 && line.starts_with("Filename") {
            continue;
        }
        let file = line.split_whitespace().next().unwrap_or_default();
        if file.is_empty() {
            continue;
        }
        if let Some(dev) = file.strip_prefix("/dev/") {
            let base = dev.trim_end_matches(char::is_numeric).trim_end_matches('p');
            if !base.is_empty() {
                out.push(base.to_string());
            }
            continue;
        }
        if let Some(disk) = disk_under(Path::new(file), mountinfo, sys) {
            out.push(disk);
        }
    }
    out
}

// Maj:min through the dev/block link to the disk, following dm and md slaves to the parent.
fn resolve_disk(majmin: &str, sys: &Path) -> Option<String> {
    let target = std::fs::read_link(sys.join("dev/block").join(majmin)).ok()?;
    let text = target.to_string_lossy().to_string();
    let at = text.find("block/")?;
    let mut rest = text[at + 6..].replace('\\', "/");
    if rest.starts_with('/') {
        rest.remove(0);
    }
    let parts: Vec<&str> = rest.split('/').filter(|p| !p.is_empty()).collect();
    let mut name = parts.last()?.to_string();
    for _ in 0..8 {
        // A partition lives one level under its disk, so the link's last component names the
        // partition and the disk is the directory holding it, never the link text alone.
        if let Some(disk) = disk_owning_partition(sys, &name) {
            name = disk;
            continue;
        }
        let base = sys.join("block").join(&name);
        if name.starts_with("dm-") || name.starts_with("md") {
            let held = slaves(&base);
            let first = held.into_iter().min()?;
            name = parent_disk(&first).to_string();
            continue;
        }
        return Some(name);
    }
    None
}

// The disk whose directory holds a partition file for name; a whole disk holds none for itself.
fn disk_owning_partition(sys: &Path, name: &str) -> Option<String> {
    let Ok(entries) = std::fs::read_dir(sys.join("block")) else { return None; };
    for entry in entries.flatten() {
        let disk = entry.file_name().to_string_lossy().to_string();
        if disk == name {
            continue;
        }
        if sys.join("block").join(&disk).join(name).join("partition").is_file() {
            return Some(disk);
        }
    }
    None
}

// The slaves a device-mapper disk is built on; holders point the other way, at what uses the disk.
fn slaves(base: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(base.join("slaves")) else { return out; };
    for entry in entries.flatten() {
        if let Some(name) = entry.file_name().to_str() {
            out.push(name.to_string());
        }
    }
    out
}

// Sample partition: "sda1" answers "sda", "nvme0n1p1" answers "nvme0n1".
fn parent_disk(part: &str) -> &str {
    let trimmed = part.trim_end_matches(char::is_numeric).trim_end_matches('p');
    if trimmed.is_empty() { part } else { trimmed }
}

// A loop device is listed only through the bench seam, and only for a backing file inside its
// marked root; with the feature off the seam does not exist in the binary at all.
fn loop_permitted(dev: &str, sys: &Path) -> bool {
    if !dev.starts_with("loop") {
        return true;
    }
    #[cfg(not(feature = "flash-test-seam"))]
    {
        let _ = sys;
        false
    }
    #[cfg(feature = "flash-test-seam")]
    {
        return loop_backing_inside_marked_root(dev, sys);
    }
}

// Sample backing file: /sys/block/loop0/loop/backing_file answers the file the loop was set up on.
#[cfg(feature = "flash-test-seam")]
fn loop_backing_inside_marked_root(dev: &str, sys: &Path) -> bool {
    // The marker this tree's own sandbox guard owns; a root without it is not a bench root.
    const MARKER: &str = ".flea-test-sandbox";
    let Ok(root) = std::env::var("FLEA_FLASH_ALLOW_LOOP") else { return false; };
    if root.is_empty() {
        return false;
    }
    let root_path = Path::new(&root);
    if !root_path.is_absolute() || !root_path.join(MARKER).is_file() {
        return false;
    }
    let backing = read_text(&sys.join("block").join(dev).join("loop/backing_file")).unwrap_or_default();
    let backing = backing.trim().to_string();
    if backing.is_empty() {
        return false;
    }
    // Strictly inside: the root itself is a directory, never the backing file.
    let Ok(meta) = std::fs::symlink_metadata(&backing) else { return false; };
    if !meta.is_file() {
        return false;
    }
    let canonical_root = root_path.canonicalize().unwrap_or_else(|_| root_path.to_path_buf());
    let canonical_backing = Path::new(&backing).canonicalize().unwrap_or_else(|_| PathBuf::from(&backing));
    canonical_backing.starts_with(&canonical_root) && canonical_backing != canonical_root
}

fn read_num(path: &Path) -> Option<u64> {
    std::fs::read_to_string(path).ok()?.trim().parse().ok()
}

fn read_text(path: &Path) -> Result<String, ()> {
    let text = std::fs::read_to_string(path).map_err(|_| ())?;
    Ok(text.trim().to_string())
}

pub fn roots_for_production() -> (PathBuf, PathBuf) {
    let exe = std::env::current_exe().unwrap_or_default();
    let ui = crate::paths::ui_dir().unwrap_or_default();
    (exe, ui)
}

#[cfg(test)]
#[path = "flasheligible_tests.rs"]
mod tests;
