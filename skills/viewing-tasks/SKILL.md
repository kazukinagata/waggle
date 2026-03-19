---
name: viewing-tasks
description: >
  Manages the local view server that renders task data as interactive HTML pages
  (Kanban, List, Calendar, Gantt). Starts the server, pushes data, and opens views.
  Triggers on: "kanban", "list view", "show tasks", "view", "visualize",
  "gantt", "calendar",
  "カンバン", "リスト表示", "タスク表示", "ガント", "カレンダー".
---

# Waggle — View Server

You manage the local view server that renders task data as interactive HTML pages.

## Provider Detection (once per session)

Load `${CLAUDE_PLUGIN_ROOT}/skills/detecting-provider/SKILL.md` and follow its instructions to determine `active_provider`. Skip if already determined in this conversation.

## Environment Detection

Before starting, detect the runtime environment:

```bash
# Check if running in a remote/sandboxed environment where localhost is not accessible from the user's browser
if [ -n "${CLOUD_SHELL:-}" ]; then
  # Use static HTML export mode (see below)
  STATIC_MODE=true
else
  STATIC_MODE=false
fi
```

If `STATIC_MODE=true`, skip "Starting the Server" and go directly to **Static HTML Export** below.

## Starting the Server

The view server runs at `http://localhost:3456`. To start it:

```bash
cd ${CLAUDE_PLUGIN_ROOT}/skills/viewing-tasks/server && npx tsx src/index.ts &
```

Before starting, check if it's already running:

```bash
curl -s http://localhost:3456/api/health 2>/dev/null
```

If the health check succeeds, the server is already running. Do NOT start a second instance.

## Available Views

| View | URL | Status |
|---|---|---|
| View Selector | http://localhost:3456/ | Available |
| List | http://localhost:3456/list.html | Available |
| Kanban | http://localhost:3456/kanban.html | Available |
| Calendar | http://localhost:3456/calendar.html | Available |
| Gantt | http://localhost:3456/gantt.html | Available |

## Opening a View

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

## Initializing Data After Start

After starting the server, push current task data so the view is populated.
Follow the **Pushing Data to View Server** section in the active provider's SKILL.md to:
1. Fetch all tasks from the data source
2. Format as `{ "tasks": [...], "updatedAt": "<ISO timestamp>", "currentTeam": { "id": "<id>", "name": "<name>" } }` (include `currentTeam` if `current_team` is set from resolving-identity; omit if null)
3. POST to `http://localhost:3456/api/data`

## Custom Views

Users can create custom visualizations using the `managing-views` skill. Custom views are served at `/custom/<slug>.html`.

### Opening a Custom View

```bash
# macOS
open http://localhost:3456/custom/<slug>.html

# Linux
xdg-open http://localhost:3456/custom/<slug>.html

# WSL
wslview http://localhost:3456/custom/<slug>.html
```

### Listing Custom Views

```bash
ls ~/.waggle/views/*.html
```

### Static Export for Custom Views

```bash
${CLAUDE_PLUGIN_ROOT}/skills/viewing-tasks/scripts/generate-static-html.sh custom:<slug> /tmp/tasks.json > /tmp/<slug>.html
```

To create, delete, or regenerate custom views, use the `managing-views` skill.

## View Features

All views support:
- **Real-time updates**: Connected to SSE at `/api/events`. Changes made via managing-tasks skill are reflected automatically.
- **Client-side filtering**: Filter by Status, Priority, search text
- **Click-to-copy**: Click a task to copy its ID for use in Claude Code
- **Dark mode**: Default dark theme

## Static HTML Export

When running in a remote environment (e.g. cloud shell) where localhost is not accessible from the user's browser, generate a standalone HTML file with embedded task data instead of starting the server.

### Steps

1. Fetch all tasks from the data source (follow the active provider's SKILL.md)
2. Save the task data as a temporary JSON file:

```bash
cat > /tmp/tasks.json << 'TASKEOF'
{ "tasks": [...], "updatedAt": "<ISO timestamp>" }
TASKEOF
```

3. For sprint-backlog view, also save sprint data:

```bash
cat > /tmp/sprints.json << 'SPRINTEOF'
{ "sprints": [...], "currentSprintId": "..." }
SPRINTEOF
```

4. Generate the standalone HTML:

```bash
# For kanban, list, or product-backlog:
${CLAUDE_PLUGIN_ROOT}/skills/viewing-tasks/scripts/generate-static-html.sh <view> /tmp/tasks.json > /tmp/<view>.html

# For sprint-backlog (with sprint data):
${CLAUDE_PLUGIN_ROOT}/skills/viewing-tasks/scripts/generate-static-html.sh sprint-backlog /tmp/tasks.json /tmp/sprints.json > /tmp/sprint-backlog.html
```

Supported views: `kanban`, `list`, `sprint-backlog`, `product-backlog`

5. Present the generated HTML file to the user. In environments that support artifacts (e.g. Claude Desktop), output the HTML content directly so it can be rendered in the browser. Otherwise, inform the user of the file path.

6. Clean up temporary files:

```bash
rm -f /tmp/tasks.json /tmp/sprints.json /tmp/<view>.html
```

### Static Mode Behavior

- All task data is embedded in the HTML — no server or network access required
- SSE indicator shows "Static" instead of "Live"
- Filtering and search work normally (client-side)
- Back links to the view selector are disabled (single-file mode)

## Troubleshooting

If views don't update after task changes:
1. Check the server is running: `curl http://localhost:3456/api/health`
2. Manually push data: use the managing-tasks skill to query tasks and POST to `/api/data`
3. Check server logs in the terminal where it's running
