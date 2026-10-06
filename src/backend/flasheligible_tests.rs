// Fake /sys/block trees for every shape TECH.md section 11 lists; each test drives list_drives.
use super::*;
use crate::backend::testdir::TestDir;
use std::sync::Mutex;

// The loop seam reads one process-global variable, so the two tests that touch it hold one lock.
static LOOP_ENV_GUARD: Mutex<()> = Mutex::new(());

struct Fake {
    _dir: TestDir,
    sys: PathBuf,
    dev: PathBuf,
}

fn fake(tag: &str) -> Fake {
    let dir = TestDir::new(tag);
    let sys = dir.dir("sys");
    std::fs::create_dir_all(sys.join("block")).unwrap();
    std::fs::create_dir_all(sys.join("dev/block")).unwrap();
    let dev = dir.dir("dev");
    Fake { _dir: dir, sys, dev }
}

// Sample by-label tree: dev/disk/by-label/128GB answers the sda1 it points at.
fn label(dev: &Path, name: &str, part: &str) {
    let dir = dev.join("disk/by-label");
    std::fs::create_dir_all(&dir).unwrap();
    let _ = std::os::unix::fs::symlink(part, dir.join(name));
}

fn disk(sys: &Path, dev: &str, removable: &str, ro: &str, bytes: u64, seq: &str, bus: &str) {
    let base = sys.join("block").join(dev);
    std::fs::create_dir_all(base.join("holders")).unwrap();
    std::fs::write(base.join("removable"), removable).unwrap();
    std::fs::write(base.join("ro"), ro).unwrap();
    std::fs::write(base.join("size"), format!("{}", bytes / 512)).unwrap();
    std::fs::write(base.join("diskseq"), seq).unwrap();
    let _ = std::os::unix::fs::symlink(bus, base.join("device"));
}

fn identity(sys: &Path, dev: &str, vendor: &str, model: &str, serial: &str) {
    let base = sys.join("block").join(dev);
    std::fs::write(base.join("vendor"), vendor).unwrap();
    std::fs::write(base.join("model"), model).unwrap();
    if !serial.is_empty() {
        std::fs::write(base.join("serial"), serial).unwrap();
    }
}

// Sample link: sys/dev/block/8:17 answers ../../block/sda/sda1, the shape read_link returns.
fn part(sys: &Path, dev: &str, part: &str, majmin: &str) {
    let base = sys.join("block").join(dev).join(part);
    std::fs::create_dir_all(&base).unwrap();
    std::fs::write(base.join("dev"), majmin).unwrap();
    std::fs::write(base.join("partition"), "1").unwrap();
    let _ = std::os::unix::fs::symlink(format!("../../block/{dev}/{part}"), sys.join("dev/block").join(majmin));
}

fn devlink(sys: &Path, majmin: &str, target: &str) {
    let _ = std::os::unix::fs::symlink(target, sys.join("dev/block").join(majmin));
}

fn roots() -> (PathBuf, PathBuf) {
    (PathBuf::new(), PathBuf::new())
}

// Sample mountinfo: root on nvme0n1p1, the box's own shape with one disk swapped in.
fn root_mountinfo() -> String {
    "28 1 8:1 / / rw - ext4 /dev/nvme0n1p1 rw\n".to_string()
}

fn drives(sys: &Path, dev: &Path, mountinfo: &str, image_bytes: Option<u64>) -> Vec<Drive> {
    let (exe, ui) = roots();
    let r = Roots { sys, dev, exe: &exe, ui: &ui };
    list_drives(&r, mountinfo, "Filename Type Size Used Priority\n", None, image_bytes)
}

fn stick(sys: &Path) {
    disk(sys, "sda", "1\n", "0\n", 124_623_257_600, "2\n", "/usb2/1-1");
    identity(sys, "sda", "General", "General USB Flash Disk", "2003007157171692");
    part(sys, "sda", "sda1", "8:17");
}

fn system(sys: &Path) {
    disk(sys, "nvme0n1", "0\n", "0\n", 512_000_000_000, "9\n", "/pci0000:00/nvme");
    identity(sys, "nvme0n1", "Samsung", "Samsung SSD 970", "");
    part(sys, "nvme0n1", "nvme0n1p1", "8:1");
    devlink(sys, "8:1", "../../block/nvme0n1/nvme0n1p1");
}

