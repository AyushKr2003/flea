// Resolving a desktop id to the file gio launch needs, through the XDG data dirs.
use std::path::PathBuf;

// The dash to slash subdir spelling, beside the verbatim one; resolve tries them in this order.
pub(crate) fn spellings(id: &str) -> Vec<String> {
    let mut out = vec![format!("applications/{}", id)];
    if id.contains('-') {
        out.push(format!("applications/{}", id.replace('-', "/")));
    }
    out
}

// Sample id: "nvim.desktop" answers its applications/ file; "org-gnome-Nautilus.desktop" also tries the dash to slash subdir spelling, the way the data dirs themselves lay vendor files out.
pub fn resolve(id: &str) -> Option<PathBuf> {
    if id.is_empty() || id.contains('/') || id.contains('\0') {
        return None;
    }
    spellings(id).into_iter().filter_map(|s| crate::userfile::data_file(&s)).next()
}

// The text editor the desktop names for text/plain, or "" when it names none.
pub fn text_editor() -> String {
    let out = std::process::Command::new("xdg-mime")
        .arg("query")
        .arg("default")
        .arg("text/plain")
        .env("LC_ALL", "C")
        .output();
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => String::new(),
    }
}

// Sample line: "Default application for 'text/plain': nvim.desktop" names nvim.desktop; "No default applications for 'text/plain'", a translated line and an id without ".desktop" name none.
pub(crate) fn default_id(line: &str) -> &str {
    line.strip_prefix("Default application for ").and_then(|rest| rest.rsplit_once(':')).map(|(_, id)| id.trim()).filter(|id| id.ends_with(".desktop")).unwrap_or_default()
}

// Sample output: "Default application for 'text/plain': nvim.desktop\nRegistered applications:\n\tnvim.desktop"; only the first line can name the default.
pub fn handler_of(output: &str) -> String {
    let line = output.lines().next().unwrap_or_default().trim();
    default_id(line).to_string()
}

// Sample output: "Default application for 'x': a.desktop" runs gio, "No default ..." asks, and a failed lookup is claimed so a refused launch keeps its sentence.
pub fn default_handler_gio(mime: &str) -> String {
    let out = std::process::Command::new("gio")
        .arg("mime")
        .arg(mime)
        .env("LC_ALL", "C")
        .output();
    match out {
        Ok(o) if o.status.success() => handler_of(&String::from_utf8_lossy(&o.stdout)),
        _ => String::from("claimed"),
    }
}

// The type the Open with dialog reads (gio info, symlinks followed), so the card and the dialog never name two; None when gio cannot say.
fn content_type(path: &std::path::Path) -> Option<String> {
    crate::backend::menu_registry::content_type(&Default::default(), path, &Default::default()).ok()
}

// True when no application claims the file, which opens the approved Open with dialog instead of an error; a lookup that cannot be had answers claimed, so a refused launch keeps the sentence it has always had.
pub fn unclaimed(path: &std::path::Path) -> bool {
    content_type(path).is_some_and(|mime| default_handler_gio(&mime).is_empty())
}

// The desktop's default for the file's own type, as its id and its entry's own Name, which the AppImage card offers as its first button; None leaves the card the board draws.
pub fn handler(path: &std::path::Path) -> Option<(String, String)> {
    let id = default_handler_gio(&content_type(path)?);
    named_entry(&id).map(|(_, name)| (id, name))
}

// An installed entry's own launchable file and Name=, never a spelling of its id; None when either cannot be read.
pub fn named_entry(id: &str) -> Option<(PathBuf, String)> {
    let app = crate::backend::menu_registry::resolve(id, &Default::default()).ok()?;
    let name = crate::backend::menu_registry::desktop_label(&app.path).ok().flatten().filter(|n| !n.trim().is_empty())?;
    Some((app.path, name))
}

#[cfg(test)]
mod tests {
    use super::*;

    // The resolver never leaves the ladder, whatever the id holds.
    #[test]
    fn an_empty_relative_or_nul_id_resolves_to_nothing() {
        assert_eq!(resolve(""), None);
        assert_eq!(resolve("../skipped.desktop"), None);
        assert_eq!(resolve("a\0.desktop"), None);
    }

    // A missing id is None rather than a bare name, so no caller can hand gio one.
    #[test]
    fn a_missing_id_is_none_on_the_real_ladder() {
        assert_eq!(resolve("flea-definitely-not-installed-9f3c.desktop"), None);
    }

    // The spelling rule the resolver tries, verbatim first and the subdir form behind it.
    #[test]
    fn dashed_ids_try_the_subdir_spelling_behind_the_verbatim_one() {
        assert_eq!(spellings("nvim.desktop"), ["applications/nvim.desktop"]);
        assert_eq!(
            spellings("org-gnome-Nautilus.desktop"),
            ["applications/org-gnome-Nautilus.desktop", "applications/org/gnome/Nautilus.desktop"]
        );
    }

    #[test]
    fn the_handler_line_names_the_desktop_id_or_nothing() {
        assert_eq!(handler_of("Default application for 'text/plain': nvim.desktop"), "nvim.desktop");
        assert_eq!(handler_of("No default applications for 'text/plain'"), "");
        assert_eq!(handler_of("junk"), "");
        assert_eq!(handler_of(""), "");
    }

    // A multi-line gio answer names the first line's id, never the trailer that follows it.
    #[test]
    fn multiline_gio_output_names_only_the_first_line() {
        let set = "Default application for 'application/vnd.appimage': zzflea-appimage.desktop\nNo registered applications\nNo recommended applications";
        assert_eq!(handler_of(set), "zzflea-appimage.desktop");
        let unset = "No default applications for 'application/vnd.appimage'\nNo registered applications\nNo recommended applications";
        assert_eq!(handler_of(unset), "");
    }

    // An id gio prints without ".desktop" is no desktop id, so it names no handler.
    #[test]
    fn an_id_without_desktop_names_none() {
        assert_eq!(handler_of("Default application for 'x': foo"), "");
        assert_eq!(default_id("Default application for 'x': foo"), "");
    }

    #[test]
    fn translated_handler_lines_name_nothing() {
        assert_eq!(handler_of("Aplicaci\u{f3}n predeterminada para 'text/plain': nvim.desktop"), "");
        assert_eq!(handler_of("Standardanwendung f\u{fc}r 'text/plain': nvim.desktop"), "");
    }
}
