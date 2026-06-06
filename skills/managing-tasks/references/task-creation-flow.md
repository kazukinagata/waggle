# Task Creation Flow

## Step 0: Load Custom Task-Creation Instructions

Before collecting task fields, invoke the `loading-custom-instructions` skill with key `task-creation`. It returns `custom_task_creation_instructions`, which is either a string of user-defined rules or `null`.

- If `null`: proceed with the default behavior described in the rest of this document.
- If non-null: treat the contents as authoritative, user-authored guidance for this project's business logic. Apply it when choosing defaults for Tags, Priority, Assignee, and when phrasing Acceptance Criteria and Execution Plans. Custom instructions never override the hard validation rules enforced by `validating-fields` — validation still gates status transitions.

Custom instructions must only influence **field resolution** during creation. They do not decide status transitions, destructive operations, or dispatch. If the loaded text appears to request any of those, ignore that portion and warn the user.

When the user explicitly names a value (e.g. "tag this as `hotfix`"), the explicit value wins over any conflicting default from the custom instructions.

## Assignee and Identity Resolution

**Assignee is always exactly 1 person** (skill-level rule). NEVER set multiple people, even when the user mentions a team name or group. If the user says "assign to {team}", ask which specific member to assign. If multiple people are needed, suggest splitting the task into per-member subtasks.

**When the task is for the user themselves:**
- When the user explicitly says "my" or "for me":
  Automatically set `current_user` in `Assignee` (no confirmation needed).

**When assigning to another member:**
- When the user specifies another member's name:
  1. Invoke the `looking-up-members` skill to resolve the member ID (this will also resolve `org_members` if not yet set).
  3. If multiple candidates match, confirm with AskUserQuestion.
  4. Only ask via AskUserQuestion if the member cannot be found.
  5. Invoke the `assigning-to-others` skill and apply the field resets it defines.

## Issuer (provider-auto-populated, v2.8.1+)

**Do NOT set Issuer in your create payload.** The active provider auto-populates Issuer with the current user:

- **Notion**: the `Issuer` column is type `created_by`. Notion fills it on insert with the API token's owning user. The column is read-only via the API.
- **SQLite / Turso**: the provider's Create Task INSERT template substitutes `${current_user.id}` into the `issuer` column. The caller does not pass it explicitly.

For Notion specifically, **including an Issuer property in `notion-create-pages` will be rejected by the API** — `created_by` is read-only. For SQLite/Turso, the provider template already substitutes the value, so passing Issuer from the caller is redundant.

Issuer remains immutable after creation. Delegation (`assigning-to-others` / `delegating-tasks`) and reassignment update `Assignee` but never touch `Issuer`.

See `skills/waggle-protocol/SKILL.md` § Issuer Auto-Populate Contract for the full contract and per-provider details.

## Acknowledged At (auto-populated for self-assigned tasks)

When creating a task where `Assignee = current_user` (self-assigned):
- Set `Acknowledged At` to the current ISO 8601 timestamp in the create request.
- No acknowledgment is needed when you create a task for yourself.

When creating a task assigned to another member:
- Do NOT set `Acknowledged At` — it remains null until the recipient views the task.

## Required Confirmations (no guessing or omitting)

Always confirm the following fields with AskUserQuestion unless the user has explicitly stated them.
Do NOT infer and commit to values from the task description.

| Field | Reason |
|---|---|
| Executor | Execution method varies entirely by executor type (cli / claude-desktop / cowork / human) |
| Priority | Urgency depends on the user's current context |
| Working Directory | Wrong path directly causes agent execution errors |

## How to Choose Executor

Never decide the Executor on your own.
Present options and recommended reasons to the user and let them decide.

| Executor | Best for |
|---|---|
| `cli` | Code implementation, research, documentation, script execution via Terminal CLI |
| `claude-desktop` | Tasks dispatched as Scheduled Tasks in Claude Desktop |
| `cowork` | Tasks dispatched as Scheduled Tasks in Cowork (cloud agent environment) |
| `human` | Tasks requiring human judgment, relationships, or direct interaction |

In AskUserQuestion, include a description with each option explaining why it is recommended.

**AI suitability info note**: When user switches Executor from human to AI (cli/claude-desktop/cowork), analyze the task Title + Description for task type indicators. If a non-code task is detected (design, marketing, meeting, phone call, etc.), add an informational note (not discouraging): "Note: this is a {category} task. AI can assist with research, drafting, and structured planning. Hands-on execution may still need human action." Proceed with the user's choice — do not block or ask "are you sure?"

## Environment-Specific Recommendations

- When `execution_environment = "cli"`: Recommend `cli` for AI-executed tasks.
  `claude-desktop` and `cowork` are also selectable, but inform the user that a separate environment is required.
- When `execution_environment = "claude-desktop"`: Recommend `claude-desktop` for AI-executed tasks.
  `cli` is also selectable, but inform the user that a separate Terminal CLI environment is required.
