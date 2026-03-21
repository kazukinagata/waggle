#!/usr/bin/env bash
# Query Notion database via REST API with server-side filtering.
#
# Usage: query-tasks.sh <database_id> [filter_json] [sort_json]
#
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Environment:
#   NOTION_TOKEN (required) — Notion internal integration token
#
# Arguments:
#   database_id  — Notion database UUID (with or without dashes)
#   filter_json  — (optional) Notion filter object as JSON string
#   sort_json    — (optional) Notion sorts array as JSON string
#
# Output:
#   JSON object: {"results": [...all pages across pagination...]}

set -euo pipefail

DATABASE_ID="${1:?Usage: query-tasks.sh <database_id> [filter_json] [sort_json]}"
FILTER_JSON="${2:-}"
SORT_JSON="${3:-}"

if [ -z "${NOTION_TOKEN:-}" ]; then
  echo "Error: NOTION_TOKEN environment variable is not set." >&2
  echo "Set it in your shell profile or ~/.claude/settings.json env block." >&2
  echo "See: https://www.notion.so/profile/integrations" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed." >&2
  echo "Install: sudo apt install jq (Linux) / brew install jq (macOS)" >&2
  exit 1
fi

API_URL="https://api.notion.com/v1/databases/${DATABASE_ID}/query"
API_VERSION="2022-06-28"

build_body() {
  local cursor="${1:-}"
  local body="{}"

  if [ -n "$FILTER_JSON" ]; then
    body=$(echo "$body" | jq --argjson f "$FILTER_JSON" '. + {filter: $f}')
  fi

  if [ -n "$SORT_JSON" ]; then
    body=$(echo "$body" | jq --argjson s "$SORT_JSON" '. + {sorts: $s}')
  fi

  if [ -n "$cursor" ]; then
    body=$(echo "$body" | jq --arg c "$cursor" '. + {start_cursor: $c}')
  fi

  echo "$body"
}

all_results="[]"
cursor=""
has_more=true

while [ "$has_more" = "true" ]; do
  body=$(build_body "$cursor")

  response=$(curl -s -w "\n%{http_code}" -X POST "$API_URL" \
    -H "Authorization: Bearer ${NOTION_TOKEN}" \
    -H "Notion-Version: ${API_VERSION}" \
    -H "Content-Type: application/json" \
    -d "$body")

  http_code=$(echo "$response" | tail -1)
  response_body=$(echo "$response" | sed '$d')

  if [ "$http_code" -ne 200 ]; then
    echo "Error: Notion API returned HTTP ${http_code}" >&2
    echo "$response_body" | jq -r '.message // .code // .' >&2 2>/dev/null || echo "$response_body" >&2
    exit 1
  fi

  page_results=$(echo "$response_body" | jq -c '.results')
  all_results=$(echo "$all_results" "$page_results" | jq -s '.[0] + .[1]')

  has_more=$(echo "$response_body" | jq -r '.has_more')
  cursor=$(echo "$response_body" | jq -r '.next_cursor // empty')
done

echo "$all_results" | jq '{results: .}'
