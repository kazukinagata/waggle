---
name: planning-tasks
description: >
  Generates or refines Acceptance Criteria and Execution Plans for tasks.
  Single task or batch mode. Ensures tasks are executable at agent-autonomous quality.
  Uses multi-round brainstorming to extract quality information from users.
  Use this skill whenever the user wants to plan, prepare, refine, or improve
  a task before execution — including writing AC, execution plans, or making
  tasks ready for autonomous agents.
  Triggers on: "plan task", "refine task", "generate AC", "write execution plan",
  "plan all tasks", "auto-plan", "prepare task", "improve task", "batch plan".
user-invocable: true
---

# Waggle — Task Planning

You generate and refine Acceptance Criteria (AC) and Execution Plans for tasks. Your goal is to make tasks executable at agent-autonomous quality — detailed enough that an AI agent can complete them without additional questions.

## Output Discipline

This skill runs as a multi-step pipeline, but the user only needs its outcomes. Do not
narrate step transitions ("Now I'll...", "X done, next Y") and do not relay protocol
internals — provider detection, config/schema checks, cache state, validation plumbing,
view-server pushes. Surfacing them buries what actually matters.

Emit user-facing text only when it changes something for the user:

- a prompt or confirmation that needs their input
- an error or a warning
- an intermediate result that changes the outcome (e.g., a non-PASS quality verdict and
  the gaps behind it — it explains why a task lands at a different status than expected)
- the final result summary

## Session Bootstrap

Invoke the `bootstrap-session` skill to establish the active provider and current user.
Skip if `active_provider` and `current_user` are already set in this conversation.

## Custom Instruction Loading

Invoke the `loading-custom-instructions` skill with key `task-creation` to populate `custom_task_creation_instructions`. If the returned value is non-null, pass it along to every planning agent spawned below — AC drafts, Execution Plan drafts, and Priority defaults should honor the user's project-specific rules (e.g. "AC must use Given/When/Then", "Execution Plan steps must start with a verb", "treat security-related tasks as High priority"). If null, proceed with the normal planning heuristics.

Custom instructions only influence generated field **content**. They never override the `validating-fields` gate at Phase 5, and they never decide status transitions or destructive operations.

## Target Selection

Three modes of operation:

### Single Task
User specifies a task by title, ID, or description. Search the Tasks DB and confirm the match.

### Batch Mode
User says "plan all Backlog tasks" or similar. Query by status filter.

### Pipeline Mode
Receives a list of task IDs from another skill (e.g., running-daily-tasks). Process each task in the list.

## Planning Flow

For each task, determine the planning path:

### Path A — [Hearing] Tasks (deterministic, no agent needed)

If the task title starts with `[Hearing]`:
- **AC**: `"Confirm with {person} about {topic_from_title}. Record response in Agent Output. Update Status to Done when confirmed."`
- **Execution Plan**: `"1. Contact {person} via messaging tool\n2. Ask about: {topic}\n3. Record response in Agent Output\n4. Update Status to Done"`
- Update the task immediately. No user confirmation needed (deterministic template).

### Path B — All Other Tasks (agent-delegated)

1. **Check minimum input threshold**:
   - If Description has no nouns or meaningful context (e.g., just "fix bug" with no other info):
     escalate to user before spawning agent:
     "I need more context to plan this task. What specifically needs to happen?"
   - If user provides more context: update Description, then proceed
   - If user declines: skip this task

2. **Spawn the `task-planning-agent`** via the Agent tool:
   - Provide: Title, Description, Context, AC (if partial), Working Directory, Repository, **Executor**
   - The agent judges the investigation mode (codebase exploration, domain planning, or both) from the task content itself — there is no property-based routing; a populated Repository/Working Directory is an investigation resource for the agent, not a classifier
   - Also forward `custom_task_creation_instructions` (if non-null) so the agent can honor project-specific rules for AC / Execution Plan style and Priority defaults
   - The agent follows the Multi-round Brainstorming Protocol (see below)
   - The agent returns: generated AC + Execution Plan as structured text

3. **Present agent output to user** for final confirmation:
   - Show the generated AC and Execution Plan
   - Options: `[Accept] [Edit] [Skip]`
   - If Accept: update the task via provider
   - If Edit: let user modify, then update. The user's wording is authoritative **intent** — if the quality gate below then returns non-PASS, the recovery is a regeneration that restates their wording as verifiable criteria (step 4), never a request that they rephrase it themselves
   - If Skip: leave task unchanged

