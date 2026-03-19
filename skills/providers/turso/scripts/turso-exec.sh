#!/usr/bin/env bash
# Execute SQL statement(s) against a Turso database via HTTP pipeline API.
#
# Usage: turso-exec.sh <sql_statement> [sql_statement2] ...
#
# Environment:
#   TURSO_URL        (required) — Turso database HTTP URL (e.g. https://db-name-org.turso.io)
#   TURSO_AUTH_TOKEN (required) — Turso authentication token
#
# Output:
#   JSON response from Turso pipeline API

set -euo pipefail

if [ $# -eq 0 ]; then
  echo "Usage: turso-exec.sh <sql_statement> [sql_statement2] ..." >&2
  exit 1
fi

if [ -z "${TURSO_URL:-}" ]; then
  echo "Error: TURSO_URL environment variable is not set." >&2
  exit 1
fi

if [ -z "${TURSO_AUTH_TOKEN:-}" ]; then
  echo "Error: TURSO_AUTH_TOKEN environment variable is not set." >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

# Build requests array
REQUESTS="[]"
for sql in "$@"; do
  REQUESTS=$(echo "$REQUESTS" | jq --arg s "$sql" '. + [{"type": "execute", "stmt": {"sql": $s}}]')
done

# Add close request
REQUESTS=$(echo "$REQUESTS" | jq '. + [{"type": "close"}]')

BODY=$(jq -n --argjson r "$REQUESTS" '{"requests": $r}')

response=$(curl -s -w "\n%{http_code}" -X POST "${TURSO_URL}/v2/pipeline" \
  -H "Authorization: Bearer ${TURSO_AUTH_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$BODY")

http_code=$(echo "$response" | tail -1)
response_body=$(echo "$response" | sed '$d')

if [ "$http_code" -ne 200 ]; then
  echo "Error: Turso API returned HTTP ${http_code}" >&2
  echo "$response_body" >&2
  exit 1
fi

echo "$response_body"
