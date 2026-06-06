# Quality Verdict Cache Format (v1)

The protocol spec (`waggle-protocol/SKILL.md` § Quality Spec) is the canonical owner of this format. This file is the implementation-side documentation for `reviewing-quality`.

## Storage

The verdict is stored in the task's `Quality Verdict` core field (rich_text, single line). The field is auto-repaired on session bootstrap by the active provider.

## Format

```
<verdict> hash=<8hex> @<iso8601> v1 [suppressed-until=<iso8601>]
```

- `<verdict>`: one of `PASS`, `NEEDS_REFINEMENT`, `REJECT`
- `hash=<8hex>`: first 8 hex chars of `sha256("${Title}|${Description}|${AC}|${EP}")`. Any edit to those fields invalidates the cache.
- `@<iso8601>`: UTC timestamp when the verdict was computed
- `v1`: format version literal
- `suppressed-until=<iso8601>`: optional. When present and in the future, the verdict is treated as a cache hit regardless of hash, blocking re-evaluation for the duration. Set after 2 consecutive same-axis failures.

### Examples

PASS, no suppression:
```
PASS hash=abc12345 @2026-05-19T10:42:00Z v1
```

NEEDS_REFINEMENT with suppression:
```
NEEDS_REFINEMENT hash=def67890 @2026-05-19T10:42:00Z v1 suppressed-until=2026-05-26T10:42:00Z
```

## Parsing

A regex that captures all fields:

```
^(?P<verdict>PASS|NEEDS_REFINEMENT|REJECT)\s+hash=(?P<hash>[0-9a-f]{8})\s+@(?P<at>\S+)\s+v(?P<version>\d+)(?:\s+suppressed-until=(?P<until>\S+))?\s*$
```

If parsing fails (empty field, malformed, or version > known): treat as cache miss.

## Forward compatibility

A future `v2` may add new fields. Parsers MUST NOT reject a line solely because of unknown trailing key=value pairs after the version literal. Unknown keys should be ignored.

## Why a single line (not JSON)

- Notion `rich_text` is a prose field; users see it.
- A single-line key=value format is human-scannable in the Notion UI without overwhelming a viewer.
- JSON in a rich_text field tends to be reformatted by users editing in Notion.

## Why content-hash (not timestamp)

Earlier draft used `@<timestamp>` as the cache key with a 24h TTL. Problems:
- AC/EP can be edited in Notion UI without invalidating the verdict — a bare timestamp marks edited specs as still-PASS.
- Stable Done tasks were re-reviewed every 24h for no reason.
- Actively-edited tasks (edited 5min ago) hit stale cache.

Content-hash key fixes both: edits auto-invalidate, stable tasks are infinite TTL.

### Interaction with `suppressed-until`

**Content-hash invalidation is intentionally bypassed while suppression is active.** If the cache entry has `suppressed-until=<future_iso>`, the verdict is returned regardless of whether the current `Title|Description|AC|EP` hash matches the cached hash.

Rationale: suppression is the anti-grinding guard that fires after two consecutive same-axis Reviewer failures. Without this exception, a user could trip the suppression by editing one character, immediately bypass it via hash mismatch, and grind the Reviewer indefinitely on the same vague spec. The 7-day window assumes the user needs that much time to either rewrite the spec substantively or accept that the task is inherently vague.

To intentionally break out of suppression early, the user clears the `Quality Verdict` field in Notion — the next call sees a cache miss (no entry to read) and runs a fresh Reviewer. This matches the protocol's "users may always override" principle.

Callers SHOULD surface the `suppressed_until` value in their UI when the cached verdict is being returned on a hash mismatch, so users understand why their edits don't immediately re-trigger the Reviewer.

## Why 7 days for suppression

7 days is long enough that the user can address the inherent vagueness in their own workflow (a sprint, a planning cycle). Shorter would grind the user; longer would let truly stale verdicts linger. Tuned to "weekly planning cadence" as the implicit recovery window.

## Findings Block Format

Companion to the verdict line. The verdict line answers "is this spec good enough?"; the findings block answers "what exactly is missing?" — without it, a non-PASS verdict's gaps and suggested fixes survive only in the chat transcript and are gone by the time anyone acts on the task.

The block is stored inside the task's `Context` extended field (the verdict line itself stays single-line — see "Why a single line" above):

```
--- Quality Review Findings hash=<8hex> @<iso8601> ---
Gaps:
- <gap 1>
- <gap 2>
Suggested fixes:
- <fix 1>
- <fix 2>
--- End Quality Review Findings ---
```

Rules:

- **At most one block per task.** Writes replace the existing block in place; the rest of `Context` is preserved verbatim.
- **`hash` equals the verdict line's hash** (same `sha256("${Title}|${Description}|${AC}|${EP}")[:8]`). A block whose hash differs from the current verdict line is stale: ignore its contents and report findings as unavailable. `Context` is not part of the content hash, so writing or removing the block never invalidates the verdict cache.
- **Lifecycle:** written on `NEEDS_REFINEMENT` / `REJECT` (Reviewer gaps/fixes, or Rubric errors when the Reviewer was skipped); deleted on `PASS`.
- **Size cap ~1500 characters.** Keep one line per gap/fix. When truncating, drop fixes before gaps (gaps are the diagnosis; fixes can be re-derived).
- **Self-exclusion:** the block is stripped from `Context` before the spec is handed to the Reviewer agent, so a review never reads its own prior output.

### Parsing

Delimiter lines are exact-match anchors:

```
^--- Quality Review Findings hash=(?P<hash>[0-9a-f]{8}) @(?P<at>\S+) ---$
^--- End Quality Review Findings ---$
```

If the opening delimiter is present but the closing one is missing or the body is malformed, treat the block as stale (ignore contents) but still replace the whole region from the opening delimiter to end-of-field on the next write, so a corrupted block cannot accumulate.
