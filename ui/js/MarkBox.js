.pragma library

// The picker's mark box: the board's content box is bodySmall plus a hairline, inside a border two
// hairlines wide, and a Rectangle's size includes that border.
// Sample input: outer(13, 1) === 18.
function inner(bodySmall, hairline) { return bodySmall + hairline }
function border(hairline) { return 2 * hairline }
function outer(bodySmall, hairline) { return inner(bodySmall, hairline) + 2 * border(hairline) }
