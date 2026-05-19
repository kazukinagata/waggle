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

1. **Reviewer prompt tweak**: tighten Goal clarity (require key terms to be defined or referenced explicitly), and add a "request-time vs execute-time" boundary so the Reviewer stops asking requesters to specify branch names and shell commands. **Status: addressed in v2.8.2 (see below)**.
2. **Worthiness classifier calibration**: 30 labeled tasks, ≥80% agreement.
3. **Re-run Reviewer calibration** after the prompt tweak to confirm the disagree pattern is gone.

---

# v2.8.2 prompt-tuning sanity check

## Scope

The v2.8.2 release ships a behavioral tweak to `agents/task-quality-reviewer-agent.md`. Three changes target the two failure patterns observed in v2.8.0 calibration:

1. Mandatory Step 3 **Goal-clarity definition test** — the Reviewer must enumerate every proper noun / brand / store / project name / internal jargon term in the goal sentence and explicitly answer "What is &lt;term&gt;?" from the spec. Binary scoring: any failure → ✗.
2. New Step 5 **Request-time vs execute-time boundary** — execute-time details (branch names, exact code edits, preview-URL syntax) MUST NOT down-score Verifiability or Reproducibility.
3. Rules section additions: "Don't ask the requester for the executor's homework"; "Undefined domain nouns are Goal-clarity failures, not Hidden-context warnings."

A full 30-task re-run is **not** included in v2.8.2; we limited the sanity check to the two known v2.8.0 disagreement cases to validate the targeted fixes without paying the full Reviewer cost again.

## Sanity-check results

Both disagreement cases were re-run against the v2.8.2 prompt:

| Case | v2.8.0 verdict | v2.8.2 verdict | Expected | Match? |
|---|---|---|---|---|
| A — undefined domain nouns in the goal | NEEDS_REFINEMENT | **REJECT** | REJECT | ✅ Resolved |
| B — AC mixes Pre-requirements + design + implementation | NEEDS_REFINEMENT | NEEDS_REFINEMENT | REJECT | ❌ Unchanged |

**Net: 1 of 2 known disagreements resolved.**

### Case A: undefined domain nouns

The strengthened Step 3 definition test produced exactly the intended behavior. The Reviewer enumerated the goal-sentence terms, applied "What is &lt;term&gt;?" mechanically, and identified multiple terms (a campaign name and two collection names) as undefined from the spec alone. Goal clarity correctly fell to ✗, dragging the verdict to REJECT. No rationalizing from context. This is the failure mode v2.8.2 targeted, and it is closed.

### Case B: AC composition / task-granularity

The v2.8.2 prompt did **not** change this verdict, and a careful read of the Reviewer's reasoning explains why:

- The Reviewer was answering the question "can a new colleague reproduce this?" and concluded "yes, after one pre-task confirmation with the requester."
- The implementer's REJECT reasoning was on a different question: "is this AC well-formed as an AC?" — pointing at:
  - Pre-requirements masquerading as completion criteria ("対象商品のリスト共有" — that's a prerequisite, not a done-signal).
  - Implementation and design conflated in one task; the design / risk-analysis step ("想定外の副作用について依頼者に懸念点をシェア済み") should be its own predecessor task.

This is a **task-granularity / AC-composition** failure, which is genuinely distinct from intent-reproducibility. The current 5 axes (Goal clarity, Boundary clarity, Verifiability, Reproducibility, Hidden context) all answer "can this be reproduced?" — none of them ask "is the AC a well-formed AC?" or "is the task at the right granularity?". The Reviewer is consistent with its remit; the gap is in the axis set, not the prompt wording.

We chose to ship v2.8.2 without a Case B fix because:
- The behavioral improvement on Case A is real and confined; bundling a structural axis change would dilute the release.
- A task-granularity axis is a non-trivial design decision (where does Boundary clarity end and AC composition begin?) that deserves its own deliberation.
- Calibration agreement remains ≥80% even counting Case B as disagreement (26/28 = 92.9% rated, accepting Case A is now agree-by-fix → 27/28 = 96.4% rated).

## Follow-ups (v2.8.3+)

1. **Task-granularity axis** — introduce a sixth axis or strengthen Boundary clarity so that ACs which conflate Pre-requirements, design outputs, and implementation completion criteria are flagged. Case B is the canonical test case.
2. **Full 30-task re-run** against the v2.8.3 prompt to confirm both v2.8.0 disagreements (Case A and Case B) are resolved without introducing new false positives elsewhere.
3. **Worthiness classifier calibration** (originally a v2.8.1 follow-up) — still pending; the Step 5a deferral in `docs/quality-calibration.md` continues to apply.
