---
name: waggle-protocol
description: >
  Waggle Protocol v1 specification. Defines the 15 core fields, 9 extended
  fields, task state machine, dispatch readiness checks, and execution
  environments. Use this skill when you need to understand the waggle
  protocol, check field definitions, or verify state transitions. Trigger on:
  "protocol spec", "waggle spec", "field definitions", "state machine",
  "task schema", "core fields".
user-invocable: true
---

# Waggle Protocol v1

## Overview

Waggle Protocol is a specification for independent AI agent instances to coordinate asynchronously through a shared task board.

Agents discover tasks, claim them, execute, and hand off results. The backing data store is irrelevant — any storage that implements this specification's fields and state transitions is a Waggle-compatible task board.

## Core Fields

Every Waggle-compatible task board MUST support these 16 fields:

| Field | Type | Description |
|---|---|---|
| Title | text | Task name |
| Description | rich_text | What the task should accomplish |
| Acceptance Criteria | rich_text | Verifiable completion conditions |
| Status | enum | See State Machine below |
| Priority | enum | Urgent / High / Medium / Low |
| Executor | enum | cli / claude-desktop / cowork / human (extensible) |
| Blocked By | relation[] | Dependencies — other task IDs that must be Done before this task is actionable |
| Requires Review | boolean | If true, task must pass In Review before Done |
| Execution Plan | rich_text | Step-by-step plan written before dispatch. Write-once |
| Working Directory | text | Absolute path for agent execution |
| Session Reference | text | Runtime session identifier (tmux session name, Scheduled Task ID, etc.) |
| Dispatched At | datetime | Timestamp when the task was dispatched |
| Agent Output | rich_text | Execution result written by the agent on completion |
| Error Message | rich_text | Written on failure only |
| Issuer | provider-managed | Who created/initiated this task. **Auto-populated by the active provider on create. Read-only after creation. Skills MUST NOT include Issuer in create payloads.** See "Issuer Auto-Populate Contract" below. v2.8.1+ |
| Quality Verdict | rich_text | Cached Reviewer verdict (PASS/NEEDS_REFINEMENT/REJECT). See Quality Spec below. v2.8.0+ |

### Extended Fields (optional)

Providers MAY support these additional fields. Skills degrade gracefully if absent.

| Field | Type | Description |
|---|---|---|
| Context | rich_text | Background info, constraints, delegation history. May carry a managed Quality Review Findings block (see Quality Spec § Findings Persistence) |
| Artifacts | rich_text | PR URLs, file paths (newline-separated) |
| Repository | url | GitHub repository URL |
| Start Date | date | ISO 8601 format. Planned work start |
| Due Date | date | ISO 8601 format |
| Tags | multi_select | Free-form tags |
| Parent Task | relation | Parent task ID (subtask relationship) |
| Project | text | Project grouping |
| Team | text | Team assignment |
| Assignee | person[] | Assigned users |
| Attachments | file[] | Files attached as task data. Array of file descriptors `{url, name, mime_type?, size?}` — references to hosted bytes, not the bytes. Hosting is per-provider (`supportsFileHosting`); see provider-contract task-schema § Provider Mapping. v2.13.0+ |

## Issuer Auto-Populate Contract (v2.8.1+)

The `Issuer` core field is **always** populated by the active provider during task creation. Skills (`managing-tasks`, `ingesting-messages`, etc.) MUST NOT pass an Issuer value when invoking the provider's Create Task operation.

### Why

Prior to v2.8.1, skills explicitly set `Issuer = current_user`. Field telemetry showed ~27% of tasks ended up with empty Issuer due to multiple failure paths: scheduled tasks where `current_user` could not be resolved, third-party automations writing directly to the data store, intake flows omitting Issuer in the create payload, and direct edits in the provider UI. Centralizing Issuer population in each provider eliminates every one of those paths.

### Per-provider implementation

