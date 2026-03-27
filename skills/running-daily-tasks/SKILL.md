---
name: running-daily-tasks
description: >
  Unified daily routine: ingests messages into tasks, then guides user through
  task refinement and dispatch. Works in both Terminal CLI and Claude Desktop.
  Use this skill whenever the user wants to start their day, run a morning
  routine, or process their daily task workflow — even if they just ask
  "what should I do today?".
  Triggers on: "daily tasks", "daily routine", "run daily tasks",
  "morning routine", "start my day", "what should I do today", "daily run".
user-invocable: true
---

# Waggle — Daily Routine

Unified daily routine that ingests messages into tasks, then guides the user through task refinement and dispatch. Works in Terminal CLI, Claude Desktop, and Cowork environments.

---

## Step 0: Session Bootstrap

Load `${CLAUDE_PLUGIN_ROOT}/skills/bootstrap-session/SKILL.md` and follow its instructions.
Skip if `active_provider` and `current_user` are already set in this conversation.

---

## Step 1: Message Intake

Execute the `ingesting-messages` skill.

If the user specified a lookback period (e.g., "past 3 days", "48 hours"), pass that instruction when invoking the skill so that `ingesting-messages` uses it as its `lookback_period`.

Record the result as `intake_result`. If the skill was skipped (e.g., no messaging MCP detected), set `intake_result = "skipped (no messaging MCP)"`.

---

## Step 2: Task Refinement (Backlog → Ready)

Promote the current user's Backlog tasks to Ready by filling quality gates.

1. Query the provider for tasks where **Status = Backlog** AND **Assignees includes `current_user`**.
2. If no tasks are found, set `refinement_result = "skipped (no Backlog tasks)"` and proceed to Step 2.5.
3. Classify tasks into code tasks (have Working Directory) vs non-code tasks.
4. Present all tasks with options:
   ```
   Backlog tasks to refine:
   [Auto-plan N code tasks] [Quick-review M non-code tasks] [Review all one by one] [Skip]
   ```
   User chooses how to proceed — no artificial threshold on count.
   - **Auto-plan code tasks**: Invoke the `planning-tasks` skill in pipeline mode with the task IDs. The `code-planning-agent` explores each codebase and generates AC/Plan. On completion, present summary: "Auto-planned N/M. K need more context."
   - **Quick-review non-code tasks**: Invoke the `planning-tasks` skill in pipeline mode. The `knowledge-planning-agent` proposes AC/Plan using domain templates, brainstorms with user.
   - **Review all one by one**: For each task, use the multi-round brainstorming protocol (see `planning-tasks` SKILL.md). Run `validate-task-fields.sh` for Ready before promoting.
   - **Skip**: Defer to next daily run.
5. For each task where planning completes successfully, run validation and promote to Ready if valid.
6. Record `refinement_result` — e.g., `"3 auto-planned, 2 reviewed, 1 deferred"`.

---

## Step 2.5: Blocked Task Review

Review Blocked tasks and surface actionable items.

1. Query using the provider's filter recipe for **Blocked tasks owned by user** (see provider SKILL.md):
   `Status=Blocked AND (Assignees=current_user OR (Issuer=current_user AND Assignees empty))`
2. If 0 results: set `blocked_review_result = "skipped (no Blocked tasks)"` and proceed to Step 3.
3. Separate into two groups:
   - **Group A — Unblocked**: ALL `Blocked By` tasks are Done
   - **Group B — Still blocked**: some `Blocked By` tasks remain non-Done

### Group A — Unblocked tasks (action required)

For each unblocked task:
1. Read the blocker task's Agent Output (contains the hearing response or execution result).
2. Synthesize: "Blocker resolved. '{blocker_title}' result: {agent_output_summary}"
3. If main task AC starts with `[DRAFT` or fails semantic validation:
   - AC MUST be replaced before transitioning (not optional).
   - Propose updated AC based on the blocker's Agent Output.
   - Ask: "Move to Ready with this updated AC? [Yes / Edit first / Skip]"
4. Run `validate-task-fields.sh` for Ready. Transition if valid.
5. Re-evaluate Executor: "Should this be executed by AI? [cli / cowork / keep human]"

### Group B — Still blocked tasks (batch summary)

Present as a single summary table (no interactive prompts per task):
```
Still blocked (N tasks):
| Title | Blocked By | Blocked Days | Blocker Assignee |
| ...   | ...        | X days       | {name}           |
```

For tasks blocked >7 days ONLY: offer batch support options:
"M tasks blocked >7 days. [Ping all blocker assignees] [Escalate all to Urgent] [Skip]"
- **Ping**: Add a comment on each blocker task noting the stagnation.
- **Escalate**: Change blocker tasks' Priority to Urgent.

If any task has Error Message non-empty, append to summary.

Record `blocked_review_result` — e.g., "2 unblocked → Ready, 3 still blocked (1 escalated)".

---

## Step 3: Task Dispatch

Execute the `executing-tasks` skill (normal mode).
The skill will verify all tasks have complete Execution Plans, Acceptance Criteria, and
other required fields before dispatch. The user will be prompted to fill any gaps and
choose the execution method.

Record the result as `dispatch_result`.

---

## Step 3.5: Ready Human Task Prompt

Surface stagnating Ready tasks with executor=human for action.

1. Query using the provider's filter recipe for **Ready human tasks owned by user** (see provider SKILL.md):
   `Status=Ready AND Executor=human AND (Assignees=current_user OR (Issuer=current_user AND Assignees empty))`
2. If 0 results: set `human_ready_result = "skipped (no Ready human tasks)"` and proceed to Step 4.
3. Run `validate-task-fields.sh` on each task. Note which have validation warnings (empty AC, empty Plan).
4. For each task (oldest first, max 5, note "and N more..." if truncated):
   - Calculate age in days since creation. If ≥3 days: flag as stagnating.
   - Analyze Title/Description for AI suitability.
   - Present with options:
     ```
     Ready human tasks requiring attention:
     1. [High] "Task title" (7d old) ⚠ missing AC
        → [Start now] [Fix AC/Plan] [Reassign to AI] [Delegate] [Defer to Backlog]
     ```
   - If task has validation warnings (empty AC/Plan): highlight **[Fix AC/Plan]** as recommended action.
   - **[Fix AC/Plan]**: Invoke `planning-tasks` on this task (spawns appropriate planning agent).
   - **[Reassign to AI]**: If non-code task detected, add info note: "Note: this is a {category} task. AI can assist with research, drafting, and structured planning." Proceed with user's choice.
   - **[Start now]**: Move to In Progress (run validation first).
   - **[Delegate]**: Invoke `delegating-tasks` skill.
   - **[Defer to Backlog]**: Move to Backlog.
5. Record `human_ready_result`.

---

## Step 4: Summary

Output the following report:

```
[Daily Tasks Complete]
Message Intake:      {intake_result}
Task Refinement:     {refinement_result}
Blocked Task Review: {blocked_review_result}
Task Dispatch:       {dispatch_result}
Ready Human Tasks:   {human_ready_result}
```


Always respond in the user's language.
