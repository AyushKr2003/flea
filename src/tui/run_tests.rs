// Losing the TUI's one-arena call warns nowhere, so its place before the first thread is pinned here.
#[test]
fn the_tui_keeps_one_malloc_arena_from_before_its_first_thread() {
    let source = include_str!("mod.rs");
    let arena = source.find("crate::heap::one_arena();").expect("tui::run keeps one arena");
    let first_thread = source.find("wire::Wire::start()").expect("tui::run starts the backend wire");
    assert!(arena < first_thread, "the arena is fixed before the wire's reader thread starts");
}
