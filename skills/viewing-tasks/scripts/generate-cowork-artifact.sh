#!/usr/bin/env bash
# generate-cowork-artifact.sh
#
# Bundles the four view HTMLs (kanban / list / calendar / gantt) into a single
# Cowork Live Artifact. The output is a self-contained HTML document that
# fetches Notion data via window.cowork.callMcpTool("...notion-query", ...)
# and renders one of the four views via a top tab strip.
#
# Usage:
#   generate-cowork-artifact.sh <tasksDatabaseId> [team_id] [team_name] [assignee_user_id]
#
# Output: writes the standalone HTML to stdout.
#
# When [assignee_user_id] is provided, the bundle's runtime fetch is scoped
# server-side to that assignee (people.contains). Status is always restricted
# to non-terminal — Done and Cancelled are excluded by a fixed select clause.
# When [assignee_user_id] is empty, the Assignee predicate is omitted (degraded
# unscoped mode); the status exclusion still applies.
#
# See skills/viewing-tasks/SKILL.md "Cowork Live Artifact Mode" for the
# protocol-level invocation. The generator enforces structural invariants
# (DOCTYPE / charset / IIFE wrap) and exits non-zero on any failure.

set -euo pipefail

DB_ID="${1:?Usage: generate-cowork-artifact.sh <tasksDatabaseId> [team_id] [team_name] [assignee_user_id]}"
TEAM_ID="${2:-}"
TEAM_NAME="${3:-}"
ASSIGNEE_USER_ID="${4:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATIC_DIR="$SCRIPT_DIR/../server/static"

VIEWS=(kanban list calendar gantt)
ASSETS=(shared.css shared.js filter-bar.css filter-bar.js detail-panel.css detail-panel.js)

# ── Pre-flight validation ─────────────────────────────────────────────────

for v in "${VIEWS[@]}"; do
  f="$STATIC_DIR/${v}.html"
  if [ ! -f "$f" ]; then
    echo "Error: Missing view template: $f" >&2
    exit 1
  fi
  if ! head -3 "$f" | grep -qi '<!doctype html>'; then
    echo "Error: $f missing <!DOCTYPE html> (mojibake guard)" >&2
    exit 1
  fi
  if ! grep -qi '<meta charset="utf-8">' "$f"; then
    echo "Error: $f missing <meta charset=\"UTF-8\"> (mojibake guard)" >&2
    exit 1
  fi
done

for a in "${ASSETS[@]}"; do
  if [ ! -f "$STATIC_DIR/$a" ]; then
    echo "Error: Missing shared asset: $STATIC_DIR/$a" >&2
    exit 1
  fi
done

# ── Helpers ───────────────────────────────────────────────────────────────

# Extract per-view inline <style> body (between the inline <style> opening
# and </style>). Returns CSS only — the wrapping <style>/</style> tags are
# stripped so they don't terminate the bundle's outer <style> early.
extract_view_style() {
  awk '
    /<link rel="stylesheet" href="detail-panel\.css">/ { gate=1; next }
    gate && /^[[:space:]]*<style>[[:space:]]*$/ { active=1; next }
    active && /^[[:space:]]*<\/style>[[:space:]]*$/ { exit }
    active { print }
  ' "$1"
}

# Extract the view-specific body content. Starts at `</header>` so view-pane
# chrome that lives between the shared header and the filter-bar (e.g. the
# calendar nav-bar with prev/next/today buttons) is included. Stops at
# `<div class="toast"`. The `<div id="filter-bar"></div>` line is filtered
# out so the shared filter-bar isn't duplicated across panes.
extract_view_body() {
  awk '
    /<\/header>/ { active=1; next }
    active && /<div class="toast"/ { exit }
    active && /^[[:space:]]*<div id="filter-bar"><\/div>[[:space:]]*$/ { next }
    active { print }
  ' "$1"
}

# Extract the inline <script> body — the first bare `^<script>$` line (no
# src attribute, no inline JSON props). This matches all four current view
# HTMLs, each of which has exactly one such block after the three
# `<script src="...">` external loads. If a view ever adds a second inline
# block, the render_count==4 self-test below will fail to surface it.
extract_view_inline_script() {
  awk '
    /^<script>[[:space:]]*$/ { in_script=1; next }
    in_script && /^<\/script>/ { exit }
    in_script { print }
  ' "$1"
}

