---
name: reviewing-quality
description: >
  Shared skill that owns the Quality Verdict pipeline for waggle tasks.
  Combines the deterministic structural checks (Layer 1) and the
  task-quality-reviewer-agent (Layer 2 IRC) behind a single contract.
  Manages the content-hash cache, batch fan-out, and worthiness-tag skip path.
  Invoked by planning-tasks, ingesting-messages, managing-tasks, executing-tasks,
  delegating-tasks (via assigning-to-others), running-daily-tasks, and
  monitoring-tasks. Not invoked directly by users.
user-invocable: false
---

# Reviewing Quality

This skill is the single integration point for the protocol quality gates. All Reviewer-related logic lives here so that the 7 caller skills do not duplicate cache handling, spawn orchestration, or Layer 1 evaluation.

**Silent operation:** This skill runs as an internal step of an invoking skill. Return
results to the invoking flow without user-facing narration — the caller owns all user
communication. Only errors, warnings, and prompts required to proceed may surface directly.

## Why this skill exists

Without a shared owner:
- Cache format would drift across 7 callers.
- Each caller would re-implement the 5-parallel batch fan-out.
- The "Layer 1 pre-filter → Reviewer agent" boundary would be repeated and inconsistent.
- The worthiness-tag skip path would have to be duplicated.

This skill consolidates all that. See `references/cache-format.md` for the on-disk verdict format (also documented in the protocol spec, kept in sync).

## How other skills invoke this one

Other skills invoke this skill via natural language. Examples:

- "Invoke the `reviewing-quality` skill to get a fresh verdict for task `<id>`."
- "Invoke the `reviewing-quality` skill in cache-only mode to look up the cached verdict for tasks `[<id1>, <id2>, ...]`."
- "Invoke the `reviewing-quality` skill to batch-review Ready+ tasks."

The invoking skill describes the task and the mode in natural language; this skill then runs the steps below.

## Modes

| Mode | Behavior |
|---|---|
| `live` | Always compute fresh: Layer 1 structural check → if pass, spawn the Reviewer agent. Write verdict to cache. Used by `planning-tasks` after AC/EP generation, by `managing-tasks` planning-assisted creation, and by `ingesting-messages` Phase A.5. The latter two run **before the task exists** — see "Deferred-write contract (creation-time callers)" below. |
| `cache-only` | Read the cached verdict. If hash matches and is non-empty, return it. If cache miss or hash mismatch, return verdict=`UNREVIEWED` to the caller; **do not** spawn the Reviewer. Used by `executing-tasks` dispatch and `managing-tasks` pre-Ready (hot paths). |
| `live, cache-aware` | First check cache (content hash). If cache hit and PASS, return it. Otherwise fall through to `live`. Used by `delegating-tasks` (via `assigning-to-others`), `running-daily-tasks` Step 2.6, and `monitoring-tasks --deep`. |

### Deferred-write contract (creation-time callers)

When `live` mode is invoked for a task that has not been created yet (`managing-tasks` planning-assisted creation, `ingesting-messages` Phase A.5), Steps 6's provider writes are impossible. Instead:

- Return the `verdict_string` **and** the rendered findings block (see `references/cache-format.md` § Findings Block Format) to the caller, which holds both in memory and includes them in the eventual create payload (`Quality Verdict` property + `Context` field respectively).

## Pipeline

For every invocation:

### Step 1 — Skip-path checks

If the task's `Tags` contain `worthiness:calendar-like` or `worthiness:info-only`:
- Apply the **reserved-placeholder check** only (no `[DRAFT-AC]` / `[DRAFT-EP]` / `[NEEDS-REFINE]` / `[INFERRED]` placeholder in either field). The Reviewer (Layer 2) is skipped for worthiness-tagged tasks per the protocol Quality Spec.
- If a placeholder remains → return verdict = `REJECT` with the placeholder as the gap. The user must remove the placeholder before promoting.
- Otherwise → return verdict = `PASS` (worthiness skip). Do not write a new cache entry; preserve any pre-existing one.

If the task's `Executor` is `human` and the call site is `managing-tasks` pre-Ready: continue to Step 2 normally. (Human tasks must still go through the cache check because they may be delegated later — see plan.)

### Step 2 — Structural checks (Layer 1)

Invoke the `validating-fields` skill to run the Layer 1 structural checks on the current task fields. These are language-independent, exactly decidable rules (empty fields, description length, reserved placeholders, verdict-line integrity) — Layer 1 makes no judgment about the meaning of AC/EP text; semantic quality belongs to the Reviewer below.

**Do not pass the task's stored `Quality Verdict` in this call.** Layer 1's verdict checks judge *the verdict travelling in a promotion write* — that it is well-formed, that it is a PASS, and that its format version is current. This step is asking a different question: is the spec structurally sound enough to be worth a Reviewer call? The verdict this run is about to produce does not exist yet, and the one currently stored is exactly what is being replaced.