| Provider | Mechanism |
|---|---|
| **Notion** | `Issuer` column is type `created_by`. Notion auto-populates with the API token's owning user on insert. Read-only via API. |
| **SQLite** | `Issuer` column is `TEXT`. The provider's Create Task INSERT template substitutes `${current_user.id}` literally; the caller invokes the template without supplying Issuer. |
| **Turso** | Same as SQLite. |

### Provider preconditions

Providers using template substitution (SQLite, Turso) MUST halt with an error before executing Create Task if `current_user.id` resolves to the unresolved-identity sentinel `"unknown"`. This enforces "no anonymous tasks" — every Issuer in the data store points to a real identity. (v2.7.x also halted on the literal `"local"`; v2.8.1 removed `"local"` from the identity chain entirely — providers now derive `id` from `$WAGGLE_USER_ID` → `$USER` → `"unknown"`, so the only remaining anonymous case is `"unknown"`.)

The Notion provider does not need this check because Notion's API binds `created_by` to the API token owner, which is always a real user.

### Write-once enforcement

Notion's `created_by` is read-only after creation. SQLite/Turso providers MUST NOT include `issuer` in their Update Task templates. Delegation (`assigning-to-others` / `delegating-tasks`) updates `Assignee` but never touches `Issuer`.

### Filtering by Issuer

Notion's API filters `created_by` columns using the `created_by:{contains: <user_id>}` operator (this is distinct from the `people` operator used for `person` columns — the operator key matches the column type). The notion-provider filter recipes in v2.8.1 use this syntax.

SQLite/Turso providers filter via `WHERE issuer = '<user_id>'` for exact match (the column is now a single-value `TEXT`, not a JSON array, so the v2.7.x `LIKE '%<user_id>%'` pattern is unnecessary).

## Subtask Hierarchy

Waggle supports a strict 2-level task hierarchy via the `Parent Task` field.

### Constraints

- **2-level limit**: A subtask (task with non-null `parentTask`) MUST NOT have children of its own. Implementations MUST reject attempts to create a 3rd level.
- **No circular references**: A task cannot reference itself as its parent.

### Auto-Cascading Transitions

When all subtasks of a parent reach `Done`, the parent auto-transitions to `Done`. When a subtask is added to or re-opened on a `Done` parent, the parent reverts to `In Progress`. These are system-initiated transitions that bypass normal validation.

### Execution Independence

Subtasks are eligible for execution regardless of their parent task's status. The hierarchy is for progress tracking, not execution gating.

## State Machine

```
Backlog → Ready → In Progress → In Review → Done
                       ↓
                    Blocked

Any → Cancelled
```

### Transition Conditions

| From | To | Condition |
|---|---|---|
| Backlog | Ready | Description, Acceptance Criteria, Assignee, and Execution Plan are all non-empty AND Rubric (Layer 1) passes AND Quality Verdict cache satisfies dispatch readiness (see Dispatch Readiness Check + Quality Spec below) |
| Ready | In Progress | Executor is assigned. Dispatched At is recorded. Dispatch Readiness Check passes |
| In Progress | In Review | Requires Review = true. Agent Output is recorded |
| In Progress | Done | Requires Review = false. Agent Output is recorded |
| In Progress | Blocked | Error occurred or dependency unresolved. Error Message is recorded |
| In Review | Done | Review approved |
| In Review | In Progress | Changes requested |
| Any | Backlog | Deprioritize / re-triage |
| Any | Cancelled | Task abandoned or no longer relevant |

### Invalid Transitions

All transitions not listed above are invalid. Implementations MUST reject them.

## Dispatch Readiness Check

Before transitioning a task from Ready → In Progress, the orchestrator MUST verify:

| Field | Check |
|---|---|
| Description | Non-empty, at least ~50 tokens |
| Acceptance Criteria | Non-empty, no reserved placeholder remaining |
| Execution Plan | Non-empty, no reserved placeholder remaining |
| Working Directory | Non-empty AND the directory exists on the filesystem |
| Quality Verdict (v2.8.0+) | Cache PASS preferred; cache miss / fail surfaces 2-choice prompt. Live Reviewer invocation is forbidden at dispatch (hot path) |

