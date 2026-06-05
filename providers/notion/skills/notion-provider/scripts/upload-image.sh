#!/usr/bin/env bash
# Upload an image to a Notion page body via REST API.
#
# Usage:
#   upload-image.sh <page_id> <file_path> [caption]
#   upload-image.sh <page_id> --url <external_url> [caption]
#
# Environment:
#   NOTION_TOKEN (required) — Notion internal integration token
#                             (needs the "Insert content" capability)
#
# Arguments:
#   page_id       — Notion page (or block) UUID to append the image to
#   file_path     — Local image file, uploaded via the Notion File Upload API
#                   (single-part, max 20MB)
#   --url <url>   — Publicly reachable image URL, embedded as an external
#                   image block (no upload)
#   caption       — (optional) Caption text for the image block
#
# Output:
#   JSON: {"ok": true, "page_id": ..., "block_id": ..., "image_type": "file_upload"|"external"}
#
# Exit codes:
#   0  — success
#   1  — missing args, NOTION_TOKEN, jq, or unsupported/oversized file
#   2  — API error

set -euo pipefail

PAGE_ID="${1:?Usage: upload-image.sh <page_id> <file_path|--url <external_url>> [caption]}"
SOURCE="${2:?Usage: upload-image.sh <page_id> <file_path|--url <external_url>> [caption]}"

EXTERNAL_URL=""
FILE_PATH=""
if [ "$SOURCE" = "--url" ]; then
  EXTERNAL_URL="${3:?Usage: upload-image.sh <page_id> --url <external_url> [caption]}"
  CAPTION="${4:-}"
else
  FILE_PATH="$SOURCE"
  CAPTION="${3:-}"
fi

if [ -z "${NOTION_TOKEN:-}" ]; then
  echo "Error: NOTION_TOKEN environment variable is not set." >&2
  echo "Set it in your shell profile or ~/.claude/settings.json env block." >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

API_VERSION="2022-06-28"
MAX_RETRIES=3
MAX_UPLOAD_BYTES=$((20 * 1024 * 1024))

# Shared retry-aware API caller. Args: method url [json_body] [form_file] [form_mime]
# When form_file is set, sends multipart/form-data (File Upload send endpoint)
# instead of a JSON body.
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
        echo "Hint: appending body blocks requires the integration's \"Insert content\" capability." >&2
        echo "Enable it at https://www.notion.so/profile/integrations (integration -> Capabilities)." >&2
      fi
      exit 2
    fi
  done

  echo "Error: Max retries exceeded" >&2
  exit 2
}

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
    *) echo "" ;;
  esac
}

# Build the image object, then append it as a child block of the page.
if [ -n "$CAPTION" ]; then
  caption_array=$(jq -n --arg c "$CAPTION" '[{type: "text", text: {content: $c}}]')
else
  caption_array="[]"
fi

if [ -n "$EXTERNAL_URL" ]; then
  IMAGE_TYPE="external"
  image_object=$(jq -n --arg url "$EXTERNAL_URL" --argjson cap "$caption_array" \
    '{type: "external", external: {url: $url}, caption: $cap}')
else
  if [ ! -f "$FILE_PATH" ]; then
    echo "Error: file not found: $FILE_PATH" >&2
    exit 1
  fi

  FILENAME=$(basename "$FILE_PATH")
  MIME_TYPE=$(mime_from_extension "$FILENAME")
  if [ -z "$MIME_TYPE" ]; then
    echo "Error: unsupported image extension in \"$FILENAME\"." >&2
    echo "Supported: png, jpg, jpeg, gif, webp, svg, bmp, tif, tiff, heic, ico." >&2
    exit 1
  fi

  FILE_SIZE=$(stat -c%s "$FILE_PATH" 2>/dev/null || stat -f%z "$FILE_PATH")
  if [ "$FILE_SIZE" -gt "$MAX_UPLOAD_BYTES" ]; then
    echo "Error: file is ${FILE_SIZE} bytes; the Notion single-part upload cap is ${MAX_UPLOAD_BYTES} bytes (20MB)." >&2
    exit 1
  fi

  # Notion File Upload flow: create the upload object, send the bytes
  # (multipart), then attach within 1 hour as an image block.
  create_body=$(jq -n --arg fn "$FILENAME" '{mode: "single_part", filename: $fn}')
  upload_json=$(notion_api POST "https://api.notion.com/v1/file_uploads" "$create_body")
  UPLOAD_ID=$(echo "$upload_json" | jq -r '.id')
  UPLOAD_URL=$(echo "$upload_json" | jq -r '.upload_url')

  notion_api POST "$UPLOAD_URL" "" "$FILE_PATH" "$MIME_TYPE" > /dev/null

  IMAGE_TYPE="file_upload"
  image_object=$(jq -n --arg id "$UPLOAD_ID" --argjson cap "$caption_array" \
    '{type: "file_upload", file_upload: {id: $id}, caption: $cap}')
fi

append_body=$(jq -n --argjson img "$image_object" \
  '{children: [{type: "image", image: $img}]}')
append_json=$(notion_api PATCH "https://api.notion.com/v1/blocks/${PAGE_ID}/children" "$append_body")

echo "$append_json" | jq --arg pid "$PAGE_ID" --arg t "$IMAGE_TYPE" \
  '{ok: true, page_id: $pid, block_id: .results[0].id, image_type: $t}'
