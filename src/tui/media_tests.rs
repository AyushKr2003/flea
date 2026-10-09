use super::*;

fn resting() -> Player {
    Player::resting(Path::new("/nonexistent/clip.mp4"), Protocol::Kitty, (40, 30, 81, 3), (160, 50), (800, 600))
}

#[test]
fn a_resting_player_waits_for_the_probe_then_draws_the_controls_mpv_would() {
    let mut player = resting();
    assert!(player.at_rest());
    assert_eq!(player.line(60), "Loading media…");
    player.probe(10_000);
    let line = player.line(60);
    assert!(line.starts_with("[Play ]  ●"), "{line}");
    assert!(line.ends_with("0:00 / 0:10"), "{line}");
    player.probe(99_000);
    assert!(player.line(60).ends_with("0:00 / 0:10"), "a second probe never moves the length");
}

#[test]
fn a_seek_asked_at_rest_stays_inside_the_clip() {
    assert_eq!(rest_target(0.0, 10.0, -5), 0.0);
    assert_eq!(rest_target(8.0, 10.0, 5), 10.0);
    assert_eq!(rest_target(2.0, 0.0, 5), 7.0);
}

#[test]
fn play_at_rest_that_cannot_start_mpv_leaves_the_controls_as_they_were() {
    let mut player = resting();
    player.probe(10_000);
    assert!(player.toggle().is_err(), "the test file does not exist, so mpv never starts");
    assert!(player.at_rest() && player.paused && player.resume.is_none());
    assert!(player.line(60).starts_with("[Play ]"), "{}", player.line(60));
    assert!(player.seek(5).is_err() && player.position == 0.0);
}

#[test]
fn a_seek_or_toggle_before_mpv_connects_waits_in_resume() {
    let mut player = resting();
    player.probe(10_000);
    player.force_starting_for_test();
    player.toggle().unwrap();
    assert!(!player.paused && player.resume == Some((0.0, false)));
    player.seek(5).unwrap();
    assert_eq!(player.resume, Some((5.0, false)));
    player.toggle().unwrap();
    assert_eq!(player.resume, Some((5.0, true)));
    assert!(player.line(60).starts_with("[Play ]"), "{}", player.line(60));
}
