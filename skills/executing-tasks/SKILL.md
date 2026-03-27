---
name: executing-tasks
description: >
  Orchestrates autonomous task execution via current session, tmux parallel,
  or Scheduled Tasks. Fetches ready tasks, validates working directories,
  and dispatches to the chosen execution mode. Use this skill whenever the
  user wants to do, run, process, start, dispatch, or launch tasks — including
  parallel execution, batch processing, or working on the next ready task.
  Triggers on: "do the next task", "process tasks", "execute tasks",
  "ready tasks", "run tasks", "start tasks", "dispatch", "launch tasks",
  "work on next task", "parallel execution", "batch process".
user-invocable: true
---

# Waggle — Task Execution

You orchestrate the execution of tasks. Tasks can be executed one at a time in the current session, or in parallel (tmux panes in Terminal CLI / Scheduled Tasks in Claude Desktop and Cowork).

## Session Bootstrap

Load `${CLAUDE_PLUGIN_ROOT}/skills/bootstrap-session/SKILL.md` and follow its instructions.
Skip if `active_provider` and `current_user` are already set in this conversation.

## Schema Validation

After loading the provider SKILL.md and config, verify Core fields exist in the Tasks data source (same check as managing-tasks). Required Core fields (15): `Title`, `Description`, `Acceptance Criteria`, `Status`, `Blocked By`, `Priority`, `Executor`, `Requires Review`, `Execution Plan`, `Working Directory`, `Session Reference`, `Dispatched At`, `Agent Output`, `Error Message`, `Issuer`.

If any Core field is missing, follow the active provider SKILL.md's instructions for handling missing fields (auto-repair or stop, as defined per provider).

## Execution Flow

### Subtask Independence

Subtasks are eligible for execution regardless of their parent task's status. The `parentTask` field does not affect dispatch readiness. After a subtask completes and its Status is updated, the status cascading logic (defined in managing-tasks) must be triggered to check whether the parent should auto-transition.

### Phase 1: Fetch & Concurrency Check

1. Query Ready tasks using the active provider's "Querying Tasks" section:
   - Filter: Status = "Ready" AND Executor in (eligible executor types) AND Assignees = `current_user.id`
     - `execution_environment = "cli"` → Executor in ("cli", "claude-desktop", "cowork")
     - `execution_environment = "claude-desktop"` → Executor in ("cli", "claude-desktop", "cowork")
     - `execution_environment = "cowork"` → Executor = "cowork"
   - CLI and Claude Desktop have full local capabilities, so they can process tasks for any AI executor type. Cowork runs in a constrained VM and can only process its own tasks.
   - Post-process: Blocked By is empty or all Blocked By tasks are Done (cannot be filtered server-side)
2. Count In Progress tasks using the same query path:
   - Filter: Status = "In Progress" AND Executor in (eligible executor types) AND Assignees = `current_user.id`
   - If any In Progress tasks exist, display count to the user as context (not a hard block)
3. Sort by Priority (Urgent > High > Medium > Low), then Due Date ascending

### Phase 2: Validate & Choose Execution Mode

For each fetched task:
- **CLI / Claude Desktop**: Verify Working Directory exists: `test -d "$WORKING_DIR"`
  - If not found: ask "Directory not found at '{path}'. [Enter correct path / Skip this task]"
    - If user provides a new path: update the task and re-validate
    - If user skips: exclude the task from dispatch (do NOT auto-block)
- **Cowork**: Skip filesystem validation (workspace-relative paths cannot be checked with `test -d`). Only verify the field is non-empty.

### Dispatch Readiness Check (hard gate)

For each task that passed Working Directory validation, run the deterministic validation script:

```bash
# Construct canonical JSON from task data (see validating-fields SKILL.md for format)
echo '<canonical_json>' > /tmp/dispatch_validate.json
bash ${CLAUDE_PLUGIN_ROOT}/skills/validating-fields/scripts/validate-task-fields.sh \
  "In Progress" /tmp/dispatch_validate.json
```

Parse the output JSON:
- If `valid: false`: present each error to the user and ask them to fill the gaps via AskUserQuestion. After filling, update the task and re-run validation.
- If `valid: true` with warnings: present warnings but proceed with dispatch.

Only dispatch when validation passes (`valid: true`).

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

**Cowork (`execution_environment = "cowork"`):**

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

### When "Scheduled Task parallel creation" is selected (Claude Desktop / Cowork)

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

**Claude Desktop / Cowork:** If Scheduled Task creation fails, fall back to executing one at a time within the current session (same flow as "One at a time").

## Safety

- Default: single task in current session
- Parallel execution is opt-in via AskUserQuestion (tmux in Terminal CLI, Scheduled Tasks in Claude Desktop / Cowork)
- Default permission mode for tmux agents: plan
- Never use `--dangerously-skip-permissions`
- Display In Progress count to the user; parallel execution count is chosen interactively
- Terminal CLI: Order strictly: generate files → claim in data source → launch tmux
- Claude Desktop / Cowork: Order strictly: generate prompts → claim in data source → create Scheduled Tasks
- Write Session Reference only after pane/task creation succeeds (no speculative writes)
- On tmux unavailable (Terminal CLI): error message + fallback to sequential Agent tool execution
- On Scheduled Task creation failure (Claude Desktop / Cowork): fallback to sequential in-session execution
