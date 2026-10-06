// Ruling 37 hold battery: no frame between a listed and its rows, capped like
// the GUI swap; rows and parent column land in one frame; the first screen
// joins the preview body. Same file both runs: the red run implements Hold
// with run-2 semantics (no peek/preview join, unbounded once painted, fixed
// 100 ms wait), so each assertion below names which shape it reddens on.
use super::hold::Hold;
use super::*;
use crate::jsondoc;
use crate::tui::model::Model;
use std::time::{Duration, Instant};
// The loop's paint decision through the hold under test.
fn paint_with(hold: &Hold, model: &Model, now: Instant, launched: Instant) -> bool {
    if hold.hold(model, now, launched) {
        return false;
    }
    let theme = theme::Theme::load();
    let map = keymap::Map::load();
    let mut frame = String::new();
    render::draw(model, &theme, &map, 80, 24, None, now.duration_since(launched), &mut frame).unwrap()
}
// A listing as the loop sees it: request observed, then listed drained.
// The model notes its own peek send; the hold reads it, never a copy.
fn listed_model(hold: &mut Hold, total: usize, launched: Instant) -> (Model, crate::tui::wire::Wire, std::thread::JoinHandle<()>) {
    let (mut wire, reader) = crate::tui::wire::echo_wire();
    let mut model = Model::new(PathBuf::from("/listing"), &jsondoc::Json::Null);
    model.open(PathBuf::from("/listing"), &mut wire).unwrap();
    hold.sync(&model, launched);
    model
        .receive(jsondoc::parse(&format!(r#"{{"t":"listed","n":{}}}"#, total)).unwrap(), &mut wire)
        .unwrap();
    (model, wire, reader)
}
fn rows_landed(model: &mut Model, wire: &mut crate::tui::wire::Wire) {
    model
        .receive(jsondoc::parse(r#"{"t":"rows","start":0,"rows":[{"n":"a.txt"}]}"#).unwrap(), wire)
        .unwrap();
}
// A listing at an explicit path: request, listed, model notes its peek.
fn path_listed(hold: &mut Hold, model: &mut Model, wire: &mut crate::tui::wire::Wire, path: &str, total: usize, at: Instant) {
    model.open(PathBuf::from(path), wire).unwrap();
    hold.sync(model, at);
    model
        .receive(jsondoc::parse(&format!(r#"{{"t":"listed","n":{}}}"#, total)).unwrap(), wire)
        .unwrap();
}
// A parent peek reply as the backend sends it; the model stores the rows.
fn peek_landed(model: &mut Model, wire: &mut crate::tui::wire::Wire, path: &str) {
    model
        .receive(jsondoc::parse(&format!(r#"{{"t":"peeked","path":"{}","rows":[{{"n":"p"}}]}}"#, path)).unwrap(), wire)
        .unwrap();
}
// A parent peek that fails still answers, so the hold ends on the reply
// instead of the cap. The backend always answers (peek.rs:24,39).
fn failed_peek_landed(model: &mut Model, wire: &mut crate::tui::wire::Wire, path: &str) {
    model
        .receive(jsondoc::parse(&format!(r#"{{"t":"peeked","path":"{}","n":0,"failed":true,"rows":[]}}"#, path)).unwrap(), wire)
        .unwrap();
}
// A pending listing older than the cap must draw; run 2 held it forever.
#[test]
fn capped_hold_draws_a_slow_listing() {
    let mut hold = Hold::new();
    hold.mark_painted();
    let launched = Instant::now();
    let (model, wire, reader) = listed_model(&mut hold, 5, launched);
    assert!(!paint_with(&hold, &model, launched + Duration::from_millis(100), launched));
    assert!(paint_with(&hold, &model, launched + Duration::from_millis(200), launched));
    crate::tui::wire::finish(wire, reader);
}
// A frame between rows and parents is drawn at run-2 shape, held after.
#[test]
fn rows_wait_for_the_parent_column() {
    let mut hold = Hold::new();
    hold.mark_painted();
    let launched = Instant::now();
    let (mut model, mut wire, reader) = listed_model(&mut hold, 5, launched);
    rows_landed(&mut model, &mut wire);
    assert!(!paint_with(&hold, &model, launched, launched));
    peek_landed(&mut model, &mut wire, "/");
    assert!(paint_with(&hold, &model, launched, launched));
    crate::tui::wire::finish(wire, reader);
}
// A frame between rows and the preview body is drawn at run-2 shape, held after.
#[test]
fn first_screen_waits_for_the_preview_body() {
    let mut hold = Hold::new();
    let launched = Instant::now();
    let (mut model, mut wire, reader) = listed_model(&mut hold, 5, launched);
    rows_landed(&mut model, &mut wire);
    model.preview = vec!["a.txt".into(), "text · 0 B".into(), "Loading…".into()];
    assert!(!paint_with(&hold, &model, launched, launched));
    model.preview = vec!["a.txt".into(), "text · 0 B".into(), String::new()];
    model.preview_body = String::new();
    peek_landed(&mut model, &mut wire, "/");
    assert!(paint_with(&hold, &model, launched, launched));
    crate::tui::wire::finish(wire, reader);
}
// A settled empty directory draws at once, never held.
#[test]
fn settled_empty_draws() {
    let mut hold = Hold::new();
    let launched = Instant::now();
    let (model, wire, reader) = listed_model(&mut hold, 0, launched);
    assert!(paint_with(&hold, &model, launched, launched));
    crate::tui::wire::finish(wire, reader);
}
// Rows with their peek and a settled preview draw under either shape.
#[test]
fn landed_all_draws() {
    let mut hold = Hold::new();
    hold.mark_painted();
    let launched = Instant::now();
    let (mut model, mut wire, reader) = listed_model(&mut hold, 5, launched);
    rows_landed(&mut model, &mut wire);
    peek_landed(&mut model, &mut wire, "/");
    assert!(paint_with(&hold, &model, launched, launched));
    crate::tui::wire::finish(wire, reader);
}
// A search in flight is not a listing and draws through.
#[test]
fn searching_draws_through() {
    let mut hold = Hold::new();
    hold.mark_painted();
    let launched = Instant::now();
    let (mut model, wire, reader) = listed_model(&mut hold, 5, launched);
    model.searching = true;
    assert!(paint_with(&hold, &model, launched, launched));
    crate::tui::wire::finish(wire, reader);
}
// The wait budget is the hold deadline, not the quantum; run 2 always waited 100.
#[test]
fn wait_budget_is_the_hold_deadline() {
    let mut hold = Hold::new();
    let launched = Instant::now();
    let (model, wire, reader) = listed_model(&mut hold, 5, launched);
    assert_eq!(hold.wait_ms(&model, launched + Duration::from_millis(110), launched), 40);
    crate::tui::wire::finish(wire, reader);
}
// The fallback lands on the deadline, not up to a quantum late.
#[test]
fn fallback_lands_on_the_deadline() {
    let (_stdin, _held) = crate::tui::wait::pair().unwrap();
    let (wake, _signaler) = crate::tui::wait::pair().unwrap();
    use std::os::unix::io::AsRawFd;
    let before = Instant::now();
    crate::tui::wait::wait_input_timeout(wake.as_raw_fd(), 40).unwrap();
    assert!(before.elapsed() < Duration::from_millis(90), "a 40 ms budget waited {:?}", before.elapsed());
}
// Launch at / paints when rows land: no parent exists, so no peek for this
// listing can ever be outstanding. Red on run 3 (held to the cap).
#[test]
fn root_launch_paints_with_rows() {
    let mut hold = Hold::new();
    let launched = Instant::now();
    let (mut echo, handle) = crate::tui::wire::echo_wire();
    let mut model = Model::new(PathBuf::from("/"), &jsondoc::Json::Null);
    path_listed(&mut hold, &mut model, &mut echo, "/", 3, launched);
    assert!(!model.peek_out());
    rows_landed(&mut model, &mut echo);
    assert!(paint_with(&hold, &model, launched, launched));
    crate::tui::wire::finish(echo, handle);
}
// A sibling step re-peeks the parent it sits under, so the rows wait for
// the new parent column and paint with it. Red on run 4 (no peek sent).
#[test]
fn sibling_step_repeeks_and_paints_on_it() {
    let mut hold = Hold::new();
    let launched = Instant::now();
    let (mut echo, handle) = crate::tui::wire::echo_wire();
    let mut model = Model::new(PathBuf::from("/a/b"), &jsondoc::Json::Null);
    path_listed(&mut hold, &mut model, &mut echo, "/a/b", 2, launched);
    rows_landed(&mut model, &mut echo);
    peek_landed(&mut model, &mut echo, "/a");
    path_listed(&mut hold, &mut model, &mut echo, "/a/c", 2, launched);
    assert!(model.peek_out());
    rows_landed(&mut model, &mut echo);
    assert!(!paint_with(&hold, &model, launched, launched));
    peek_landed(&mut model, &mut echo, "/a");
    assert!(!model.peek_out());
    assert!(paint_with(&hold, &model, launched, launched));
    crate::tui::wire::finish(echo, handle);
}
// A same-path relist re-peeks its parent, so the rows wait for the fresh
// parent column like any other listing. Red on run 4 (no peek sent).
#[test]
fn relist_repeeks_and_waits_for_it() {
    let mut hold = Hold::new();
    hold.mark_painted();
    let launched = Instant::now();
    let (mut echo, handle) = crate::tui::wire::echo_wire();
    let mut model = Model::new(PathBuf::from("/p"), &jsondoc::Json::Null);
    path_listed(&mut hold, &mut model, &mut echo, "/p", 2, launched);
    rows_landed(&mut model, &mut echo);
    peek_landed(&mut model, &mut echo, "/");
    path_listed(&mut hold, &mut model, &mut echo, "/p", 2, launched);
    assert!(model.peek_out());
    rows_landed(&mut model, &mut echo);
    assert!(!paint_with(&hold, &model, launched, launched));
    peek_landed(&mut model, &mut echo, "/");
    assert!(paint_with(&hold, &model, launched, launched));
    crate::tui::wire::finish(echo, handle);
}
// A hidden toggle and a sort relist re-peek: the rows must not keep a
// parent column fetched under the old setting. Red on run 4.
#[test]
fn hidden_toggle_and_sort_relist_repeek() {
    let mut hold = Hold::new();
    hold.mark_painted();
    let launched = Instant::now();
    let (mut echo, handle) = crate::tui::wire::echo_wire();
    let mut model = Model::new(PathBuf::from("/p"), &jsondoc::Json::Null);
    path_listed(&mut hold, &mut model, &mut echo, "/p", 2, launched);
    rows_landed(&mut model, &mut echo);
    peek_landed(&mut model, &mut echo, "/");
    model.hidden = true;
    path_listed(&mut hold, &mut model, &mut echo, "/p", 2, launched);
    assert!(model.peek_out());
    rows_landed(&mut model, &mut echo);
    assert!(!paint_with(&hold, &model, launched, launched));
    peek_landed(&mut model, &mut echo, "/");
    path_listed(&mut hold, &mut model, &mut echo, "/p", 2, launched);
    assert!(model.peek_out());
    rows_landed(&mut model, &mut echo);
    assert!(!paint_with(&hold, &model, launched, launched));
    peek_landed(&mut model, &mut echo, "/");
    assert!(paint_with(&hold, &model, launched, launched));
    crate::tui::wire::finish(echo, handle);
}
// A failed parent peek still answers, so the hold ends on the reply and
// never waits out the cap. Green on run 4 too: the backend always answers.
#[test]
fn failed_parent_peek_releases_the_hold() {
    let mut hold = Hold::new();
    hold.mark_painted();
    let launched = Instant::now();
    let (mut echo, handle) = crate::tui::wire::echo_wire();
    let mut model = Model::new(PathBuf::from("/p"), &jsondoc::Json::Null);
    path_listed(&mut hold, &mut model, &mut echo, "/p", 2, launched);
    assert!(model.peek_out());
    rows_landed(&mut model, &mut echo);
    assert!(!paint_with(&hold, &model, launched, launched));
    failed_peek_landed(&mut model, &mut echo, "/");
    assert!(!model.peek_out());
    assert!(paint_with(&hold, &model, launched, launched));
    crate::tui::wire::finish(echo, handle);
}
// A peeked that lands before its rows draws nothing: the rows map is
// still empty, so the hold stays until the rows land with it.
#[test]
fn peeked_before_rows_draws_nothing() {
    let mut hold = Hold::new();
    hold.mark_painted();
    let launched = Instant::now();
    let (mut echo, handle) = crate::tui::wire::echo_wire();
    let mut model = Model::new(PathBuf::from("/fx"), &jsondoc::Json::Null);
    path_listed(&mut hold, &mut model, &mut echo, "/fx/child", 4, launched);
    assert!(model.peek_out());
    peek_landed(&mut model, &mut echo, "/fx");
    assert!(model.rows.is_empty());
    assert!(!paint_with(&hold, &model, launched, launched));
    crate::tui::wire::finish(echo, handle);
}
// The wait budget never passes the hold deadline: across the hold window it
// is the deadline remainder, then the idle quantum. True on either shape.
#[test]
fn wait_budget_never_passes_the_deadline() {
    let mut hold = Hold::new();
    let launched = Instant::now();
    let (model, wire, reader) = listed_model(&mut hold, 5, launched);
    for ms in [0, 1, 50, 99, 100, 110, 149, 150, 151, 300] {
        let now = launched + Duration::from_millis(ms);
        let remain = 150 - ms as i32;
        let want = if remain > 0 { remain.min(100) } else { 100 };
        assert_eq!(hold.wait_ms(&model, now, launched), want, "at +{} ms", ms);
    }
    crate::tui::wire::finish(wire, reader);
}
