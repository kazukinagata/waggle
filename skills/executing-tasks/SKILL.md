---
name: executing-tasks
description: >
  Orchestrates autonomous task execution via current session, tmux parallel,
  or Scheduled Tasks. Fetches ready tasks, validates working directories,
  and dispatches to the chosen execution mode.
  Triggers on: "do the next task", "process tasks",
  "execute tasks", "ready tasks",
  "タスク実行", "次のタスクを実行", "タスク処理".
user-invocable: true
---

# Waggle — Task Execution

You orchestrate the execution of tasks. Tasks can be executed one at a time in the current session, or in parallel (tmux panes in Terminal CLI / Scheduled Tasks in Claude Desktop).

## Provider Detection + Identity Resolve (once per session)

1. Load `${CLAUDE_PLUGIN_ROOT}/skills/detecting-provider/SKILL.md` and determine `active_provider` + `headless_config`. Skip if already set.
2. Load `${CLAUDE_PLUGIN_ROOT}/skills/resolving-identity/SKILL.md` and resolve `current_user`. Skip if already set.

## Schema Validation

After loading the provider SKILL.md and config, verify Core fields exist in the Tasks data source (same check as managing-tasks). Required Core fields: `Title`, `Description`, `Acceptance Criteria`, `Status`, `Blocked By`, `Priority`, `Executor`, `Requires Review`, `Execution Plan`, `Working Directory`, `Session Reference`, `Dispatched At`, `Agent Output`, `Error Message`.

If any Core field is missing, follow the active provider SKILL.md's instructions for handling missing fields (auto-repair or stop, as defined per provider).

## Execution Flow

### Phase 1: Fetch & Concurrency Check

1. Query Ready tasks using the active provider's "Querying Tasks" section:
   - Filter: Status = "Ready" AND Executor = current executor type AND Assignees = `current_user.id`
     - `execution_environment = "cli"` → Executor = "cli"
     - `execution_environment = "claude-desktop"` → Executor = "claude-desktop"
   - Post-process: Blocked By is empty or all Blocked By tasks are Done (cannot be filtered server-side)
2. Count In Progress tasks using the same query path:
   - Filter: Status = "In Progress" AND Executor = current executor type AND Assignees = `current_user.id`
3. Calculate `available_slots = headless_config.maxConcurrentAgents - in_progress_count` (default: 3)
4. If `available_slots <= 0`: report "N tasks are in progress (limit: M). Wait for completion or increase maxConcurrentAgents" and stop
5. Sort by Priority (Urgent > High > Medium > Low), then Due Date ascending
6. Take the first `min(ready_count, available_slots)` tasks

### Phase 2: Validate & Choose Execution Mode

For each fetched task:
- Verify Working Directory exists: `test -d "$WORKING_DIR"`
- If not found: exclude that task, set Status = "Blocked", Error Message = "Working directory not found"

### Dispatch Readiness Check (hard gate)

For each task that passed Working Directory validation, verify ALL of the following
fields are filled. If any field is empty or insufficient, do NOT dispatch.
Instead, present the gaps to the user and ask them to fill each one via AskUserQuestion.

| Field | Check | If missing |
|---|---|---|
| Description | Non-empty, at least ~50 tokens | Ask: "What should this task accomplish?" |
| Acceptance Criteria | Non-empty, contains testable conditions | Ask: "What are the verifiable completion conditions?" |
| Execution Plan | Non-empty | Ask: "What is the step-by-step plan for this task?" and propose one based on Description |
| Working Directory | Non-empty AND directory exists | Ask: "What is the absolute path to the working directory?" |

After the user provides the missing information, update the task via the provider's
update tool, then re-validate. Only proceed to dispatch when all checks pass.

Display the validated task(s) with a "Ready for dispatch" confirmation:

Display the task list:

```
Executable tasks:
1. [Urgent] Feature Login   → /home/user/project-a
2. [High]   API Tests       → /home/user/project-b  (branch: feature/api)
3. [Medium] Fix Bug #42     → /home/user/project-c
```

