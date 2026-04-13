#!/usr/bin/env bash
# load.sh — load user-supplied custom instructions for a given key
#
# Usage: load.sh <key>
#
# Reads ~/.waggle/<key>-prompt.md and prints its contents to stdout iff the
# file passes all safety checks. Warnings go to stderr. Always exits 0.
#
# Safety checks:
#   - File must exist (otherwise silent empty output)
#   - File size must be <= 10 KiB (10240 bytes)
#   - File must not contain prompt-boundary control markers
#     (<|endofprompt|>, <|im_start|>, <|im_end|>)
#
# This script handles the CLI / Claude Desktop path only. The Cowork path
# (Global Instructions → XML tags in system prompt) is handled in SKILL.md
# directly because bash cannot read the agent's own system prompt.

set -u

readonly MAX_BYTES=10240
readonly DANGEROUS_TOKENS=('<|endofprompt|>' '<|im_start|>' '<|im_end|>')

usage() {
    echo "usage: $(basename "$0") <key>" >&2
    echo "  <key> must be a non-empty kebab-case identifier (e.g. task-creation)" >&2
    exit 2
}

[ $# -eq 1 ] || usage
key="$1"

# Validate key: non-empty, kebab-case only. Prevents path traversal like
# "../../etc/passwd" and rejects empty / whitespace keys.
if ! [[ "$key" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "[loading-custom-instructions] invalid key: '$key' (expected kebab-case: ^[a-z][a-z0-9-]*\$)" >&2
    exit 2
fi

file="${HOME}/.waggle/${key}-prompt.md"

# Case 1: file does not exist → silent empty output, exit 0
[ -f "$file" ] || exit 0

# Case 2: file is empty → silent empty output, exit 0
[ -s "$file" ] || exit 0

# Case 3: file exceeds size limit → warn + empty output, exit 0
bytes=$(wc -c < "$file")
if [ "$bytes" -gt "$MAX_BYTES" ]; then
    echo "[loading-custom-instructions] ${file} is ${bytes} bytes, exceeds ${MAX_BYTES} byte limit — skipping. Trim the file or split it before retrying." >&2
    exit 0
fi

# Case 4: dangerous token present → warn + empty output, exit 0
for token in "${DANGEROUS_TOKENS[@]}"; do
    if LC_ALL=C grep -qF -- "$token" "$file"; then
        echo "[loading-custom-instructions] ${file} contains prompt-boundary marker '${token}' — skipping. Remove the marker before retrying. Never paste untrusted text into this file." >&2
        exit 0
    fi
done

# Happy path: print file contents verbatim to stdout.
cat -- "$file"
exit 0
