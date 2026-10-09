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

fn run(chunks: &[&[u8]], poster: bool) -> (Vec<u8>, Handoff) {
    let mut handoff = Handoff { poster, drawing: false };
    let mut pending = Vec::new();
    let mut out = Vec::new();
    for chunk in chunks {
        pending.extend_from_slice(chunk);
        let (bytes, used) = pass(&pending, &mut handoff);
        pending.drain(..used);
        out.extend_from_slice(&bytes);
    }
    assert!(pending.is_empty(), "left over: {pending:?}");
    (out, handoff)
}
const START: &[u8] = b"\x1b[?25l\x1b[?1003h\x1b_Ga=d;\x1b\\\x1b[3;81f\x1b_Ga=T,f=24,s=800,v=450,C=1,q=2,m=1;AAAA\x1b\\\x1b_Gm=1;BBBB\x1b\\\x1b_Gm=0;CC==\x1b\\";

#[test]
fn the_poster_stays_until_mpv_has_sent_its_whole_first_frame() {
    let (out, handoff) = run(&[START], true);
    let expected: &[u8] = b"\x1b[3;81f\x1b_Ga=T,f=24,s=800,v=450,C=1,q=2,m=1;AAAA\x1b\\\x1b_Gm=1;BBBB\x1b\\\x1b_Gm=0;CC==\x1b\\\x1b_Ga=d,d=I,i=42,q=2\x1b\\";
    assert_eq!(out, expected, "{}", String::from_utf8_lossy(&out));
    assert!(!handoff.poster && !handoff.drawing);
}

#[test]
fn without_a_poster_mpv_clears_its_own_images_and_only_terminal_modes_are_held_back() {
    let (out, _) = run(&[START, b"\x1b_Ga=d;\x1b\\"], false);
    assert!(out.starts_with(b"\x1b_Ga=d;\x1b\\\x1b[3;81f"), "{}", String::from_utf8_lossy(&out));
    assert!(out.ends_with(b"\x1b_Gm=0;CC==\x1b\\\x1b_Ga=d;\x1b\\"));
    assert!(!out.windows(3).any(|w| w == b"\x1b[?"), "no mode change reaches the terminal");
}

#[test]
fn an_escape_split_across_reads_waits_for_its_end() {
    let whole = run(&[START], true).0;
    for cut in 1..START.len() {
        let (out, _) = run(&[&START[..cut], &START[cut..]], true);
        assert_eq!(out, whole, "cut at {cut}");
    }
}

#[test]
fn a_sixel_frame_and_an_osc_stay_whole_across_reads() {
    let units: [&[u8]; 4] = [b"\x1b[3;81f", b"\x1bPq#0;2;0;0;0#0~~-~~\x1b\\", b"\x1b]0;mpv\x07", b"\x1b_Gm=0;\x1b\\"];
    let stream = units.concat();
    let ends: Vec<usize> = units.iter().scan(0, |at, unit| { *at += unit.len(); Some(*at) }).collect();
    for cut in 1..stream.len() {
        let mut handoff = Handoff { poster: false, drawing: false };
        let (first, used) = pass(&stream[..cut], &mut handoff);
        let whole = ends.iter().copied().filter(|&end| end <= cut).max().unwrap_or(0);
        assert_eq!(used, whole, "cut {cut}: a read may only end on a whole escape");
        let (second, rest) = pass(&stream[used..], &mut handoff);
        assert_eq!(rest, stream.len() - used, "cut {cut}");
        assert_eq!([first, second].concat(), stream, "cut {cut}");
    }
}
