---
name: reviewing-quality
description: >
  Shared skill that owns the Quality Verdict pipeline for waggle tasks.
  Combines the deterministic Rubric (Layer 1) and the task-quality-reviewer-agent
  (Layer 2 IRC) behind a single contract. Manages the content-hash cache,
  7-day suppression, batch fan-out, and worthiness-tag skip path.
  Invoked by planning-tasks, ingesting-messages, managing-tasks, executing-tasks,
  delegating-tasks (via assigning-to-others), running-daily-tasks, and
  monitoring-tasks. Not invoked directly by users.
user-invocable: false
---

# Reviewing Quality

This skill is the single integration point for the v2.8.0 quality gates. All Reviewer-related logic lives here so that the 7 caller skills do not duplicate cache handling, spawn orchestration, or rubric evaluation.

**Silent operation:** This skill runs as an internal step of an invoking skill. Return
results to the invoking flow without user-facing narration — the caller owns all user
communication. Only errors, warnings, and prompts required to proceed may surface directly.

## Why this skill exists

Without a shared owner:
- Cache format would drift across 7 callers.
- Each caller would re-implement the 5-parallel batch fan-out.
- The "Rubric pre-filter → Reviewer agent" boundary would be repeated and inconsistent.
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
| `live` | Always compute fresh: Rubric → if pass, spawn the Reviewer agent. Write verdict to cache. Used by `planning-tasks` after AC/EP generation, by `managing-tasks` planning-assisted creation, and by `ingesting-messages` Phase A.5. The latter two run **before the task exists** — see "Deferred-write contract (creation-time callers)" below. |
| `cache-only` | Read the cached verdict. If hash matches and is non-empty, return it. If cache miss or hash mismatch, return verdict=`UNREVIEWED` to the caller; **do not** spawn the Reviewer. Used by `executing-tasks` dispatch and `managing-tasks` pre-Ready (hot paths). |
| `live, cache-aware` | First check cache (hash + suppression). If cache hit and PASS, return it. Otherwise fall through to `live`. Used by `delegating-tasks` (via `assigning-to-others`), `running-daily-tasks` Step 2.6, and `monitoring-tasks --deep`. |

### Deferred-write contract (creation-time callers)

When `live` mode is invoked for a task that has not been created yet (`managing-tasks` planning-assisted creation, `ingesting-messages` Phase A.5), Steps 6's provider writes are impossible. Instead:

- Return the `verdict_string` **and** the rendered findings block (see `references/cache-format.md` § Findings Block Format) to the caller, which holds both in memory and includes them in the eventual create payload (`Quality Verdict` property + `Context` field respectively).
- During a creation-time refine loop (the caller re-plans and re-invokes `live` on revised content), the previous **in-memory** verdict serves as the "existing cached verdict" for the Step 5 suppression check — same-axis failure counting works identically to the persisted path.

## Pipeline

For every invocation:

### Step 1 — Skip-path checks

If the task's `Tags` contain `worthiness:calendar-like` or `worthiness:info-only`:
- Apply **R-AC4 + R-EP5** (no `[DRAFT-AC]` / `[DRAFT-EP]` / `[NEEDS-REFINE]` placeholder in either field) only. All other Rubric rules (R-AC1..R-AC3, R-EP1..R-EP4) are exempt for worthiness-tagged tasks per the protocol Quality Spec.
- If either placeholder rule fails → return verdict = `REJECT` with the failing rule as the gap. The user must remove the placeholder before promoting.
- Otherwise → return verdict = `PASS` (worthiness skip). Do not write a new cache entry; preserve any pre-existing one.

If the task's `Executor` is `human` and the call site is `managing-tasks` pre-Ready: continue to Step 2 normally. (Human tasks must still go through the cache check because they may be delegated later — see plan.)

### Step 2 — Rubric (Layer 1)

Invoke the `validating-fields` skill to evaluate the Rubric on the current `Title|Description|AC|EP`.

- Rubric `REJECT` (`valid: false`): return verdict = `REJECT` with the Rubric errors. **Do not** spawn the Reviewer. Cache the verdict so `monitoring-tasks` can list it.
- Rubric `PASS` with warnings: continue.

### Step 3 — Cache lookup (when mode ≠ `live`)

Compute the content hash: first 8 hex chars of `sha256("${Title}|${Description}|${AC}|${EP}")`.

Read the task's `Quality Verdict` field. Parse using `references/cache-format.md`.

Evaluate in this exact order:

