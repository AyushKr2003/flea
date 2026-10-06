use super::key::{collect_env, key_for, Roots};
use super::*;
use crate::backend::fifotest::{mkfifo, within};
use crate::backend::testdir::TestDir;
use std::cell::Cell;
use std::ffi::OsString;
// A fake sysfs and manifest tree, so no test reads the real ones.
struct Fake {
    _t: TestDir,
    boot: PathBuf,
    pci: PathBuf,
    drm: PathBuf,
    icd: PathBuf,
    layer: PathBuf,
    lib: PathBuf,
    exe: PathBuf,
}
fn fake(tag: &str) -> Fake {
    let t = TestDir::new(tag);
    let (pci, drm, icd, layer, lib) = (t.dir("pci"), t.dir("drm"), t.dir("icd"), t.dir("layer"), t.dir("lib"));
    let slot = pci.join("0000:00:02.0");
    std::fs::create_dir_all(&slot).unwrap();
    std::fs::write(slot.join("class"), "0x030000\n").unwrap();
    std::fs::write(slot.join("vendor"), "0x8086\n").unwrap();
    std::fs::write(slot.join("device"), "0xa788\n").unwrap();
    let card = drm.join("card0").join("device");
    std::fs::create_dir_all(&card).unwrap();
    std::fs::write(card.join("vendor"), "0x8086\n").unwrap();
    std::fs::write(card.join("device"), "0xa788\n").unwrap();
    std::fs::write(icd.join("intel_icd.json"), "{\"ICD\":{\"library_path\":\"libvulkan_intel.so\"}}\n").unwrap();
    std::fs::write(lib.join("libvulkan_intel.so"), "lib one\n").unwrap();
    std::fs::write(layer.join("VK_LAYER_MESA_overlay.json"), "{\"layer\":1}\n").unwrap();
    let boot = t.file("boot_id", "boot-one\n");
    let exe = t.file("flea", "exe one\n");
    Fake { _t: t, boot, pci, drm, icd, layer, lib, exe }
}
fn env_one() -> Vec<(String, String)> {
    vec![
        ("VK_ICD_FILENAMES".into(), "a.json".into()),
        ("XDG_DATA_HOME".into(), "/x".into()),
    ]
}
fn key_opt(f: &Fake, env_vars: &[(String, String)], surface: &str) -> Option<String> {
    let icd = vec![f.icd.clone()];
    let layer = vec![f.layer.clone()];
    let lib = vec![f.lib.clone()];
    key_for(&Roots { boot: &f.boot, pci: &f.pci, drm: &f.drm, icd_dirs: &icd, layer_dirs: &layer, lib_dirs: &lib, exe: &f.exe, env_vars, surface })
}
fn key_of(f: &Fake, env_vars: &[(String, String)], surface: &str) -> String {
    key_opt(f, env_vars, surface).expect("a whole inventory has a key")
}
#[test]
fn the_same_inputs_give_the_same_key() {
    let f = fake("vkkey-same");
    let env_vars = env_one();
    assert_eq!(key_of(&f, &env_vars, "VK_KHR_wayland_surface"), key_of(&f, &env_vars, "VK_KHR_wayland_surface"));
}
#[test]
fn an_inventory_that_cannot_be_had_whole_has_no_key() {
    let f = fake("vkkey-nokey");
    let env_vars = env_one();
    assert!(key_opt(&f, &env_vars, "VK_KHR_wayland_surface").is_some());
    for n in 0..256 {
        std::fs::write(f.icd.join(format!("filler{n}_icd.json")), "{}\n").unwrap();
    }
    assert_eq!(key_opt(&f, &env_vars, "VK_KHR_wayland_surface"), None, "257 manifests are not a driver set");
}
#[test]
fn a_boot_id_is_part_of_the_key() {
    let f = fake("vkkey-boot");
    let env_vars = env_one();
    let base = key_of(&f, &env_vars, "VK_KHR_wayland_surface");
    std::fs::write(&f.boot, "boot-two\n").unwrap();
    assert_ne!(key_of(&f, &env_vars, "VK_KHR_wayland_surface"), base);
}
#[test]
fn a_pci_vendor_is_part_of_the_key() {
    let f = fake("vkkey-pci");
    let env_vars = env_one();
    let base = key_of(&f, &env_vars, "VK_KHR_wayland_surface");
    std::fs::write(f.pci.join("0000:00:02.0").join("vendor"), "0x10de\n").unwrap();
    assert_ne!(key_of(&f, &env_vars, "VK_KHR_wayland_surface"), base);
}
#[test]
fn a_drm_card_added_changes_the_key() {
    let f = fake("vkkey-drm");
    let env_vars = env_one();
    let base = key_of(&f, &env_vars, "VK_KHR_wayland_surface");
    let card = f.drm.join("card1").join("device");
    std::fs::create_dir_all(&card).unwrap();
    std::fs::write(card.join("vendor"), "0x10de\n").unwrap();
    std::fs::write(card.join("device"), "0x27e0\n").unwrap();
    assert_ne!(key_of(&f, &env_vars, "VK_KHR_wayland_surface"), base);
}
#[test]
fn a_manifest_added_changes_the_key() {
    let f = fake("vkkey-manifest");
    let env_vars = env_one();
    let base = key_of(&f, &env_vars, "VK_KHR_wayland_surface");
    std::fs::write(f.icd.join("extra_icd.json"), "{\"ICD\":{\"library_path\":\"libvulkan_radeon.so\"}}\n").unwrap();
    assert_ne!(key_of(&f, &env_vars, "VK_KHR_wayland_surface"), base);
}
#[test]
fn a_manifest_mtime_is_part_of_the_key() {
    let f = fake("vkkey-mtime");
    let env_vars = env_one();
    let base = key_of(&f, &env_vars, "VK_KHR_wayland_surface");
    std::thread::sleep(std::time::Duration::from_millis(25));
    let body = std::fs::read(f.icd.join("intel_icd.json")).unwrap();
    std::fs::write(f.icd.join("intel_icd.json"), body).unwrap();
    assert_ne!(key_of(&f, &env_vars, "VK_KHR_wayland_surface"), base);
}
#[test]
fn a_manifest_library_replaced_changes_the_key() {
    let f = fake("vkkey-lib");
    let env_vars = env_one();
    let base = key_of(&f, &env_vars, "VK_KHR_wayland_surface");
    std::fs::write(f.lib.join("libvulkan_intel.so"), "lib two, longer\n").unwrap();
    assert_ne!(key_of(&f, &env_vars, "VK_KHR_wayland_surface"), base);
}
#[test]
fn an_implicit_layer_added_changes_the_key() {
    let f = fake("vkkey-layer");
    let env_vars = env_one();
    let base = key_of(&f, &env_vars, "VK_KHR_wayland_surface");
    std::fs::write(f.layer.join("extra_layer.json"), "{\"layer\":2}\n").unwrap();
    assert_ne!(key_of(&f, &env_vars, "VK_KHR_wayland_surface"), base);
}
fn fake_env(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
    collect_env(pairs.iter().map(|(k, v)| (OsString::from(k), OsString::from(v))))
}
#[test]
fn a_loader_or_device_order_variable_is_part_of_the_key() {
    let f = fake("vkkey-env");
    let base = key_of(&f, &fake_env(&[("XDG_DATA_HOME", "/x")]), "VK_KHR_wayland_surface");
    for name in ["VK_ICD_FILENAMES", "MESA_VK_DEVICE_SELECT", "DRI_PRIME"] {
        let env_vars = fake_env(&[("XDG_DATA_HOME", "/x"), (name, "1")]);
        assert_ne!(key_of(&f, &env_vars, "VK_KHR_wayland_surface"), base, "{name}");
    }
}
#[test]
fn the_surface_choice_is_part_of_the_key() {
    let f = fake("vkkey-surface");
    let env_vars = env_one();
    assert_ne!(key_of(&f, &env_vars, "VK_KHR_wayland_surface"), key_of(&f, &env_vars, "VK_KHR_xcb_surface"));
}
#[test]
fn the_binary_is_part_of_the_key() {
    let f = fake("vkkey-exe");
    let env_vars = env_one();
    let base = key_of(&f, &env_vars, "VK_KHR_wayland_surface");
    std::fs::write(&f.exe, "exe two, longer\n").unwrap();
    assert_ne!(key_of(&f, &env_vars, "VK_KHR_wayland_surface"), base);
}
#[test]
fn the_file_round_trips_the_devices() {
    let key = crate::figurecache::digest(b"k");
    let devices = vec![(0x8086, 0xa788, 1), (0x10de, 0x27e0, 2)];
    assert_eq!(parse(&render(&key, &devices), &key), Some(devices));
}
#[test]
fn bad_files_are_misses() {
    let key = crate::figurecache::digest(b"k");
    let good = render(&key, &[(0x8086, 0xa788, 1)]);
    assert_eq!(parse("", &key), None, "empty");
    assert_eq!(parse(&good.lines().take(2).collect::<Vec<_>>().join("\n"), &key), None, "truncated");
    assert_eq!(parse(&"x".repeat(MAX_FILE_BYTES as usize + 1), &key), None, "oversized");
    assert_eq!(parse(&good.replacen(VERSION, "flea-vulkan-probe 2", 1), &key), None, "wrong version");
    assert_eq!(parse(&good, "other"), None, "wrong key");
    assert_eq!(parse("flea-vulkan-probe 1\n{key}\nnot hex here\n".replace("{key}", &key).as_str(), &key), None, "garbled");
    let error = format!("{VERSION}\n{key}\nerror vkCreateInstance answered -9\n");
    assert_eq!(parse(&error, &key), None, "an error line");
}
#[test]
fn a_hit_returns_the_stored_result_without_calling_the_probe() {
    let t = TestDir::new("vkkey-hit");
    let path = t.join("vulkan-probe");
    let key = crate::figurecache::digest(b"hit");
    let stored = vec![(0x8086, 0xa788, 1)];
    write_cached(&path, &render(&key, &stored));
    let calls = Cell::new(0);
    let probe = || -> ProbeResult { calls.set(calls.get() + 1); Ok(vec![(1, 2, 3)]) };
    let answer = get(Some(key.as_str()), Some(&path), false, &probe);
    assert_eq!(answer, Ok(stored));
    assert_eq!(calls.get(), 0);
}
#[test]
fn a_miss_calls_once_and_writes_the_file() {
    let t = TestDir::new("vkkey-miss");
    let path = t.join("vulkan-probe");
    let key = crate::figurecache::digest(b"miss");
    let calls = Cell::new(0);
    let probe = || -> ProbeResult { calls.set(calls.get() + 1); Ok(vec![(0x8086, 0xa788, 1)]) };
    let answer = get(Some(key.as_str()), Some(&path), false, &probe);
    assert_eq!(calls.get(), 1);
    assert_eq!(read_cached(&path, &key), Some(vec![(0x8086, 0xa788, 1)]));
    assert_eq!(answer, Ok(vec![(0x8086, 0xa788, 1)]));
}
#[test]
fn off_calls_and_writes_nothing() {
    let t = TestDir::new("vkkey-off");
    let path = t.join("vulkan-probe");
    let key = crate::figurecache::digest(b"off");
    let calls = Cell::new(0);
    let probe = || -> ProbeResult { calls.set(calls.get() + 1); Ok(vec![(9, 9, 9)]) };
    let answer = get(Some(key.as_str()), Some(&path), true, &probe);
    assert_eq!(calls.get(), 1);
    assert_eq!(answer, Ok(vec![(9, 9, 9)]));
    assert!(!path.exists());
}
#[test]
fn a_fifo_at_the_cache_path_is_a_miss_that_never_blocks() {
    let t = TestDir::new("vkkey-fifo");
    let path = t.join("vulkan-probe");
    mkfifo(&path);
    let key = crate::figurecache::digest(b"fifo");
    let answer = within("a fifo at the cache path", move || read_cached(&path, &key));
    assert_eq!(answer, None);
}
#[test]
fn an_err_answer_is_probed_every_launch_and_never_written() {
    let t = TestDir::new("vkkey-err");
    let path = t.join("vulkan-probe");
    let key = crate::figurecache::digest(b"err");
    let calls = Cell::new(0);
    let probe = || -> ProbeResult { calls.set(calls.get() + 1); Err(String::from("no loader")) };
    let first = get(Some(key.as_str()), Some(&path), false, &probe);
    assert_eq!(first, Err(String::from("no loader")));
    assert!(!path.exists(), "an Err answer must write no file");
    let _ = get(Some(key.as_str()), Some(&path), false, &probe);
    assert_eq!(calls.get(), 2, "the next get must probe again");
}
#[test]
fn no_key_probes_and_writes_nothing() {
    let t = TestDir::new("vkkey-none");
    let path = t.join("vulkan-probe");
    let calls = Cell::new(0);
    let probe = || -> ProbeResult { calls.set(calls.get() + 1); Ok(vec![(0x8086, 0xa788, 1)]) };
    let answer = get(None, Some(&path), false, &probe);
    assert_eq!(answer, Ok(vec![(0x8086, 0xa788, 1)]));
    assert!(!path.exists(), "no key means no file");
    let _ = get(None, Some(&path), false, &probe);
    assert_eq!(calls.get(), 2, "no key probes every launch");
}