#[test]
fn a_usb_stick_is_listed_and_the_system_disk_is_not() {
    let f = fake("eligible-usb");
    system(&f.sys);
    stick(&f.sys);
    label(&f.dev, "128GB", "sda1");
    let got = drives(&f.sys, &f.dev, &root_mountinfo(), None);
    assert_eq!(got.len(), 1, "only the stick is a candidate: {:?}", got.iter().map(|d| &d.dev).collect::<Vec<_>>());
    let sda = &got[0];
    assert_eq!(sda.dev, "sda");
    assert_eq!((sda.seq, sda.bytes), (2, 124_623_257_600));
    assert_eq!(sda.serial, "2003007157171692");
    assert_eq!(sda.model, "General USB Flash Disk", "the model already holds the vendor");
    assert_eq!(sda.volumes, vec!["128GB"], "the rail's volume label, not the kernel name");
    assert_eq!(sda.label, "128GB", "one volume names the row until the rail says otherwise");
    assert_eq!(sda.refused, "");
}

#[test]
fn a_partition_with_no_label_lists_under_its_kernel_name() {
    let f = fake("eligible-nolabel");
    system(&f.sys);
    stick(&f.sys);
    let got = drives(&f.sys, &f.dev, &root_mountinfo(), None);
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].volumes, vec!["sda1"]);
    assert_eq!(got[0].label, "sda1");
}

#[test]
fn an_sd_card_with_its_lock_on_is_refused_readonly() {
    let f = fake("eligible-ro");
    system(&f.sys);
    disk(&f.sys, "mmcblk0", "1\n", "1\n", 32_000_000_000, "4\n", "/mmc/host");
    identity(&f.sys, "mmcblk0", "SD", "SD32G", "9");
    let got = drives(&f.sys, &f.dev, &root_mountinfo(), None);
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].refused, "readonly");
}

#[test]
fn a_usb_disk_holding_home_is_never_listed() {
    let f = fake("eligible-home");
    system(&f.sys);
    stick(&f.sys);
    let info = root_mountinfo() + "40 28 8:17 / /home rw - ext4 /dev/sda1 rw\n";
    let got = drives(&f.sys, &f.dev, &info, None);
    assert!(got.is_empty(), "the disk under /home is never a candidate");
}

#[test]
fn a_btrfs_root_on_dm_crypt_excludes_its_disk() {
    let f = fake("eligible-crypt");
    system(&f.sys);
    // Removable over USB, so only the dm-crypt chain below can exclude this disk, never its flags.
    std::fs::write(f.sys.join("block").join("nvme0n1").join("removable"), "1\n").unwrap();
    let _ = std::fs::remove_file(f.sys.join("block").join("nvme0n1").join("device"));
    let _ = std::os::unix::fs::symlink("/usb2/1-9", f.sys.join("block").join("nvme0n1").join("device"));
    stick(&f.sys);
    // Sample chain: / on dm-0, dm-0 built on nvme0n1p2, the box's own dm-crypt shape.
    let dm = f.sys.join("block").join("dm-0");
    std::fs::create_dir_all(dm.join("holders")).unwrap();
    std::fs::create_dir_all(dm.join("slaves")).unwrap();
    std::fs::write(dm.join("slaves").join("nvme0n1p2"), "").unwrap();
    part(&f.sys, "nvme0n1", "nvme0n1p2", "8:2");
    devlink(&f.sys, "253:0", "../../block/dm-0");
    let info = "28 1 253:0 / / rw - btrfs /dev/mapper/root rw\n".to_string();
    assert_eq!(disk_under(std::path::Path::new("/"), &info, &f.sys).as_deref(), Some("nvme0n1"), "the chain is source, dev/block, slaves, parent");
    let (exe, ui) = roots();
    let r = Roots { sys: &f.sys, dev: &f.dev, exe: &exe, ui: &ui };
    let got = list_drives(&r, &info, "Filename Type Size Used Priority\n", None, None);
    assert_eq!(got.len(), 1, "the stick survives while the crypt disk is excluded");
    assert_eq!(got[0].dev, "sda");
}

#[test]
fn a_disk_under_an_active_swap_partition_is_never_listed() {
    let f = fake("eligible-swap");
    system(&f.sys);
    stick(&f.sys);
    part(&f.sys, "sda", "sda2", "8:18");
    let (exe, ui) = roots();
    let r = Roots { sys: &f.sys, dev: &f.dev, exe: &exe, ui: &ui };
    let swaps = "Filename Type Size Used Priority\n/dev/sda2 partition 1 0 -2\n";
    let got = list_drives(&r, &root_mountinfo(), swaps, None, None);
    assert!(got.is_empty(), "the swap partition's disk is never a candidate");
}

#[test]
fn a_drive_with_holders_is_refused_as_a_member() {
    let f = fake("eligible-member");
    system(&f.sys);
    stick(&f.sys);
    std::fs::write(f.sys.join("block").join("sda").join("holders").join("md0"), "").unwrap();
    let got = drives(&f.sys, &f.dev, &root_mountinfo(), None);
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].refused, "member");
}