1. **Active suppression takes precedence** — if `suppressed-until` is in the future, return cache hit regardless of hash. The verdict is intentionally frozen for 7 days after two consecutive same-axis failures so the user is not forced into a grinding loop on an inherently vague task.
2. Hash matches AND no active suppression → cache hit, return the cached verdict.
3. Hash mismatch with no active suppression → cache stale, fall through to live evaluation.

When returning a suppressed cache hit on a content-hash mismatch, the response payload sets `suppressed_until` to the cached value so the caller's UI can surface "this verdict is frozen until <date>; rerun manually after that to recompute". Users who want to break out of suppression can clear the `Quality Verdict` field manually in Notion — the next call will see a cache miss and run a fresh Reviewer.

In `cache-only` mode, a cache miss returns verdict = `UNREVIEWED` to the caller. The caller decides how to surface this to the user (typically a 2-choice `[Refine first] [Proceed anyway]` prompt).

**Findings on cache hit:** when the cached verdict is `NEEDS_REFINEMENT` or `REJECT`, also read the task's `Context` field and look for a Quality Review Findings block (format in `references/cache-format.md`). If the block's `hash` equals the cached verdict's hash, parse it and populate `gaps` / `fixes` in the return payload — this is what lets cache-only callers present the gaps and suggested fixes without a live Reviewer call. On hash mismatch (stale findings from an earlier review of different content) or no block, leave `gaps` / `fixes` empty; the caller falls back to verdict-only display.

### Step 4 — Reviewer agent (Layer 2)

Spawn the `task-quality-reviewer-agent` subagent with the task spec block (Title, Description, AC, EP, Context, Working Directory, Repository, Executor).

Before passing `Context`, strip any Quality Review Findings block it contains (this skill's own persisted output from a previous round) — the Reviewer must evaluate the requester's spec, not be steered by its own prior findings.

Wait for its return. Parse the structured output to extract:
- Verdict (`PASS` / `NEEDS_REFINEMENT` / `REJECT` / `INSUFFICIENT_CONTEXT`)
- Per-axis findings
- Specific gaps
- Suggested concrete fixes

Treat `INSUFFICIENT_CONTEXT` as `NEEDS_REFINEMENT` for cache/return purposes; surface the verification gap to the user via the caller.

### Step 5 — Suppression

Before writing the cache entry, check the existing cached verdict. If the previous verdict was also `NEEDS_REFINEMENT` or `REJECT` AND its failing axes overlap with the new failing axes by ≥1 axis, set `suppressed-until` = now + 7 days. This stops the grinding loop on inherently vague tasks.

### Step 6 — Cache write

Write the verdict to the task's `Quality Verdict` field in the format documented in `references/cache-format.md`. Single line, overwrites the previous entry.

**Findings persistence (same write step):** keep the gaps and suggested fixes on the task, not just in chat — they are what the user (or a later session) needs to act on a non-PASS verdict.

- Verdict is `NEEDS_REFINEMENT` or `REJECT` → render a Quality Review Findings block (format in `references/cache-format.md`) from the Reviewer's gaps and fixes (or the Rubric errors when the Reviewer was not spawned) and upsert it into the task's `Context` field: replace any existing findings block, leave the rest of `Context` untouched. At most one block per task.
- Verdict is `PASS` → remove any existing findings block from `Context` (the issues are resolved; stale findings would mislead executors).
- The block carries the same `hash` as the verdict line, so staleness is detectable without extra writes. `Context` is not part of the content hash, so writing the block never invalidates the verdict cache.
- Graceful degradation: if the provider/task has no `Context` field, skip findings persistence — the verdict line still caches; gaps/fixes surface in chat only.
- Creation-time callers: see "Deferred-write contract" above — the block is returned to the caller instead of written.

### Step 7 — Return to caller

Return a structured payload:

```
verdict: PASS | NEEDS_REFINEMENT | REJECT | UNREVIEWED
verdict_string: "<verdict> hash=<8hex> @<iso8601> v1 [suppressed-until=<iso8601>]" | ""
hash: <8-hex>
cached_at: <iso8601>
suppressed_until: <iso8601 | null>
per_axis: { goal: ◯|△|✗, boundary: ◯|△|✗, ... }   # only on live verdicts
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
- **Task lacks Tags field (provider doesn't support)**: skip the worthiness check; proceed with Rubric.
- **Notion 429 rate limit on cache write**: respect Retry-After, then retry once.

## Self-references

This skill uses `${CLAUDE_SKILL_DIR}` for its own bundled files (e.g., scripts under `${CLAUDE_SKILL_DIR}/scripts/...`). It must not reference other skills' internal paths.
