#!/usr/bin/env bash
# driver.sh — run the external PreToolUse guard script exactly as the hook does.
#
# hooks.json now delegates to hooks/check-task-write.sh via a thin wrapper, so the
# guard logic lives in a real file. This driver invokes that file directly with the
# fixture JSON on stdin — the same `bash <script>` path the wrapper takes once
# ${CLAUDE_PLUGIN_ROOT} resolves.
#
# Usage: driver.sh <fixture.json>
# Stdin of the hook is the fixture file; stdout/exit-code are passed through.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK_SCRIPT="${HOOK_SCRIPT:-$HERE/../../hooks/check-task-write.sh}"
FIXTURE="$1"

bash "$HOOK_SCRIPT" < "$FIXTURE"
