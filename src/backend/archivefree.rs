// The free-space refusal: before extracting, the archive's unpacked size is weighed against the
// target's free space, and a fit that cannot land is refused with both numbers rather than failing
// halfway through. Unknown on either side refuses nothing: an unreadable index or an unstattable
// filesystem is not evidence the extract cannot fit.
use crate::backend::fsinfo;

// SI with one decimal, the desktop's own rule and ui/js/Format.js's: 3.4 GB, 512 B, never IEC.
// Sample input: 3400000000 -> "3.4 GB".
pub fn format_size(bytes: u64) -> String {
    const UNITS: &[&str] = &["B", "kB", "MB", "GB", "TB"];
    if bytes < 1000 {
        return format!("{} B", bytes);
    }
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1000.0 && unit < UNITS.len() - 1 {
        value /= 1000.0;
        unit += 1;
    }
    format!("{:.1} {}", value, UNITS[unit])
}

// True only when both sides are known and the need passes what is free; an exact fit still fits.
pub fn refuses(needed: u64, free: u64) -> bool {
    needed > free
}

// The board's own sentence, with the archive's leaf, both sizes, and whose free space ran out.
pub fn refusal(archive_leaf: &str, needed: u64, free: u64, target_leaf: &str, fs_name: &str) -> String {
    let _ = fs_name;
    format!("Extracting {} needs {}, and {} has {} free.",
            archive_leaf, format_size(needed), target_leaf, format_size(free))
}

// Some(sentence) when the extract cannot fit, None when it fits or either side is unknown. dest is
// the directory the extract would land in, whose filesystem answers the free space.
pub fn check(archive_leaf: &str, unpacked: u64, dest: &std::path::Path) -> Option<String> {
    if unpacked == 0 {
        return None;
    }
    let parent = dest.parent().unwrap_or(dest);
    let info = fsinfo::read(parent)?;
    if !refuses(unpacked, info.free) {
        return None;
    }
    let target = parent.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "home".to_string());
    Some(refusal(archive_leaf, unpacked, info.free, &target, &info.name))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::testdir::TestDir;

    // SI with one decimal, the desktop's own rule and ui/js/Format.js's: 3.4 GB, 1.2 GB, never IEC.
    #[test]
    fn sizes_read_the_way_the_status_bar_already_writes_them() {
        assert_eq!(format_size(3_400_000_000), "3.4 GB");
        assert_eq!(format_size(1_200_000_000), "1.2 GB");
        assert_eq!(format_size(512), "512 B");
        assert_eq!(format_size(2_400), "2.4 kB");
    }

    #[test]
    fn only_a_real_shortfall_refuses() {
        assert!(refuses(3_400_000_000, 1_200_000_000), "needed past free must refuse");
        assert!(!refuses(1_200_000_000, 3_400_000_000), "needed inside free must pass");
        assert!(!refuses(1_200_000_000, 1_200_000_000), "an exact fit still fits");
        assert!(!refuses(0, 0), "nothing needed refuses nothing");
    }

    // The board's own sentence, with the archive's leaf and both sizes in it.
    #[test]
    fn the_refusal_names_the_archive_and_both_sizes() {
        assert_eq!(refusal("backup.tar.zst", 3_400_000_000, 1_200_000_000, "home", "btrfs"),
                   "Extracting backup.tar.zst needs 3.4 GB, and home has 1.2 GB free.");
    }

    // No fixture can fake a nearly-full filesystem, but every filesystem is nearly full beside
    // u64::MAX: an unpacked size no disk can hold is refused on any directory that statfs can read.
    #[test]
    fn an_unpacked_size_no_disk_can_hold_is_refused_wherever_it_would_land() {
        let d = TestDir::new("archivefree");
        let sentence = check("huge.tar", u64::MAX, d.path()).expect("u64::MAX fits on no filesystem");
        assert!(sentence.contains("huge.tar"), "the sentence names the archive: {}", sentence);
        assert!(sentence.contains("needs"), "and the needed size: {}", sentence);
    }

    #[test]
    fn nothing_needed_or_nothing_known_refuses_nothing() {
        let d = TestDir::new("archivefreefit");
        assert_eq!(check("empty.tar", 0, d.path()), None, "an empty archive always fits");
        assert_eq!(check("small.tar", 1, d.path()), None, "one byte fits on any test filesystem");
    }

    #[test]
    fn an_unstattable_target_is_not_evidence_the_extract_cannot_fit() {
        assert_eq!(check("a.tar", 10, std::path::Path::new("/nonexistent-dir-for-this-test")), None);
    }
}
