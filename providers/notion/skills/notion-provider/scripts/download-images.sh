#!/usr/bin/env bash
# Download all images from a Notion page body to local files.
#
# Usage: download-images.sh <page_id> [output_dir]
#
# Environment:
#   NOTION_TOKEN (required) — Notion internal integration token
#
# Arguments:
#   page_id     — Notion page (or block) UUID to read images from
#   output_dir  — (optional) Directory to save images into
#                 (default: ${TMPDIR:-/tmp}/notion-images/<page_id>)
#
# Behavior:
#   Walks the page's block tree (recursing into toggles/columns/callouts up
#   to depth 3; never into child pages/databases), downloads every image
#   block to <output_dir>/<block_id>.<ext>, and prints a JSON manifest.
#   Notion "file"-type image URLs are signed and expire after ~1 hour, so
#   images are downloaded immediately rather than returning URLs.
#
# Output:
#   JSON: {"images": [{"block_id", "path", "mime_type", "source_type", "caption"}, ...]}
#
# Exit codes:
#   0  — success
#   1  — missing args, NOTION_TOKEN, or jq
#   2  — API error

set -euo pipefail

PAGE_ID="${1:?Usage: download-images.sh <page_id> [output_dir]}"
OUTPUT_DIR="${2:-${TMPDIR:-/tmp}/notion-images/${PAGE_ID}}"

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
MAX_DEPTH=3

notion_api() {
  local method="$1" url="$2"
  local attempt=0 response http_code response_body retry_after

  while [ $attempt -lt $MAX_RETRIES ]; do
    response=$(curl -s -w "\n%{http_code}" -X "$method" "$url" \
      -H "Authorization: Bearer ${NOTION_TOKEN}" \
      -H "Notion-Version: ${API_VERSION}")

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

ext_from_mime() {
  case "$1" in
    image/png) echo "png" ;;
    image/jpeg) echo "jpg" ;;
    image/gif) echo "gif" ;;
    image/webp) echo "webp" ;;
    image/svg+xml) echo "svg" ;;
    image/bmp) echo "bmp" ;;
    image/tiff) echo "tiff" ;;
    image/heic) echo "heic" ;;
    image/x-icon | image/vnd.microsoft.icon) echo "ico" ;;
    *) echo "" ;;
  esac
}

IMAGES_TMP=$(mktemp)
trap 'rm -f "$IMAGES_TMP"' EXIT

# Walk the block tree collecting image blocks as JSON lines:
# {block_id, source_type, url, caption}
collect_images() {
  local block_id="$1" depth="$2"
  local cursor="" has_more=true url response

  while [ "$has_more" = "true" ]; do
    url="https://api.notion.com/v1/blocks/${block_id}/children?page_size=100"
    if [ -n "$cursor" ]; then
      url="${url}&start_cursor=${cursor}"
    fi
    response=$(notion_api GET "$url")

    echo "$response" | jq -c '.results[]
      | select(.type == "image")
      | {block_id: .id,
         source_type: .image.type,
         url: (if .image.type == "file" then .image.file.url else .image.external.url end),
         caption: ([.image.caption[]?.plain_text] | join(""))}' >> "$IMAGES_TMP"

    # Recurse into containers (toggles, columns, callouts, ...) but never
    # into child pages/databases — their images belong to those pages.
    if [ "$depth" -lt "$MAX_DEPTH" ]; then
      local child
      for child in $(echo "$response" | jq -r '.results[]
          | select(.has_children == true and .type != "child_page" and .type != "child_database")
          | .id'); do
        collect_images "$child" $((depth + 1))
      done
    fi

    has_more=$(echo "$response" | jq -r '.has_more')
    cursor=$(echo "$response" | jq -r '.next_cursor // empty')
  done
}

collect_images "$PAGE_ID" 1

if [ ! -s "$IMAGES_TMP" ]; then
  echo '{"images": []}'
  exit 0
fi

mkdir -p "$OUTPUT_DIR"

manifest="[]"
while IFS= read -r entry; do
  block_id=$(echo "$entry" | jq -r '.block_id')
  image_url=$(echo "$entry" | jq -r '.url // empty')
  if [ -z "$image_url" ]; then
    echo "Warning: image block ${block_id} has no URL; skipping." >&2
    continue
  fi

  # Signed S3 / external URLs take no Notion auth header.
  tmp_file="${OUTPUT_DIR}/.download.tmp"
  content_type=$(curl -sL -o "$tmp_file" -w '%{content_type}' "$image_url") || {
    echo "Warning: download failed for block ${block_id}; skipping." >&2
    rm -f "$tmp_file"
    continue
  }
  mime_type="${content_type%%;*}"

  ext=$(ext_from_mime "$mime_type")
  if [ -z "$ext" ]; then
    # Fall back to the URL path's extension (before the query string).
    ext=$(echo "$image_url" | sed 's/[?#].*$//' | grep -oE '\.[A-Za-z0-9]+$' | tr -d '.' || true)
    ext="${ext:-bin}"
  fi

  dest="${OUTPUT_DIR}/${block_id}.${ext}"
  mv "$tmp_file" "$dest"

  manifest=$(echo "$manifest" | jq \
    --argjson e "$entry" --arg path "$dest" --arg mime "$mime_type" \
    '. + [{block_id: $e.block_id, path: $path, mime_type: $mime, source_type: $e.source_type, caption: $e.caption}]')
done < "$IMAGES_TMP"

echo "$manifest" | jq '{images: .}'
