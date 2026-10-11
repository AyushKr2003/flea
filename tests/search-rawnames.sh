#!/usr/bin/env bash
# Runs the search session tests for names that are not UTF-8: the walk, the patch and the tag filter keep each name's raw bytes.
set -euo pipefail
cd "$(dirname "$0")/.."
cargo test --locked -- --test-threads=1 backend::searchindex backend::searchwalk backend::searchsession backend::searchtags
