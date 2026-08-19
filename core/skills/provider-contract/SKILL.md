---
name: provider-contract
description: >
  Waggle provider plugin development guide and interface contract.
  Defines the required SKILL.md sections, data shapes, naming conventions,
  and compliance checklist for building a waggle provider plugin.
  Trigger on: "provider contract", "provider interface", "create provider plugin",
  "new provider", "provider compliance", "how to build a provider".
user-invocable: true
---

# Waggle Provider Contract

This document defines the interface contract for building a waggle provider plugin. A provider plugin connects waggle to a specific data store (Notion, SQLite, Turso, etc.) by implementing a standardized set of operations and SKILL.md sections.

## How Provider Discovery Works

Waggle core discovers provider skills differently depending on the runtime environment:

- **Cowork**: Provider skills appear in the `<available_skills>` system prompt block. Each skill is listed with `<name>`, `<description>`, and `<location>`.
- **CLI / Claude Desktop**: Provider skills are registered via `installed_plugins.json`. The plugin's `.claude-plugin/plugin.json` declares the plugin metadata.

In all environments, waggle core loads the provider SKILL.md via the Skill tool. `${CLAUDE_PLUGIN_ROOT}` in the provider SKILL.md is automatically resolved to the provider plugin's absolute path.

## Naming Conventions

Follow these naming rules strictly:

| Entity | Pattern | Example |
|---|---|---|
| Plugin directory | `waggle-{provider}` | `waggle-sqlite` |
| Setup skill | `{provider}-setup` | `sqlite-setup` |
| Provider skill | `{provider}-provider` | `sqlite-provider` |
| Plugin name in plugin.json | `waggle-{provider}` | `waggle-sqlite` |

- The setup skill MUST be `user-invocable: true`.
- The provider skill MUST be `user-invocable: false`.
- The provider skill MUST operate silently: it returns results to the invoking skill and
  produces no user-facing narration of its own (no progress reports, no step announcements).
  Only errors, warnings, and prompts required to proceed may surface directly. The invoking
  skill owns all user communication — this keeps the user-visible output of a waggle flow
  identical regardless of which provider backs it.

## Plugin Directory Structure

```
waggle-{provider}/
├── .claude-plugin/
│   └── plugin.json          # Plugin metadata (name, version, description)
├── skills/
│   ├── {provider}-setup/
│   │   ├── SKILL.md         # user-invocable: true — initial setup wizard
│   │   └── references/      # Setup-specific references (optional)
│   └── {provider}-provider/
│       ├── SKILL.md         # user-invocable: false — all provider operations
│       └── scripts/         # Bash scripts using SCRIPT_DIR pattern
└── CLAUDE.md                # Project-level instructions
```

## Required Sections in Provider SKILL.md

The `{provider}-provider/SKILL.md` file MUST contain all of the following sections with exact headings. Waggle core skills reference these sections by name.

### 1. Config Retrieval

Retrieve provider configuration (database IDs, constants) and populate the `headless_config` session variable.

Requirements:
- MUST be self-sufficient — do not depend on a local config file as the sole source.
- Each provider uses its natural storage for config:
  - Notion: Search for the "Waggle Config" page, parse JSON code block.
  - Turso: Read from `TURSO_URL` and `TURSO_AUTH_TOKEN` environment variables.
  - SQLite: Use a default path (`~/.waggle/waggle.db`) or `WAGGLE_SQLITE_PATH` env var.
- `~/.waggle/config.json` MAY be used as a local cache for faster startup, but MUST NOT be the only source.
- If config is not found, instruct the user to run the `{provider}-setup` skill, then stop.

The `headless_config` object MUST include at minimum:
- `tasksDatabaseId` (or equivalent identifier for the tasks data source)

Optional fields:
- `teamsDatabaseId`
- `intakeLogDatabaseId`

### 2. Schema Validation & Auto-Repair

Verify that all 15 Core fields exist in the backing store. See `references/task-schema.md` for the complete field list.

