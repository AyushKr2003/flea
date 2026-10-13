// Window icons against one mount table, including mixed-path listings and SMB extensions.
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
    l.push("mnt/usb/Launcher", false);
    l.push("home/programs/Launcher", false);
    let metas = (0..2).map(|_| Meta { size: 1, mtime: 2, mode: 0o100755, target_is_dir: false, target: String::new(), dev: 0 }).collect::<Vec<_>>();
    let (mime, icons, aliases, thumbs, mut kinds) = dbs();
    crate::backend::mountinfo::test_reset();
    rows_line(Path::new("/"), &l, &metas, 0, 0.0, &mime, &icons, &aliases, &thumbs, &mut kinds);
    assert_eq!(crate::backend::mountinfo::test_reads(), 1);
}

#[test]
fn listpaths_rows_use_their_own_mount_modes() {
    let mut l = Listing::new();
    l.push("mnt/usb/Launcher", false);
    l.push("home/programs/Launcher", false);
    let metas = (0..2).map(|_| Meta { size: 1, mtime: 2, mode: 0o100755, target_is_dir: false, target: String::new(), dev: 0 }).collect::<Vec<_>>();
    let body = "1 0 8:1 / / rw - ext4 /dev/a rw\n\
                2 1 8:17 / /mnt/usb rw - exfat /dev/sdb1 rw\n";
    let (mime, icons, aliases, thumbs, mut kinds) = dbs();
    let line = rows_line_in(Path::new("/"), body, &l, &metas, 0, 0.0, &mime, &icons, &aliases, &thumbs, &mut kinds);
    let parsed = crate::jsondoc::parse(&line).unwrap();
    let rows = parsed.get("rows").unwrap().as_array().unwrap();
    assert_eq!(rows[0].get("i").and_then(crate::jsondoc::Json::as_str), Some("text-x-generic"), "an exFAT Recent row has no real execute bits");
    assert_eq!(rows[1].get("i").and_then(crate::jsondoc::Json::as_str), Some("application-x-executable"), "an ext4 Recent row keeps its execute bits");
    for row in rows {
        assert_eq!(row.get("p").and_then(crate::jsondoc::Json::as_f64), Some(33261.0), "the reported mode is preserved");
    }
}

#[test]
fn search_rows_on_an_ext4_mount_keep_modes_under_an_exfat_base() {
    let mut l = Listing::new();
    l.push("before", false);
    l.push("native/Launcher", false);
    let metas = vec![Meta { size: 1, mtime: 2, mode: 0o100755, target_is_dir: false, target: String::new(), dev: 0 }];
    let body = "1 0 8:17 / /mnt/usb rw - exfat /dev/sdb1 rw\n\
                2 1 8:1 / /mnt/usb/native rw - ext4 /dev/a rw\n";
    let (mime, icons, aliases, thumbs, mut kinds) = dbs();
    let line = rows_line_in(Path::new("/mnt/usb"), body, &l, &metas, 1, 0.0, &mime, &icons, &aliases, &thumbs, &mut kinds);
    assert!(line.contains(r#""n":"native/Launcher","d":false,"s":1,"m":2,"p":33261,"i":"application-x-executable""#), "the nested ext4 file keeps its own mode: {line}");
}

#[test]
fn a_gvfs_row_window_never_reads_the_mount_table() {
    let mut l = Listing::new();
    l.push("sub/Launcher", false);
    let metas = vec![Meta { size: 1, mtime: 2, mode: 0o100755, target_is_dir: false, target: String::new(), dev: 0 }];
    let (mime, icons, aliases, thumbs, mut kinds) = dbs();
    mountinfo::test_reset();
    rows_line(Path::new("/run/user/1000/gvfs/smb-share:server=nas,share=files"), &l, &metas, 0, 0.0, &mime, &icons, &aliases, &thumbs, &mut kinds);
    assert_eq!(mountinfo::test_reads(), 0);
}

#[test]
fn smb_rows_keep_real_modes_only_with_posix_or_unix_super_options() {
    let mut l = Listing::new();
    l.push("Launcher", false);
    let metas = vec![Meta { size: 1, mtime: 2, mode: 0o100755, target_is_dir: false, target: String::new(), dev: 0 }];
    for fstype in ["cifs", "smb3"] {
        for (options, icon) in [
            ("rw,posix", "application-x-executable"),
            ("rw,unix", "application-x-executable"),
            ("rw,nounix,noposix", "text-x-generic"),
            ("rw,posix=0,unix=0", "text-x-generic"),
            ("rw", "text-x-generic"),
        ] {
            let body = format!("1 0 8:1 / / rw - ext4 /dev/a rw\n2 1 0:31 / /mnt/share rw - {fstype} //server/share {options}\n");
            let (mime, icons, aliases, thumbs, mut kinds) = dbs();
            let line = rows_line_in(Path::new("/mnt/share"), &body, &l, &metas, 0, 0.0, &mime, &icons, &aliases, &thumbs, &mut kinds);
            let parsed = crate::jsondoc::parse(&line).unwrap();
            let rows = parsed.get("rows").unwrap().as_array().unwrap();
            assert_eq!(rows[0].get("i").and_then(crate::jsondoc::Json::as_str), Some(icon), "{fstype} super options {options}");
        }
    }
}
