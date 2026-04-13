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
# Prompt-boundary markers this script rejects. Covers ChatML (OpenAI-family)
# and Claude's legacy Human/Assistant text-completion format. Claude's tool-
# use XML tags (<function_calls>, <invoke>) are NOT blocked because they can
# legitimately appear in markdown rules files; the 10 KiB cap and the
# "only author your own rules" trust reminder in setting-up-tasks are the
# primary defences for that surface.
readonly DANGEROUS_TOKENS=(
    '<|endofprompt|>'
    '<|im_start|>'
    '<|im_end|>'
    $'\n\nHuman:'
    $'\n\nAssistant:'
)

usage() {
    echo "usage: $(basename "$0") <key>" >&2
    echo "  <key> must be a non-empty kebab-case identifier (e.g. task-creation)" >&2
    exit 2
}

[ $# -eq 1 ] || usage
key="$1"

# Validate key: strict kebab-case. Segments of [a-z0-9]+ joined by single
# hyphens, no trailing / consecutive hyphens. Prevents path traversal and
# rejects keys that would silently resolve to nonexistent files (e.g.
# "task-" → "~/.waggle/task--prompt.md").
if ! [[ "$key" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ ]]; then
    echo "[loading-custom-instructions] invalid key: '$key' (expected strict kebab-case: lowercase alnum segments joined by single hyphens, e.g. task-creation)" >&2
    exit 2
fi

file="${HOME}/.waggle/${key}-prompt.md"

# Case 1: file does not exist → silent empty output, exit 0
[ -f "$file" ] || exit 0

# Case 2: file is empty → silent empty output, exit 0
[ -s "$file" ] || exit 0

# Read the file once into memory and perform every subsequent check against
# that snapshot. This eliminates the TOCTOU window where the file could be
# replaced between the size check and the content emit. The in-memory path
# also lets us do literal multi-line token matching (for $'\n\nHuman:' etc.)
# via bash case-statement globbing, which `grep -F` cannot do across lines.
#
# Note: command substitution strips trailing newlines, so `content` never
# retains a trailing \n. This is fine for instruction text and simplifies
# byte counting.
content=$(cat -- "$file")
bytes=$(printf '%s' "$content" | LC_ALL=C wc -c)

# Case 3: snapshot exceeds size limit → warn + empty output, exit 0
if [ "$bytes" -gt "$MAX_BYTES" ]; then
    echo "[loading-custom-instructions] ${file} is ${bytes} bytes, exceeds ${MAX_BYTES} byte limit — skipping. Trim the file or split it before retrying." >&2
    exit 0
fi

# If stripping trailing newlines left an empty snapshot, treat as empty.
[ "$bytes" -gt 0 ] || exit 0

# Case 4: dangerous token present → warn + empty output, exit 0
for token in "${DANGEROUS_TOKENS[@]}"; do
    case "$content" in
        *"$token"*)
            # Sanitize the token for display: replace embedded newlines with
            # "\n" so the warning renders on a single stderr line.
            display_token=${token//$'\n'/\\n}
            echo "[loading-custom-instructions] ${file} contains prompt-boundary marker '${display_token}' — skipping. Remove the marker before retrying. Never paste untrusted text into this file." >&2
            exit 0
            ;;
    esac
done

# Happy path: print the snapshot to stdout with a trailing newline so line-
# oriented consumers behave predictably.
printf '%s\n' "$content"
exit 0