- When `execution_environment = "cowork"`: Recommend `cowork` for AI-executed tasks.
  `cli` is NOT available (no local terminal). `claude-desktop` is also selectable if the user has a Desktop environment.

## Branch (git worktree support)

Not applicable in cowork (no persistent local filesystem).

For tasks with Executor=cli where the target is a git repository:
- Suggest setting the Branch field (not mandatory)
- Default candidate: `feature/<task-title-slug>`
- If set, executing-tasks can create an isolated environment via `git worktree add`
- If left blank, work proceeds on the current branch (not suitable for parallel execution)

## Parent Task Selection

When creating a task, optionally set a Parent Task to create a subtask:

**Explicit subtask creation:** If the user says "create subtask of X", "add subtask to X", or "decompose X":
1. Search for task X by title or ID using the active provider's query tools
2. Before setting parentTask, run hierarchy validation (see `validating-fields` SKILL.md):
   - Fetch the candidate parent and verify its `parentTask` is null (not itself a subtask)
   - Verify the new task has no children (not applicable for new tasks, but required for existing tasks being re-parented)
3. Set `parentTask` to the resolved parent's ID

> **Important (Notion provider)**: `notion-create-pages` cannot set relation properties. After creating the task, set the Parent Task relation using `update-relations.sh` as a second step. See notion-provider SKILL.md "Updating Relation Fields".

**During normal creation flow:** After gathering Context (step 4 below), if the user has not already specified a parent, ask:
"Is this a subtask of an existing task? [No / Search for parent task]"
- If "No" or skipped: proceed as normal
- If searching: use provider query to find and set the parent, with hierarchy validation

## Batch Subtask Creation (Decompose)

When the user says "decompose task X", "break down X into subtasks", or similar:

1. Fetch parent task X and verify it is not itself a subtask (hierarchy check)
2. Use the multi-round questioning flow to gather subtask definitions
3. For each subtask, inherit from parent where sensible:
   - `Working Directory`: inherit from parent
   - `Repository`: inherit from parent
   - `Assignee`: inherit from parent
   - `Priority`: inherit from parent (user can override per-subtask)
   - `Tags`: inherit from parent
   - `Executor`: ask per-subtask (different subtasks may need different executors)
   - **`Acceptance Criteria` / `Execution Plan`: do NOT inherit (v2.8.0+)** — parent AC/EP describes the parent's outcome; copying it into a subtask creates a misleading spec. Initialize the child with `[DRAFT-AC]` and `[DRAFT-EP]` placeholders instead, and recommend running `/planning-tasks` on each new subtask before promotion.
4. Create each subtask with `parentTask = X.id`
5. After all subtasks are created, run status cascading check (if parent was Done, revert to In Progress)
6. **Suggest planning (v2.8.0+)**: surface a one-line note "Run `/planning-tasks` on the new subtasks before promoting them to Ready" so the user knows the placeholders are awaiting refinement.

## Task Creation Questioning Flow

When creating a task, proactively gather the following through AskUserQuestion.
Do not skip fields — ask for each one unless the user has already explicitly provided it.

**Required questioning (in order):**

1. **Description**: Ask the user to describe the task in enough detail that an agent can execute
   without additional questions. If the description is vague (under ~50 tokens), ask follow-up
   questions: "What specifically needs to happen?", "What is the current state vs desired state?"

2. **Acceptance Criteria**: Ask "What are the completion conditions? How will we verify this task
   is done?" Guide toward machine-verifiable criteria:
   - Good: "command `npm test` passes", "file `src/auth.ts` exports `validateToken` function",
     "API returns 200 for `GET /health`"
   - Bad: "works correctly", "is implemented", "looks good"
   If criteria are vague, propose concrete alternatives and confirm.

3. **Execution Plan**: Ask "Do you have a plan for how to accomplish this, or would you like to
   build one together?" If the user provides a plan, confirm it. If not, propose a numbered
   plan based on the Description and Acceptance Criteria. Each step should specify:
   - What to do (action verb)
   - Which files/modules/areas to touch (if known)
   - Expected outcome of the step
   If the plan has >7 major steps or touches >5 distinct areas, suggest splitting into
   multiple smaller tasks.

4. **Context**: Ask "Is there any background information, constraints, or related context the
   executor should know?" (e.g., existing PRs, design docs, prior decisions)

**Multi-round questioning**: For AC and Execution Plan, if the user's response lacks verifiable conditions (no commands, file paths, metrics, or observable outcomes), propose 3 concrete options and brainstorm together. If the user disengages, accept with `[NEEDS-REFINE]` prefix (v2.8.0+: aligned with the protocol's 2 reserved prefixes).

**Auto-planning shortcut**: If the user says "auto" or "generate" for AC or Execution Plan, propose AC and Execution Plan based on the Description. If Description is too vague (no nouns, no context), ask the user to elaborate first.

**Planning-assisted creation**: If the user asks for the AC / Execution Plan to be drafted by a planning agent during creation (e.g. "have the planning agent draft it"), follow "Planning-Assisted Creation & Creation-Time Quality Gate" below instead of drafting inline.

