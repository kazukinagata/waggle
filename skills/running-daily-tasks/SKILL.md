---
name: running-daily-tasks
description: >
  Unified daily routine: ingests messages into tasks, then guides user through
  task refinement and dispatch. Works in both Terminal CLI and Claude Desktop.
  Triggers on: "daily tasks", "daily routine", "run daily tasks",
  "デイリータスク", "日次ルーティン"
user-invocable: true
---

# Agentic Tasks — Daily Routine

Unified daily routine that ingests messages into tasks, then guides the user through task refinement and dispatch. Works in both Terminal CLI and Claude Desktop environments.

---

## Step 0: Preparation

1. Load `${CLAUDE_PLUGIN_ROOT}/skills/detecting-provider/SKILL.md` → `active_provider`, `headless_config`. Skip if set.
2. Load `${CLAUDE_PLUGIN_ROOT}/skills/resolving-identity/SKILL.md` → `current_user`, `org_members`. Skip if set.

---

## Step 1: Message Intake

Execute the `ingesting-messages` skill.

Record the result as `intake_result`. If the skill was skipped (e.g., no messaging MCP detected), set `intake_result = "skipped (no messaging MCP)"`.

---

## Step 2: Task Refinement (Backlog → Ready)

Promote the current user's Backlog tasks to Ready by filling quality gates interactively.

1. Query the provider for tasks where **Status = Backlog** AND **Assignees includes `current_user`**.
2. If no tasks are found, set `refinement_result = "skipped (no Backlog tasks)"` and proceed to Step 3.
3. For each task, check the following quality gates in order. If a gate fails, use `AskUserQuestion` to ask the user to provide or confirm the missing content, then update the task:
   - **Description**: Must be non-empty and at least ~50 tokens. If too short or empty, ask the user to elaborate.
   - **Acceptance Criteria**: Must be non-empty and contain testable/verifiable conditions (not vague phrases like "works correctly"). If missing or vague, propose concrete criteria and confirm.
   - **Execution Plan**: Must be non-empty. If empty, propose a numbered plan based on Description and Acceptance Criteria, then confirm with the user.
   - **Assignees**: Must be set (should already be satisfied by the query filter).
4. Once all gates pass for a task, calculate `Complexity Score` (if the field exists and is empty) and update Status to **Ready**.
5. Record `refinement_result` — e.g., `"3 tasks promoted to Ready"` or `"1 promoted, 2 still in Backlog (user deferred)"`.

If the user chooses to skip or defer a task, leave it in Backlog and note it in the result.

---

## Step 3: Task Dispatch

Execute the `executing-tasks` skill (normal mode).
The skill will verify all tasks have complete Execution Plans, Acceptance Criteria, and
other required fields before dispatch. The user will be prompted to fill any gaps and
choose the execution method.

Record the result as `dispatch_result`.

---

## Step 4: Summary

Output the following report:

```
[Daily Tasks Complete]
Message Intake: {intake_result}
Task Refinement: {refinement_result}
Task Dispatch: {dispatch_result}
```

---

## Language

Always respond in the user's language.