Use AskUserQuestion to choose execution method:

**Terminal CLI (`execution_environment = "cli"`):**

| Option | Description |
|--------|-------------|
| One at a time (Recommended) | Select one task and execute in the current session |
| tmux parallel execution | Execute multiple tasks simultaneously in tmux panes |

**Claude Desktop (`execution_environment = "claude-desktop"`):**

| Option | Description |
|--------|-------------|
| One at a time (Recommended) | Select one task and execute in the current session |
| Scheduled Task parallel creation | Register each task as a Scheduled Task for parallel execution |

### When "One at a time" is selected

1. Use AskUserQuestion to let the user choose which task to execute
2. Claim: Status → "In Progress", Dispatched At → now
3. Execute within the current session:
   - `cd <Working Directory>`
   - If Branch is set: `git checkout <branch> || git checkout -b <branch>`
   - Perform work based on the task's Description, Acceptance Criteria, and Execution Plan
   - On completion: record results in Agent Output, update Status to "In Review" or "Done" based on Requires Review
   - On error: record error details in Error Message, update Status to "Blocked"

### When "tmux parallel execution" is selected (Terminal CLI only)

1. Use AskUserQuestion to choose permission mode:
   - plan (Recommended)
   - default
   - acceptEdits
   - bypassPermissions
2. Load `tmux-parallel.md` (this directory) and follow Phases 3–6.

### When "Scheduled Task parallel creation" is selected (Claude Desktop only)

Load `desktop-parallel.md` (this directory) and follow Steps 1–5.

## Dispatch Prompt Template

See `dispatch-prompt.md` in this directory.

### Dynamic On Completion Block Injection

When generating the dispatch prompt for each task, replace the `<ON_COMPLETION_BLOCK>` placeholder with the active provider's On Completion Template:

1. Read the "On Completion Template" section from the provider SKILL.md (from detecting-provider's `provider_skill_path`)
2. Replace placeholders in the template with actual values:
   - `<task_id>` → the actual task page ID / row ID
   - `<db_path>` → the actual database path (SQLite/Turso providers)
   - `<absolute_path_to_turso_exec_sh>` → resolved absolute path of `${PROVIDER_PLUGIN_ROOT}/skills/turso-provider/scripts/turso-exec.sh` (Turso provider only)
3. Inject the rendered block into the dispatch prompt, replacing `<ON_COMPLETION_BLOCK>`
4. **All paths MUST be absolute** — no `${CLAUDE_PLUGIN_ROOT}` or `${PROVIDER_PLUGIN_ROOT}` should remain in the final dispatch prompt

## Fallback: Sequential Execution

**Terminal CLI:** If tmux is unavailable, fall back to sequential execution via the Agent tool:

For each task:
1. Set Status → "In Progress", Dispatched At → now
2. Spawn the `task-agent` agent using the Agent tool with the assembled dispatch prompt
3. Record any returned session reference in `Session Reference`
4. On success: write result to `Agent Output`, transition Status per `Requires Review`
5. On failure: write error to `Error Message`, set Status → "Blocked"

**Claude Desktop:** If Scheduled Task creation fails, fall back to executing one at a time within the current session (same flow as "One at a time").

## Safety

- Default: single task in current session
- Parallel execution is opt-in via AskUserQuestion (tmux in Terminal CLI, Scheduled Tasks in Claude Desktop)
- Default permission mode for tmux agents: plan
- Never use `--dangerously-skip-permissions`
- Respect `maxConcurrentAgents` limit by subtracting current In Progress count
- Terminal CLI: Order strictly: generate files → claim in data source → launch tmux
- Claude Desktop: Order strictly: generate prompts → claim in data source → create Scheduled Tasks
- Write Session Reference only after pane/task creation succeeds (no speculative writes)
- On tmux unavailable (Terminal CLI): error message + fallback to sequential Agent tool execution
- On Scheduled Task creation failure (Claude Desktop): fallback to sequential in-session execution