Requirements:
- On startup, check every Core field exists with the correct type.
- If any Core field is missing, automatically repair it — create the field with sensible defaults.
- Never ask the user to manually fix the schema.
- After repair, re-verify and continue.

### 3. CRUD Operations

Implement Create, Read, Update, and Delete for tasks.

Requirements:
- **Create**: Accept all Core and Extended fields. Return the created task ID.
- **Read**: Retrieve a single task by ID with all field values.
- **Update**: Update one or more fields on an existing task by ID.
- **Delete**: Delete a task by ID.
- Document which MCP tools or API calls are used for each operation.

### 4. Query Tasks

Filter and sort tasks, returning results in the standard query output format.

Requirements:
- Accept filter and sort parameters.
- Return `{ "results": [Task, Task, ...] }` — see `references/query-output-format.md`.
- Support filtering by: Status, Priority, Executor, Assignee.
- Support sorting by: Priority, Due Date.
- Document the query mechanism (API script, SQL query, MCP tool).
- Include a "Fetch All Tasks" variant with no filter for view server data push.
- Include a "Displaying Task Lists" variant that extracts only display-relevant fields.

### 5. Identity Resolution

Resolve the current user, team membership, and org members.

Requirements:
- **Current User**: Return `{ id, name, email }`. Provide a fallback using `$USER` env var if the provider API is unavailable.
- **Team Membership**: Given `teamsDatabaseId`, determine which teams the current user belongs to. Handle single-team, multi-team (ask user), and no-team cases.
- **Org Members**: List all workspace/org members as `{ id, name, email }[]`. Provide a fallback (empty array) if unavailable.
- **Self-Task Detection**: Describe how to check if a task is assigned to the current user.

### 6. View Server Data Push

Push task data to the local view server after any task mutation.

Requirements:
- Fetch all tasks from the data source.
- Transform into the `TasksResponse` shape: `{ "tasks": [...], "updatedAt": "<ISO timestamp>" }`.
- POST to `http://localhost:3456/api/data`.
- Silently skip if the view server is not running (check health endpoint first).

### 7. On Completion Template

Define the instructions injected into dispatch prompts so dispatched agents know how to report results. See `references/dispatch-completion-template.md` for the full specification.

Requirements:
- Include the task ID placeholder.
- Specify how to write results to Agent Output.
- Specify how to update Status based on Requires Review.
- Specify how to record errors to Error Message.
- Use absolute paths for any scripts. MUST NOT use `${CLAUDE_PLUGIN_ROOT}`.

### 8. Error Handling

Define error categories and retry behavior.

Requirements:
- Classify errors into retryable (transient network errors, rate limits) and terminal (auth failures, missing permissions, invalid schema).
- For retryable errors: specify max retries and backoff strategy.
- For terminal errors: specify the user-facing message and recovery action.
- Provider API errors MUST NOT crash the skill — handle gracefully and report.

## Script Path Convention

Bash scripts in the provider plugin MUST follow these rules:

1. Use the `SCRIPT_DIR` pattern for self-referencing paths:
   ```bash
   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
   ```

2. MUST NOT use `${CLAUDE_PLUGIN_ROOT}` in bash scripts. This variable is only available in the SKILL.md instruction context, not in shell execution.

3. SKILL.md instructions MUST reference their own scripts through `${CLAUDE_SKILL_DIR}` **and MUST resolve it before use** — see § Resolving the Skill Directory below. Calling `bash ${CLAUDE_SKILL_DIR}/scripts/foo.sh` directly is forbidden: it fails on every runtime whose shell does not share a filesystem with the agent loop. Never hardcode `${CLAUDE_PLUGIN_ROOT}/skills/<this-skill-name>/...` either — that pattern silently breaks on rename.

4. Scripts that call other scripts within the plugin MUST use `SCRIPT_DIR`-relative paths:
   ```bash
   source "${SCRIPT_DIR}/helpers.sh"
   ```