#[test]
fn a_card_reader_with_no_medium_is_listed_with_no_bytes() {
    let f = fake("eligible-empty");
    system(&f.sys);
    disk(&f.sys, "sdb", "1\n", "0\n", 0, "5\n", "/usb2/1-2");
    identity(&f.sys, "sdb", "Generic", "Card Reader", "");
    let got = drives(&f.sys, &f.dev, &root_mountinfo(), None);
    assert_eq!(got.len(), 1);
    assert_eq!((got[0].dev.as_str(), got[0].bytes), ("sdb", 0));
}

#[test]
fn loop_and_optical_devices_are_never_listed() {
    let _guard = LOOP_ENV_GUARD.lock().unwrap();
    std::env::remove_var("FLEA_FLASH_ALLOW_LOOP");
    let f = fake("eligible-never");
    system(&f.sys);
    disk(&f.sys, "loop0", "1\n", "0\n", 1_000_000, "6\n", "/pci/loop");
    disk(&f.sys, "sr0", "1\n", "0\n", 1_000_000, "7\n", "/usb/sr");
    let got = drives(&f.sys, &f.dev, &root_mountinfo(), None);
    assert!(got.is_empty(), "loop, zram, dm, md, nbd and sr are never candidates");
}

// With the feature off the seam does not exist: even a marked root with its backing file
// inside is refused, so a release build made without the feature never lists a loop device.
#[cfg(not(feature = "flash-test-seam"))]
#[test]
fn the_default_build_has_no_loop_seam() {
    let _guard = LOOP_ENV_GUARD.lock().unwrap();
    let f = fake("eligible-loopoff");
    system(&f.sys);
    let backing = f._dir.file("backing.img", "backing");
    disk(&f.sys, "loop0", "1\n", "0\n", 64_000_000, "6\n", "/pci/loop");
    identity(&f.sys, "loop0", "", "loop", "");
    let loopdir = f.sys.join("block").join("loop0").join("loop");
    std::fs::create_dir_all(&loopdir).unwrap();
    std::fs::write(loopdir.join("backing_file"), backing.to_string_lossy().to_string()).unwrap();
    std::env::set_var("FLEA_FLASH_ALLOW_LOOP", f._dir.path().to_string_lossy().to_string());
    let got = drives(&f.sys, &f.dev, &root_mountinfo(), None);
    std::env::remove_var("FLEA_FLASH_ALLOW_LOOP");
    assert!(got.is_empty(), "without the feature no loop device is ever listed");
}

// With the feature on the seam admits only a regular backing file strictly inside a marked root.
#[cfg(feature = "flash-test-seam")]
#[test]
fn the_seam_lists_a_loop_whose_backing_file_is_inside_its_marked_root() {
    let _guard = LOOP_ENV_GUARD.lock().unwrap();
    let f = fake("eligible-loop");
    system(&f.sys);
    let backing = f._dir.file("backing.img", "backing");
    disk(&f.sys, "loop0", "1\n", "0\n", 64_000_000, "6\n", "/pci/loop");
    identity(&f.sys, "loop0", "", "loop", "");
    let loopdir = f.sys.join("block").join("loop0").join("loop");
    std::fs::create_dir_all(&loopdir).unwrap();
    std::fs::write(loopdir.join("backing_file"), backing.to_string_lossy().to_string()).unwrap();
    std::env::set_var("FLEA_FLASH_ALLOW_LOOP", f._dir.path().to_string_lossy().to_string());
    let got = drives(&f.sys, &f.dev, &root_mountinfo(), None);
    std::env::remove_var("FLEA_FLASH_ALLOW_LOOP");
    assert_eq!(got.len(), 1, "the seam admits a loop backed inside its marked root");
    assert_eq!(got[0].dev, "loop0");
}

#[cfg(feature = "flash-test-seam")]
#[test]
fn the_seam_refuses_a_root_without_its_marker() {
    let _guard = LOOP_ENV_GUARD.lock().unwrap();
    let f = fake("eligible-loopnomark");
    system(&f.sys);
    let plain = f._dir.dir("plain");
    let backing = plain.join("backing.img");
    std::fs::write(&backing, "backing").unwrap();
    disk(&f.sys, "loop0", "1\n", "0\n", 64_000_000, "6\n", "/pci/loop");
    identity(&f.sys, "loop0", "", "loop", "");
    let loopdir = f.sys.join("block").join("loop0").join("loop");
    std::fs::create_dir_all(&loopdir).unwrap();
    std::fs::write(loopdir.join("backing_file"), backing.to_string_lossy().to_string()).unwrap();
    std::env::set_var("FLEA_FLASH_ALLOW_LOOP", plain.to_string_lossy().to_string());
    let got = drives(&f.sys, &f.dev, &root_mountinfo(), None);
    std::env::remove_var("FLEA_FLASH_ALLOW_LOOP");
    assert!(got.is_empty(), "a root without the sandbox marker admits nothing");
}

