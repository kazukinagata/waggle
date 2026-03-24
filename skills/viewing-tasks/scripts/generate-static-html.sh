#!/usr/bin/env bash
# Generate a standalone HTML file with embedded task data.
# Usage: generate-static-html.sh <view> <tasks-json>
#   view:         kanban | list
#   tasks-json:   Path to JSON file with { "tasks": [...], "updatedAt": "..." }
#
# Output: writes the standalone HTML to stdout.

set -euo pipefail

VIEW="${1:?Usage: generate-static-html.sh <view> <tasks-json>}"
TASKS_JSON="${2:?Usage: generate-static-html.sh <view> <tasks-json>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATIC_DIR="$SCRIPT_DIR/../server/static"

case "$VIEW" in
  kanban|list)
    TEMPLATE="$STATIC_DIR/${VIEW}.html"
    ;;
  custom:*)
    SLUG="${VIEW#custom:}"
    TEMPLATE="$HOME/.waggle/views/${SLUG}.html"
    ;;
  *)
    echo "Error: Unknown view '$VIEW'. Supported: kanban, list, custom:<slug>" >&2
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
INJECT="<script>window.__STATIC_DATA__ = ${TASKS_DATA};</script>"

# Inject before the closing </head> tag and neutralize back links to selector
sed \
  -e "s|</head>|${INJECT}</head>|" \
  -e 's|href="/selector.html"|href="#"|g' \
  -e 's|href="selector.html"|href="#"|g' \
  "$TEMPLATE"