5. MUST NOT feed a shell-emitted path back into a later shell command. On Cowork,
   listing files under a connected folder from the shell prints *host* paths, not the
   VM paths the shell itself can open. A path a shell printed may be unusable by the
   next shell. Always recompute a path from `${CLAUDE_SKILL_DIR}` (or from the
   connected-folder root) rather than round-tripping one through command output.

## Resolving the Skill Directory

`${CLAUDE_SKILL_DIR}` is substituted into a bash code block when the skill is loaded,
and the value is a path in the **agent loop's** filesystem. On runtimes where code
execution happens in the same filesystem — CLI and Claude Desktop — that path is
directly usable. On Cowork it is not: the agent loop runs natively on the host while
Bash runs in an isolated Linux VM, and the host path does not exist there. The
substituted value is a literal, not a shell lookup — `CLAUDE_SKILL_DIR` is absent
from the VM's environment.

Providers MUST therefore resolve the directory in shell before invoking a bundled
script, and MUST fail closed when resolution does not land on the expected file.

### The canonical resolver

Parameterise `SCRIPT` with the path of the script being invoked, relative to the
skill directory. Everything else is copied verbatim.

```bash
SCRIPT=scripts/query-tasks.sh; SKILL_DIR="${CLAUDE_SKILL_DIR}"
if [ ! -d "$SKILL_DIR" ]; then _S="${PWD%%/mnt/*}"; _R="$_S/mnt/.remote-plugins"
  case "$SKILL_DIR" in */plugin_*) _P="plugin_${SKILL_DIR#*/plugin_}"; SKILL_DIR="$_R/$_P"
    if [ ! -f "$SKILL_DIR/$SCRIPT" ]; then _M=$(find "$_R/${_P%%/*}" -path "*/$SCRIPT" 2>/dev/null)
      [ "$(printf %s "$_M" | grep -c .)" = 1 ] && SKILL_DIR="${_M%/$SCRIPT}"; fi ;;
  esac
fi
[ -f "$SKILL_DIR/$SCRIPT" ] || { echo "waggle: skill directory unresolved; $SCRIPT not found. Operation not performed." >&2; exit 1; }
bash "$SKILL_DIR/$SCRIPT" '<where_clause>' '<order_clause>'
```

Three tiers, in order:

1. **Convert the path.** Deterministic; no search. The host path carries the
   `plugin_<id>/skills/<name>` tail, which is the one segment common to every route,
   so the plugin is identified exactly.
2. **Scoped search.** Only if tier 1 misses the expected file. Searches under
   `.remote-plugins` alone, narrowed to the plugin id taken from the host path, and
   accepts the result only when exactly one candidate carries the script. Insurance
   against a change in mount layout.
3. **Fail closed.** The script is not run and the caller reports that the operation
   was not performed.

### Why each line is what it is

Do not "simplify" this. Each clause carries a specific failure mode:

- `SKILL_DIR="${CLAUDE_SKILL_DIR}"` is a literal after substitution. If a future
  runtime stops substituting, the shell expands it to the empty string, every check
  below fails, and the snippet degrades to fail-closed rather than to a wrong path.
- `[ ! -d "$SKILL_DIR" ]` discriminates runtimes without naming one. On CLI and
  Claude Desktop the directory exists, the branch is skipped, and behaviour is
  byte-for-byte unchanged. Do not replace this with a `-f` test on the script — the
  `-d` test is what guarantees the untouched path.
- `${PWD%%/mnt/*}` yields the session root whether the working directory is the root
  itself or sits under the mount. `%%` (longest match) is required.
- The `case */plugin_*)` guard rewrites only a path that actually contains a
  `plugin_` segment. An unexpected shape is left alone and fails closed instead of
  being fabricated.
- `${SKILL_DIR#*/plugin_}` uses `#` (shortest match), so the cut lands on the
  *first* `/plugin_` — the plugin root. `##` would cut at the last one and produce a
  broken path. The literal `plugin_` is prepended because the cut consumes it.
