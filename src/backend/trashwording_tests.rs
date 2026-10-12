// The words the Trash browser and its deletion path show for the lines no fixture reaches, pinned by their source.
fn live(source: &'static str) -> &'static str {
    source.rsplit_once("\n#[cfg(test)]\n").map_or(source, |(code, _)| code)
}

#[test]
fn the_trash_browser_says_each_outcome_in_one_plain_sentence() {
    let browse = live(include_str!("trashbrowse.rs"));
    for retired in ["Could not run the Trash helper", "GIO Trash request", "gio failed", "GIO returned", "GIO did not report", "review a fresh confirmation",
                    "Trash selection has no reviewed", "Trash selection expired", "did not report stable item", "Trash backing identity"] {
        assert!(!browse.contains(retired), "retired wording came back: {}", retired);
    }
    for plain in ["The Trash could not be read.", "The Trash took too long to answer.", "The Trash changed; confirm again.",
                  "The Trash selection changed; select the items again.",
                  "Items in this Trash cannot be told apart, so they cannot be selected.",
                  "This Trash cannot be checked, so nothing can be deleted.", "This Trash cannot be checked, so nothing can be restored."] {
        assert!(browse.contains(plain), "plain wording is missing: {}", plain);
    }
}

#[test]
fn the_trash_deletion_path_says_folder_and_confirm_again() {
    let delete = live(include_str!("trashdelete.rs"));
    let recovery = live(include_str!("trashdelete/recovery.rs"));
    for retired in ["review a fresh confirmation", "Could not open Trash directory", "Trash original location changed"] {
        assert!(!delete.contains(retired), "retired wording came back: {}", retired);
    }
    for plain in ["Could not open the Trash folder {}: {}", "The Trash item changed; confirm again.", "The item's original folder changed; select it again."] {
        assert!(delete.contains(plain), "plain wording is missing: {}", plain);
    }
    for plain in ["Could not create the recovery folder {}: {}", "Could not read the recovery folder {}: {}"] {
        assert!(recovery.contains(plain), "plain wording is missing: {}", plain);
    }
    assert!(!recovery.contains("recovery directory {}"), "retired wording came back");
}
