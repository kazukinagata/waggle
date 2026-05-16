---
name: managing-views
description: >
  Creates, lists, deletes, and regenerates custom task visualizations.
  In cli / claude-desktop they are HTML files served by the local view server.
  In Cowork each custom view is registered as its own Live Artifact (id
  `waggle-view-<slug>`) that fetches data via window.cowork.callMcpTool.
  Use this skill whenever the user wants to create, delete, customize, or
  manage saved task visualizations — custom dashboards, filtered boards, or
  personalized views. Triggers on: "create view", "custom view",
  "make a dashboard", "view of", "delete view", "list views",
  "regenerate view", "my view", "build a board", "design visualization".
user-invocable: true
---

# Waggle — Custom View Management

You manage custom task visualizations that users can create via natural language. The local HTML file at `~/.waggle/views/<slug>.html` is the source of truth in every environment; how it reaches the user differs by `execution_environment`.

## Session Bootstrap

Invoke the `bootstrap-session` skill to establish the active provider, the current user, and `execution_environment`. Skip if these are already set in this conversation.

## Directory Setup

Custom views are stored outside the plugin directory so they survive updates:

```bash
mkdir -p ~/.waggle/views
```

## Mode Selection

Pick the operation's transport based on `execution_environment`:

- **`cli`** / **`claude-desktop`** → the local view server (`localhost:3456`) serves each `~/.waggle/views/<slug>.html` at `/custom/<slug>.html`. Plain file create/delete/edit on disk.
- **`cowork`** → each custom view is registered as a Live Artifact with `id = "waggle-view-<slug>"` via `mcp__cowork__create_artifact`. Updates go through `mcp__cowork__update_artifact`. Cowork has **no delete API**, so delete degrades to a stub-HTML replacement (see Delete below).

In both modes the local HTML at `~/.waggle/views/<slug>.html` remains the canonical source — Cowork operations regenerate from it via `generate-cowork-custom-artifact.sh`.

## Resolving the Notion-query MCP tool name (Cowork operations only)

Before any `cowork` operation that calls `generate-cowork-custom-artifact.sh` or `create_artifact` / `update_artifact`, look through your available MCP tools and find the one whose unqualified name is `notion-query` and that comes from the notion-extension MCP. Its full name typically looks like `mcp__notion-extension__notion-query`, but the exact prefix depends on the installed extension version's manifest — never hardcode it. Use that exact, full tool name as the 6th argument to the generator **and** as the value in the `mcp_tools` array when registering the artifact with Cowork. If no such tool is available, surface the failure and stop — the artifact cannot operate without it. Subsequent sections refer to this as "the resolved notion-query tool name".

## Operations

### Create

When the user asks to create a custom view (e.g., "create a view showing blocked tasks by assignee", "make a dashboard for team progress"):

1. Derive a slug from the user's description (e.g., "team progress dashboard" -> `team-progress-dashboard`). See **Naming Convention** below.
2. Generate a standalone HTML file using the **Reference Template** below. The template must include the `<!-- COWORK_BOOT -->` marker inside `<head>` so Cowork-mode registration can inject the live-fetch adapter.
3. Write it to `~/.waggle/views/<slug>.html`.

**Then, depending on `execution_environment`**:

- **`cli`** / **`claude-desktop`**: confirm creation and provide the URL `http://localhost:3456/custom/<slug>.html`. Open in the browser using platform detection (see viewing-tasks skill).
- **`cowork`**: resolve `tasksDatabaseId` (and optional `current_team`) from `headless_config`. Determine the assignee to scope the view to — default to `current_user.id`; if the user explicitly asked for another person's view ("Alice's blocked tasks"), resolve via the `looking-up-members` skill and pass that Notion user ID. Also resolve the notion-query MCP tool name (see "Resolving the Notion-query MCP tool name" above) — required as the 6th argument. The generator bakes the assignee + a fixed `Status != Done`/`Cancelled` exclusion into the live-fetch adapter so the artifact's Notion query is scoped at the source:

  ```bash
  bash "${CLAUDE_SKILL_DIR}/scripts/generate-cowork-custom-artifact.sh" \
    "<slug>" "<tasksDatabaseId>" \
    "<current_team.id or empty>" "<current_team.name or empty>" \
    "<assignee notion user id, e.g. current_user.id>" \
    "<the resolved notion-query tool name>" \
    > /tmp/waggle-view-<slug>.html
  ```

  Pass an empty string for the 5th argument only if the user explicitly asked for an unscoped view across all assignees; the status exclusion still applies. Then call:

  ```
  mcp__cowork__create_artifact({
    id: "waggle-view-<slug>",
    html_path: "/tmp/waggle-view-<slug>.html",
    description: "<short description from user's request>",
    mcp_tools: ["<the resolved notion-query tool name>"]
  })
  ```

  Clean up: `rm -f /tmp/waggle-view-<slug>.html`. Tell the user to open the `waggle-view-<slug>` Live Artifact panel in the Cowork sidebar.