If any check fails, the orchestrator MUST NOT dispatch. Instead, it should prompt the user to fill the missing information.

## Quality Spec (v2.8.0+)

Waggle v2.8.0 introduces a 3-layer quality gate system to ensure agent-reproducible task specs.

### Layer 0: Task-Worthiness Advisory

Applied at intake (`ingesting-messages` Phase A) only. Classifies whether an incoming item is task-shaped.

| Verdict | Meaning |
|---|---|
| `task` | Actionable work; proceeds to Layer 1/2 |
| `calendar-like` | Recurring meeting / pure attendance; should not be a task. Advisory only |
| `info-only` | FYI / handled / single-fact message; should not be a task. Advisory only |

**Waggle never silently discards user-created items.** Layer 0 surfaces a suggestion in the intake confirmation table; the user always has the final say via `[Create as task] / [Convert to note] / [Discard]`. Items chosen as `[Create as task]` are tagged `worthiness:calendar-like` or `worthiness:info-only` and skip Layer 1/2 for the rest of their lifecycle.

### Layer 1: Structural checks (deterministic)

Applied at every status transition into Ready or beyond. No LLM involvement. Layer 1 checks only what a script can decide exactly and language-independently; it makes **no judgment about the meaning** of AC/EP text — semantic quality belongs entirely to Layer 2.

| Check | Rule |
|---|---|
| Description | Non-empty; ≥50 characters at Ready+ |
| Acceptance Criteria | Non-empty; no reserved placeholder (`[DRAFT-AC]` / `[DRAFT-EP]` / `[NEEDS-REFINE]` / `[INFERRED]`) remaining |
| Execution Plan | Non-empty; no reserved placeholder remaining |
| Quality Verdict | When supplied, well-formed per the cache format below; must be `PASS` for Ready+, and format `v2` at Ready (`v1` still accepted at In Progress and beyond during the migration window) |
| Executor / Working Directory | Executor set at In Progress; Working Directory set for AI executors (cli / claude-code / claude-desktop / cowork) |

> **v3.0.0 breaking change**: v2.8.x defined semantic rules at this layer (R-AC1–R-AC3, R-EP1–R-EP4: verifiable-indicator keyword lists, echo-of-title detection, step-count/step-richness thresholds, concrete-artifact detection). They were removed. Keyword heuristics cannot judge semantics language-independently — the shipped check hard-rejected well-specified non-English ACs while passing vague English prose — and every axis those rules approximated is evaluated by Layer 2. Implementations MUST NOT gate status transitions on semantic keyword heuristics.

### Layer 2: Intent Reproducibility Check (LLM)

The `task-quality-reviewer-agent` evaluates a task spec along 6 axes from the perspective of "a new colleague handed only this spec, with access to the team's tools — can they reproduce the issuer's intent?":

| Axis | Question |
|---|---|
| Goal clarity | Can the desired end state be described in one sentence after reading? |
| Boundary clarity | Is scope clear; where does the task stop? |
| Verifiability | How do I know I'm done? Is there a checkable signal? |
| Reproducibility | Are tools/paths/commands/datasets named? |
| Hidden context | Is there organizational knowledge the issuer assumed but didn't write down? |
| Fidelity | Is every statement in the spec traceable to the request it claims to serve? |

> **v4.0.0 breaking change**: Fidelity is new, and `PASS` now means all **six** axes.
> The first five all measure clarity, so a clearly written fabrication passed every
> one of them — which is what shipped a task naming a feature that does not exist and
> a person from an unrelated case. Fidelity asks whether the AC/EP contradict the
> original request, title, or description; whether they introduce a proper noun,
> feature, or person without a citable source; and whether they assert a material
> means the issuer never specified without the alternatives having been surfaced.
> The reviewer detects unsupported commitment — it does not enumerate the
> alternatives, because its turn and file budget is small and route discovery belongs
> to planning.

Fidelity compares against the verbatim original request when the task carries one
(the `## Original request (verbatim)` section of `Description`, or the original
message text stored by the ingest path), and against the issuer-authored
`Description` and `Title` otherwise.