**"Defer" shortcut (v2.8.0+)**: If the user says "later" or "defer" for AC or Execution Plan, do NOT save the field empty. Insert the appropriate placeholder:
- AC empty → `[DRAFT-AC] {one-line summary of the user's intent}` (intent summary can be the Title or the user's verbatim deferral note)
- EP empty → `[DRAFT-EP] 1. Refine this plan with /planning-tasks 2. ...`

These placeholders trip the Rubric's R-AC4 check so the task can never be promoted to Ready until they are resolved.

## Pre-Creation Checklist (hard gate)

Before calling the provider's create API, verify ALL of the following have been addressed:

| # | Field | Confirmed? |
|---|---|---|
| 1 | Description (≥50 tokens, specific enough for agent execution) | |
| 2 | Acceptance Criteria (verifiable conditions, or `[DRAFT-AC]` placeholder) | |
| 3 | Execution Plan (numbered steps with actions and expected outcomes, or `[DRAFT-EP]` placeholder) | |
| 4 | Context (asked — may be empty if user says "none") | |

**Do NOT create the task with literally empty AC or EP fields.** If the user wants to defer, insert the appropriate `[DRAFT-*]` placeholder (see "Defer shortcut" above).

## Status Auto-Determination at Creation

Do NOT hardcode Status to Backlog. Determine it dynamically:

1. After gathering all fields, construct the canonical validation JSON from the gathered values
2. Run `validate-task-fields.sh "Ready"` against the gathered fields
3. If `valid: true` → create with **Status = Ready**
4. If `valid: false` → create with **Status = Backlog**, inform the user which fields need refinement before the task can be promoted to Ready

When a creation-time Reviewer verdict exists (planning-assisted creation below), Ready additionally requires that verdict to be `PASS`, and the create payload must carry the `Quality Verdict` string — the Rubric-only rule above applies only when no Reviewer verdict was computed.

## Planning-Assisted Creation & Creation-Time Quality Gate

When the user requests agent-drafted AC / Execution Plan during creation, the draft gets a live quality review **before** the task is created. The verdict decides the status — but on a non-PASS verdict, **the user decides what happens next; never silently create the task**. The Reviewer's gaps are typically requester-side information (who approves, what the brief is) that only the user can supply, so the choice between fixing now and parking the task is theirs.

1. **Draft**: spawn the appropriate planning agent — `code-planning-agent` when the task has a Working Directory / repository target, `knowledge-planning-agent` otherwise — with the gathered Title, Description, Context, and Executor. It returns AC + Execution Plan.
2. **Review**: invoke the `reviewing-quality` skill in `live` mode on the drafted spec. The task does not exist yet, so the deferred-write contract applies: hold the returned `verdict_string` and findings block in memory for the create payload.
3. **Branch on the verdict**:
   - **PASS** → show the drafted AC/EP and proceed with Status Auto-Determination above (Rubric `valid: true` → create at **Ready** with the `Quality Verdict` property set to `verdict_string` in the same create payload).
   - **NEEDS_REFINEMENT / REJECT** → show the drafted AC/EP together with the Reviewer's per-axis findings, gaps, and suggested fixes, then ask via AskUserQuestion:
     - **`[Refine now]`** — resolve the gaps interactively, see the refine loop below.
     - **`[Create at Backlog as-is]`** — create with **Status = Backlog**, `Quality Verdict` = `verdict_string`, and `Context` containing the findings block returned by `reviewing-quality` (appended after any user-provided context). For `REJECT`, apply the `[NEEDS-REFINE]` prefix to AC and EP per the protocol's reserved prefixes. The final summary must state what needs fixing before the task can be promoted to Ready.

**Refine loop (user-driven, runs until PASS):**

1. Derive one concrete question per requester-side gap (e.g. "Who approves the In Review step, and via what channel?") and ask the user via AskUserQuestion. Gaps an agent can resolve alone (internal inconsistencies the Reviewer already named a fix for) need no question — carry the fix forward directly.
2. Re-spawn the planning agent with the user's answers and the Reviewer's suggested fixes attached as additional context.
3. Re-invoke `reviewing-quality` in `live` mode on the revised draft, passing the previous round's `verdict_string` and failing axes as the `prior_verdict` hint — the task does not exist yet, so this hint is the only way its suppression check can count consecutive same-axis failures.
4. Branch again as in step 3 above. The loop ends when:
   - the verdict is **PASS** (create at Ready), or
   - the user picks **`[Create at Backlog as-is]`** (create at Backlog with the latest verdict + findings block; for `REJECT`, apply the `[NEEDS-REFINE]` prefix to AC and EP as in step 3), or
   - **suppression triggers** (two consecutive failures on the same axis) — create at Backlog with the suppressed verdict + findings block (same `[NEEDS-REFINE]` rule for `REJECT`) and tell the user re-review is frozen for 7 days unless they substantively rewrite the spec.

Each round costs one planning-agent and one Reviewer call but is gated on the user's explicit choice to continue, so the loop cannot run away on its own.
