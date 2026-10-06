use super::*;
use crate::backend::testdir::TestDir;
// A fake sysfs and manifest tree, so no test reads the real ones.
struct Fake {
    t: TestDir,
    boot: PathBuf,
    pci: PathBuf,
    drm: PathBuf,
    icd: PathBuf,
    layer: PathBuf,
    lib: PathBuf,
    exe: PathBuf,
    settings: PathBuf,
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
    let settings = t.join("vk_loader_settings.json");
    Fake { t, boot, pci, drm, icd, layer, lib, exe, settings }
}
fn env_one() -> Vec<(String, String)> {
    vec![
        ("VK_ICD_FILENAMES".into(), "a.json".into()),
        ("XDG_DATA_HOME".into(), "/x".into()),
    ]
}
fn key_with_libs(f: &Fake, env_vars: &[(String, String)], surface: &str, libs: &[PathBuf]) -> Option<String> {
    let icd = vec![f.icd.clone()];
    let layer = vec![f.layer.clone()];
    let settings = vec![f.settings.clone()];
    key_for(&Roots {
        boot: &f.boot,
        pci: &f.pci,
        drm: &f.drm,
        icd_dirs: &icd,
        layer_dirs: &layer,
        lib_dirs: libs,
        settings_files: &settings,
        exe: &f.exe,
        env_vars,
        surface,
    })
}
fn key_opt(f: &Fake, env_vars: &[(String, String)], surface: &str) -> Option<String> {
    key_with_libs(f, env_vars, surface, std::slice::from_ref(&f.lib))
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
// The loader reads a library_path with a slash relative to the manifest's own directory, not through the search path.
#[test]
fn a_manifest_relative_library_replaced_changes_the_key() {
    let f = fake("vkkey-rel");
    let env_vars = env_one();
    std::fs::write(f.icd.join("rel_icd.json"), "{\"ICD\":{\"library_path\":\"../lib/x.so\"}}\n").unwrap();
    std::fs::write(f.lib.join("x.so"), "lib one\n").unwrap();
    let base = key_with_libs(&f, &env_vars, "VK_KHR_wayland_surface", &[]);
    std::fs::write(f.lib.join("x.so"), "lib two, longer\n").unwrap();
    assert_ne!(key_with_libs(&f, &env_vars, "VK_KHR_wayland_surface", &[]), base);
}
// The dynamic loader searches LD_LIBRARY_PATH before the system dirs, so a libvulkan.so.1 there is the one loaded.
#[test]
fn a_libvulkan_in_an_ld_library_path_dir_replaced_changes_the_key() {
    let f = fake("vkkey-ld");
    let env_vars = env_one();
    let ld = f.t.dir("ld");
    let dirs = lib_search_dirs(Some(ld.clone().into_os_string()), std::slice::from_ref(&f.lib));
    std::fs::write(ld.join("libvulkan.so.1"), "loader one\n").unwrap();
    let base = key_with_libs(&f, &env_vars, "VK_KHR_wayland_surface", &dirs);
    std::fs::write(ld.join("libvulkan.so.1"), "loader two, longer\n").unwrap();
    assert_ne!(key_with_libs(&f, &env_vars, "VK_KHR_wayland_surface", &dirs), base);
}
// Sample input: LD_LIBRARY_PATH="/a::/b" with system dirs [/usr/lib] gives /a, /b, /usr/lib.
#[test]
fn the_search_order_is_ld_library_path_then_the_system_dirs_with_empties_dropped() {
    let dirs = lib_search_dirs(Some(OsString::from("/a::/b")), &[PathBuf::from("/usr/lib")]);
    assert_eq!(dirs, vec![PathBuf::from("/a"), PathBuf::from("/b"), PathBuf::from("/usr/lib")]);
}
// The loader reads vk_loader_settings.json from every root, so adding one changes what the probe sees.
#[test]
fn a_loader_settings_file_added_changes_the_key() {
    let f = fake("vkkey-settings");
    let env_vars = env_one();
    let base = key_of(&f, &env_vars, "VK_KHR_wayland_surface");
    std::fs::write(&f.settings, "{}\n").unwrap();
    assert_ne!(key_of(&f, &env_vars, "VK_KHR_wayland_surface"), base);
}
