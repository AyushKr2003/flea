#!/usr/bin/env bash
# Runs the fence14 case's README reader against the pane's row on every fixture the case pins, and on fence shapes a README may grow, so both halves agree before a capture.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
. "$repo/tools/flea-sandbox-guard"
. "$repo/tests/ui-captures-markdown.sh"
command -v jq >/dev/null || { printf 'FAIL ui-captures-fences: jq is required\n'; exit 1; }
sandbox_root_ok
scratch=$(mktemp -d "$SANDBOX_ROOT/flea-capfences.XXXXXX") || exit 1
: > "$scratch/$SANDBOX_MARKER"
trap 'sandbox_remove "$scratch"' EXIT
checks=0
failed=0

# Sample input: fence-four.md fence:md fence:md passes; a reader row that differs from the pane's fails and names both.
check() {
    checks=$((checks + 1))
    if [[ "$2" == "$3" ]]; then
        printf 'ok   %s reads [%s]\n' "$1" "$2"
    else
        failed=$((failed + 1))
        printf 'FAIL %s: the reader gives [%s], the pane draws [%s]\n' "$1" "$2" "$3"
    fi
}

# The pane's row for each pinned fixture is its capmdfence14_want row, which the native case checks against the pane itself.
mkdir -p "$scratch/listing" "$scratch/shapes"
capmarkdownfences_fixture "$scratch/listing"
capmarkdownfences14_fixture "$scratch/listing"
for file in "$scratch"/listing/fence*.md; do
    name="${file##*/}"
    [[ "$name" != fence-readme.md ]] || continue
    if row="$(capmdfence14_want "$name")"; then
        check "$name" "$(capmdfence14_fences "$file")" "$(jq -Rr "$capmdfence14_tagged" <<< "$row")"
    else
        check "$name" "no pinned row" "a pinned row"
    fi
done

# Sample input: shape name, the document with \n escapes, the tagged fences ui/js/Markdown.js builds for it.
shape() {
    printf '%b' "$2" > "$scratch/shapes/$1.md"
    check "$1" "$(capmdfence14_fences "$scratch/shapes/$1.md")" "$3"
}
shape info-words '```sh title="x"\nls\n```\n' fence:sh
shape figures '```mermaid\ngraph TD\n```\n\n```math\nx^2\n```\n\n```sh\nls\n```\n' fence:sh
shape inline-ticks 'a\n\n```a`b\n\n```sh\nls\n```\n' fence:sh
shape quote '> ```js\n> x\n> ```\n' fence:js
shape nested-list '- a\n  - b\n\n    ```py\n    x\n    ```\n' fence:py
shape tilde-holds-ticks '~~~rust\n```\n~~~\n\n```toml\nk = 1\n```\n' fence:rust,fence:toml
shape longer-close '```sh\nx\n````\n\n```toml\nk = 1\n```\n' fence:sh,fence:toml
shape indented-block 'a\n\n    plain code\n\n```sh\nls\n```\n' fence:sh
printf 'ui-captures-fences: README reads [%s]\n' "$(capmdfence14_fences "$scratch/listing/fence-readme.md")"
printf 'ui-captures-fences: %s checks, %s failed\n' "$checks" "$failed"
(( failed == 0 ))