### List

When the user asks to list custom views:

- **`cli`** / **`claude-desktop`**:
  ```bash
  ls ~/.waggle/views/*.html 2>/dev/null
  ```
  Or use the API: `curl -s http://localhost:3456/api/views | jq`

- **`cowork`**: call `mcp__cowork__list_artifacts()` and filter the response to entries where `id == "waggle-tasks"` (the primary dashboard) or `id.startsWith("waggle-view-")` (custom views). Surface each entry's `id`, `name`, and `createdAt`. Cowork's `list_artifacts` does not return the `description` or `mcp_tools` we pass on create — all metadata lives in the `id`.

### Delete

Confirm deletion with the user before proceeding.

- **`cli`** / **`claude-desktop`**:
  ```bash
  rm ~/.waggle/views/<slug>.html
  ```

- **`cowork`**: Cowork has no delete API, and `id` is immutable across `update_artifact` calls. Degrade as follows:

  1. Remove the local source: `rm -f ~/.waggle/views/<slug>.html`.
  2. Write a stub HTML to `/tmp/waggle-view-<slug>-stub.html`:

     ```html
     <!DOCTYPE html>
     <html lang="en">
     <head>
       <meta charset="UTF-8">
       <title>View removed</title>
       <style>body{font-family:-apple-system,sans-serif;padding:32px;color:#888;}</style>
     </head>
     <body>
       <h2>This view has been removed.</h2>
       <p>Dismiss this panel via the Cowork sidebar (✕).</p>
     </body>
     </html>
     ```

  3. Call:

     ```
     mcp__cowork__update_artifact({
       id: "waggle-view-<slug>",
       html_path: "/tmp/waggle-view-<slug>-stub.html",
       update_summary: "[DELETED] <slug>"
     })
     ```

  4. Tell the user the stub will linger until they manually dismiss the panel; this is the documented Cowork limitation, not a bug.

### Regenerate

When the user asks to regenerate or update a custom view:

1. Read the existing file at `~/.waggle/views/<slug>.html` to understand what it does.
2. Generate a new version incorporating the user's feedback. Keep the `<!-- COWORK_BOOT -->` marker in `<head>`.
3. Overwrite `~/.waggle/views/<slug>.html`.

**Then, depending on `execution_environment`**:

- **`cli`** / **`claude-desktop`**: the localhost server serves the updated file on next browser refresh.
- **`cowork`**: re-run the cowork generator, then `list_artifacts` and dispatch on whether the artifact already exists — `update_artifact` if so, `create_artifact` if not. The fallback to `create_artifact` matters when the user previously deleted the view (which only sets a stub HTML) or when the local file exists but was never registered. **Assignee binding caveat**: Cowork's `list_artifacts` does not return the `assigneeUserId` baked into a previously-registered artifact, so the original scoping is irrecoverable at regenerate time. If the user originally scoped this custom view to someone other than themselves (e.g., Alice) and then asks for a plain "regenerate" without naming the assignee, the default below silently re-scopes to `current_user.id`. When in doubt, confirm with the user before defaulting — or have them re-state the assignee on the regenerate command (`/managing-views regenerate <slug> for Alice`). By default pass `current_user.id` as the 5th positional, or the Notion user ID of an explicitly-named person via the `looking-up-members` skill. Also resolve the notion-query MCP tool name (see "Resolving the Notion-query MCP tool name" above) for the 6th positional:

  ```bash
  bash "${CLAUDE_SKILL_DIR}/scripts/generate-cowork-custom-artifact.sh" \
    "<slug>" "<tasksDatabaseId>" \
    "<current_team.id or empty>" "<current_team.name or empty>" \
    "<assignee notion user id, e.g. current_user.id>" \
    "<the resolved notion-query tool name>" \
    > /tmp/waggle-view-<slug>.html
  ```

  Call `mcp__cowork__list_artifacts()` and check whether the response includes an entry with `id == "waggle-view-<slug>"`.

  **If the artifact already exists**, update it in place:

  ```
  mcp__cowork__update_artifact({
    id: "waggle-view-<slug>",
    html_path: "/tmp/waggle-view-<slug>.html",
    update_summary: "[FEAT] <one-line summary of changes>",
    mcp_tools: ["<the resolved notion-query tool name>"]
  })
  ```

  **If the artifact does not exist**, register it via create:

  ```
  mcp__cowork__create_artifact({
    id: "waggle-view-<slug>",
    html_path: "/tmp/waggle-view-<slug>.html",
    description: "<short description from user's request>",
    mcp_tools: ["<the resolved notion-query tool name>"]
  })
  ```

  Tell the user whether it was an update or a fresh registration. Clean up: `rm -f /tmp/waggle-view-<slug>.html`.

## Reference Template

