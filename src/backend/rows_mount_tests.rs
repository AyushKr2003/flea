// The window's icon against a mount table: an extensionless program on FAT-family and on btrfs, and one table read per window.
use super::tests::dbs;
use super::*;

// A FAT or exFAT mount reports 0755 on every file, so its execute bits are the mount's, never the file's.
#[test]
fn an_extensionless_program_draws_the_program_mark_only_where_its_mode_is_its_own() {
    let mut l = Listing::new();
    l.push("PinyonShiftLauncher", false);
    let metas = vec![Meta { size: 1, mtime: 2, mode: 0o100755, target_is_dir: false, target: String::new(), dev: 0 }];
    let exfat = "36 25 0:31 / /mnt/usb rw,relatime - exfat /dev/sdb1 rw\n";
    let btrfs = "36 25 0:31 / /mnt/usb rw,relatime - btrfs /dev/sdb1 rw\n";
    let (mime, icons, aliases, thumbs, mut kinds) = dbs();
    let on_exfat = rows_line_in(Path::new("/mnt/usb"), exfat, &l, &metas, 0, 0.0, &mime, &icons, &aliases, &thumbs, &mut kinds);
    assert!(on_exfat.contains(r#""p":33261,"i":"text-x-generic""#), "the mount's 0755 is not a program: {}", on_exfat);
    let (mime, icons, aliases, thumbs, mut kinds) = dbs();
    let on_btrfs = rows_line_in(Path::new("/mnt/usb"), btrfs, &l, &metas, 0, 0.0, &mime, &icons, &aliases, &thumbs, &mut kinds);
    assert!(on_btrfs.contains(r#""p":33261,"i":"application-x-executable""#), "a btrfs file keeps its own bits: {}", on_btrfs);
}

// One window reads the mount table once through the counted seam, so no call site adds a read.
#[test]
fn a_row_window_reads_the_mount_table_once() {
    let mut l = Listing::new();
    l.push("a.txt", false);
    let metas = vec![Meta { size: 1, mtime: 2, mode: 0o100644, target_is_dir: false, target: String::new(), dev: 0 }];
    let (mime, icons, aliases, thumbs, mut kinds) = dbs();
    crate::backend::mountinfo::test_reset();
    rows_line(Path::new("/nonexistent"), &l, &metas, 0, 0.0, &mime, &icons, &aliases, &thumbs, &mut kinds);
    assert_eq!(crate::backend::mountinfo::test_reads(), 1);
}
