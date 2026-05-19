# Calibration Results — v2.8.0

Per `docs/quality-calibration.md`, this document records the outcome of the v2.8.0 ship-blocker calibration. Per the spec, **no task content is reproduced here** — only aggregate numbers, the confusion matrix shape, and the ship decision.

## Run metadata

- Date: 2026-05-19
- Sample size: 30 tasks (stratified across Backlog / Ready / In Progress / In Review / Done; both human and AI executor)
- Pre-classification: 15 "bad" + 15 "good" by a heuristic completeness score (Description / AC / EP length, EP step structure, verifiable indicator detection)
- Reviewer agent: `task-quality-reviewer-agent` (model: `claude-sonnet-4-6`, maxTurns: 4)
- Worthiness classifier: **calibration deferred to v2.8.1** — see "Worthiness classifier" section below

## Reviewer agreement

Reviewer was run once per task, returning `PASS` / `NEEDS_REFINEMENT` / `REJECT`. The implementer then judged each verdict against their own sense of whether a new colleague could reproduce the task's intent.

Per `docs/quality-calibration.md` Step 4, the implementer may mark a task as 論外 / `not_gradable`. When the Reviewer issued `REJECT` on such a task, the task counts as an **implicit agreement** (the agent independently arrived at the same dismissal). Otherwise it counts as truly unrated.

| | Count | Notes |
|---|---|---|
| Explicit agree | 23 / 30 | Reviewer verdict matches the implementer's explicit judgment |
| Explicit disagree | 2 / 30 | Reviewer wrong in the implementer's view |
| Implicit agree (論外 + Reviewer REJECT) | 3 / 30 | Implementer marked "論外", Reviewer also REJECT |
| Truly unrated (no judgment, no 論外 mark) | 2 / 30 | Excluded from gate calculation |
| Total agree (explicit + implicit) | **26 / 30** | |

**Agreement rates:**

- **Rated denominator (canonical for the gate):** 26 / 28 = **92.9%** ✅
- Strict denominator (÷ 30 for transparency): 26 / 30 = 86.7% ✅

**Ship threshold (per `docs/quality-calibration.md` Step 5): ≥80% on the rated denominator. → PASS.**

### Confusion matrix shape (Pre × Reviewer verdict × judgment)

| Pre | Reviewer verdict | explicit agree | implicit agree (論外) | disagree | truly unrated |
|---|---|---|---|---|---|
| bad | REJECT | 9 | 3 | 0 | 0 |
| bad | NEEDS_REFINEMENT | 2 | 0 | 1 | 0 |
| good | PASS | 1 | 0 | 0 | 0 |
| good | NEEDS_REFINEMENT | 11 | 0 | 1 | 2 |

### Notable disagreement pattern

Both disagreements share the same shape: **Reviewer issued `NEEDS_REFINEMENT`, the implementer would have issued `REJECT`** — i.e., the Reviewer was too lenient in two cases. The Reviewer rated `Goal clarity: ◯` in both, but the implementer judged the goal ambiguous because key terms ("topics", a domain object referenced in the AC) were undefined.

No false positives in the other direction (Reviewer too strict) were observed.

### Implementer's qualitative notes

Across the rated tasks, the implementer flagged a recurring concern with the **type** of fixes Reviewer suggests on `good` tasks: the Reviewer often asks for implementer-level details ("branch from main and edit `assets/foo.css`", exact preview URL pattern) that should arguably be the executor's responsibility at run-time, not the requester's at create-time. The Reviewer does not distinguish "request-time spec" from "execute-time spec" cleanly.

This does not block v2.8.0 (Reviewer's verdict step still aligns 92% of the time), but is the highest-signal direction for a v2.8.1 Reviewer prompt tweak.

## Worthiness classifier

Calibration for the Layer 0 worthiness classifier (`task | calendar-like | info-only`) is **deferred to v2.8.1** under `docs/quality-calibration.md` Step 5a (Calibration deferral, Layer 0 only). All four required safeguards hold:

1. **No silent discard.** Worthiness verdicts surface in `ingesting-messages` Phase B with a 3-button row (`[Create as task]` / `[Convert to note]` / `[Discard]`), default = `Skip`. The user always sees the verdict before any action is taken.
2. **No synchronous gating.** The worthiness tag is advisory; it never blocks dispatch, delegation, or any hot-path flow. `reviewing-quality` skips Layer 2 for tagged tasks but does not reject them; downstream skills treat them like any other task minus the Reviewer cost.
3. **Recoverable.** A user who disagrees with a `worthiness:*` tag removes the tag from the Notion task; subsequent transitions then run through the full Rubric + Reviewer pipeline as normal. No data loss.
4. **Follow-up commitment.** A v2.8.1 follow-up will run the worthiness calibration alongside the Reviewer prompt tweak; see "Follow-ups" below.

Until v2.8.1, Layer 0 ships **enabled** under the deferral.

## Decision

**Ship full v2.8.0 with the Reviewer agent enabled and the Layer 0 worthiness classifier enabled.**

The Reviewer dimension passed the ≥80% threshold (92.9% on the rated denominator, 86.7% on the strict ÷ 30 denominator — both above 80%). The Layer 0 dimension is deferred under the Step 5a deferral, with all four safeguards satisfied as documented above.

## Follow-ups (v2.8.1 candidates)

1. **Reviewer prompt tweak**: tighten Goal clarity (require key terms to be defined or referenced explicitly), and add a "request-time vs execute-time" boundary so the Reviewer stops asking requesters to specify branch names and shell commands.
2. **Worthiness classifier calibration**: 30 labeled tasks, ≥80% agreement.
3. **Re-run Reviewer calibration** after the prompt tweak to confirm the disagree pattern is gone.
