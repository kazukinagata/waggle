#!/usr/bin/env bash
# Generate a standalone HTML file with embedded task data.
# Usage: generate-static-html.sh <view> <tasks-json> [sprint-json]
#   view:         kanban | list | sprint-backlog | product-backlog
#   tasks-json:   Path to JSON file with { "tasks": [...], "updatedAt": "..." }
#   sprint-json:  (optional, for sprint-backlog) Path to JSON file with { "sprints": [...] }
#
# Output: writes the standalone HTML to stdout.

set -euo pipefail

VIEW="${1:?Usage: generate-static-html.sh <view> <tasks-json> [sprint-json]}"
TASKS_JSON="${2:?Usage: generate-static-html.sh <view> <tasks-json> [sprint-json]}"
SPRINT_JSON="${3:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATIC_DIR="$SCRIPT_DIR/../server/static"

case "$VIEW" in
  kanban|list|sprint-backlog|product-backlog)
    TEMPLATE="$STATIC_DIR/${VIEW}.html"
    ;;
  custom:*)
    SLUG="${VIEW#custom:}"
    TEMPLATE="$HOME/.agentic-tasks/views/${SLUG}.html"
    ;;
  *)
    echo "Error: Unknown view '$VIEW'. Supported: kanban, list, sprint-backlog, product-backlog, custom:<slug>" >&2
    exit 1
    ;;
esac

if [ ! -f "$TEMPLATE" ]; then
  echo "Error: Template not found: $TEMPLATE" >&2
  exit 1
fi

if [ ! -f "$TASKS_JSON" ]; then
  echo "Error: Tasks JSON file not found: $TASKS_JSON" >&2
  exit 1
fi

TASKS_DATA=$(cat "$TASKS_JSON")

# Build the injection script
INJECT="<script>window.__STATIC_DATA__ = ${TASKS_DATA};"
if [ -n "$SPRINT_JSON" ] && [ -f "$SPRINT_JSON" ]; then
  SPRINT_DATA=$(cat "$SPRINT_JSON")
  INJECT="${INJECT} window.__STATIC_SPRINT_DATA__ = ${SPRINT_DATA};"
fi
INJECT="${INJECT}</script>"

# Inject before the closing </head> tag and neutralize back links to selector
sed \
  -e "s|</head>|${INJECT}</head>|" \
  -e 's|href="/selector.html"|href="#"|g' \
  -e 's|href="selector.html"|href="#"|g' \
  "$TEMPLATE"