# Scope per-view "broad" CSS selectors that start with `body` or `main` to the
# view's pane attribute so they do not leak across panes when bundled. Catches:
#   body { … }              → [data-view-pane="<view>"] { … }
#   body.foo { … }          → [data-view-pane="<view>"].foo { … }
#   body .foo { … }         → [data-view-pane="<view>"] .foo { … }
#   body > .foo { … }       → [data-view-pane="<view>"] > .foo { … }
#   main { … }              → [data-view-pane="<view>"] main { … }
#   main .foo { … }         → [data-view-pane="<view>"] main .foo { … }
# The trigger is `body` or `main` as a whole word at the start of a selector
# line (after optional indentation), followed by any non-identifier character.
# Other rules use unique class names and need no rewriting.
scope_view_style() {
  local view="$1"
  awk -v view="$view" '
    /^[[:space:]]*body([^a-zA-Z0-9_-]|$)/ {
      sub(/body/, "[data-view-pane=\"" view "\"]")
      print; next
    }
    /^[[:space:]]*main([^a-zA-Z0-9_-]|$)/ {
      sub(/main/, "[data-view-pane=\"" view "\"] main")
      print; next
    }
    { print }
  '
}

# Per-view DOM ID collision rewrites. Currently only `id="empty"` collides
# (both list.html and gantt.html ship an empty-state pane with that id, and
# their inline scripts call `document.getElementById('empty')`). Rename
# gantt's `empty` so list's stays the first match. Extend this function if
# more collisions appear.
rewrite_view_ids() {
  local view="$1"
  case "$view" in
    gantt)
      sed -E \
        -e 's#id="empty"#id="gantt-empty"#g' \
        -e "s#getElementById\\('empty'\\)#getElementById('gantt-empty')#g" \
        -e 's#getElementById\("empty"\)#getElementById("gantt-empty")#g'
      ;;
    *)
      cat
      ;;
  esac
}

# Drop `W.initKeyboard({ ... });` blocks from per-view scripts. `shared.js`
# stores keyboard state in one singleton, so bundling four views would have
# the last view's call clobber earlier ones. The bundled artifact installs
# a single tab-aware keyboard binding later; per-view calls must be stripped.
strip_init_keyboard() {
  awk '
    /W\.initKeyboard[[:space:]]*\(/ {
      in_keyboard=1
    }
    in_keyboard {
      if (match($0, /\}\)[[:space:]]*;/)) {
        in_keyboard=0
      }
      next
    }
    { print }
  '
}

# Wrap a view's inline script body in an IIFE with the defensive preamble.
# Rewrites `W.onDataUpdate = render` → multiplex push, strips per-view
# `W.initData()` calls, and strips `W.initKeyboard(...)` blocks (one
# bundle-level keyboard binding takes over). Use `#` as the sed delimiter
# so the `||` in the replacement doesn't collide.
wrap_view_script() {
  local view="$1"
  printf '<script>(function () {\n'
  printf '  // Cowork bundle preamble (view: %s)\n' "$view"
  printf '  var W = window.Waggle = window.Waggle || {};\n'
  printf '  W._renderers = W._renderers || [];\n'
  strip_init_keyboard | sed -E \
    -e 's#W\.onDataUpdate[[:space:]]*=[[:space:]]*render[[:space:]]*;#(W._renderers = W._renderers || []).push(render);#' \
    -e '/^[[:space:]]*W\.initData\(\)[[:space:]]*;[[:space:]]*$/d'
  printf '})();</script>\n'
}

# ── Build inlined shared assets (single read each) ───────────────────────

SHARED_CSS=$(cat "$STATIC_DIR/shared.css")
SHARED_JS=$(cat "$STATIC_DIR/shared.js")
FILTER_CSS=$(cat "$STATIC_DIR/filter-bar.css")
FILTER_JS=$(cat "$STATIC_DIR/filter-bar.js")
DETAIL_CSS=$(cat "$STATIC_DIR/detail-panel.css")
DETAIL_JS=$(cat "$STATIC_DIR/detail-panel.js")

# The COWORK_QUERY_CONFIG JSON block is emitted inline below from Python
# (see the "Cowork query config + adapter" section). DB_ID / TEAM_ID /
# TEAM_NAME flow from agent-resolved values; never trust raw string
# interpolation into JS. Python json.dumps escapes quotes / backslashes /
# unicode correctly. Building the block in Python also bypasses bash heredoc
# expansion entirely.

