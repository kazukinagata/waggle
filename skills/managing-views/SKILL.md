---
name: managing-views
description: >
  Creates, lists, deletes, and regenerates custom task visualizations.
  Triggers on: "create view", "custom view", "make a dashboard", "view of",
  "delete view", "list views", "regenerate view", "my view",
  "ビュー作成", "カスタムビュー", "ダッシュボード作成".
user-invocable: true
---

# Agentic Tasks — Custom View Management

You manage custom task visualizations that users can create via natural language.

## Provider Detection (once per session)

Load `${CLAUDE_PLUGIN_ROOT}/skills/detecting-provider/SKILL.md` and follow its instructions to determine `active_provider`. Skip if already determined in this conversation.

## Directory Setup

Custom views are stored outside the plugin directory so they survive updates:

```bash
mkdir -p ~/.agentic-tasks/views
```

## Operations

### Create

When the user asks to create a custom view (e.g., "create a view showing blocked tasks by assignee", "make a dashboard for team progress"):

1. Derive a slug from the user's description (e.g., "team progress dashboard" -> `team-progress-dashboard`)
2. Generate a standalone HTML file using the **Reference Template** below
3. Write it to `~/.agentic-tasks/views/<slug>.html`
4. Confirm creation and provide the URL: `http://localhost:3456/custom/<slug>.html`
5. Open the view in the browser using platform detection (see viewing-tasks skill)

### List

When the user asks to list custom views:

```bash
ls ~/.agentic-tasks/views/*.html 2>/dev/null
```

Or use the API: `curl -s http://localhost:3456/api/views | jq`

### Delete

When the user asks to delete a custom view:

```bash
rm ~/.agentic-tasks/views/<slug>.html
```

Confirm deletion with the user before removing.

### Regenerate

When the user asks to regenerate or update a custom view:

1. Read the existing file to understand what it does
2. Generate a new version incorporating the user's feedback
3. Overwrite the file at `~/.agentic-tasks/views/<slug>.html`
4. The view will update on next browser refresh

## Reference Template

When generating a custom view HTML file, use this skeleton. Fill in the visualization logic based on the user's request.

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="view-name" content="VIEW_NAME_HERE">
  <meta name="view-description" content="VIEW_DESCRIPTION_HERE">
  <title>VIEW_NAME_HERE — Agentic Tasks</title>
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

    // Check for static mode
    if (window.__STATIC_DATA__) {
      tasks = window.__STATIC_DATA__.tasks || [];
      document.getElementById('sse-status').textContent = 'Static';
      document.getElementById('sse-status').classList.add('bg-accent-orange/20', 'text-accent-orange');
      render();
    } else {
      // Fetch initial data
      fetch('/api/tasks')
        .then(r => r.json())
        .then(data => {
          tasks = data.tasks || [];
          render();
        })
        .catch(() => {
          document.getElementById('app').innerHTML = '<p class="text-accent-red">Failed to load tasks.</p>';
        });

      // SSE for real-time updates
      const es = new EventSource('/api/events');
      es.addEventListener('connected', () => {
        const el = document.getElementById('sse-status');
        el.textContent = 'Live';
        el.className = 'text-xs px-2 py-1 rounded-full bg-accent-green/20 text-accent-green';
      });
      es.addEventListener('refresh', (e) => {
        const data = JSON.parse(e.data);
        tasks = data.tasks || [];
        render();
      });
      es.onerror = () => {
        const el = document.getElementById('sse-status');
        el.textContent = 'Disconnected';
        el.className = 'text-xs px-2 py-1 rounded-full bg-accent-red/20 text-accent-red';
      };
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
  status: "Backlog" | "Ready" | "In Progress" | "In Review" | "Done" | "Blocked";
  blockedBy: string[];
  priority: "Urgent" | "High" | "Medium" | "Low";
  executor: string;           // "claude-code" | "cowork" | "human" | custom
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
  assignees: { id: string; name: string }[];
  url: string;
  complexityScore?: number | null;
  sprintId?: string | null;
  backlogOrder?: number | null;
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
- Keep the header consistent with back link to `/selector.html`
- Include SSE status indicator
- Make visualizations interactive where possible (hover states, click-to-copy)
- Ensure the view is responsive
