#!/usr/bin/env bash
# Rejects full MCP tool names (`mcp__<server>__<tool>`) for Notion query/write tools in
# skills, hooks and plugin guidance.
#
# The server part of a full tool name differs per environment: the Notion Desktop
# Extension, a remote MCP connector named by whoever runs it, or an opaque id such as a
# UUID in Cowork. A skill that names a tool by its full name works in one environment and
# silently picks nothing (or the wrong tool) in the others. Skills describe a tool by what
# it does or by its unqualified name (e.g. `notion-query`), and resolve a full name at run
# time from the session's tool list when one must be written down (e.g. a Cowork Live
# Artifact's `mcp_tools`).
#
# Allowed: the placeholder form `mcp__<server>__<tool>` (angle brackets), which explains
# the shape without naming a server. Out of scope: the Desktop Extension itself
# (providers/notion/extension/ — it defines the tools), its tests, eval fixtures
# (*/evals/ — they stand in for specific servers on purpose), CHANGELOGs and docs/
# (historical records).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2

pattern='mcp__[A-Za-z0-9_-]+__notion-'
hits=$(git ls-files -- '*.md' '*.sh' '*.js' '*.json' \
  | grep -v -E '^providers/notion/extension/|^providers/notion/tests/extension/|/evals/|CHANGELOG\.md$|^docs/' \
  | xargs -r grep -n -E "$pattern" 2>/dev/null || true)

if [ -n "$hits" ]; then
  echo "Full Notion tool names found (describe the tool by what it does or by its unqualified name):" >&2
  echo "$hits" >&2
  exit 1
fi
echo "ok: no full Notion tool names in skills, hooks or guidance"