4. **Quality gate**: After the user accepts the AC/EP, invoke the `reviewing-quality` skill in `live` mode for the updated task. It returns a verdict (`PASS` / `NEEDS_REFINEMENT` / `REJECT`) plus per-axis findings and concrete suggested fixes. Branch on the verdict:
   - **PASS** → invoke the `validating-fields` skill with target `"Ready"`; on `valid: true`, the task is Ready-eligible. **When you write the Status=Ready promotion, include the `Quality Verdict` property set to the `verdict_string` returned by `reviewing-quality` in the *same* provider update** — the verdict must travel in the same payload as the status change, not in a separate write. A direct write that sets Status=Ready without a valid verdict is rejected before it reaches the provider.
   - **NEEDS_REFINEMENT** → surface the Reviewer's gaps and suggested fixes and ask the user `[Refine now] [Save anyway]`. The gaps are usually requester-side information (who approves, what the brief is) that a re-plan cannot invent, so refining starts with the user:
     1. Derive one concrete question per requester-side gap and ask via AskUserQuestion (gaps the Reviewer already named a self-contained fix for need no question — carry the fix forward directly).
     2. Re-spawn the `task-planning-agent` with the user's answers and the Reviewer's fixes attached as additional context, then invoke `reviewing-quality` in `live` mode again.
     3. Repeat until the verdict is `PASS` or the user picks `[Save anyway]`. On `[Save anyway]`, save with `[NEEDS-REFINE]` prefix and keep Status=Backlog; the gaps/fixes are persisted on the task's `Context` field as a findings block by `reviewing-quality`, so a later session can pick up where this one left off.
     Each round is gated on the user's explicit choice to continue, so the loop cannot run away on its own (there is no automatic re-review throttle — user choice is the throttle).
   - **REJECT** → surface the gaps and suggested fixes and ask the user `[Regenerate with fixes] [Save as-is]`. The primary recovery is regeneration, not asking the user to reword their spec:
     - `[Regenerate with fixes]` → re-spawn the `task-planning-agent` with the current AC/EP, the user's own wording marked as authoritative intent, and the Reviewer's (or Layer 1's) gaps/fixes attached, then re-invoke `reviewing-quality` in `live` mode — same user-gated loop mechanics as NEEDS_REFINEMENT above.
     - `[Save as-is]` → save with `[NEEDS-REFINE]` prefix and keep Status=Backlog. The verdict (with the same `[NEEDS-REFINE]` rationale) is written to the `Quality Verdict` Notion column by `reviewing-quality`, and the gaps/fixes are persisted as a findings block on `Context`.
   - **UNREVIEWED** (upstream error only — worthiness-skipped tasks now return `PASS` with a `verdict_string`, not `UNREVIEWED`) → do **not** promote to Ready. `UNREVIEWED` carries an empty `verdict_string`, so a Status=Ready write would be rejected by the provider guard. Keep Status=Backlog, surface the error to the user, and let them retry planning.

### Batch Execution

When processing multiple tasks (batch mode or pipeline mode):

#### Phase 1: Order the Queue

- Sort tasks by Priority (Urgent > High > Medium > Low)

#### Phase 2: Parallel Agent Dispatch

- Spawn up to **5 `task-planning-agent` instances in parallel** using a single message with multiple Agent tool calls
- If >5 tasks, process in chunks of 5 (wait for chunk to complete before next)
- Each agent receives the full task context (Title, Description, Context, AC, Working Directory, Repository, Executor) plus `custom_task_creation_instructions` if non-null
- Each agent judges its own investigation mode (codebase exploration, domain planning, or both) from the task content — no routing decision happens at this layer

Example (5 tasks = one chunk):
```
Message 1: [Agent(task-1), Agent(task-2), Agent(task-3), Agent(task-4), Agent(task-5)]
→ All 5 run in parallel
```

Example (8 tasks = 2 chunks):
```
Message 1: [Agent(task-1), Agent(task-2), Agent(task-3), Agent(task-4), Agent(task-5)]
→ Wait for all 5 to complete
Message 2: [Agent(task-6), Agent(task-7), Agent(task-8)]
→ Wait for all 3 to complete
```

#### Phase 3: Result Collection

Wait for all agents in the current chunk to complete. Classify each result:
- **Success** → store generated AC + Execution Plan
- **Failure/timeout** → mark as "needs manual planning"
- **Insufficient context** (agent requested more info) → mark as "needs user input"

#### Phase 4: Bulk Confirmation

Present all results together:
```
Planning results (5 tasks):
1. [OK]          "API endpoint"  — AC: 4 criteria, Plan: 6 steps
2. [OK]          "Fix auth bug"  — AC: 3 criteria, Plan: 4 steps
3. [NEEDS INPUT] "Refactor DB"   — agent needs: "Which tables are affected?"
4. [OK]          "Write blog"    — AC: 5 criteria, Plan: 7 steps
5. [FAILED]      "Update docs"   — agent error: timeout

[Accept all OK] [Review one by one] [Skip all]
```

- **Accept all OK**: Update all successful tasks via provider, then handle "needs input" tasks interactively
- **Review one by one**: Present each task's AC/Plan for individual Accept/Edit/Skip
- **Skip all**: Leave all tasks unchanged

#### Phase 5: Quality Gate and Promotion

For each accepted task in the chunk, invoke the `reviewing-quality` skill in batch mode (the skill internally fans out 5 Reviewer agents in parallel, reusing the same chunking pattern). Then branch each task on its verdict using the same rules as the single-task flow (step 4):

- **PASS** → run `validating-fields` for `"Ready"`; promote to Ready on `valid: true`. The Status=Ready write **must carry the `Quality Verdict` property set to that task's `verdict_string` (from `reviewing-quality`) in the same provider update** — same atomic-promotion rule as the single-task flow (step 4).
- **NEEDS_REFINEMENT** → save with `[NEEDS-REFINE]` prefix and keep Backlog. Do not auto-retry in batch mode — the user can `/planning-tasks` the task individually if they want to apply Reviewer's suggested fixes. The gaps/fixes are persisted on each task's `Context` field as a findings block by `reviewing-quality`, so the individual re-plan has them on record.
- **REJECT** → save with `[NEEDS-REFINE]` prefix and keep Backlog.

Summary: "Planned N tasks. M PASS (Ready-eligible). R NEEDS_REFINEMENT (kept in Backlog with [NEEDS-REFINE]). J REJECT. K need more context."

## Multi-round Brainstorming Protocol

This protocol is embedded in the planning agent prompts. The agent drives the conversation:

```
Round 1: Agent proposes an initial AC draft based on Title + Description + Context.
  → "Based on your task, I propose these completion criteria:
     1. {criterion 1}
     2. {criterion 2}
     3. {criterion 3}
     What would you add or change? You can also describe your own."

Round 2 (if user response lacks verifiable conditions):
  → Agent refines: "I understood X. Let me also suggest:
     - {additional criterion based on user input}
     - {edge case consideration}
     Anything else? What about error cases or edge conditions?"

Round 3 (continue if user is engaged):
  → Synthesize: "Here's the complete checklist:
     1. {final criterion 1}
     2. {final criterion 2}
     ...
     Anything missing?"
  → If user says "done" / "OK": finalize
  → If user adds more: incorporate and re-present

Fallback (user disengages — "that's enough", "just go with it", etc.):
  → Accept current state with [LOW CONFIDENCE] tag prepended
  → Move on to next task
```

**Key principle**: The agent PROPOSES first, then refines through dialogue. Never wait for the user to provide content from scratch — generate drafts proactively.

**Semantic triggers**: Round 2 fires when the user's response lacks verifiable conditions (no commands, file paths, metrics, or observable outcomes) — not based on character count.

## Execution Plan Generation

After AC is finalized, generate the Execution Plan:

- When a codebase was explored, the `task-planning-agent` generates steps with specific file paths, test commands, and module references.
- For domain planning, it generates a numbered plan using domain templates (see `references/knowledge-work-patterns.md`).
- Each step: action verb + target + expected outcome
- If >7 steps: suggest splitting the task into multiple tasks

## Summary Output

```
[Planning Complete]
Tasks processed: N
AC generated: X
Execution Plans generated: Y
Ready-eligible: Z (passed validation)
Skipped: K (insufficient context or user declined)
```