When generating a custom view HTML file, use this skeleton. Fill in the visualization logic based on the user's request. **Keep the `<!-- COWORK_BOOT -->` marker in `<head>` unchanged** — the Cowork generator replaces it with the live-fetch adapter; in cli / claude-desktop it stays a harmless HTML comment.

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="view-name" content="VIEW_NAME_HERE">
  <meta name="view-description" content="VIEW_DESCRIPTION_HERE">
  <title>VIEW_NAME_HERE — Waggle</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <script>
    tailwind.config = {
      theme: {
        extend: {
          colors: {
            surface: { primary: 'rgba(28,28,30,0.8)', secondary: 'rgba(44,44,46,0.6)', tertiary: 'rgba(58,58,60,0.4)' },
            label: { primary: '#ffffff', secondary: 'rgba(235,235,245,0.6)', tertiary: 'rgba(235,235,245,0.3)' },
            accent: { blue: '#0a84ff', green: '#30d158', orange: '#ff9f0a', red: '#ff453a', purple: '#bf5af2', indigo: '#5e5ce6' },
          }
        }
      }
    }
  </script>
  <style>
    body { background: #000; font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif; -webkit-font-smoothing: antialiased; }
  </style>
  <!-- COWORK_BOOT -->
</head>
<body class="min-h-screen text-white">
  <!-- Header -->
  <header class="sticky top-0 z-50 backdrop-blur-xl bg-black/80 border-b border-white/10">
    <div class="max-w-7xl mx-auto px-6 h-14 flex items-center justify-between">
      <div class="flex items-center gap-4">
        <a href="/selector.html" class="text-label-secondary hover:text-white transition text-sm">&larr; Views</a>
        <h1 class="text-base font-semibold">VIEW_NAME_HERE</h1>
      </div>
      <div class="flex items-center gap-3">
        <span id="sse-status" class="text-xs px-2 py-1 rounded-full bg-surface-secondary text-label-tertiary">Connecting...</span>
      </div>
    </div>
  </header>

  <!-- Main content -->
  <main id="app" class="max-w-7xl mx-auto px-6 py-8">
    <p class="text-label-secondary">Loading tasks...</p>
  </main>

  <script>
    let tasks = [];

    function setStatus(text, kind) {
      const el = document.getElementById('sse-status');
      if (!el) return;
      el.textContent = text;
      el.className = 'text-xs px-2 py-1 rounded-full ' + ({
        live: 'bg-accent-green/20 text-accent-green',
        cowork: 'bg-accent-blue/20 text-accent-blue',
        error: 'bg-accent-red/20 text-accent-red',
        idle: 'bg-surface-secondary text-label-tertiary'
      }[kind] || 'bg-surface-secondary text-label-tertiary');
    }

    if (typeof window.__coworkFetch === 'function') {
      // Cowork mode — generator replaced <!-- COWORK_BOOT --> with the adapter.
      (async () => {
        setStatus('Loading…', 'idle');
        const data = await window.__coworkFetch();
        tasks = data.tasks || [];
        if (data.error) {
          setStatus('Error: ' + data.error, 'error');
          document.getElementById('app').innerHTML = '<p class="text-accent-red">Failed to load tasks: ' + data.error + '</p>';
          return;
        }
        setStatus('Live (Cowork)', 'cowork');
        render();
      })();
    } else {
      // Localhost mode — local view server + SSE.
      fetch('/api/tasks')
        .then(r => r.json())
        .then(data => {
          tasks = data.tasks || [];
          render();
        })
        .catch(() => {
          document.getElementById('app').innerHTML = '<p class="text-accent-red">Failed to load tasks.</p>';
        });

      const es = new EventSource('/api/events');
      es.addEventListener('connected', () => { setStatus('Live', 'live'); });
      es.addEventListener('refresh', (e) => {
        const data = JSON.parse(e.data);
        tasks = data.tasks || [];
        render();
      });
      es.onerror = () => { setStatus('Disconnected', 'error'); };
    }

    // Click-to-copy task ID
    document.getElementById('app').addEventListener('click', (e) => {
      const taskEl = e.target.closest('[data-task-id]');
      if (taskEl) {
        navigator.clipboard.writeText(taskEl.dataset.taskId);
        const orig = taskEl.style.outline;
        taskEl.style.outline = '2px solid rgba(10,132,255,0.5)';
        setTimeout(() => { taskEl.style.outline = orig; }, 600);
      }
    });

    function render() {
      const app = document.getElementById('app');
      if (!tasks.length) {
        app.innerHTML = '<p class="text-label-secondary">No tasks match this view.</p>';
        return;
      }
      // ===== CUSTOM VISUALIZATION LOGIC HERE =====
      // Use the `tasks` array. Each task has these fields:
      // See "Task Data Shape" below for the full interface.
      app.innerHTML = '<p class="text-label-secondary">Implement render() for this view.</p>';
    }
  </script>
</body>
</html>
```

## Task Data Shape

Each task object in the `tasks` array has these fields:

```typescript
interface Task {
  id: string;
  title: string;
  description: string;
  acceptanceCriteria: string;
  status: "Backlog" | "Ready" | "In Progress" | "In Review" | "Done" | "Blocked" | "Cancelled";
  blockedBy: string[];
  priority: "Urgent" | "High" | "Medium" | "Low";
  executor: string;           // "cli" | "claude-desktop" | "cowork" | "human" | custom
  requiresReview: boolean;
  executionPlan: string;
  workingDirectory: string;
  sessionReference: string;
  dispatchedAt: string | null;
  agentOutput: string;
  errorMessage: string;
  context: string;
  artifacts: string;
  repository: string | null;
  dueDate: string | null;
  tags: string[];
  parentTaskId: string | null;
  project: string | null;
  team: string | null;
  assignee: { id: string; name: string }[];
  acknowledgedAt: string | null;
  createdAt: string | null;
  url: string;
}
```

## Naming Convention

Derive slugs from the user's description:
- "team progress dashboard" -> `team-progress-dashboard`
- "blocked tasks by assignee" -> `blocked-tasks-by-assignee`
- "priority heatmap" -> `priority-heatmap`

Use lowercase, hyphens for spaces, remove special characters.

## Design Guidelines

- Match the existing dark theme (black background, glass-morphism surfaces)
- Use the design system colors defined in the Tailwind config above
- The back link to `/selector.html` is meaningful in localhost mode only; in Cowork it points to an artifact-internal path that won't resolve. The link can stay (harmless dead link in Cowork) or be hidden when `window.__coworkFetch` is defined.
- Include the status badge (`#sse-status`) — the template's `setStatus()` helper renders "Live" (localhost) / "Live (Cowork)" / "Disconnected" / "Error" with consistent styling.
- Make visualizations interactive where possible (hover states, click-to-copy).
- Ensure the view is responsive.
- Render the **Loading / Empty / Error** triad consistently: the template ships with "Loading…" + "No tasks match this view." + "Failed to load tasks: …" states wired up. Reuse those rather than inventing per-view variants.
