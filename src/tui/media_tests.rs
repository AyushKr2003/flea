use super::*;

#[test]
fn a_graphics_driver_never_clears_the_screen_around_the_pane() {
    for (protocol, driver) in [(Protocol::Kitty, "kitty"), (Protocol::Sixel, "sixel")] {
        let args = arguments(protocol, Path::new("/tmp/flea-tui-x/ipc"), (40, 30, 81, 3), (160, 50), (800, 600));
        assert!(args.contains(&format!("--vo-{driver}-config-clear=no")), "{driver}: {args:?}");
        assert!(args.contains(&format!("--vo-{driver}-alt-screen=no")), "{driver}: {args:?}");
        assert!(args.contains(&format!("--vo-{driver}-left=81")) && args.contains(&format!("--vo-{driver}-top=3")));
        assert!(args.contains(&"--pause=yes".to_string()) && args.contains(&format!("--vo={driver}")));
    }
}

#[test]
fn a_terminal_without_graphics_gets_the_null_driver_and_no_pane_options() {
    let args = arguments(Protocol::None, Path::new("/tmp/flea-tui-x/ipc"), (40, 30, 81, 3), (160, 50), (0, 0));
    assert!(args.contains(&"--vo=null".to_string()));
    assert!(!args.iter().any(|arg| arg.starts_with("--vo-null-")), "{args:?}");
    assert!(args.contains(&"--input-ipc-server=/tmp/flea-tui-x/ipc".to_string()));
}
