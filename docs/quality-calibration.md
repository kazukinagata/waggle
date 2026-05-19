# Quality Calibration Gate (v2.8.0)

Before shipping the v2.8.0 quality gates to production, **the implementer MUST verify that the new agents agree with human judgment**. This is a Goodhart's Law guardrail — a Reviewer or Worthiness classifier whose verdicts diverge from human expectation will train users to game the heuristic instead of improving their task specs.

This document defines the **calibration gate**: the procedure, the threshold, and the fallback if the gate fails.

## Why a calibration gate

The v2.8.0 quality gates introduce two LLM-based judgments:

1. **`task-quality-reviewer-agent`** (Layer 2 — Intent Reproducibility Check) — judges whether a task spec is reproducible by a stranger.
2. **`ingesting-messages` Phase A worthiness classifier** (Layer 0) — judges whether an incoming message should become a task, a calendar event, or info-only.

Both are LLM judgments. Without measurement, we cannot know whether they:

- Reject good tasks (false negative — frustrating, erodes trust)
- Pass bad tasks (false positive — defeats the gate's purpose)
- Get gamed by users who learn the surface pattern instead of the substance

The calibration gate is the lightweight, repeatable check that catches obvious miscalibration before users encounter it.

## Procedure

### Step 1 — Sample selection (30 tasks)

From the existing production Notion DB, sample **30 tasks** from the most recent 4 weeks of activity. Stratify by status:

- 10 from Ready / In Progress / In Review (active work)
- 10 from Done (recently completed)
- 10 from Backlog (incoming / unprocessed)

Within each stratum, randomize selection. Avoid cherry-picking; you want a representative slice.

### Step 2 — Hand labeling (≥80% target)

For **each** sampled task, the implementer (or a small group — the originating user is ideal) labels it on two questions:

**Q-Reproducibility**: "If you handed this spec to a new colleague who joined the team today, with no other context beyond this task, could they reproduce what you wanted?" → **PASS / NEEDS_REFINEMENT / REJECT**

**Q-Worthiness**: "Should this even be a task? Or is it a calendar event, an informational note, or something that should be discarded?" → **task / calendar-like / info-only**

Aim for a roughly even split: ~15 good (PASS / task) and ~15 bad (NEEDS_REFINEMENT or REJECT / calendar-like or info-only). If the natural sample is too skewed, augment by picking known bad/good examples until you reach 15 + 15.

Record labels in `docs/calibration-labels.csv` (gitignored — these are about your real tasks):

```csv
task_id,title_excerpt,human_reproducibility,human_worthiness
abc123,Update README to mention v2.8.0,PASS,task
def456,MTG参加,REJECT,calendar-like
...
```

### Step 3 — Run the agents

For each sampled task:

1. Invoke `reviewing-quality` (which spawns `task-quality-reviewer-agent`) → get the Reviewer verdict.
2. Invoke the `ingesting-messages` Phase A classifier (in a dry-run mode) on the task's original source message if available, OR run the worthiness classifier as a stand-alone judgment on the Title + Description → get the worthiness verdict.

Record agent verdicts alongside human labels.

### Step 4 — Agreement measurement

Compute two agreement rates.

**Counting rule for "implicit agreement":** the implementer (the human labeler) MAY mark a task as 論外 / `not_gradable` instead of giving an explicit `agree` / `disagree` label, when the task is so obviously deficient that there is nothing to evaluate. In that case:

- If the Reviewer (or worthiness classifier) issued `REJECT` (resp. `info-only` / `calendar-like`), the task counts as an **implicit agreement** (the agent independently arrived at the same dismissal).
- If the Reviewer issued anything else, the task counts as **unrated** and is excluded from both numerator and denominator.

This rule prevents the implementer's "obviously bad, why grade?" intuition from being penalized by the strict denominator. It is **not** a free agreement — it only applies when the agent's verdict matches the dismissal direction.

Then:

**Reviewer agreement** = (explicit agree + implicit agree) / (30 − truly unrated)

**Worthiness agreement** = (explicit agree + implicit agree) / (30 − truly unrated)

Report both the strict denominator (÷30) and the rated denominator (÷(30 − truly_unrated)) in the results doc for transparency. The rated denominator is the canonical figure for the gate decision.

For partial credit on Reviewer: treat `NEEDS_REFINEMENT` and `REJECT` as collapsed into "not-PASS" if you'd like a binary agreement. The strict 3-way agreement is the canonical bar.

### Step 5 — Gate decision

**Pass threshold: ≥80% agreement on EACH dimension** (using the rated denominator from Step 4).

- **Both ≥80%** → ship the full v2.8.0 release.
- **One <80%** → ship with the failing component DISABLED (see Fallback below). The other component ships.
- **Both <80%** → do not ship the v2.8.0 LLM gates. Ship Rubric-only (Layer 1) and the placeholder + cache infrastructure; defer Layer 0 and Layer 2 to a later release after agent prompt tuning.

### Step 5a — Calibration deferral (Layer 0 only)

The Layer 0 worthiness classifier MAY ship without calibration when **all of** the following safeguards hold:

1. **No silent discard.** The worthiness verdict surfaces in a user-confirmation UI that defaults to a safe action (`Skip`, never `Discard`).
2. **No synchronous gating.** The verdict does not block dispatch, delegation, or any other hot-path flow. It is advisory only.
3. **Recoverable.** A misclassified task can be corrected by the user removing the `worthiness:*` tag, without any data loss.
4. **Follow-up commitment.** A subsequent minor release (e.g., v2.8.1) is scheduled to run the calibration and either confirm or apply the relevant fallback.

If all four safeguards hold, the calibration may be deferred. The deferral and the safeguard rationale MUST be documented in `docs/calibration-results.md`. This deferral path is **not** available for the Reviewer (Layer 2) because Layer 2 gates dispatch readiness and the delegation flow synchronously and cannot ship un-calibrated.

### Step 6 — Record results

Commit a sanitized summary (no task content) to `docs/calibration-results.md`:

```markdown
# Calibration Results — v2.8.0 (YYYY-MM-DD)

- Sample: 30 tasks (10 active, 10 Done, 10 Backlog)
- Reviewer agreement: 26/30 = 86.7% ✅
- Worthiness agreement: 24/30 = 80% ✅
- Decision: Ship full v2.8.0.

Confusion matrix:
| | Agent PASS | Agent NEEDS_REFINEMENT | Agent REJECT |
|---|---|---|---|
| Human PASS | 14 | 1 | 0 |
| Human NEEDS_REFINEMENT | 1 | 4 | 1 |
| Human REJECT | 0 | 1 | 8 |
```

## Fallback configurations

If the gate fails, ship the v2.8.0 release with the affected components disabled.

### Fallback A: Reviewer disabled

If Reviewer agreement <80%:

- Skip Step 4 (Reviewer agent spawn) inside `reviewing-quality`. All invocations return verdict = `UNREVIEWED` after Rubric pass.
- `planning-tasks` Quality Gate degrades to Rubric-only.
- `ingesting-messages` Phase A.5 only runs the Rubric.
- `running-daily-tasks` Step 2.6 falls back to Rubric-only debt enumeration.
- `monitoring-tasks --deep` becomes a no-op (or a notice: "Reviewer is disabled in this release. See calibration results.").
- Document the disable in `CHANGELOG.md` for v2.8.0.

### Fallback B: Worthiness classifier disabled

If Worthiness agreement <80%:

- `ingesting-messages` Phase A returns `worthiness=task` for every message (no Layer 0 classification).
- The 3-way Phase B confirmation prompt is suppressed for worthiness-flagged items (since none are flagged).
- `monitoring-tasks` LIKELY_NON_TASK category continues to work (it's a deterministic title regex, not the classifier).
- Document the disable in `CHANGELOG.md`.

### Fallback C: Both disabled

If both <80%:

- Ship Layer 1 (Rubric) + placeholder spec + Quality Verdict cache infrastructure. The cache will be empty for now; it remains useful as a hook for future versions.
- All other LLM-based steps are no-ops.
- Plan a v2.8.1 with prompt-tuned agents and re-run calibration.

## When to re-calibrate

Re-run the gate (small sample, ~15 tasks) whenever:

- The Reviewer agent prompt is materially changed in `agents/task-quality-reviewer-agent.md`.
- The classification heuristics in `skills/ingesting-messages/references/classification-guide.md` are updated.
- A user reports systematic false rejections / false positives in the live system.

Calibration is cheap (an hour of human labeling + the LLM runs). It is much cheaper than rolling back a bad release.

## Related

- Protocol spec: `skills/waggle-protocol/SKILL.md` § Calibration Requirement
- Reviewer agent: `agents/task-quality-reviewer-agent.md`
- Worthiness classifier: `skills/ingesting-messages/references/classification-guide.md`