# ── Emit the bundle ──────────────────────────────────────────────────────

OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

{
  cat <<'HTML_HEAD'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Waggle — Tasks Dashboard</title>
  <style>
HTML_HEAD

  # Shared CSS (always first)
  printf '/* shared.css */\n'
  printf '%s\n' "$SHARED_CSS"
  printf '/* filter-bar.css */\n'
  printf '%s\n' "$FILTER_CSS"
  printf '/* detail-panel.css */\n'
  printf '%s\n' "$DETAIL_CSS"

  # Per-view styles, scoped to data-view-pane
  for v in "${VIEWS[@]}"; do
    printf '/* per-view CSS: %s (scoped) */\n' "$v"
    extract_view_style "$STATIC_DIR/${v}.html" | scope_view_style "$v"
  done

  # Tab strip + view-pane visibility
  cat <<'TAB_CSS'

/* Cowork tab strip (added by generate-cowork-artifact.sh) */
.tab-strip { display: flex; gap: 4px; padding: 0 24px; border-bottom: 0.5px solid var(--separator); background: var(--surface-primary); }
.tab-strip button { background: none; border: none; padding: 10px 14px; font-size: 13px; color: var(--label-secondary); cursor: pointer; border-bottom: 2px solid transparent; }
.tab-strip button:hover { color: var(--label-primary); }
.tab-strip button.active { color: var(--label-primary); border-bottom-color: var(--accent-blue, #4f8df0); font-weight: 600; }
[data-view-pane][hidden] { display: none !important; }
.cowork-banner { padding: 8px 24px; font-size: 12px; color: var(--label-secondary); background: var(--surface-secondary); border-bottom: 0.5px solid var(--separator); }
TAB_CSS

  printf '  </style>\n'
  printf '</head>\n'
  printf '<body>\n'

  # ── Shared header ──
  cat <<'HEADER_HTML'
<header>
  <div class="header-title-group">
    <h1>Tasks</h1>
    <div class="header-meta">
      <div class="sse-indicator">
        <span class="sse-dot disconnected" id="sse-dot"></span>
        <span id="sse-status">Connecting...</span>
      </div>
      <div class="header-stats">
        <span class="task-count" id="task-count"></span>
        <span id="updated-at"></span>
      </div>
      <button class="refresh-btn" id="refresh-btn" onclick="Waggle.refreshTasks()" title="Refresh"><span class="refresh-icon">&#x21BB;</span></button>
    </div>
  </div>
</header>

<nav class="tab-strip" id="waggle-tabs" role="tablist">
  <button type="button" data-tab="kanban" role="tab" aria-selected="true">Kanban</button>
  <button type="button" data-tab="list" role="tab">List</button>
  <button type="button" data-tab="calendar" role="tab">Calendar</button>
  <button type="button" data-tab="gantt" role="tab">Gantt</button>
</nav>

<div id="cowork-status-banner" class="cowork-banner" hidden></div>

<div id="filter-bar"></div>
HEADER_HTML

  # ── View panes ──
  for v in "${VIEWS[@]}"; do
    printf '<section data-view-pane="%s" hidden>\n' "$v"
    extract_view_body "$STATIC_DIR/${v}.html" | rewrite_view_ids "$v"
    printf '</section>\n'
  done

  # ── Shared toast ──
  printf '<div class="toast" id="toast"></div>\n'

  # ── Inline shared JS ──
  printf '<script>\n/* shared.js */\n'
  printf '%s\n' "$SHARED_JS"
  printf '</script>\n'
  printf '<script>\n/* filter-bar.js */\n'
  printf '%s\n' "$FILTER_JS"
  printf '</script>\n'
  printf '<script>\n/* detail-panel.js */\n'
  printf '%s\n' "$DETAIL_JS"
  printf '</script>\n'

  # ── Cowork query config + adapter ──
  # Emit the config block entirely from Python to bypass bash heredoc
  # interpolation. bash heredocs only do a single expansion pass, so any
  # `$X` patterns inside the JSON would survive intact today — but a future
  # maintainer adding a literal `$X` or backtick to the body would get a
  # surprise. Building the block in Python removes the foot-gun entirely.
  python3 -c '
import json, sys
db = sys.argv[1]
team_id = sys.argv[2] or ""
team_name = sys.argv[3] or ""
assignee_user_id = sys.argv[4] or ""
team = {"id": team_id, "name": team_name} if (team_id and team_name) else None
cfg = {
    "databaseId": db,
    "currentTeam": team,
    "assigneeUserId": assignee_user_id or None,
}
print("<script>")
print("window.__COWORK_QUERY_CONFIG__ = " + json.dumps(cfg, ensure_ascii=False) + ";")
print("</script>")
' "$DB_ID" "$TEAM_ID" "$TEAM_NAME" "$ASSIGNEE_USER_ID"

  cat <<'COWORK_ADAPTER'
<script>
/* Cowork live-fetch adapter (injected by generate-cowork-artifact.sh) */
(function () {
  'use strict';

  var COLD_START_TIMEOUT_MS = 3000;
  var COLD_START_POLL_INTERVAL_MS = 50;
  var PAGE_SIZE = 100;
  var MAX_ROWS = 1000;

  function setBanner(msg, kind) {
    var el = document.getElementById('cowork-status-banner');
    if (!el) return;
    if (!msg) { el.hidden = true; el.textContent = ''; return; }
    el.hidden = false;
    el.textContent = msg;
    el.dataset.kind = kind || 'info';
  }

  function setStatus(text, live) {
    var status = document.getElementById('sse-status');
    var dot = document.getElementById('sse-dot');
    if (status) status.textContent = text;
    if (dot) {
      if (live) dot.classList.remove('disconnected');
      else dot.classList.add('disconnected');
    }
  }

  function waitForCowork() {
    return new Promise(function (resolve, reject) {
      var start = Date.now();
      (function poll() {
        if (window.cowork && typeof window.cowork.callMcpTool === 'function') {
          resolve();
        } else if (Date.now() - start > COLD_START_TIMEOUT_MS) {
          reject(new Error('Cowork runtime unavailable (timed out after ' + COLD_START_TIMEOUT_MS + 'ms). Reload the panel, or call any Notion MCP tool from the Cowork chat once before reopening this artifact.'));
        } else {
          setTimeout(poll, COLD_START_POLL_INTERVAL_MS);
        }
      })();
    });
  }

  // Defensive unwrap — callMcpTool returns one of several shapes.
  function extractJson(maybe) {
    var v = maybe;
    if (v && typeof v === 'object' && Array.isArray(v.content)) {
      var textPart = v.content.find(function (c) { return c && c.type === 'text' && typeof c.text === 'string'; });
      if (textPart) v = textPart.text;
    }
    if (typeof v === 'string' && (v.indexOf('Tool call failed') === 0 || v.indexOf('Error:') === 0)) {
      throw new Error(v);
    }
    if (v && typeof v === 'object' && (v.results || v.object === 'list')) return v;
    if (typeof v !== 'string') v = JSON.stringify(v);
    var first = v.indexOf('{');
    var last = v.lastIndexOf('}');
    if (first < 0 || last <= first) throw new Error('No JSON span in MCP response: ' + v.slice(0, 200));
    return JSON.parse(v.substring(first, last + 1));
  }

  function rtText(rt) {
    if (!Array.isArray(rt)) return '';
    return rt.map(function (x) { return x.plain_text || ''; }).join('');
  }

  function parseNotionPageToTask(p) {
    var props = p.properties || {};
    var pick = function (k) { return props[k] || {}; };
    return {
      id: p.id,
      url: p.url || null,
      title: ((pick('Title').title) || []).map(function (x) { return x.plain_text || ''; }).join(''),
      description: rtText(pick('Description').rich_text),
      acceptanceCriteria: rtText(pick('Acceptance Criteria').rich_text),
      status: (pick('Status').select && pick('Status').select.name) || 'Backlog',
      blockedBy: (pick('Blocked By').relation || []).map(function (r) { return r.id; }),
      priority: (pick('Priority').select && pick('Priority').select.name) || null,
      executor: (pick('Executor').select && pick('Executor').select.name) || null,
      requiresReview: pick('Requires Review').checkbox === true,
      executionPlan: rtText(pick('Execution Plan').rich_text),
      workingDirectory: rtText(pick('Working Directory').rich_text),
      sessionReference: rtText(pick('Session Reference').rich_text),
      dispatchedAt: (pick('Dispatched At').date && pick('Dispatched At').date.start) || null,
      agentOutput: rtText(pick('Agent Output').rich_text),
      errorMessage: rtText(pick('Error Message').rich_text),
      context: rtText(pick('Context').rich_text),
      artifacts: rtText(pick('Artifacts').rich_text),
      repository: pick('Repository').url || null,
      dueDate: (pick('Due Date').date && pick('Due Date').date.start) || null,
      tags: (pick('Tags').multi_select || []).map(function (t) { return t.name; }),
      parentTaskId: ((pick('Parent Task').relation || [])[0] || {}).id || null,
      project: (pick('Project').select && pick('Project').select.name) || null,
      team: (pick('Team').select && pick('Team').select.name) || null,
      assignee: (pick('Assignee').people || []).map(function (u) { return { id: u.id, name: u.name || '' }; }),
      acknowledgedAt: (pick('Acknowledged At').date && pick('Acknowledged At').date.start) || null,
      createdAt: pick('Created At').created_time || p.created_time || null
    };
  }

  // Build the Notion filter object. Status is always restricted to
  // non-terminal (Done / Cancelled excluded). When assigneeUserId is set,
  // narrow further to "Assignee contains <id>". An empty assigneeUserId
  // means degraded unscoped mode — status-only filtering — so the artifact
  // still renders something rather than silently going blank.
  function buildFilter(assigneeUserId) {
    var clauses = [
      { property: 'Status', select: { does_not_equal: 'Done' } },
      { property: 'Status', select: { does_not_equal: 'Cancelled' } }
    ];
    if (assigneeUserId) {
      clauses.unshift({ property: 'Assignee', people: { contains: assigneeUserId } });
    }
    return { and: clauses };
  }

  async function paginatedQuery(databaseId, assigneeUserId) {
    var filter = buildFilter(assigneeUserId);
    var rows = [];
    var cursor;
    var truncated = false;
    var loops = 0;
    while (true) {
      loops++;
      if (loops > 20) break;
      var args = { database_id: databaseId, page_size: PAGE_SIZE, filter: filter };
      if (cursor) args.start_cursor = cursor;
      var res = await window.cowork.callMcpTool('mcp__Notion_Extension_for_Waggle__notion-query', args);
      var data = extractJson(res);
      var results = data.results || [];
      for (var i = 0; i < results.length && rows.length < MAX_ROWS; i++) rows.push(results[i]);
      if (rows.length >= MAX_ROWS) { truncated = true; break; }
      if (!data.has_more) break;
      cursor = data.next_cursor;
      if (!cursor) break;
    }
    return { rows: rows, truncated: truncated };
  }

  // Returns `true` when fresh data was painted, `false` when an error banner
  // was surfaced. shared.js's refreshTasks() reads this to decide whether to
  // fire the "Refreshed" toast — silencing it on the false branch so the
  // toast doesn't contradict the visible banner.
  async function coworkFetch() {
    setStatus('Loading…', false);
    setBanner('');
    try {
      await waitForCowork();
    } catch (e) {
      setStatus('Error', false);
      setBanner(e.message || String(e), 'error');
      return false;
    }
    var cfg = window.__COWORK_QUERY_CONFIG__ || {};
    if (!cfg.databaseId) {
      setStatus('Error', false);
      setBanner('Missing tasksDatabaseId — regenerate the artifact via /viewing-tasks.', 'error');
      return false;
    }
    try {
      var out = await paginatedQuery(cfg.databaseId, cfg.assigneeUserId);
      var tasks = out.rows.map(parseNotionPageToTask);
      if (window.Waggle && typeof window.Waggle.updateData === 'function') {
        window.Waggle.updateData({ tasks: tasks, updatedAt: new Date().toISOString(), currentTeam: cfg.currentTeam || null });
      }
      setStatus('Live (Cowork)', true);
      if (out.truncated) {
        var scope = cfg.assigneeUserId ? 'open tasks for the configured assignee' : 'open tasks';
        setBanner('Showing first ' + MAX_ROWS + ' ' + scope + ' (cap exceeded).', 'warn');
      } else if (!cfg.assigneeUserId) {
        setBanner('Showing all open tasks (no assignee configured — regenerate via /viewing-tasks to scope).', 'info');
      }
      return true;
    } catch (e) {
      setStatus('Error', false);
      setBanner('Failed to load tasks: ' + (e.message || String(e)), 'error');
      return false;
    }
  }

  window.__coworkFetch = coworkFetch;
})();
</script>
COWORK_ADAPTER

  # ── Tab switcher + visibility controller ──
  cat <<'TAB_JS'
<script>
(function () {
  'use strict';
  var STORAGE_KEY = 'waggle-tasks-active-tab-v1';
  var DEFAULT_TAB = 'kanban';
  var VIEWS = ['kanban', 'list', 'calendar', 'gantt'];

  function readTab() {
    try {
      var v = window.localStorage.getItem(STORAGE_KEY);
      if (v && VIEWS.indexOf(v) !== -1) return v;
    } catch (e) {}
    return DEFAULT_TAB;
  }

  function writeTab(v) {
    try { window.localStorage.setItem(STORAGE_KEY, v); } catch (e) {}
  }

  function showTab(v) {
    var panes = document.querySelectorAll('[data-view-pane]');
    for (var i = 0; i < panes.length; i++) {
      panes[i].hidden = (panes[i].getAttribute('data-view-pane') !== v);
    }
    var btns = document.querySelectorAll('#waggle-tabs button');
    for (var j = 0; j < btns.length; j++) {
      var on = btns[j].getAttribute('data-tab') === v;
      btns[j].classList.toggle('active', on);
      btns[j].setAttribute('aria-selected', on ? 'true' : 'false');
    }
  }

  document.addEventListener('click', function (e) {
    var btn = e.target.closest && e.target.closest('#waggle-tabs button[data-tab]');
    if (!btn) return;
    var v = btn.getAttribute('data-tab');
    writeTab(v);
    showTab(v);
  });

  // Initial tab restore — must run before W.initData() so renderers paint into
  // the visible pane on first paint.
  showTab(readTab());
})();
</script>
TAB_JS

  # ── Per-view IIFE-wrapped scripts ──
  # rewrite_view_ids runs on the script content too so `getElementById` calls
  # that reference renamed IDs stay paired with their elements.
  for v in "${VIEWS[@]}"; do
    extract_view_inline_script "$STATIC_DIR/${v}.html" | rewrite_view_ids "$v" | wrap_view_script "$v"
  done

  # ── Bundle-level keyboard binding (replaces stripped per-view W.initKeyboard) ──
  # shared.js's W.initKeyboard wires a single document-level key handler against
  # a singleton state. Bundling four views would clobber that state to whichever
  # view called initKeyboard last. Install one keyboard binding here that
  # dispatches to the active tab's renderer surface.
  cat <<'KEYBOARD_JS'
<script>
(function () {
  'use strict';
  function activeView() {
    var panes = document.querySelectorAll('[data-view-pane]');
    for (var i = 0; i < panes.length; i++) {
      if (!panes[i].hidden) return panes[i].getAttribute('data-view-pane');
    }
    return null;
  }
  function activeFilteredTaskIds() {
    var W = window.Waggle;
    if (!W || typeof W.getFiltered !== 'function') return [];
    return W.getFiltered().map(function (t) { return t.id; });
  }
  function activeTaskElement(taskId) {
    var v = activeView();
    if (!v) return null;
    var pane = document.querySelector('[data-view-pane="' + v + '"]');
    if (!pane) return null;
    return pane.querySelector('[data-task-id="' + taskId + '"]');
  }
  if (window.Waggle && typeof window.Waggle.initKeyboard === 'function') {
    window.Waggle.initKeyboard({
      getNavigableTasks: activeFilteredTaskIds,
      getTaskElement: activeTaskElement
    });
  }
})();
</script>
KEYBOARD_JS

  # ── Trailing global init ──
  cat <<'TRAILER'
<script>
(function () {
  if (window.Waggle && typeof window.Waggle.initData === 'function') {
    window.Waggle.initData();
  }
})();
</script>
</body>
</html>
TRAILER
} > "$OUT"

# ── Self-test ─────────────────────────────────────────────────────────────

iife_count=$(grep -c '^<script>(function ()' "$OUT" || true)
if [ "$iife_count" -lt 4 ]; then
  echo "Self-test FAILED: expected >=4 IIFE-wrapped view scripts, got $iife_count" >&2
  exit 1
fi

preamble_count=$(grep -c 'var W = window.Waggle = window.Waggle || {};' "$OUT" || true)
if [ "$preamble_count" -lt 4 ]; then
  echo "Self-test FAILED: expected >=4 defensive preambles, got $preamble_count" >&2
  exit 1
fi

# Every view contributes exactly one `function render(` to the bundle. With 4
# IIFE openings + 4 defensive preambles in place above, having exactly 4
# `function render(` declarations proves each render is paired with one IIFE.
# A higher count would mean a view inlined helpers named `render`; a lower
# count means a view's script was lost during bundling.
render_count=$(grep -cE 'function render[[:space:]]*\(' "$OUT" || true)
if [ "$render_count" -ne 4 ]; then
  echo "Self-test FAILED: expected exactly 4 'function render(' declarations, got $render_count" >&2
  exit 1
fi

# Every per-view W.onDataUpdate=render must be rewritten to the multiplex push.
# If sed missed one, that view's renderer wouldn't subscribe.
if grep -q 'W\.onDataUpdate = render' "$OUT"; then
  echo "Self-test FAILED: leftover 'W.onDataUpdate = render' — multiplex rewrite incomplete" >&2
  exit 1
fi

push_count=$(grep -c '(W._renderers = W._renderers || \[\]).push(render);' "$OUT" || true)
if [ "$push_count" -lt 4 ]; then
  echo "Self-test FAILED: expected >=4 multiplex push calls, got $push_count" >&2
  exit 1
fi

if ! head -3 "$OUT" | grep -qi '<!doctype html>'; then
  echo "Self-test FAILED: output missing <!DOCTYPE html>" >&2
  exit 1
fi

if ! grep -qi '<meta charset="utf-8">' "$OUT"; then
  echo "Self-test FAILED: output missing <meta charset=\"UTF-8\">" >&2
  exit 1
fi

# Stylesheet integrity: there must be exactly ONE outer <style>...</style>
# pair. Extra closing tags would mean a per-view <style> was inlined intact
# and prematurely terminated the bundle stylesheet.
style_open=$(grep -c '^[[:space:]]*<style>[[:space:]]*$' "$OUT" || true)
style_close=$(grep -c '^[[:space:]]*</style>[[:space:]]*$' "$OUT" || true)
if [ "$style_open" -ne 1 ] || [ "$style_close" -ne 1 ]; then
  echo "Self-test FAILED: expected exactly one <style>/</style> pair, got open=$style_open close=$style_close" >&2
  exit 1
fi

# DOM ID uniqueness for the IDs we explicitly bake into the bundle. Each must
# appear exactly once after rewrite_view_ids resolves known collisions.
for id in empty gantt-empty tbody board calendar-container gantt-container; do
  count=$(grep -oE "id=\"$id\"" "$OUT" | wc -l)
  if [ "$count" -gt 1 ]; then
    echo "Self-test FAILED: id=\"$id\" appears $count times (must be unique)" >&2
    exit 1
  fi
done

# Per-view W.initKeyboard calls must be stripped — the single bundle-level
# keyboard binding takes over. shared.js's `W.initKeyboard = function ...`
# definition is exempt (one match expected).
per_view_init_keyboard=$(grep -c '^[[:space:]]\+W\.initKeyboard(' "$OUT" || true)
# Bundle-level binding starts at column 4 (`    window.Waggle.initKeyboard({`)
# so it's NOT counted by the per-view pattern above.
if [ "$per_view_init_keyboard" -ne 0 ]; then
  echo "Self-test FAILED: $per_view_init_keyboard leftover W.initKeyboard(...) calls — strip_init_keyboard missed something" >&2
  grep -n '^[[:space:]]\+W\.initKeyboard(' "$OUT" >&2 || true
  exit 1
fi

# Filter wiring: the baked config must carry the assigneeUserId key, and the
# adapter's buildFilter must include the fixed Done/Cancelled exclusions. If
# any future refactor drops the filter, these assertions fire so the artifact
# can never silently revert to "fetch every row in the workspace".
if ! grep -q '"assigneeUserId"' "$OUT"; then
  echo "Self-test FAILED: config block missing assigneeUserId key" >&2
  exit 1
fi

if ! grep -q "does_not_equal: 'Done'" "$OUT"; then
  echo "Self-test FAILED: Status != Done clause missing from buildFilter" >&2
  exit 1
fi

if ! grep -q "does_not_equal: 'Cancelled'" "$OUT"; then
  echo "Self-test FAILED: Status != Cancelled clause missing from buildFilter" >&2
  exit 1
fi

cat "$OUT"
