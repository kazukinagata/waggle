#!/usr/bin/env bash
# Update a Notion relation property via REST API.
#
# Usage: update-relations.sh <page_id> <property_name> <mode> [page_id_1] [page_id_2] ...
#
# Environment:
#   NOTION_TOKEN (required) — Notion internal integration token
#
# Arguments:
#   page_id        — Notion page UUID to update
#   property_name  — Relation property name (e.g., "Blocked By", "Parent Task")
#   mode           — "replace" (set exact list) or "append" (merge with existing, dedup)
#   page_id_N      — Zero or more page IDs for the relation
#                    (zero IDs with "replace" clears the relation)
#
# Output:
#   JSON response from Notion API on success
#
# Exit codes:
#   0  — success
#   1  — missing args, NOTION_TOKEN, or jq
#   2  — API error

set -euo pipefail

PAGE_ID="${1:?Usage: update-relations.sh <page_id> <property_name> <mode> [page_id_1] ...}"
PROPERTY_NAME="${2:?Usage: update-relations.sh <page_id> <property_name> <mode> [page_id_1] ...}"
MODE="${3:?Usage: update-relations.sh <page_id> <property_name> <mode> [page_id_1] ...}"
shift 3
RELATION_IDS=("$@")

if [ -z "${NOTION_TOKEN:-}" ]; then
  echo "Error: NOTION_TOKEN environment variable is not set." >&2
  echo "Set it in your shell profile or ~/.claude/settings.json env block." >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

if [[ "$MODE" != "replace" && "$MODE" != "append" ]]; then
  echo "Error: mode must be 'replace' or 'append', got '$MODE'" >&2
  exit 1
fi

API_VERSION="2022-06-28"
MAX_RETRIES=3

notion_api() {
  local method="$1" url="$2" body="${3:-}"
  local attempt=0 response http_code response_body retry_after

  while [ $attempt -lt $MAX_RETRIES ]; do
    if [ -n "$body" ]; then
      response=$(curl -s -w "\n%{http_code}" -X "$method" "$url" \
        -H "Authorization: Bearer ${NOTION_TOKEN}" \
        -H "Notion-Version: ${API_VERSION}" \
        -H "Content-Type: application/json" \
        -d "$body")
    else
      response=$(curl -s -w "\n%{http_code}" -X "$method" "$url" \
        -H "Authorization: Bearer ${NOTION_TOKEN}" \
        -H "Notion-Version: ${API_VERSION}")
    fi

    http_code=$(echo "$response" | tail -1)
    response_body=$(echo "$response" | sed '$d')

    if [ "$http_code" -eq 200 ]; then
      echo "$response_body"
      return 0
    elif [ "$http_code" -eq 429 ]; then
      retry_after=$(echo "$response_body" | jq -r '.retry_after // 1' 2>/dev/null || echo 1)
      echo "Rate limited. Retrying after ${retry_after}s..." >&2
      sleep "$retry_after"
      attempt=$((attempt + 1))
    elif [ "$http_code" -eq 500 ] && [ $attempt -lt $((MAX_RETRIES - 1)) ]; then
      local wait=$((1 << attempt))
      echo "Server error (500). Retrying after ${wait}s..." >&2
      sleep "$wait"
      attempt=$((attempt + 1))
    else
      echo "Error: Notion API returned HTTP ${http_code}" >&2
      echo "$response_body" | jq -r '.message // .code // .' >&2 2>/dev/null || echo "$response_body" >&2
      exit 2
    fi
  done

  echo "Error: Max retries exceeded" >&2
  exit 2
}

# Build the relation array from provided IDs
build_relation_array() {
  local ids=("$@")
  if [ ${#ids[@]} -eq 0 ]; then
    echo "[]"
    return
  fi
  printf '%s\n' "${ids[@]}" | jq -R '.' | jq -s '[.[] | {id: .}]'
}

# If append mode, fetch existing relation IDs and merge
if [ "$MODE" = "append" ]; then
  existing_json=$(notion_api GET "https://api.notion.com/v1/pages/${PAGE_ID}")
  existing_ids=$(echo "$existing_json" | jq -r --arg prop "$PROPERTY_NAME" \
    '[.properties[$prop].relation[]?.id] | .[]' 2>/dev/null || true)

  # Merge existing + new, dedup
  all_ids=()
  declare -A seen
  for id in $existing_ids; do
    if [ -z "${seen[$id]:-}" ]; then
      all_ids+=("$id")
      seen[$id]=1
    fi
  done
  for id in "${RELATION_IDS[@]}"; do
    if [ -z "${seen[$id]:-}" ]; then
      all_ids+=("$id")
      seen[$id]=1
    fi
  done
  RELATION_IDS=("${all_ids[@]}")
fi

relation_array=$(build_relation_array "${RELATION_IDS[@]}")

# Build PATCH body
patch_body=$(jq -n --arg prop "$PROPERTY_NAME" --argjson rel "$relation_array" \
  '{properties: {($prop): {relation: $rel}}}')

notion_api PATCH "https://api.notion.com/v1/pages/${PAGE_ID}" "$patch_body"
