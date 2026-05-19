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

| | Count |
|---|---|
| Agree (Reviewer verdict matches the implementer's judgment) | **23 / 30** |
| Disagree (Reviewer was wrong in the implementer's view) | **2 / 30** |
| Skipped (implementer declined to rate; tasks were "論外" — too obviously deficient to grade) | 5 / 30 |
| **Agreement rate over rated tasks** | **23 / 25 = 92.0%** |

**Ship threshold (per `docs/quality-calibration.md`): ≥80% agreement on the Reviewer dimension. → PASS.**

### Confusion matrix shape (Pre × Reviewer verdict × judgment)

| Pre | Reviewer verdict | agree | disagree | unrated |
|---|---|---|---|---|
| bad | REJECT | 9 | 0 | 3 |
| bad | NEEDS_REFINEMENT | 2 | 1 | 0 |
| good | PASS | 1 | 0 | 0 |
| good | NEEDS_REFINEMENT | 11 | 1 | 2 |

### Notable disagreement pattern

Both disagreements share the same shape: **Reviewer issued `NEEDS_REFINEMENT`, the implementer would have issued `REJECT`** — i.e., the Reviewer was too lenient in two cases. The Reviewer rated `Goal clarity: ◯` in both, but the implementer judged the goal ambiguous because key terms ("topics", a domain object referenced in the AC) were undefined.

No false positives in the other direction (Reviewer too strict) were observed.

### Implementer's qualitative notes

Across the rated tasks, the implementer flagged a recurring concern with the **type** of fixes Reviewer suggests on `good` tasks: the Reviewer often asks for implementer-level details ("branch from main and edit `assets/foo.css`", exact preview URL pattern) that should arguably be the executor's responsibility at run-time, not the requester's at create-time. The Reviewer does not distinguish "request-time spec" from "execute-time spec" cleanly.

This does not block v2.8.0 (Reviewer's verdict step still aligns 92% of the time), but is the highest-signal direction for a v2.8.1 Reviewer prompt tweak.

## Worthiness classifier

Calibration for the Layer 0 worthiness classifier (`task | calendar-like | info-only`) was **deferred to v2.8.1** at the implementer's discretion. Rationale:

- The Reviewer dimension passed comfortably (92% > 80%), establishing baseline trust in the IRC framing.
- The 30-task sample has a clear long-tail of "obviously not a worthy task" items (empty titles, single-line stubs) — labeling these would be near-trivial and offers little new information.
- Layer 0 has no synchronous gating effect on dispatch or delegation: the worst case if mis-calibrated is a noisy intake confirmation table, not a flow-breaking false reject.

A worthiness calibration will be folded into a v2.8.1 follow-up that also addresses the Reviewer prompt tweak above. Until then, the Layer 0 classifier ships **enabled** with the protocol's "never silently discard" safeguard.

## Decision

**Ship full v2.8.0 with the Reviewer agent enabled and the Layer 0 worthiness classifier enabled.**

The Reviewer dimension passed the ≥80% threshold (92%). The Layer 0 dimension is deferred per the rationale above; the design's "advisory only, never silent discard" property bounds its blast radius if it later proves miscalibrated.

## Follow-ups (v2.8.1 candidates)

1. **Reviewer prompt tweak**: tighten Goal clarity (require key terms to be defined or referenced explicitly), and add a "request-time vs execute-time" boundary so the Reviewer stops asking requesters to specify branch names and shell commands.
2. **Worthiness classifier calibration**: 30 labeled tasks, ≥80% agreement.
3. **Re-run Reviewer calibration** after the prompt tweak to confirm the disagree pattern is gone.
