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

fn assert_program_icon(base: &Path, body: &str, names: &[&str], expected: &[&str]) {
    let mut l = Listing::new();
    for name in names {
        l.push(name, false);
    }
    let metas = names.iter().map(|_| Meta { size: 1, mtime: 2, mode: 0o100755, target_is_dir: false, target: String::new(), dev: 0 }).collect::<Vec<_>>();
    let (mime, icons, aliases, thumbs, mut kinds) = dbs();
    let line = rows_line_in(base, body, &l, &metas, 0, 0.0, &mime, &icons, &aliases, &thumbs, &mut kinds);
    let parsed = crate::jsondoc::parse(&line).unwrap();
    let rows = parsed.get("rows").unwrap().as_array().unwrap();
    assert_eq!(rows.len(), expected.len());
    for (row, icon) in rows.iter().zip(expected) {
        assert_eq!(row.get("i").and_then(crate::jsondoc::Json::as_str), Some(*icon), "{base:?}: {line}");
        assert_eq!(row.get("p").and_then(crate::jsondoc::Json::as_f64), Some(33261.0), "the reported mode stays intact");
    }
}

#[test]
fn gvfs_phone_rows_have_no_real_execute_bits() {
    for backend in ["mtp", "afc", "gphoto2", "MTP"] {
        let base = format!("/run/user/1000/gvfs/{backend}:host=phone");
        assert_eq!(gvfs_class(Path::new(&base)), Some("phone"));
        assert_program_icon(Path::new(&base), "", &["Launcher", "sub/Launcher"], &["text-x-generic"; 2]);
    }
}

#[test]
fn gvfs_network_rows_without_unix_modes_have_no_real_execute_bits() {
    for backend in ["smb-share", "smb-server", "dav", "davs", "http", "https", "google-drive", "onedrive", "SMB-SHARE"] {
        let base = format!("/run/user/1000/gvfs/{backend}:host=server");
        assert_eq!(gvfs_class(Path::new(&base)), Some("network"));
        assert_program_icon(Path::new(&base), "", &["Launcher", "sub/Launcher"], &["text-x-generic"; 2]);
    }
}

#[test]
fn gvfs_sftp_and_unknown_backends_keep_their_execute_bits() {
    for backend in ["sftp", "SFTP", "unknown-backend"] {
        let base = format!("/run/user/1000/gvfs/{backend}:host=server");
        assert_eq!(gvfs_class(Path::new(&base)), Some("network"));
        assert_program_icon(Path::new(&base), "", &["Launcher", "sub/Launcher"], &["application-x-executable"; 2]);
    }
    assert_eq!(gvfs_class(Path::new("/unrecognized")), None);
    assert_program_icon(Path::new("/unrecognized"), "", &["Launcher"], &["application-x-executable"]);
}

#[test]
fn gvfs_rows_decide_modes_without_resolving_the_base() {
    let base = Path::new("/run/user/1000/gvfs/smb-share:server=nas,share=files");
    mountinfo::test_reset();
    assert_program_icon(base, "", &["Launcher"], &["text-x-generic"]);
    assert_eq!(mountinfo::test_resolutions(), 0, "the gvfs spelling decides the base without any resolution");
}

#[test]
fn gvfs_search_rows_decide_modes_without_resolving_their_parent() {
    let base = Path::new("/run/user/1000/gvfs/smb-share:server=nas,share=files");
    mountinfo::test_reset();
    assert_program_icon(base, "", &["sub/Launcher", "sub/OtherLauncher"], &["text-x-generic"; 2]);
    assert_eq!(mountinfo::test_resolutions(), 0, "neither the base nor a gvfs search parent is resolved");
}

#[test]
fn a_symlinked_window_base_uses_the_target_mounts_modes() {
    let d = crate::backend::testdir::TestDir::new("rows-linked-base");
    let usb = d.dir("usb");
    let link = d.join("linked-usb");
    std::os::unix::fs::symlink(&usb, &link).unwrap();
    for fstype in ["vfat", "exfat", "ext4"] {
        let body = format!("1 0 8:1 / / rw - ext4 /dev/a rw\n2 1 8:17 / {} rw - {fstype} /dev/b rw\n", usb.display());
        let icon = if fstype == "ext4" { "application-x-executable" } else { "text-x-generic" };
        mountinfo::test_reset();
        assert_program_icon(&link, &body, &["Launcher", "OtherLauncher"], &[icon; 2]);
        assert_eq!(mountinfo::test_resolutions(), 1, "plain children reuse the resolved window base");
    }
}

#[test]
fn mixed_path_rows_resolve_each_distinct_symlinked_parent_once() {
    let d = crate::backend::testdir::TestDir::new("rows-linked-parents");
    let usb = d.dir("usb");
    let native = d.dir("native");
    std::os::unix::fs::symlink(&usb, d.join("linked-usb")).unwrap();
    std::os::unix::fs::symlink(&native, usb.join("linked-native")).unwrap();
    let body = format!("1 0 8:1 / / rw - ext4 /dev/a rw\n2 1 8:17 / {} rw - exfat /dev/b rw\n", usb.display());
    mountinfo::test_reset();
    assert_program_icon(d.path(), &body, &["linked-usb/Launcher", "linked-usb/OtherLauncher", "linked-usb/linked-native/Launcher"],
        &["text-x-generic", "text-x-generic", "application-x-executable"]);
    assert_eq!(mountinfo::test_resolutions(), 3, "one base and two distinct parents, not three rows");
    assert_program_icon(&native, &body, &["../linked-usb/Launcher"], &["text-x-generic"]);
}

#[test]
fn failed_parent_resolution_keeps_the_supplied_mount_path() {
    let d = crate::backend::testdir::TestDir::new("rows-missing-parent");
    let missing = d.join("missing-usb");
    let body = format!("1 0 8:1 / / rw - ext4 /dev/a rw\n2 1 8:17 / {} rw - exfat /dev/b rw\n", missing.display());
    assert_program_icon(&missing, &body, &["Launcher", "sub/Launcher"], &["text-x-generic"; 2]);
}
