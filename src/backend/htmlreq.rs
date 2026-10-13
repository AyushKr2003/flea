use super::{archivework::Work, codereq, htmlcache, jail, opsreq::OpMsg, regfile, sandbox};
use crate::json::{escape, field_bool, field_str, field_usize};
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Stdio;
use std::sync::mpsc::Sender;
use std::time::{Duration, Instant};

const MAX_BYTES: u64 = 1_048_576;
const HELPER: &str = include_str!("htmlrender.qml");
const LIMIT: Duration = Duration::from_secs(15);

pub struct Ask {
    token: usize,
    slot: String,
    path: String,
    width: usize,
    cancel: bool,
}

impl Ask {
    // Sample input: {"c":"html","token":3,"slot":"look","path":"/home/gm/index.html","width":984}.
    pub fn parse(line: &str) -> Self {
        Self { token: field_usize(line, "token").unwrap_or(0), slot: field_str(line, "slot").unwrap_or_default(),
            path: field_str(line, "path").unwrap_or_default(), width: field_usize(line, "width").unwrap_or(984).clamp(1, 4096),
            cancel: field_bool(line, "cancel") }
    }
}

pub fn spawn(ask: Ask, tx: Sender<OpMsg>) {
    let ticket = codereq::begin(&format!("html:{}", ask.slot));
    std::thread::spawn(move || {
        let answer = if ask.cancel { Some(reply(&ask, "cancelled", "", 0, "")) }
            else { render(&ask, &ticket).or_else(|| (!ticket.superseded()).then(|| reply(&ask, "failed", "", 0, ""))) };
        if let Some(line) = answer { ticket.finish(line, &tx) }
    });
}

fn exclusive(path: &Path, bytes: &[u8]) -> Option<()> {
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path).ok()?;
    file.write_all(bytes).ok()
}

// The policy is installed before the page parses; runtime files and other URL schemes never become subresources.
fn confined_html(bytes: &[u8]) -> Vec<u8> {
    let policy = b"<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src file://*/page/ data:; style-src 'unsafe-inline' file://*/page/; font-src file://*/page/ data:; media-src file://*/page/; form-action 'none'; base-uri file://*/page/\"><base href=\"file:///page/\">";
    let head = bytes.iter().position(|b| !b.is_ascii_whitespace()).unwrap_or(0);
    let doctype = bytes.get(head..head + 9).is_some_and(|prefix| prefix.eq_ignore_ascii_case(b"<!doctype"));
    let at = if doctype { bytes[head..].iter().position(|b| *b == b'>').map_or(0, |end| head + end + 1) } else { 0 };
    let mut out = Vec::with_capacity(bytes.len() + policy.len());
    out.extend_from_slice(&bytes[..at]);
    out.extend_from_slice(policy);
    out.extend_from_slice(&bytes[at..]);
    out
}

fn render(ask: &Ask, ticket: &codereq::Ticket) -> Option<String> {
    if ticket.superseded() || !Path::new(&ask.path).is_absolute() || !sandbox::available() { return None }
    let path = Path::new(&ask.path).canonicalize().ok()?;
    let (file, meta) = regfile::open_if_regular_with_meta(&path, 0).ok()?;
    if meta.len() > MAX_BYTES { return None }
    let mut bytes = Vec::new();
    file.take(MAX_BYTES + 1).read_to_end(&mut bytes).ok()?;
    if bytes.len() as u64 > MAX_BYTES || bytes.contains(&0) { return None }
    let total = bytes.iter().filter(|&&b| b == b'\n').count() + usize::from(!bytes.is_empty() && !bytes.ends_with(b"\n"));
    let cache = htmlcache::root();
    let dest = cache.join(format!("{}.png", htmlcache::key(&path, &meta, ask.width)));
    if htmlcache::hit(&dest, ask.width) { return Some(reply(ask, "ready", &dest.to_string_lossy(), total, "")) }
    std::fs::create_dir_all(&cache).ok()?;
    let work = Work::new(&cache, "html").ok()?;
    std::fs::set_permissions(&work.dir, std::fs::Permissions::from_mode(0o700)).ok()?;
    exclusive(&work.dir.join("render.qml"), HELPER.as_bytes())?;
    exclusive(&work.dir.join("input.html"), &confined_html(&bytes))?;
    exclusive(&work.dir.join("page.png"), &[])?;
    if ticket.superseded() { return None }
    let inner = vec!["/usr/bin/qml6".to_string(), "/output/render.qml".to_string(), "--".to_string(), format!("--width={}", ask.width)];
    let mut argv = sandbox::wrap_html(&inner, path.parent()?, &work.dir);
    sandbox::add_status(&mut argv, inner.len());
    let mut jailed = jail::spawn_jailed(&argv, |cmd| {
        cmd.env_clear().env("PATH", std::env::var_os("PATH").unwrap_or_default());
        cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::piped());
    }).ok()?;
    let stderr = jailed.child.stderr.take();
    if !ticket.attach(jailed) { return None }
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        if let Some(pipe) = stderr { let _ = pipe.take(64 * 1024).read_to_end(&mut bytes); }
        bytes
    });
    if !ticket.reap_until(Some(Instant::now() + LIMIT))?.ok()?.success() { return None }
    let png = work.dir.join("page.png");
    if !htmlcache::hit(&png, ask.width) || ticket.superseded() { return None }
    let log = String::from_utf8_lossy(&reader.join().ok()?).into_owned();
    let title = log.lines().find_map(|line| line.split_once("HTML_META ").and_then(|(_, text)| field_str(text, "title"))).unwrap_or_default();
    std::fs::rename(&png, &dest).ok()?;
    htmlcache::evict(&cache);
    Some(reply(ask, "ready", &dest.to_string_lossy(), total, &title))
}

// Sample output: {"t":"html","slot":"look","token":3,"state":"ready","file":"/cache/x.png","total":61,"width":984,"title":"Page"}.
fn reply(ask: &Ask, state: &str, file: &str, total: usize, title: &str) -> String {
    format!(r#"{{"t":"html","slot":"{}","token":{},"state":"{}","file":"{}","total":{},"width":{},"title":"{}"}}"#,
        escape(&ask.slot), ask.token, state, escape(file), total, ask.width, escape(title))
}

#[cfg(test)]
#[path = "htmlreq_tests.rs"]
mod tests;