- Naming the script once, in `SCRIPT`, keeps the `-f` guard and the invocation from
  ever disagreeing.

### Obtaining the resolved path without running the script

Dispatch generation needs the resolved *path*, not the script's output. The canonical
block ends by executing the script, and its shell variables die when the Bash call
exits, so a caller cannot read `$SKILL_DIR` out of it afterwards. Use the same resolver
with a printing final line instead:

```bash
SCRIPT=scripts/turso-exec.sh; SKILL_DIR="${CLAUDE_SKILL_DIR}"
if [ ! -d "$SKILL_DIR" ]; then _S="${PWD%%/mnt/*}"; _R="$_S/mnt/.remote-plugins"
  case "$SKILL_DIR" in */plugin_*) _P="plugin_${SKILL_DIR#*/plugin_}"; SKILL_DIR="$_R/$_P"
    if [ ! -f "$SKILL_DIR/$SCRIPT" ]; then _M=$(find "$_R/${_P%%/*}" -path "*/$SCRIPT" 2>/dev/null)
      [ "$(printf %s "$_M" | grep -c .)" = 1 ] && SKILL_DIR="${_M%/$SCRIPT}"; fi ;;
  esac
fi
[ -f "$SKILL_DIR/$SCRIPT" ] || { echo "waggle: skill directory unresolved; $SCRIPT not found. Operation not performed." >&2; exit 1; }
printf '%s\n' "$SKILL_DIR/$SCRIPT"
```

Capture stdout and inject that literal into the dispatch template. The resolver body is
identical — only the last line differs — so the path is validated by the same
fail-closed guard before it is printed; an unresolved directory prints nothing and exits
non-zero, and a template must not be emitted in that case.

This is the one sanctioned exception to "never feed a shell-emitted path back into a
later shell command", and it is narrow: the path goes into *another agent's prompt*, not
into a later shell command in this session, and only where the dispatcher and the
receiver share a filesystem. See § On Completion Template for that precondition.

### Rules for applying it

- **Resolution and invocation MUST sit in the same shell invocation.** Every Bash
  call is a fresh process, so a resolver placed once at the top of a document
  section does not apply to the commands below it.
- **The snippet is a template.** `SCRIPT` is filled with *this* script's path. A
  block copied between skills with another skill's script name resolves the wrong
  directory.
- **Never reimplement a script's logic in the model** when resolution fails. Report
  that the operation was not performed. A deterministic check replaced by an
  improvised one returns a plausible answer instead of an error, which is worse than
  no answer.
- **Reading** a bundled reference file with Read, Glob, or Grep needs no resolution —
  those tools reach the agent loop's own filesystem. The rule is narrow: do not read
  or execute a bundled file *through the shell* without resolving first.
- **Dispatch generation** substitutes the resolved literal absolute path; neither
  `${CLAUDE_*}` nor `$SKILL_DIR` may survive into a dispatch prompt. See § On
  Completion Template.

## Config Storage

Provider configuration is cached per execution environment so bootstrap can skip remote lookups on subsequent sessions:

- **CLI / Claude Desktop**: environment variables in `~/.claude/settings.json` (under the `env` field).
- **Cowork**: a `<waggle-config>{json}</waggle-config>` block in Global Instructions. Cowork's session home is created fresh per session and is permission-denied from other sessions, so `~/.claude/settings.json` is not durable there. (A connected folder *is* host-backed and persists across sessions, but the user picks it per session, so it is not a dependable config location.)

The legacy `~/.waggle/config.json` file is deprecated — use the `health-checking` skill to migrate.

