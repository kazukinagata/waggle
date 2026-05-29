#!/usr/bin/env bash
# driver.sh — run the inline PreToolUse hook command exactly as Claude Code would.
#
# Reads the `command` string out of hooks.json (the same field the runtime executes),
# then evals it with the fixture JSON on stdin. This exercises the real
# jq-decode -> bash -c parse path, so JSON-escape bugs in the inline script
# surface here instead of in production.
#
# Usage: driver.sh <fixture.json>
# Stdin of the hook is the fixture file; stdout/exit-code are passed through.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS_JSON="${HOOKS_JSON:-$HERE/../../hooks/hooks.json}"
FIXTURE="$1"

CMD=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$HOOKS_JSON")
eval "$CMD" < "$FIXTURE"
