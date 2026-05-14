---
name: viewing-tasks
description: >
  Renders task data as interactive HTML dashboards (Kanban, List, Calendar, Gantt).
  In cli / claude-desktop the dashboard is served by a local view server on
  localhost:3456. In Cowork the dashboard is registered as a Live Artifact that
  fetches Notion data directly via window.cowork.callMcpTool.
  Use this skill whenever the user wants to see tasks visually — board views,
  timelines, calendars, or any kind of task visualization or dashboard display.
  Triggers on: "kanban", "list view", "show tasks", "view", "visualize",
  "gantt", "calendar", "board", "timeline", "display tasks", "open dashboard".
user-invocable: true
---

# Waggle — Tasks Dashboard

You render the user's tasks as an interactive dashboard. The transport depends on the execution environment; the user-visible interface (Kanban / List / Calendar / Gantt) is the same in every environment.

## Session Bootstrap

Invoke the `bootstrap-session` skill to establish the active provider, the current user, and `execution_environment`. Skip if these are already set in this conversation.

## Mode Selection

Pick the transport based on `execution_environment` (set by bootstrap):

- **`cowork`** → use **Cowork Live Artifact Mode** (below). localhost is not reachable from the user's browser in Cowork.
- **`cli`** / **`claude-desktop`** → use **Localhost Server Mode** (below). The local view server hosts the dashboard at `http://localhost:3456`.

The two modes use the same `Task` data shape and the same set of view renderers (kanban / list / calendar / gantt). Only the transport and the host shell differ.

## Cowork Live Artifact Mode

In Cowork, the dashboard is a single Live Artifact (`id = "waggle-tasks"`) that bundles all four view renderers with a tab strip at the top. The artifact fetches Notion data itself via `mcp__Notion_Extension_for_Waggle__notion-query`; refresh is driven by Cowork's built-in ↻ button or the in-page refresh, both of which re-run the artifact JS.

### Steps

1. Resolve `tasksDatabaseId` from `headless_config` (set during bootstrap). If `current_team` is set, capture `current_team.id` / `current_team.name` for baking into the artifact.

2. Call `mcp__cowork__list_artifacts()`. If the response includes an entry with `id == "waggle-tasks"`, the dashboard is already registered. Tell the user:

   > "Your Tasks Dashboard is already registered. Open the **waggle-tasks** Live Artifact panel in Cowork to view it."

   Stop here — do **not** re-register.

3. Otherwise (no existing artifact), generate the bundled HTML and register it:

   ```bash
   bash "${CLAUDE_SKILL_DIR}/scripts/generate-cowork-artifact.sh" \
     "<tasksDatabaseId>" \
     "<current_team.id or empty>" \
     "<current_team.name or empty>" \
     > /tmp/waggle-tasks.html
   ```

   Then call:

   ```
   mcp__cowork__create_artifact({
     id: "waggle-tasks",
     html_path: "/tmp/waggle-tasks.html",
     description: "Waggle Tasks Dashboard — Kanban / List / Calendar / Gantt",
     mcp_tools: ["mcp__Notion_Extension_for_Waggle__notion-query"]
   })
   ```

   Clean up the temp file afterwards: `rm -f /tmp/waggle-tasks.html`.

4. Tell the user the artifact has been registered and to open the **waggle-tasks** Live Artifact panel in the Cowork sidebar.

### Cowork-mode behavior

- The artifact bundles Kanban / List / Calendar / Gantt; the active tab is persisted per-user in `localStorage` (`waggle-tasks-active-tab-v1`).
- Each artifact reload re-fetches via `mcp__Notion_Extension_for_Waggle__notion-query` (paginated, cap 1000 rows). The status badge reads "Live (Cowork)" when the fetch succeeds.
- The artifact is **read-only**. Mutating Notion tools are deliberately not declared in `mcp_tools` yet; inline-edit UI will come in a later skill release and will widen `mcp_tools` via `update_artifact`.
- **Windows cold-start (GitHub Issue #55788)**: on Windows the artifact's first call to `callMcpTool` may fail with HTTP 400 in a cold-start state. Workaround: ask the user to invoke any Notion MCP tool from the Cowork chat once before opening the artifact, then reload the panel. Mac is unaffected.
- Custom user-defined views are managed by the `managing-views` skill and registered as separate `waggle-view-<slug>` artifacts.

### Troubleshooting

- **"Cowork runtime unavailable" banner** in the artifact: the cold-start race fired. Reload the panel, or have the user run any Notion MCP tool from chat first.
- **"Failed to load tasks: ..."**: open DevTools on the artifact panel (right-click → Inspect). Network tab shows the `callMcpTool` request; Console shows any JS errors. Verify the baked `databaseId` matches the active `tasksDatabaseId`.
- **Dashboard shows stale data**: click the Cowork built-in ↻, which re-executes the artifact JS and re-fetches.
- **Stale artifact (schema changed, wrong team)**: re-run `/viewing-tasks` — the skill regenerates and calls `update_artifact` with the latest `databaseId` / team binding.

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
