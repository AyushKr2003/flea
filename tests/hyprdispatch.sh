#!/usr/bin/env bash
# Typed-call lint and the compositor-free proofs of the dispatch and pointer glide helpers share this headless suite.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
failed=0
checks=3
python3 tests/hyprdispatch.py || failed=$((failed + 1))
python3 tests/hypr-dispatch-proof.py || failed=$((failed + 1))
bash tests/pointer-glide-proof.sh || failed=$((failed + 1))
printf 'hyprdispatch: %d checks passed, %d failed\n' "$((checks - failed))" "$failed"
[[ "$failed" == 0 ]]
