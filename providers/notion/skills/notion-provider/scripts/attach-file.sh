#!/usr/bin/env bash
# Set or append files on a Notion files-type page property via REST API.
#
# Usage:
#   attach-file.sh <page_id> <property_name> <mode> [--file <path>]... [--url <name> <url>]...
#
# Environment:
#   NOTION_TOKEN (required) — Notion internal integration token
#                             (local-file uploads need the "Insert content" capability)
#
# Arguments:
#   page_id        — Notion page UUID to update
#   property_name  — files-type property name (e.g., "Attachments")
#   mode           — "replace" (set exact list) or "append" (merge with existing)
#   --file <path>  — local file, uploaded via the Notion File Upload API (repeatable, max 20MB each)
#   --url <name> <url>
#                  — external file entry, stored as-is (repeatable; Notion requires a name)
#
#   With "replace" and no --file/--url, the property is cleared.
#
# Output:
#   JSON: {"ok": true, "page_id": ..., "property": ..., "files": [{"url","name"}, ...]}
#
# Exit codes:
#   0  — success
#   1  — missing args, NOTION_TOKEN, jq, or unsupported/oversized file
#   2  — API error

set -euo pipefail

PAGE_ID="${1:?Usage: attach-file.sh <page_id> <property_name> <mode> [--file <path>]... [--url <name> <url>]...}"
PROPERTY_NAME="${2:?Usage: attach-file.sh <page_id> <property_name> <mode> [--file <path>]... [--url <name> <url>]...}"
MODE="${3:?Usage: attach-file.sh <page_id> <property_name> <mode> [--file <path>]... [--url <name> <url>]...}"
shift 3

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

# Parse repeatable --file / --url flags.
LOCAL_FILES=()
URL_NAMES=()
URL_URLS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      [ -n "${2:-}" ] || { echo "Error: --file needs a path." >&2; exit 1; }
      LOCAL_FILES+=("$2"); shift 2 ;;
    --url)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "Error: --url needs <name> <url>." >&2; exit 1; }
      URL_NAMES+=("$2"); URL_URLS+=("$3"); shift 3 ;;
    *)
      echo "Error: unexpected argument '$1'." >&2; exit 1 ;;
  esac
done

API_VERSION="2022-06-28"
MAX_RETRIES=3
MAX_UPLOAD_BYTES=$((20 * 1024 * 1024))

# Shared retry-aware API caller. Args: method url [json_body] [form_file] [form_mime]
# When form_file is set, sends multipart/form-data (File Upload send endpoint).
notion_api() {
  local method="$1" url="$2" body="${3:-}" form_file="${4:-}" form_mime="${5:-}"
  local attempt=0 response http_code response_body retry_after

  while [ $attempt -lt $MAX_RETRIES ]; do
    if [ -n "$form_file" ]; then
      response=$(curl -s -w "\n%{http_code}" -X "$method" "$url" \
        -H "Authorization: Bearer ${NOTION_TOKEN}" \
        -H "Notion-Version: ${API_VERSION}" \
        -F "file=@${form_file};type=${form_mime}")
    elif [ -n "$body" ]; then
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
      if [ "$http_code" -eq 403 ]; then
        echo "Hint: uploading files requires the integration's \"Insert content\" capability." >&2
        echo "Enable it at https://www.notion.so/profile/integrations (integration -> Capabilities)." >&2
      fi
      exit 2
    fi
  done

  echo "Error: Max retries exceeded" >&2
  exit 2
}

# Content type for the multipart upload send. Notion accepts arbitrary file types;
# unknown extensions fall back to application/octet-stream.
mime_from_extension() {
  case "${1,,}" in
    *.png) echo "image/png" ;;
    *.jpg | *.jpeg) echo "image/jpeg" ;;
    *.gif) echo "image/gif" ;;
    *.webp) echo "image/webp" ;;
    *.svg) echo "image/svg+xml" ;;
    *.bmp) echo "image/bmp" ;;
    *.tif | *.tiff) echo "image/tiff" ;;
    *.heic) echo "image/heic" ;;
    *.ico) echo "image/x-icon" ;;
    *.pdf) echo "application/pdf" ;;
    *.txt | *.log) echo "text/plain" ;;
    *.csv) echo "text/csv" ;;
    *.md) echo "text/markdown" ;;
    *.json) echo "application/json" ;;
    *.zip) echo "application/zip" ;;
    *.doc) echo "application/msword" ;;
    *.docx) echo "application/vnd.openxmlformats-officedocument.wordprocessingml.document" ;;
    *.xls) echo "application/vnd.ms-excel" ;;
    *.xlsx) echo "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" ;;
    *) echo "application/octet-stream" ;;
  esac
}

