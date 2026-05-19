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

## Why 7 days for suppression

7 days is long enough that the user can address the inherent vagueness in their own workflow (a sprint, a planning cycle). Shorter would grind the user; longer would let truly stale verdicts linger. Tuned to "weekly planning cadence" as the implicit recovery window.