A premise the specification itself introduced — a test method, an operating
procedure, a property of the environment — is **not** rescued by "a skilled executor
would know this". That exemption belongs to the request-time / execute-time boundary
and covers details the executor resolves at run time; it does not license the spec to
assert an unsourced fact about the environment. Unsourced environment assertions are
a Fidelity finding.

Verdict (rules applied in order — first match wins):
- `REJECT` — ≥1 axis ✗ (fundamental rewrite required)
- `NEEDS_REFINEMENT` — ≥1 axis △ and no ✗ (specific suggested fixes can elevate to PASS; the number of △ axes is informational only)
- `PASS` — all 6 axes ◯

### Source Citations

Fidelity turns on whether an assertion is *sourced*. Exactly two things count:

- **the issuer's own words**, or
- **a named reference** carrying all four of: the identifier (document, skill, page), the section it points at, the specific claim or plan step it supports, and — for a mutable source — a version, commit, or date.

A citation supports **one** assertion. It does not implicitly license every proper noun introduced near it. A bare source name is not a citation: it proves neither which revision was read nor which claim came from it.

### Reserved Placeholder Prefixes

Exactly 3 prefixes are reserved at the protocol level:

| Prefix | Meaning |
|---|---|
| `[DRAFT-AC]` / `[DRAFT-EP]` | Field is intentionally an empty stub; refinement pending |
| `[NEEDS-REFINE]` | Reviewer returned NEEDS_REFINEMENT or REJECT; field needs work before promotion |
| `[INFERRED]` | The line is an **unresolved assertion** — not traceable to the issuer's words or a citable source |

All three block Ready and above: they are part of the Layer 1 reserved-placeholder check, which is a structural, language-independent string test.

Skills MUST NOT introduce additional reserved prefixes. Other tags (e.g., `worthiness:*`) live on the `Tags` field, not as title or AC prefixes.

> **v4.0.0 breaking change**: `[INFERRED]` was already being persisted by the ingest path as an audit trail on tasks that reached Ready — the table said two prefixes while shipped code wrote a third, and a fourth (`[LOW CONFIDENCE]`) was documented elsewhere. The table is now aligned with reality, and the meaning changes: `[INFERRED]` no longer marks "an inferred line, visible on a Ready task"; it marks "an assertion nobody has resolved yet", and it blocks promotion. `[LOW CONFIDENCE]` is removed entirely — the planning agent's disengagement fallback uses `[NEEDS-REFINE]`.
>
> **Resolution has exactly two outcomes**: the issuer confirms the line and the prefix is removed, or the task stays in Backlog. Removing the prefix means "the issuer adopted this into the contract", not "the issuer originally said this" — which is why the verbatim original request and the Confirmation Log both exist.
>
> Note the interaction with Layer 2: `reviewing-quality` runs Layer 1 first and does not spawn the Reviewer when a structural check fails. A draft carrying `[INFERRED]` is therefore rejected **before** Fidelity ever runs. `[INFERRED]` is a Layer 1 defect marker, not a Fidelity flag — which is why bulk approval must be gated on the planning agent's own metadata rather than on a review that never happened.

> **Rejected alternative**: an authorship tag vocabulary (`[USER]` / `[KNOWLEDGE:topic]` / `[INFERRED]`) inside AC text. AC is the field the executor reads; every additional reserved prefix couples Layer 1, the dispatch prompt, the view server, and the monitoring scripts to a growing vocabulary. And under this release an unsourced inferred line must not reach a Ready task at all, so labelling it as metadata to carry forward is the wrong shape. Knowledge-derived lines cite their source inline instead of being tagged.

### Quality Verdict Cache Format (v2)

The `Quality Verdict` core field stores at most one line in the format:

```
{verdict} hash=<review-input hash [:8]> @<iso8601> v2
```

