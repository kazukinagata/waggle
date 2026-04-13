#!/usr/bin/env bash
# Detect whether a custom-source intake item is a "stub" — a placeholder with
# almost no content, typically just a reference ID and a status keyword. The
# canonical example is a GOps task imported with description like
# "GOpsタスク (タスクID: 4548). 見積前" — the item exists but the waggle task
# it produces would be useless without enrichment.
#
# This script performs structural detection only. Semantic enrichment
# (fetching the source page body and comments, then generating a richer
# Description/AC/Context) is the LLM's job in the SKILL.md orchestration.
#
# Usage: detect-stub-import.sh <item_json_file>
#
# Input JSON (flat):
#   {
#     "description": "GOpsタスク (タスクID: 4548). 見積前",
#     "source_name": "gops",
#     "title": "..."  # optional, used as fallback if description is empty
#   }
#
# Output JSON:
#   {
#     "is_stub": true|false,
#     "stub_reason": "<human-readable reason or null>",
#     "source_id": "<extracted ID or null>",
#     "description_length": <int>
#   }
#
# Exit code: always 0 — check .is_stub in output.

set -euo pipefail

ITEM_FILE="${1:?Usage: detect-stub-import.sh <item_json_file>}"

if [ ! -f "$ITEM_FILE" ]; then
  echo "{\"is_stub\":false,\"stub_reason\":\"item file not found: ${ITEM_FILE}\",\"source_id\":null,\"description_length\":0}"
  exit 0
fi

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

jq '
  (.description // "") as $desc |
  (.title // "") as $title |
  ($desc | length) as $len |

  # Extract a source ID from common patterns (Japanese "タスクID:", English
  # "task ID:", "issue #", "ticket #", bare "ID:"). We only pull the first
  # match — enrichment logic can refine further if needed.
  (
    ($desc + " " + $title)
    | (capture("(?:タスクID|task\\s*ID|issue\\s*#|ticket\\s*#|ID)[:\\s#]*(?<id>[A-Z0-9][A-Z0-9_\\-]*)"; "i") // null)
  ) as $id_match |

  # Heuristic: stubs are short AND contain a reference-ID marker AND either
  # have no prose beyond the marker or only status keywords like
  # 見積前 / Waiting / Pending / TODO.
  ($desc | test("タスクID|task\\s*ID|issue\\s*#|ticket\\s*#"; "i")) as $has_id_marker |
  ($desc | test("見積前|対応中|Waiting|Pending|TODO|backlog|未着手"; "i")) as $has_status_only |

  if $len < 100 and $has_id_marker then
    {
      is_stub: true,
      stub_reason: (
        if $has_status_only then "Short description with task ID reference and only status keyword"
        else "Short description with task ID reference"
        end
      ),
      source_id: ($id_match.id // null),
      description_length: $len
    }
  elif $len < 40 and ($desc | length) > 0 then
    {
      is_stub: true,
      stub_reason: "Description is too short (< 40 chars)",
      source_id: ($id_match.id // null),
      description_length: $len
    }
  else
    {
      is_stub: false,
      stub_reason: null,
      source_id: ($id_match.id // null),
      description_length: $len
    }
  end
' "$ITEM_FILE"