| Provider | Cache (CLI / Claude Desktop) | Cache (Cowork) | Fallback |
|---|---|---|---|
| Notion | env vars: `WAGGLE_NOTION_TASKS_DB_ID`, `WAGGLE_NOTION_TEAMS_DB_ID`, `WAGGLE_NOTION_INTAKE_LOG_DB_ID`, `WAGGLE_NOTION_SPRINTS_DB_ID`, `WAGGLE_NOTION_ACTIVE_THREADS_DB_ID` | `<waggle-config>` JSON in Global Instructions | "Waggle Config" Notion page search (exact title match) |
| Turso | env vars: `TURSO_URL`, `TURSO_AUTH_TOKEN` (required) | n/a (Cowork unsupported) | None |
| SQLite | env vars: `WAGGLE_SQLITE_DB_PATH` (optional, default: `~/.waggle/tasks.db`) | n/a (Cowork unsupported) | Default path |

## Environment Support

Not all providers support all execution environments:

| Provider | CLI | Claude Desktop | Cowork | Notes |
|---|---|---|---|---|
| Notion | Yes | Yes | Yes | Requires Notion MCP tools |
| Turso | Yes | Yes | No | Requires `TURSO_URL` and `TURSO_AUTH_TOKEN` env vars; Cowork requires Desktop Extension (not yet available) |
| SQLite | Yes | Yes | No | Local file — not accessible from Cowork |

See `references/environment-detection.md` for runtime environment detection logic.

## Provider Compliance Checklist

Use this checklist to verify a provider plugin meets all requirements before release:

### Plugin Structure
- [ ] Plugin directory follows `waggle-{provider}` naming
- [ ] `.claude-plugin/plugin.json` exists with correct metadata
- [ ] Setup skill exists at `skills/{provider}-setup/SKILL.md` with `user-invocable: true`
- [ ] Provider skill exists at `skills/{provider}-provider/SKILL.md` with `user-invocable: false`

### Provider SKILL.md Sections
- [ ] Config Retrieval — self-sufficient, not solely dependent on local config file
- [ ] Schema Validation & Auto-Repair — all 15 Core fields verified and auto-repaired
- [ ] CRUD Operations — Create, Read, Update, Delete documented
- [ ] Query Tasks — filter/sort with `{ "results": [...] }` output format
- [ ] Identity Resolution — current user, teams, org members, self-task detection
- [ ] View Server Data Push — TasksResponse shape, POST to localhost:3456
- [ ] On Completion Template — task ID placeholder, absolute paths, no `${CLAUDE_PLUGIN_ROOT}`
- [ ] Error Handling — retryable vs terminal classification

### Script Conventions
- [ ] All bash scripts use `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"` pattern
- [ ] No `${CLAUDE_PLUGIN_ROOT}` in bash scripts
- [ ] SKILL.md references its own scripts through `${CLAUDE_SKILL_DIR}`
- [ ] Every shell invocation of a bundled script applies the canonical resolver from
  § Resolving the Skill Directory, in the same shell invocation, with `SCRIPT` set to
  that script's own path
- [ ] Inside a shell block, `${CLAUDE_SKILL_DIR}` appears **only** in the resolver's
  `SKILL_DIR=` assignment — every downstream use is `"$SKILL_DIR"`. This covers every
  way a path reaches the shell (`bash`, `cd`, `source`, `cat`, shell `grep`, `<`
  redirection, or executing the path directly), not just the obvious ones
- [ ] Resolution failure fails closed — the script is not run and no model-improvised
  substitute is used
- [ ] No shell-emitted path is fed back into a later shell command

### Schema Support
- [ ] All 15 Core fields supported with correct types
- [ ] Extended fields supported with graceful degradation if absent
- [ ] Auto-repair creates missing fields without user intervention
- [ ] `supportsFileHosting` declared for the `Attachments` (`file[]`) field. Providers with
  `supportsFileHosting=false` accept attachments only as externally-hosted URLs; skills MUST NOT upload local
  files to them. See task-schema § Provider Mapping.

### Data Format
- [ ] Query output matches `{ "results": [Task, ...] }` format
- [ ] Task objects include `id` and all populated field values
- [ ] View server data matches `TasksResponse` shape
