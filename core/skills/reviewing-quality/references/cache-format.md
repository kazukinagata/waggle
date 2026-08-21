# Quality Verdict Cache Format (v2)

The protocol spec (the `waggle-protocol` skill, § Quality Spec) is the canonical owner of this format. This file is the implementation-side documentation for `reviewing-quality`.

## Storage

The verdict is stored in the task's `Quality Verdict` core field (rich_text, single line). The field is auto-repaired on session bootstrap by the active provider.

## Format

```
<verdict> hash=<8hex> @<iso8601> v2
```

- `<verdict>`: one of `PASS`, `NEEDS_REFINEMENT`, `REJECT`
- `hash=<8hex>`: first 8 lowercase hex chars of `sha256(<normalized review input>)` — see below
- `@<iso8601>`: UTC timestamp when the verdict was computed
- `v2`: format version literal

### The normalized review input

Six components, in this order, joined by a single `|`:

```
Title | Description | Acceptance Criteria | Execution Plan | reviewer-visible Context | irc-6axis
```

Normalization, applied to each component before joining:

- An absent, null, or provider-unsupported field is the **empty string** — never omitted. The component and its delimiter always occupy their position, so the pipe count is constant at 5.
- Line endings normalized to `LF`.
- Trailing whitespace at the **end of the component** removed. Internal whitespace and blank lines preserved exactly.
- Joined string encoded as UTF-8, no trailing newline.

**Reviewer-visible `Context`** is `Context` with the **machine-written blocks** removed: the Quality Review Findings block and the Delegation History block (both below). The removal must be byte-identical to the strip performed before the spec is handed to the Reviewer in Step 4: the hash covers exactly what the Reviewer read.

The **Confirmation Log block is not removed** — it is issuer evidence the Reviewer must see, so it stays in both the review input and the hash.

That is the whole rule, and the line it draws is by **authorship**, not by "is it a block":

| In `Context` | In the hash and the review input? | Why |
|---|---|---|
| Issuer prose | **yes** | It is part of the specification |
| Confirmation Log | **yes** | It records the issuer's decisions; a confirmed line is sourced by it |
| Quality Review Findings | no | The pipeline's own judgment; a review must not read its own prior output |
| Delegation History | no | Machine-written audit metadata; it carries no requirement |

Anything written by the pipeline that is not an issuer decision belongs in a delimited block and is stripped. A bare line appended by a skill is a bug: it enters the hash, and it invalidates a verdict that nothing about the specification actually changed.

`irc-6axis` is the rubric identifier. It is inside the hash because a sixth axis changes what `PASS` means — without it, a verdict produced under the five-axis rubric would be indistinguishable from one produced under six.

Producing it, given the six components already normalized and joined in `$INPUT`:

```
printf '%s' "$INPUT" | sha256sum | cut -c1-8
```

`sha256sum` emits lowercase, which is what makes a mnemonic or upper-case hash detectable as fabricated.

### Examples

```
PASS hash=abc12345 @2026-05-19T10:42:00Z v2
```

```
NEEDS_REFINEMENT hash=def67890 @2026-05-19T10:42:00Z v2
```

## Parsing

A regex that captures all fields:

```
^(?P<verdict>PASS|NEEDS_REFINEMENT|REJECT)\s+hash=(?P<hash>[0-9a-f]{8})\s+@(?P<at>\S+)\s+v(?P<version>\d+)(?:\s+\S+=\S+)*\s*$
```

**Return the captured `version` — do not discard it.** The version is load-bearing: a `v1` line is a verdict produced under a different rubric and a different hash input, and callers gate on that (see below). A parser that reports only "well-formed" makes the migration window unimplementable.

If parsing fails (empty field, malformed, or version > known): treat as cache miss.

## Format versions and the migration window

| Transition | Accepted |
|---|---|
| Backlog → Ready | current `v2` PASS only |
| Ready → In Progress / In Review / Done | `v2` PASS, or a legacy `v1` PASS |

Exactly two versions are defined, and **any other version is rejected at every gate**. Note the asymmetry with trailing keys: a parser must tolerate an unknown trailing `key=value` because the contract declares it meaningless, but it must *not* tolerate an unknown version, because the hash behind one was computed over an input the parser does not know. Tolerating it would admit a verdict nobody can recompute.

New verdict producers emit `v2` only; `v1` is never written again.

### The legacy v1 hash

Retained for the migration window only, so a `v1` line can still be validated:

```
sha256("<Title>|<Description>|<Acceptance Criteria>|<Execution Plan>")[:8]
```

Four components, no `Context`, no rubric identifier. A `v1` line can therefore never match a recomputed `v2` hash — so a `v1` line is **version-mismatched, not content-stale**, and the distinction matters when reporting: "re-review needed after the format change" is a different message from "someone edited the spec".

Never *produce* this hash. Compute it only to answer "does this legacy verdict still describe the current spec?".

### How a v1 line is treated, by mode

| Mode | A well-formed `v1` PASS |
|---|---|
| `cache-only` | Validate against the **legacy v1 hash**. Match → **cache hit**, usable; the caller dispatches. Mismatch → genuinely stale, cache miss. |
| `live`, `live, cache-aware` | Never a hit. Produce a `v2` verdict. |