# Upload one local file through the Notion File Upload flow; echo its upload id.
upload_file() {
  local path="$1" filename mime size create_body upload_json upload_id upload_url
  if [ ! -f "$path" ]; then
    echo "Error: file not found: $path" >&2
    exit 1
  fi
  filename=$(basename "$path")
  mime=$(mime_from_extension "$filename")
  size=$(stat -c%s "$path" 2>/dev/null || stat -f%z "$path")
  if [ "$size" -gt "$MAX_UPLOAD_BYTES" ]; then
    echo "Error: file is ${size} bytes; the Notion single-part upload cap is ${MAX_UPLOAD_BYTES} bytes (20MB)." >&2
    exit 1
  fi

  create_body=$(jq -n --arg fn "$filename" '{mode: "single_part", filename: $fn}')
  upload_json=$(notion_api POST "https://api.notion.com/v1/file_uploads" "$create_body")
  upload_id=$(echo "$upload_json" | jq -r '.id // empty')
  upload_url=$(echo "$upload_json" | jq -r '.upload_url // empty')
  if [ -z "$upload_id" ] || [ -z "$upload_url" ]; then
    echo "Error: unexpected create-upload response (missing id/upload_url):" >&2
    echo "$upload_json" >&2
    exit 2
  fi
  notion_api POST "$upload_url" "" "$path" "$mime" > /dev/null
  echo "$upload_id"
}

# Build the array of new file entries in Notion's write shape.
new_entries="[]"

for path in "${LOCAL_FILES[@]:-}"; do
  [ -n "$path" ] || continue
  uid=$(upload_file "$path")
  entry=$(jq -n --arg id "$uid" --arg name "$(basename "$path")" \
    '{type: "file_upload", name: $name, file_upload: {id: $id}}')
  new_entries=$(echo "$new_entries" | jq --argjson e "$entry" '. + [$e]')
done

i=0
for name in "${URL_NAMES[@]:-}"; do
  [ -n "$name" ] || continue
  url="${URL_URLS[$i]}"
  entry=$(jq -n --arg name "$name" --arg url "$url" \
    '{type: "external", name: $name, external: {url: $url}}')
  new_entries=$(echo "$new_entries" | jq --argjson e "$entry" '. + [$e]')
  i=$((i + 1))
done

# Append mode: read existing entries and prepend them (normalized to write shape).
# Done immediately, so signed "file"-type URLs are still valid for the round-trip.
files_array="$new_entries"
if [ "$MODE" = "append" ]; then
  existing_json=$(notion_api GET "https://api.notion.com/v1/pages/${PAGE_ID}")
  existing=$(echo "$existing_json" | jq --arg prop "$PROPERTY_NAME" \
    '[.properties[$prop].files[]? | (
       if .type == "external" then {type: "external", name: .name, external: {url: .external.url}}
       elif .type == "file" then {type: "file", name: .name, file: {url: .file.url}}
       elif .type == "file_upload" then {type: "file_upload", name: .name, file_upload: {id: .file_upload.id}}
       else empty end)]')
  files_array=$(jq -n --argjson a "$existing" --argjson b "$new_entries" '$a + $b')
fi

patch_body=$(jq -n --arg prop "$PROPERTY_NAME" --argjson files "$files_array" \
  '{properties: {($prop): {files: $files}}}')

append_json=$(notion_api PATCH "https://api.notion.com/v1/pages/${PAGE_ID}" "$patch_body")

echo "$append_json" | jq --arg pid "$PAGE_ID" --arg prop "$PROPERTY_NAME" \
  '{ok: true, page_id: $pid, property: $prop,
    files: [.properties[$prop].files[]? | {
      url: (if .type == "file" then .file.url elif .type == "external" then .external.url else null end),
      name: .name}]}'