- `verdict` ∈ `PASS`, `NEEDS_REFINEMENT`, `REJECT`
- `hash` is the first 8 lowercase hex chars of SHA-256 over the **normalized review input** defined below.
- `v2` is the format version literal. Parsers MUST return the version they parsed rather than discarding it — the version is load-bearing (see § Format Versions and the Migration Window).
- Parsers MUST ignore unknown trailing `key=value` tokens after the version literal. This covers forward compatibility and the retired v2.x `suppressed-until` key: the 7-day re-review suppression was removed in v3.0.0 (it kept returning frozen verdicts even after the user substantively fixed the spec; the content hash plus user-gated refine loops already bound re-review cost). Legacy lines carrying the key parse normally and the key carries no semantics.

#### The normalized review input

The hash must be recomputable by anyone holding the task — a downstream deterministic
gate recomputes it to detect a fabricated or stale verdict — so the input is specified
exactly. It is these **six components, in this order, joined by a single `|`**:

| # | Component |
|---|---|
| 1 | `Title` |
| 2 | `Description` |
| 3 | `Acceptance Criteria` |
| 4 | `Execution Plan` |
| 5 | reviewer-visible `Context` |
| 6 | the rubric identifier literal `irc-6axis` |

Normalization, applied to each component before joining:

- A field the provider does not support, or that is absent or null, is the **empty string**. It is never omitted — the component and its delimiter always occupy their position, so the pipe count is constant.
- Line endings are normalized to `LF`.
- Trailing whitespace at the **end of the component** is removed. Internal whitespace and blank lines are preserved exactly.
- The joined string is encoded as UTF-8 with no trailing newline.

**Reviewer-visible `Context`** means `Context` with every managed block removed — the
Quality Review Findings block and the Confirmation Log block. The removal must be
byte-identical to the strip performed before the spec is handed to the Reviewer:
the hash covers exactly what the Reviewer read, no more and no less. This is what
lets a managed block be written, replaced, or deleted without invalidating the verdict,
while an issuer's edit to their own `Context` prose does invalidate it.

> **v4.0.0 breaking change**: `Context` was previously outside the hash. A citation or
> constraint in `Context` could be added, changed, or removed while a `PASS` stood.
> That was already a latent defect; with Fidelity treating citations as evidence it
> becomes a way to hold a PASS while changing what the PASS was based on. The accepted
> consequence is more re-review: **an edit to `Context` now invalidates a PASS.** That
> is the intended behavior — a judgment about a specification must not survive a change
> to the specification the judgment read.

The rubric identifier is inside the hash because a sixth axis changes what `PASS`
means. Without it, a verdict produced under the five-axis rubric would be
indistinguishable from one produced under six.

#### Format versions and the migration window

| Transition | Accepted verdict format |
|---|---|
| Backlog → Ready | current `v2` PASS only |
| Ready → In Progress / In Review / Done | `v2` PASS, **or** a legacy `v1` PASS |

New verdict producers emit `v2` only; `v1` is never written again.

Dispatch is cache-only and cannot fall back to a live review, so invalidating `v1`
wholesale would make every existing Ready task undispatchable. The daily health check
and monitoring re-review `v1` Ready+ tasks progressively instead, which is what makes
this a migration window rather than a cutover.

Accepted consequence: a task already at Ready keeps dispatching without ever having
been evaluated on Fidelity, until the daily sweep reaches it.

> **Rejected alternative**: keeping format `v1` and adding a `rubric=v2` trailing token.
> The format spec above requires parsers to *ignore* unknown trailing tokens, and every
> shipped parser accepts any `v[0-9]+` with arbitrary trailing keys. Giving normative
> meaning to a token the contract declares ignorable would require changing every one
> of those parsers while the contract still says the token means nothing.

Live Reviewer invocation is allowed at: `planning-tasks`, `managing-tasks` planning-assisted creation, `ingesting-messages` Phase A.5, `running-daily-tasks` Step 2.6, `delegating-tasks` (cache miss), `monitoring-tasks --deep`.

Live Reviewer invocation is **forbidden** at: `executing-tasks` dispatch (cache-only), `managing-tasks` pre-Ready status transition (cache-only). These are hot paths.

