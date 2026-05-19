# Quality Rubric (Layer 1, v2.8.0+)

Deterministic rules applied at every status transition into Ready or beyond. No LLM involvement; this is a fast pre-filter that catches obvious failures before any expensive Reviewer call.

This document is the canonical rubric definition. The `task-quality-reviewer-agent` (Layer 2) is the canonical owner of the 5 IRC axes; both layers are referenced by `reviewing-quality`, `monitoring-tasks`, `planning-tasks`, `running-daily-tasks`, and the protocol spec.

## AC Rubric

Each AC criterion (bullet or numbered item) is scored against four rules.

### R-AC1 — Verifiable indicator

The criterion text MUST contain ≥1 of:

- **Command**: `npm`, `git`, `curl`, `bash`, `python`, `node`, `gh`, `shopify`, `bq`, `make`, `cargo`, `go`, `mvn`, `gradle`, `pytest`, `vitest`, `jest`, `playwright`, `cypress`, `kubectl`, `docker`
- **File path / extension**: contains `/` or matches `\.(ts|tsx|js|jsx|md|sql|json|yaml|yml|sh|py|liquid|css|html|svg|png|jpe?g|pdf|xlsx?|csv|toml|env|lock|dockerfile)\b`
- **Numeric threshold + unit**: digits followed by `%`, `ms`, `s`, `分`, `時間`, `日`, `週間`, `月`, `年`, `件`, `個`, `回`, `本`, `KB`, `MB`, `GB`, `count`, `items`, `times`, `lines`
- **Observable verb**: returns / displays / contains / generates / sends / receives / confirms / records / updates / passes / fails / exists / matches / equals / shows
- **URL**: starts with `http://` or `https://`
- **Code token**: backtick-quoted identifier, `CONST_NAME` ALL_CAPS_WITH_UNDERSCORE, or namespaced symbol like `module.function`

If ≥2 criteria fail this rule → **error**. If 1 criterion fails → **warning**.

### R-AC2 — Not an echo-of-title

A criterion is an "echo-of-title" if it merely restates the Title with a verb-form suffix like "〜が完成している" / "〜できている" / "is implemented" / "is done", without adding new specifics.

Heuristic: lowercase the Title and the criterion; drop common verb-form suffixes; if the remainder of the criterion ⊆ Title (≥80% token overlap), flag.

If **all** criteria are echo-of-title → **error**. If half are echo-of-title → **warning**.

### R-AC3 — Grounding

Each criterion SHOULD either:
- Reference a keyword, entity, file path, or value present in the Description / Context / source message, OR
- Be explicitly prefixed `[INFERRED]` (preserves audit trail that this is a speculative addition).

Ungrounded, non-`[INFERRED]` criteria → **warning** (not error — sometimes legitimate).

### R-AC4 — No reserved placeholder remaining

The criterion text MUST NOT contain `[DRAFT-AC]` or `[NEEDS-REFINE]` if the target status is Ready or beyond. These placeholders signal incomplete work.

Presence at Ready transition → **error**.

## EP Rubric

The EP is scored holistically against five rules (R-EP1..R-EP5).

### R-EP1 — Step count

Count numbered steps (lines matching `^\s*\d+\.`). MUST be in `[3, 7]`.

- `<3`: too thin → **error**
- `4..7`: ok
- `>7`: suggest split → **warning** + recommend `managing-tasks` subtask decomposition

### R-EP2 — Step richness

For each step:
- Average line length ≥30 characters (excluding leading number)
- Contains an action verb + target (heuristic: matches one of `[実装|作成|追加|修正|更新|削除|確認|検証|テスト|デプロイ|run|build|test|verify|implement|update|add|fix|create|deploy|migrate]` AND at least one noun-like token)

If average step length <25 chars OR no step contains a target → **error**. If average is 25..30 → **warning**.

### R-EP3 — Concrete artifact

The EP overall MUST contain ≥1:
- File path or directory
- Shell command (in backticks or with recognizable prefix)
- Branch name (`feature/...`, `fix/...`, etc.)
- URL
- PR number (`#123`)
- DB query keyword (`SELECT`, `INSERT`, `UPDATE`, `DELETE`)

Missing → **warning** (some non-code tasks legitimately have no concrete artifact).

### R-EP4 — Working Directory alignment

When `Executor` ∈ {cli, claude-code, claude-desktop, cowork} (the AI executor set — `cli / claude-desktop / cowork` are the canonical protocol enum values; `claude-code` is a known extension value present in production provider schemas):
- `Working Directory` MUST be non-empty
- If the EP references file paths, at least one should be consistent with `Working Directory` (heuristic: path starts with `Working Directory` or is a relative path)

Mismatch with AI executor → **error**.

### R-EP5 — No EP placeholder remaining (v2.8.0)

The EP text MUST NOT contain `[DRAFT-EP]` or `[NEEDS-REFINE]` if the target status is Ready or beyond. Mirror of R-AC4 for the EP field. A task with `[DRAFT-EP]` followed by 3 real-looking steps would otherwise pass R-EP1..R-EP3 and slip through.

Presence at Ready transition → **error**.

## Verdict composition

`validate_for_ready(task)` returns:

```json
{
  "valid": true|false,
  "target_status": "Ready",
  "errors": [{ "rule": "R-AC1", "message": "..." }, ...],
  "warnings": [{ "rule": "R-AC3", "message": "..." }, ...]
}
```

- Any **error** sets `valid: false` and blocks the transition.
- **Warnings** do not block but are surfaced to the user.

## `find_quality_debt(tasks)`

Given a list of Ready+ tasks, returns each task that fails the Rubric, categorized by which rule(s) failed. Used by `monitoring-tasks` and `running-daily-tasks` Step 2.6.

```json
{
  "EMPTY_AC_READY_PLUS": ["task_id_1", ...],
  "EMPTY_EP_READY_PLUS": [...],
  "SHALLOW_AC": [...],            // R-AC1 + R-AC2 fail
  "SHALLOW_EP_STEPS": [...],      // R-EP1 + R-EP2 fail
  "MISSING_CONCRETE_ARTIFACT_EP": [...],  // R-EP3 fail
  "DRAFT_AC_PRESENT": [...],      // R-AC4 fail
  "DRAFT_EP_PRESENT": [...],      // R-EP5 fail
  "LIKELY_NON_TASK": [...]        // title regex match + 1-line desc + empty AC/EP
}
```

## Worthiness tag skip

Tasks with `Tags` containing `worthiness:calendar-like` or `worthiness:info-only` are exempt from Rubric R-AC1..R-AC3 and R-EP1..R-EP4 at Ready transitions — they have explicitly been classified by the user as non-task or non-actionable, and the Reviewer (Layer 2) is also skipped for them per the protocol Quality Spec.

**R-AC4 and R-EP5 still apply** to worthiness-tagged tasks: a worthiness-tagged task with `[DRAFT-AC]` / `[DRAFT-EP]` / `[NEEDS-REFINE]` placeholder in either field cannot be promoted to Ready until the user removes the placeholder. This prevents accidentally promoting a never-refined worthiness-tagged stub.
