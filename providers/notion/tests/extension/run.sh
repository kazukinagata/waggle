#!/usr/bin/env bash
# run.sh — unit tests for the notion-extension server's pure helpers
# (server/helpers.js: MIME detection, upload-input validation, image-block
# collection). Network-touching handlers in server/index.js are exercised
# manually against a real workspace — see the extension README.
#
# Exit 0 only if every case passes.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

if ! command -v node &>/dev/null; then
  echo "Error: node is required but not installed." >&2
  exit 1
fi

node "$HERE/test.mjs"