#[cfg(feature = "flash-test-seam")]
#[test]
fn the_seam_refuses_a_backing_file_outside_its_root() {
    let _guard = LOOP_ENV_GUARD.lock().unwrap();
    let f = fake("eligible-loopoutside");
    let elsewhere = TestDir::new("eligible-loopelsewhere");
    system(&f.sys);
    let backing = elsewhere.file("backing.img", "backing");
    disk(&f.sys, "loop0", "1\n", "0\n", 64_000_000, "6\n", "/pci/loop");
    identity(&f.sys, "loop0", "", "loop", "");
    let loopdir = f.sys.join("block").join("loop0").join("loop");
    std::fs::create_dir_all(&loopdir).unwrap();
    std::fs::write(loopdir.join("backing_file"), backing.to_string_lossy().to_string()).unwrap();
    std::env::set_var("FLEA_FLASH_ALLOW_LOOP", f._dir.path().to_string_lossy().to_string());
    let got = drives(&f.sys, &f.dev, &root_mountinfo(), None);
    std::env::remove_var("FLEA_FLASH_ALLOW_LOOP");
    assert!(got.is_empty(), "a backing file outside the named root is refused");
}

#[cfg(feature = "flash-test-seam")]
#[test]
fn the_seam_refuses_a_symlink_escaping_its_root() {
    let _guard = LOOP_ENV_GUARD.lock().unwrap();
    let f = fake("eligible-looplink");
    let elsewhere = TestDir::new("eligible-looplescape");
    system(&f.sys);
    let outside = elsewhere.file("backing.img", "backing");
    let link = f._dir.join("link.img");
    std::os::unix::fs::symlink(&outside, &link).unwrap();
    disk(&f.sys, "loop0", "1\n", "0\n", 64_000_000, "6\n", "/pci/loop");
    identity(&f.sys, "loop0", "", "loop", "");
    let loopdir = f.sys.join("block").join("loop0").join("loop");
    std::fs::create_dir_all(&loopdir).unwrap();
    std::fs::write(loopdir.join("backing_file"), link.to_string_lossy().to_string()).unwrap();
    std::env::set_var("FLEA_FLASH_ALLOW_LOOP", f._dir.path().to_string_lossy().to_string());
    let got = drives(&f.sys, &f.dev, &root_mountinfo(), None);
    std::env::remove_var("FLEA_FLASH_ALLOW_LOOP");
    assert!(got.is_empty(), "a symlink pointing outside the root is not a file inside it");
}

#[test]
fn a_drive_holding_the_image_is_refused() {
    let f = fake("eligible-holds");
    system(&f.sys);
    stick(&f.sys);
    let info = root_mountinfo() + "40 28 8:17 / /media/stick rw - vfat /dev/sda1 rw\n";
    let image = PathBuf::from("/media/stick/raspios.img");
    let (exe, ui) = roots();
    let r = Roots { sys: &f.sys, dev: &f.dev, exe: &exe, ui: &ui };
    let got = list_drives(&r, &info, "Filename Type Size Used Priority\n", Some(&image), None);
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].refused, "holdsimage");
}

#[test]
fn a_drive_smaller_than_the_image_is_refused() {
    let f = fake("eligible-small");
    system(&f.sys);
    stick(&f.sys);
    let got = drives(&f.sys, &f.dev, &root_mountinfo(), Some(999_000_000_000));
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].refused, "small");
}

#[test]
fn identity_is_changed_on_any_difference_and_quiet_when_equal() {
    let f = fake("eligible-identity");
    system(&f.sys);
    stick(&f.sys);
    let info = root_mountinfo();
    let (exe, ui) = roots();
    let r = Roots { sys: &f.sys, dev: &f.dev, exe: &exe, ui: &ui };
    assert!(!identity_changed(&r, &info, "Filename Type Size Used Priority\n", "sda", 2, "2003007157171692", 124_623_257_600));
    assert!(identity_changed(&r, &info, "Filename Type Size Used Priority\n", "sda", 3, "2003007157171692", 124_623_257_600), "a swapped stick has a new diskseq");
    assert!(identity_changed(&r, &info, "Filename Type Size Used Priority\n", "sda", 2, "other", 124_623_257_600), "a changed card has a new serial");
    assert!(identity_changed(&r, &info, "Filename Type Size Used Priority\n", "sda", 2, "2003007157171692", 1), "a resized drive differs");
    assert!(identity_changed(&r, &info, "Filename Type Size Used Priority\n", "sdb", 2, "2003007157171692", 124_623_257_600), "a gone drive differs");
}