### Findings Persistence

A non-PASS verdict line alone tells a later session *that* a spec fell short, not *why*. The gaps and suggested fixes behind a `NEEDS_REFINEMENT` / `REJECT` verdict are persisted on the task itself as a **Quality Review Findings block** inside the `Context` extended field:

- The block is managed by the verdict pipeline (`reviewing-quality` skill) — written on non-PASS verdicts, replaced in place on re-review, **removed on PASS**. Users do not edit it directly.
- It carries the same content `hash` as the verdict line; a hash mismatch marks the findings as stale and they are ignored.
- The block is **stripped before hashing**, exactly as it is stripped before review, so managing it never invalidates the verdict cache. (Under v1 this held for a different reason — `Context` was outside the hash entirely. Under v2 `Context` is inside it, and only the managed blocks are excluded.)
- Graceful degradation: when a provider does not support `Context`, findings surface in conversation only and the verdict line still caches.

This is what makes the cache-only hot paths able to present "what to fix" (not just the verdict) when gating a promotion or dispatch. The exact block format is owned by the `reviewing-quality` skill's reference documentation, kept in sync with this section.

### Confirmation Log

A second managed block, in the same field and with the same lifecycle rules as the findings block.

When an `[INFERRED]` line is confirmed by the issuer, the prefix is removed (see § Reserved Placeholder Prefixes) — and at that moment nothing records that the line was *adopted* rather than originally stated. The Confirmation Log block records it:

- One block per task, inside the `Context` extended field, with exact delimiters.
- Written when an inferred line is confirmed; each entry names the line and who confirmed it.
- **Stripped before hashing and before review**, exactly like the findings block. This matters under the v2 hash: `Context` is inside it, so an unmanaged confirmation note would invalidate the verdict at the very moment of confirmation.
- Graceful degradation: when a provider does not support `Context`, the confirmation is surfaced in conversation only.

Removing an `[INFERRED]` prefix means "the issuer adopted this into the contract", not "the issuer originally said this" — which is exactly the distinction this block preserves. The block format is owned by the `reviewing-quality` skill's reference documentation, kept in sync with this section.

### Calibration Requirement

Before a Waggle release that ships the Reviewer agent or Layer 0 classifier, implementations MUST measure agreement against hand-labeled samples. Recommended bar: ≥80% on 30 hand-labeled tasks. Below threshold, the affected layer ships disabled.

## Provider Interface

A Waggle provider is any backend that implements the following operations:

| Operation | Description |
|---|---|
| `create_task(fields)` | Create a new task with the given fields |
| `update_task(id, fields)` | Update one or more fields on an existing task |
| `get_task(id)` | Retrieve a single task by ID |
| `query_tasks(filters, sorts)` | Query tasks with filters and sort ordering |
| `delete_task(id)` | Delete a task |
| `validate_schema()` | Verify all Core fields exist in the backing store |
| `auto_repair_schema()` | Create any missing Core fields with sensible defaults |

### Provider Registration

Providers are delivered as separate plugins (e.g., waggle-notion, waggle-sqlite, waggle-turso). Detection happens via `<available_skills>` on Cowork or `installed_plugins.json` on CLI/Desktop. See the detecting-provider skill for the detection algorithm.

## Execution Environments

| Environment | Detection | Parallel Method |
|---|---|---|
| Cowork | system prompt self-identifies as Cowork, OR `mcp__cowork__*` tools available, OR `CLAUDE_CODE_IS_COWORK=1` (legacy) | Scheduled Tasks |
| Claude Desktop | `CLAUDE_CODE_ENTRYPOINT=claude-desktop` | Scheduled Tasks |
| CLI | `CLAUDE_CODE_ENTRYPOINT=cli` (or unset) | tmux panes |

See the `provider-contract` skill for the full multi-signal Cowork detection logic.

All environments support single-task execution in the current session.

## Versioning

This is Waggle Protocol **v1**. Breaking changes to Core fields or the state machine require a major version bump.
