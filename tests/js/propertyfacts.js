.import "../../ui/js/PropertyFacts.js" as PropertyFacts

function run(check) {
    // Every string below is the board's own (Properties040, "Folder, counting" and "Folder, done"), value then muted tail.
    function drawn(line) { return line.value + line.tail }
    var counting = {bytes: 2104332800, items: 812, partial: false, done: false}
    check("Size while counting is the floor with the tail", drawn(PropertyFacts.size(0, counting)), "> 2.1 GB (2104332800 bytes) · counting…")
    check("Contains while counting is the floor with the tail", drawn(PropertyFacts.contains(counting)), "> 812 items · counting…")
    check("the tail is its own run, so it can wear the muted colour", PropertyFacts.size(0, counting).tail, " · counting…")
    var done = {bytes: 7404118016, items: 1204, partial: false, done: true}
    check("Size done is exact with no prefix and no tail", drawn(PropertyFacts.size(0, done)), "7.4 GB (7404118016 bytes)")
    check("Contains done is grouped", drawn(PropertyFacts.contains(done)), "1,204 items")

    // The first frame: the folder's own entry, nothing counted below it yet.
    var first = PropertyFacts.begin({bytes: 4096})
    check("the first frame counts the entry's own size", drawn(PropertyFacts.size(4096, first)), "> 4.1 kB (4096 bytes) · counting…")
    check("and nothing below it", drawn(PropertyFacts.contains(first)), "> 0 items · counting…")
    check("one entry reads item, not items", drawn(PropertyFacts.contains({bytes: 4096, items: 1, partial: false, done: true})), "1 item")
    check("one entry while counting is still a floor", drawn(PropertyFacts.contains({bytes: 4096, items: 1, partial: false, done: false})), "> 1 item · counting…")
    check("an empty folder done reads 0 items", drawn(PropertyFacts.contains({bytes: 4096, items: 0, partial: false, done: true})), "0 items")

    // A walk that met a directory it could not read ends partial: still a floor, with no counting tail.
    var cut = {bytes: 5000, items: 3, partial: true, done: true}
    check("a partial done Size stays a floor", drawn(PropertyFacts.size(0, cut)), "> 5.0 kB (5000 bytes)")
    check("a partial done Contains stays a floor", drawn(PropertyFacts.contains(cut)), "> 3 items")
    check("a partial done floor has no tail", PropertyFacts.size(0, cut).tail + PropertyFacts.contains(cut).tail, "")

    // A file has no walk: Size is its own, Contains does not exist.
    check("a file's Size is unchanged", drawn(PropertyFacts.size(13, null)), "13 B (13 bytes)")
    check("a file's Size has no tail", PropertyFacts.size(13, null).tail, "")
    check("a file has no Contains", PropertyFacts.contains(null), null)

    // Replies fold into the walk the card holds.
    var progress = PropertyFacts.next(first, {ok: true, bytes: 9000, items: 5, partial: false, done: false})
    check("a progress reply moves both numbers and keeps counting", JSON.stringify(progress), JSON.stringify({bytes: 9000, items: 5, partial: false, done: false}))
    var last = PropertyFacts.next(progress, {ok: true, bytes: 9500, items: 6, partial: false, done: true})
    check("the final reply ends the count", last.done, true)
    check("a cancelled walk settles as the floor already counted", JSON.stringify(PropertyFacts.next(progress, {ok: true, cancelled: true, bytes: 1, items: 1, partial: false, done: false})), JSON.stringify({bytes: 9000, items: 5, partial: true, done: true}))
    check("a cancelled reply after done changes nothing", PropertyFacts.next(last, {ok: true, cancelled: true, bytes: 1, items: 1, partial: false, done: false}), last)
    var refused = PropertyFacts.next(progress, {ok: false, error: "Menu selection expired; reopen the menu."})
    check("a refused request ends as the floor already counted", JSON.stringify(refused), JSON.stringify({bytes: 9000, items: 5, partial: true, done: true}))

    // The value is plain text with a coloured tail, so the markup carries only the tail's colour.
    check("the counting form wears the tail in the given colour",
          PropertyFacts.styled(PropertyFacts.size(0, counting), "#565f89"),
          "&gt; 2.1 GB (2104332800 bytes)<font color=\"#565f89\"> · counting…</font>")
    check("the done form carries no markup beyond escaping", PropertyFacts.styled(PropertyFacts.contains(done), "#565f89"), "1,204 items")
    check("a markup character in a value is escaped", PropertyFacts.styled({value: "a<b&c", tail: ""}, "#565f89"), "a&lt;b&amp;c")
}