Passing the stored verdict here would deadlock the thing it is meant to protect. A Ready task holding a legacy `v1` PASS is the migration's whole subject; if Layer 1 rejects it for being `v1`, this step returns `REJECT`, the Reviewer never runs, no `v2` verdict is ever produced, and the task can never leave `v1`. The same trap catches a task holding a stale `NEEDS_REFINEMENT`: it could never be re-reviewed into a PASS. Omit the field and both work.

The verdict checks still run where they belong — at the promotion itself, where `managing-tasks` and the other callers pass the `verdict_string` this skill returned, in the same write that sets the new Status.

- Layer 1 fail (`valid: false`): return verdict = `REJECT` with the structural errors. **Do not** spawn the Reviewer. Cache the verdict so `monitoring-tasks` can list it. The errors name exactly what is missing (a field, a placeholder), so the caller can present a mechanical fix.
- Layer 1 pass (warnings allowed): continue.

### Step 3 — Cache lookup (when mode ≠ `live`)

Compute the review-input hash over the normalized review input defined in `references/cache-format.md`: `Title`, `Description`, `Acceptance Criteria`, `Execution Plan`, reviewer-visible `Context`, and the rubric identifier, pipe-joined and normalized exactly as that file specifies.

**Reviewer-visible `Context` means `Context` with the machine-written blocks removed** — the findings block and the delegation history block. The confirmation log stays: it is issuer evidence the Reviewer must see (Step 4). Perform the strip once and use the same result for both the hash here and the spec handed to the Reviewer, since two independent strip implementations would drift and a drift here silently mismatches every hash.

Read the task's `Quality Verdict` field. Parse using `references/cache-format.md`, and **keep the parsed format version** — the next step branches on it.

Evaluate on the parsed version, and note that **`v1` is handled differently per mode** — this is the whole of the migration window:

1. **Version `v2`** → compare against the v2 review-input hash. Match → cache hit, return it. Mismatch → cache stale.
2. **Version `v1`** → the line was hashed over the legacy input (`Title|Description|AC|EP`, no `Context`, no rubric identifier), so it can never match a recomputed v2 hash. Do not read that as content staleness:
   - In **`cache-only`** mode, validate it against the **legacy v1 hash** instead. A well-formed `v1` PASS whose legacy hash still matches is a **cache hit**: return it, with `format_version: 1`, so dispatch proceeds. This is required, not a courtesy — `cache-only` has no live fallback, so treating `v1` as a miss returns `UNREVIEWED` and strands every task that was already Ready before the upgrade, which is precisely what the migration window exists to prevent. If the legacy hash does *not* match, the spec changed after even that verdict, so it is genuinely stale → cache miss.
   - In **`live`** and **`live, cache-aware`** modes, a `v1` line is never a hit. Fall through and produce a `v2` verdict. A caller already willing to pay for a live review is exactly where the upgrade should happen, and this is what makes the migration progress rather than sit still.
3. **Any other version** → cache miss in every mode. Only two versions are defined; the hash behind an unknown one was computed over an unknown input.

When surfacing a `v1` result to the caller, say the verdict predates the rubric change and will be re-reviewed by the daily sweep — not that someone edited the spec.

There is no re-review throttle (the 7-day suppression mechanism was removed in v3.0.0): identical content is already deduplicated by the content hash, and every refine loop is gated on an explicit user choice at the caller, so re-reviews only happen when the user changed the spec and asked for one.

In `cache-only` mode, a cache miss returns verdict = `UNREVIEWED` to the caller. The caller decides how to surface this to the user (typically a 2-choice `[Refine first] [Proceed anyway]` prompt).

**Findings on cache hit:** when the cached verdict is `NEEDS_REFINEMENT` or `REJECT`, also read the task's `Context` field and look for a Quality Review Findings block (format in `references/cache-format.md`). If the block's `hash` equals the cached verdict's hash, parse it and populate `gaps` / `fixes` in the return payload — this is what lets cache-only callers present the gaps and suggested fixes without a live Reviewer call. On hash mismatch (stale findings from an earlier review of different content) or no block, leave `gaps` / `fixes` empty; the caller falls back to verdict-only display.

### Step 4 — Reviewer agent (Layer 2)

Spawn the `task-quality-reviewer-agent` subagent with the task spec block (Title, Description, AC, EP, Context, Working Directory, Repository, Executor).

