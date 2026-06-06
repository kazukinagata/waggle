---
name: viewing-tasks
description: >
  Renders task data as interactive HTML dashboards (Kanban, List, Calendar, Gantt).
  In cli / claude-desktop the dashboard is served by a local view server on
  localhost:3456. In Cowork the dashboard is registered as a Live Artifact that
  fetches Notion data directly via window.cowork.callMcpTool.
  Use this skill whenever the user wants to see tasks visually — board views,
  timelines, calendars, or any kind of task visualization or dashboard display.
  Read-only views only. For any write, or a scoped filter that may lead to a
  mutation, route through `managing-tasks` instead.
  Triggers on: "kanban", "list view", "show tasks", "view", "visualize",
  "gantt", "calendar", "board", "timeline", "display tasks", "open dashboard".
user-invocable: true
---

# Waggle — Tasks Dashboard

You render the user's tasks as an interactive dashboard. The transport depends on the execution environment; the user-visible interface (Kanban / List / Calendar / Gantt) is the same in every environment.

## Output Discipline

This skill runs as a multi-step pipeline, but the user only needs its outcomes. Do not
narrate step transitions ("Now I'll...", "X done, next Y") and do not relay protocol
internals — provider detection, config/schema checks, cache state, validation plumbing,
view-server data pushes (POST /api/data). Surfacing them buries what actually matters.

Emit user-facing text only when it changes something for the user:

- a prompt or confirmation that needs their input
- an error or a warning
- an intermediate result that changes the outcome
- the final result summary

The view server URL (`http://localhost:3456`) and dashboard status are this skill's final
result and must always surface.

## Session Bootstrap

Invoke the `bootstrap-session` skill to establish the active provider, the current user, and `execution_environment`. Skip if these are already set in this conversation.

## Mode Selection

Pick the transport based on `execution_environment` (set by bootstrap):

- **`cowork`** → use **Cowork Live Artifact Mode** (below). localhost is not reachable from the user's browser in Cowork.
- **`cli`** / **`claude-desktop`** → use **Localhost Server Mode** (below). The local view server hosts the dashboard at `http://localhost:3456`.

The two modes use the same `Task` data shape and the same set of view renderers (kanban / list / calendar / gantt). Only the transport and the host shell differ.

## Cowork Live Artifact Mode

In Cowork, the dashboard is a single Live Artifact (`id = "waggle-tasks"`) that bundles all four view renderers with a tab strip at the top. The artifact fetches Notion data itself via the **notion-query** tool from the notion-extension MCP; refresh is driven by Cowork's built-in ↻ button or the in-page refresh, both of which re-run the artifact JS.

### Steps

1. Resolve `tasksDatabaseId` from `headless_config` (set during bootstrap). If `current_team` is set, capture `current_team.id` / `current_team.name` for baking into the artifact.

2. Determine the assignee to scope the artifact to. By default this is `current_user.id` (the person opening the artifact almost always wants their own open tasks, not the entire workspace). If the user has explicitly asked to view another person's tasks ("show Alice's board", "build a dashboard for the platform team lead"), resolve that person via the `looking-up-members` skill and use their Notion user ID instead.