The `cache-only` row is load-bearing. Dispatch is cache-only and cannot fall back to a live review, so treating `v1` as a miss there returns `UNREVIEWED` and makes every task that was already Ready before the upgrade undispatchable — the exact outcome this window exists to prevent. The `live` row is what makes the migration progress: every caller willing to pay for a review upgrades the task it touches, and the daily health check and `monitoring-tasks` sweep the rest progressively.

## Forward and backward compatibility

A future `v3` may add new fields. Parsers MUST NOT reject a line solely because of unknown trailing key=value pairs after the version literal. Unknown keys should be ignored.

This rule also covers legacy lines: verdict lines written by v2.x may carry a trailing `suppressed-until=<iso8601>` key (the retired 7-day re-review suppression, removed in v3.0.0). Such lines parse normally; the key is ignored and carries **no semantics** — the ordinary content-hash rules apply. Suppression was removed because it kept returning the frozen verdict even after the user substantively fixed the spec, punishing legitimate rework to guard a cost (Reviewer re-runs) that the content hash and user-gated refine loops already bound.

## Why a single line (not JSON)

- Notion `rich_text` is a prose field; users see it.
- A single-line key=value format is human-scannable in the Notion UI without overwhelming a viewer.
- JSON in a rich_text field tends to be reformatted by users editing in Notion.

## Confirmation Log Block Format

The second managed block. When an `[INFERRED]` line is confirmed by the issuer and the prefix removed, this block records that the line was **adopted into the contract**, not that the issuer originally stated it.

Stored inside the task's `Context` extended field, alongside the findings block:

```
--- Waggle Confirmation Log ---
- <the confirmed line, after prefix removal> — confirmed by <who> @<iso8601>
- <...>
--- End Waggle Confirmation Log ---
```

Rules:

- **At most one block per task.** Writes replace the existing block in place; the rest of `Context` is preserved verbatim.
- **Append-only within the block.** A confirmation is a historical fact; entries are not rewritten when the spec changes later.
- **No hash.** Unlike the findings block, this block does not go stale — it records what happened, not a judgment about current content.
- **NOT stripped** — the block stays in the review input and inside the hash. This is the one place the two managed blocks behave differently, and the difference is the point: the findings block is the pipeline's own judgment (the Reviewer must not read it), while this block is the issuer's decision (the Reviewer must). A confirmed line is sourced *by the confirmation*; a Reviewer who cannot see it judges the line unsourced, which would make `[INFERRED]` unresolvable — confirming it would remove the prefix and still fail Fidelity, so the task could never reach Ready.
- Confirming a line edits `Acceptance Criteria` anyway (the prefix comes off), so the verdict is invalidated through the AC component regardless. Stripping this block to protect the verdict would have protected nothing while costing the axis its evidence.
- **Graceful degradation:** when a provider does not support `Context`, surface the confirmation in conversation only — and fold the confirmed statement into `Description`, since a confirmation the Reviewer cannot see is not evidence.

Delimiter lines are exact-match anchors:

```
^--- Waggle Confirmation Log ---$
^--- End Waggle Confirmation Log ---$
```

An unterminated block is bounded the same conservative way as the findings block: replace from the opening delimiter through the last consecutive line that parses as block content (`- ` bullets), never blindly to end-of-field.

## Delegation History Block Format

Machine-written audit metadata: who handed the task to whom, and when. It carries no requirement, so it is stripped before hashing and before review.

Stored inside the task's `Context` extended field:

```
--- Waggle Delegation History ---
- Delegated from @<name> to @<name> on <YYYY-MM-DD>
- <...>
--- End Waggle Delegation History ---
```

Rules:

- **At most one block per task**, appended to in place; entries are append-only.
- **Stripped before hashing and before review**, like the findings block.
- Delimiter lines are exact-match anchors, bounded conservatively when unterminated, exactly as for the findings block.

**Why this needs a block at all.** Delegation used to append a bare `Delegated from ...` line to `Context`. Under the v2 hash that silently breaks delegation: the assignment gate reviews the task, gets a `PASS`, and then the delegation write appends to `Context` — so the verdict it just obtained is stale the moment it is stored, and the next cache-only dispatch rejects the task that was just delegated. Reviewing *after* the append would fix the hash but destroy the cache-hit path that makes assignment silent in the common case, turning every delegation into a live Reviewer call. Stripping the block keeps both.

**Migration.** Tasks delegated before v4.0.0 carry a bare `Delegated from ...` line with no delimiters. It stays inside the hash — it is indistinguishable from issuer prose without guessing at line shapes, and guessing is how a strip starts eating user text. Those tasks are re-reviewed once by the daily sweep like any other `v1` task, and the line moves into the block the next time the task is delegated.

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
- **`hash` equals the verdict line's hash** (the same normalized review input). A block whose hash differs from the current verdict line is stale: ignore its contents and report findings as unavailable. The block is stripped from `Context` before hashing, so writing or removing it never invalidates the verdict cache — note this is *because of the strip*, not because `Context` is outside the hash; under v2 it is inside it.
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
