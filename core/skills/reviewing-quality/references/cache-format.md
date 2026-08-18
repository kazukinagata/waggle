# Quality Verdict Cache Format (v1)

The protocol spec (`waggle-protocol/SKILL.md` § Quality Spec) is the canonical owner of this format. This file is the implementation-side documentation for `reviewing-quality`.

## Storage

The verdict is stored in the task's `Quality Verdict` core field (rich_text, single line). The field is auto-repaired on session bootstrap by the active provider.

## Format

```
<verdict> hash=<8hex> @<iso8601> v1
```

- `<verdict>`: one of `PASS`, `NEEDS_REFINEMENT`, `REJECT`
- `hash=<8hex>`: first 8 hex chars of `sha256("${Title}|${Description}|${AC}|${EP}")`. Any edit to those fields invalidates the cache.
- `@<iso8601>`: UTC timestamp when the verdict was computed
- `v1`: format version literal

### Examples

```
PASS hash=abc12345 @2026-05-19T10:42:00Z v1
```

```
NEEDS_REFINEMENT hash=def67890 @2026-05-19T10:42:00Z v1
```

## Parsing

A regex that captures all fields:

```
^(?P<verdict>PASS|NEEDS_REFINEMENT|REJECT)\s+hash=(?P<hash>[0-9a-f]{8})\s+@(?P<at>\S+)\s+v(?P<version>\d+)(?:\s+\S+=\S+)*\s*$
```

If parsing fails (empty field, malformed, or version > known): treat as cache miss.

## Forward and backward compatibility

A future `v2` may add new fields. Parsers MUST NOT reject a line solely because of unknown trailing key=value pairs after the version literal. Unknown keys should be ignored.

This rule also covers legacy lines: verdict lines written by v2.x may carry a trailing `suppressed-until=<iso8601>` key (the retired 7-day re-review suppression, removed in v3.0.0). Such lines parse normally; the key is ignored and carries **no semantics** — the ordinary content-hash rules apply. Suppression was removed because it kept returning the frozen verdict even after the user substantively fixed the spec, punishing legitimate rework to guard a cost (Reviewer re-runs) that the content hash and user-gated refine loops already bound.

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
- **Lifecycle:** written on `NEEDS_REFINEMENT` / `REJECT` (Reviewer gaps/fixes, or Layer 1 structural errors when the Reviewer was skipped); deleted on `PASS`.
- **Size cap ~1500 characters.** Keep one line per gap/fix. When truncating, drop fixes before gaps (gaps are the diagnosis; fixes can be re-derived).
- **Self-exclusion:** the block is stripped from `Context` before the spec is handed to the Reviewer agent, so a review never reads its own prior output.

### Parsing

Delimiter lines are exact-match anchors:

```
^--- Quality Review Findings hash=(?P<hash>[0-9a-f]{8}) @(?P<at>\S+) ---$
^--- End Quality Review Findings ---$
```

If the opening delimiter is present but the closing one is missing or the body is malformed, treat the block as stale (ignore contents). On the next write, bound the replaced region conservatively so user-authored text is never consumed: replace from the opening delimiter through the last consecutive line that parses as block content (the `Gaps:` / `Suggested fixes:` headers and their `- ` bullets), or through the closing delimiter when present — never blindly to end-of-field. Any trailing lines that do not parse as block content (e.g. user notes appended after an unterminated block) are preserved after the new block; surface a one-line warning to the caller when such trailing content was found inside an unterminated region.