3. **Resolve the Notion-query MCP tool name.** Look through your available MCP tools and find the one whose unqualified name is `notion-query` and that comes from the notion-extension MCP (its full name typically looks like `mcp__notion-extension__notion-query`, but the exact prefix depends on the installed extension version's manifest — never hardcode it). Use that exact, full tool name as the 5th argument to the generator below **and** as the value in the `mcp_tools` array when calling `create_artifact` / `update_artifact`. If you cannot find such a tool, surface the failure to the user and stop — the artifact cannot operate without it.

4. Generate the bundled HTML. The 4th argument is the assignee Notion user ID; the 5th argument is the resolved MCP tool name from Step 3. The bundle will server-side filter to that assignee AND exclude Done/Cancelled at the Notion query layer:

   ```bash
   bash "${CLAUDE_SKILL_DIR}/scripts/generate-cowork-artifact.sh" \
     "<tasksDatabaseId>" \
     "<current_team.id or empty>" \
     "<current_team.name or empty>" \
     "<assignee notion user id, e.g. current_user.id>" \
     "<the full MCP tool name you resolved in Step 3>" \
     > /tmp/waggle-tasks.html
   ```

   Pass an empty string for the 4th argument only if the user has explicitly asked for an unscoped view across all assignees; the bundle then shows all open tasks with an informational banner. Status exclusion (Done + Cancelled) is always applied — these terminal states are never useful in the active dashboard.

5. Call `mcp__cowork__list_artifacts()` and check whether the response includes an entry with `id == "waggle-tasks"`.

6. **If the artifact already exists**, refresh it in place via `update_artifact` (don't create a duplicate):

   ```
   mcp__cowork__update_artifact({
     id: "waggle-tasks",
     html_path: "/tmp/waggle-tasks.html",
     update_summary: "[REFRESH] regenerated against latest schema / team / assignee scope",
     mcp_tools: ["<the full MCP tool name you resolved in Step 3>"]
   })
   ```

   This re-bakes the latest `databaseId` / `currentTeam` / `assigneeUserId` and picks up any code changes since the last registration. The user gets the Cowork approval prompt on update.

7. **If the artifact does not exist**, register it via `create_artifact`:

   ```
   mcp__cowork__create_artifact({
     id: "waggle-tasks",
     html_path: "/tmp/waggle-tasks.html",
     description: "Waggle Tasks Dashboard — Kanban / List / Calendar / Gantt",
     mcp_tools: ["<the full MCP tool name you resolved in Step 3>"]
   })
   ```

8. Clean up the temp file: `rm -f /tmp/waggle-tasks.html`. Tell the user to open the **waggle-tasks** Live Artifact panel in the Cowork sidebar (or, on update, reload the existing panel).

### Cowork-mode behavior

- The artifact bundles Kanban / List / Calendar / Gantt; the active tab is persisted per-user in `localStorage` (`waggle-tasks-active-tab-v1`).
- Each artifact reload re-fetches via the resolved notion-query MCP tool (paginated, cap 1000 rows). The fetch is server-side filtered to the baked `assigneeUserId` and always excludes `Status == Done` / `Status == Cancelled`; the bundled `filter-bar.js` narrows further on the client. The status badge reads "Live (Cowork)" when the fetch succeeds. To switch the bound assignee, re-run `/viewing-tasks` with the new person's name — the skill regenerates and calls `update_artifact` with the new scope.
- The artifact is **read-only**. Mutating Notion tools are deliberately not declared in `mcp_tools` yet; inline-edit UI will come in a later skill release and will widen `mcp_tools` via `update_artifact`.
- **Cold-start race (GitHub Issue #55788)**: on either Windows or macOS the artifact's first call to `callMcpTool` may fail with HTTP 400 in a cold-start state. Workaround: ask the user to invoke any Notion MCP tool from the Cowork chat once before opening the artifact, then reload the panel.
- Custom user-defined views are managed by the `managing-views` skill and registered as separate `waggle-view-<slug>` artifacts.

### Troubleshooting

- **"Cowork runtime unavailable" banner** in the artifact: the cold-start race fired. Reload the panel, or have the user run any Notion MCP tool from chat first.
- **"Failed to load tasks: ..."**: open DevTools on the artifact panel (right-click → Inspect). Network tab shows the `callMcpTool` request; Console shows any JS errors. Verify the baked `databaseId` matches the active `tasksDatabaseId`.
- **`Tool call failed: 400` from the artifact (with chat-mode calls succeeding)**: known Cowork-platform issue with extension tool prefixes that contain **underscores**. Isolation testing confirms the bridge accepts prefixes with uppercase letters (e.g. `mcp__EchoUpper__...` works) but rejects prefixes with underscores (e.g. `mcp__echo_lower_only__...` returns 400). The prefix is derived from the extension manifest's `display_name`; a manifest with a `display_name` containing whitespace gets normalized with whitespace converted to `_`, producing a prefix that the Live Artifact bridge currently rejects, even though chat-mode calls work. Mitigation: install notion-extension v0.5.0+ which drops `display_name` and yields a hyphenated `mcp__notion-extension__...` prefix that the bridge accepts. Older v0.4.x installs keep working from chat but not from Live Artifact.
- **Dashboard shows stale data**: click the Cowork built-in ↻, which re-executes the artifact JS and re-fetches.
- **Stale artifact (schema changed, wrong team, wrong assignee)**: re-run `/viewing-tasks` — the skill regenerates and calls `update_artifact` with the latest `databaseId` / team / assignee binding.
- **"My dashboard is empty / shows the wrong person's tasks"**: the baked `assigneeUserId` may not match the user's expectations. Re-run `/viewing-tasks` (defaults to `current_user.id`) or `/viewing-tasks <name>` to scope to someone else. To see everyone, ask for an unscoped regeneration explicitly.

## Localhost Server Mode

In cli / claude-desktop, the dashboard is served from a local Hono server on `http://localhost:3456`. The skill ensures the server is running, pushes the current task snapshot, and opens the browser.

### Starting the Server

```bash
cd "${CLAUDE_SKILL_DIR}/server" && npm ci --silent && npx tsx src/index.ts &
```

Before starting, check if it's already running:

```bash
curl -s http://localhost:3456/api/health 2>/dev/null
```

If the health check succeeds, the server is already running. Do NOT start a second instance.

### Available Views

| View | URL | Status |
|---|---|---|
| View Selector | http://localhost:3456/ | Available |
| List | http://localhost:3456/list.html | Available |
| Kanban | http://localhost:3456/kanban.html | Available |
| Calendar | http://localhost:3456/calendar.html | Available |
| Gantt | http://localhost:3456/gantt.html | Available |

### Opening a View

After ensuring the server is running, open the appropriate URL in the user's browser:

```bash
# macOS
open http://localhost:3456/kanban.html

# Linux
xdg-open http://localhost:3456/kanban.html

# WSL
wslview http://localhost:3456/kanban.html
```

Detect the platform and use the appropriate command.

### Initializing Data After Start

After starting the server, push current task data so the view is populated.
Follow the **Pushing Data to View Server** section in the active provider's SKILL.md to:
1. Fetch all tasks from the data source
2. Format as `{ "tasks": [...], "updatedAt": "<ISO timestamp>", "currentTeam": { "id": "<id>", "name": "<name>" } }` (include `currentTeam` if `current_team` is set from resolving-identity; omit if null)
3. POST to `http://localhost:3456/api/data`

### Custom Views

Users can create custom visualizations using the `managing-views` skill. Custom views are served at `/custom/<slug>.html`.

#### Opening a Custom View

```bash
# macOS
open http://localhost:3456/custom/<slug>.html

# Linux
xdg-open http://localhost:3456/custom/<slug>.html

# WSL
wslview http://localhost:3456/custom/<slug>.html
```

#### Listing Custom Views

```bash
ls ~/.waggle/views/*.html
```

To create, delete, or regenerate custom views, use the `managing-views` skill.

### View Features (Localhost Mode)

All views support:
- **Real-time updates**: Connected to SSE at `/api/events`. Changes made via managing-tasks skill are reflected automatically.
- **Client-side filtering**: Filter by Status, Priority, search text
- **Click-to-copy**: Click a task to copy its ID for use in Claude Code
- **Dark mode**: Default dark theme

### Troubleshooting (Localhost Mode)

If views don't update after task changes:
1. Check the server is running: `curl http://localhost:3456/api/health`
2. Manually push data: use the managing-tasks skill to query tasks and POST to `/api/data`
3. Check server logs in the terminal where it's running