Before passing `Context`, strip the machine-written blocks it contains: the Quality Review Findings block (this skill's own persisted output from a previous round) and the Delegation History block (audit metadata carrying no requirement). The Reviewer must evaluate the requester's spec, not be steered by its own prior findings or asked to read a handoff log as a requirement. This is the **same strip** whose result fed the hash in Step 3; reuse it rather than recomputing.

**Keep the Confirmation Log block.** It is the opposite case: it records what the issuer confirmed, and a confirmation is the issuer's own words about that line — the strongest form of sourcing the Fidelity axis recognizes. Strip it and the axis has no evidence for a line that was just adopted, so resolving an `[INFERRED]` marker would produce a spec that can never PASS and the task could never reach Ready. Tell the Reviewer what the block is, so it reads the entries as issuer statements rather than as prose someone left in `Context`.

Wait for its return. Parse the structured output to extract:
- Verdict (`PASS` / `NEEDS_REFINEMENT` / `REJECT` / `INSUFFICIENT_CONTEXT`)
- Per-axis findings
- Specific gaps
- Suggested concrete fixes

Treat `INSUFFICIENT_CONTEXT` as `NEEDS_REFINEMENT` for cache/return purposes; surface the verification gap to the user via the caller.

### Step 5 — Cache write

Write the verdict to the task's `Quality Verdict` field in the format documented in `references/cache-format.md`. Single line, overwrites the previous entry. **Emit `v2` only** — `v1` is never written again, including when re-reviewing a task that currently carries a `v1` line.

**Findings persistence (same write step):** keep the gaps and suggested fixes on the task, not just in chat — they are what the user (or a later session) needs to act on a non-PASS verdict.

- Verdict is `NEEDS_REFINEMENT` or `REJECT` → render a Quality Review Findings block (format in `references/cache-format.md`) from the Reviewer's gaps and fixes (or the Layer 1 structural errors when the Reviewer was not spawned) and upsert it into the task's `Context` field: replace any existing findings block, leave the rest of `Context` untouched. At most one block per task.
- Verdict is `PASS` → remove any existing findings block from `Context` (the issues are resolved; stale findings would mislead executors).
- The block carries the same `hash` as the verdict line, so staleness is detectable without extra writes. The block is stripped before hashing, so writing it never invalidates the verdict cache — note the reason: under v2 `Context` *is* inside the hash, and it is the strip, not the field's exclusion, that keeps the block harmless.
- Graceful degradation: if the provider/task has no `Context` field, skip findings persistence — the verdict line still caches; gaps/fixes surface in chat only.
- Creation-time callers: see "Deferred-write contract" above — the block is returned to the caller instead of written.

### Step 6 — Return to caller

Return a structured payload:

```
verdict: PASS | NEEDS_REFINEMENT | REJECT | UNREVIEWED
verdict_string: "<verdict> hash=<8hex> @<iso8601> v2" | ""
hash: <8-hex>
format_version: 1 | 2                                # parsed from the line; never discarded
cached_at: <iso8601>
per_axis: { goal: ◯|△|✗, boundary, verifiability, reproducibility, hidden_context, fidelity }   # only on live verdicts; 6 axes
gaps: [...]                                          # only on non-PASS verdicts
fixes: [...]                                         # only on non-PASS verdicts
findings_block: "<rendered block>" | null            # non-PASS only; for deferred-write callers
```

On live non-PASS verdicts, `gaps` / `fixes` come from the Reviewer's output. On **cache hits**, they are populated from the persisted findings block when its hash matches (see Step 3) — so callers on hot paths can present them without a live call.

`verdict_string` is the **canonical cache string** for this verdict — byte-identical to what was written to (Step 6) or read from the task's `Quality Verdict` field. Callers that promote a task to a Ready+ status (`Ready` / `In Progress` / `In Review` / `Done`) **must echo this exact string into the `Quality Verdict` property of the same provider write that sets the new Status**, so the promotion is atomic and self-evidencing (the persisted verdict travels in the same payload as the status change). For a real verdict (`PASS` / `NEEDS_REFINEMENT` / `REJECT`), or a worthiness-skip `PASS` (return the preserved pre-existing entry, or a fresh `PASS` line if none exists), `verdict_string` is non-empty. Only a `cache-only` miss (`UNREVIEWED`) returns `verdict_string: ""`.

## Batch mode

For batch invocations (`monitoring-tasks --deep`, `running-daily-tasks` Step 2.6):

1. Receive list of task IDs.
2. For each task, perform Step 1 (skip-path) and Step 3 (cache lookup) sequentially. Tasks that hit cache return immediately.
3. Group the remaining tasks into chunks of 5. For each chunk, spawn 5 Reviewer agents in parallel (Step 4) — reuse the existing parallel pattern from `planning-tasks` batch mode.
4. Aggregate results.

## Failure modes

- **Reviewer returns malformed output**: treat as `INSUFFICIENT_CONTEXT`. Do not write cache. Surface to user.
- **Cache write fails (provider error)**: return the verdict to the caller anyway; log the cache write failure and retry on next invocation. Do not block.
- **Task lacks Tags field (provider doesn't support)**: skip the worthiness check; proceed with the Layer 1 structural checks.
- **Notion 429 rate limit on cache write**: respect Retry-After, then retry once.

## Self-references

This skill uses `${CLAUDE_SKILL_DIR}` for its own bundled files (e.g., scripts under `${CLAUDE_SKILL_DIR}/scripts/...`). It must not reference other skills' internal paths.
