#!/usr/bin/env bash
# Generate a standalone HTML file with embedded task data.
# Usage: generate-static-html.sh <view> <tasks-json>
#   view:         kanban | list | calendar | gantt
#   tasks-json:   Path to JSON file with { "tasks": [...], "updatedAt": "..." }
#
# Output: writes the standalone HTML to stdout.

set -euo pipefail

VIEW="${1:?Usage: generate-static-html.sh <view> <tasks-json>}"
TASKS_JSON="${2:?Usage: generate-static-html.sh <view> <tasks-json>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATIC_DIR="$SCRIPT_DIR/../server/static"

case "$VIEW" in
  kanban|list|calendar|gantt)
    TEMPLATE="$STATIC_DIR/${VIEW}.html"
    ;;
  custom:*)
    SLUG="${VIEW#custom:}"
    TEMPLATE="$HOME/.waggle/views/${SLUG}.html"
    ;;
  *)
    echo "Error: Unknown view '$VIEW'. Supported: kanban, list, calendar, gantt, custom:<slug>" >&2
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

# Read shared resources for inlining
SHARED_CSS=""
SHARED_JS=""
DETAIL_CSS=""
DETAIL_JS=""
FILTER_CSS=""
FILTER_JS=""

for f in shared.css shared.js detail-panel.css detail-panel.js filter-bar.css filter-bar.js; do
  if [ -f "$STATIC_DIR/$f" ]; then
    case "$f" in
      shared.css)       SHARED_CSS=$(cat "$STATIC_DIR/$f") ;;
      shared.js)        SHARED_JS=$(cat "$STATIC_DIR/$f") ;;
      detail-panel.css) DETAIL_CSS=$(cat "$STATIC_DIR/$f") ;;
      detail-panel.js)  DETAIL_JS=$(cat "$STATIC_DIR/$f") ;;
      filter-bar.css)   FILTER_CSS=$(cat "$STATIC_DIR/$f") ;;
      filter-bar.js)    FILTER_JS=$(cat "$STATIC_DIR/$f") ;;
    esac
  fi
done

# Build the injection script
INJECT="<script>window.__STATIC_DATA__ = ${TASKS_DATA};</script>"

# Process template: inject data, inline shared resources, neutralize back links
sed \
  -e "s|</head>|${INJECT}</head>|" \
  -e 's|href="/selector.html"|href="#"|g' \
  -e 's|href="selector.html"|href="#"|g' \
  "$TEMPLATE" \
| sed \
  -e "s|<link rel=\"stylesheet\" href=\"shared.css\">|<style>${SHARED_CSS//&/\\&}</style>|" \
  -e "s|<link rel=\"stylesheet\" href=\"filter-bar.css\">|<style>${FILTER_CSS//&/\\&}</style>|" \
  -e "s|<link rel=\"stylesheet\" href=\"detail-panel.css\">|<style>${DETAIL_CSS//&/\\&}</style>|" \
  -e "s|<script src=\"shared.js\"></script>|<script>${SHARED_JS//&/\\&}</script>|" \
  -e "s|<script src=\"filter-bar.js\"></script>|<script>${FILTER_JS//&/\\&}</script>|" \
  -e "s|<script src=\"detail-panel.js\"></script>|<script>${DETAIL_JS//&/\\&}</script>|"
